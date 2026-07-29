[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet("init", "check", "context", "append-log", "rotate", "help")]
    [string]$Command = "help",

    [Parameter(Position = 1)]
    [string]$Project = ".",

    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Arguments
)

$ErrorActionPreference = "Stop"
$TemplatesDir = Join-Path $PSScriptRoot "..\templates"
$DocsDir = Join-Path $Project "docs"
$RequiredFiles = @(
    "Agents.md",
    "Agentslog.md",
    "ProductDescription.md",
    "Stack_Tecnologies.md",
    "Roadmap.md",
    "Features.md"
)
$ContextLimit = 8192
$LogBytesLimit = 131072
$LogEntriesLimit = 200
$Utf8 = [System.Text.UTF8Encoding]::new($false)

function Write-Utf8File([string]$Path, [string]$Content) {
    [System.IO.File]::WriteAllText($Path, $Content, $script:Utf8)
}

function Invoke-Init {
    if (-not (Test-Path -LiteralPath $TemplatesDir -PathType Container)) {
        throw "templates directory not found: $TemplatesDir"
    }
    New-Item -ItemType Directory -Path $DocsDir -Force | Out-Null
    $created = 0
    foreach ($file in $RequiredFiles) {
        $target = Join-Path $DocsDir $file
        if (Test-Path -LiteralPath $target -PathType Leaf) {
            Write-Output "= preserved: docs/$file"
        } else {
            Copy-Item -LiteralPath (Join-Path $TemplatesDir $file) -Destination $target
            Write-Output "+ created: docs/$file"
            $created++
        }
    }
    Write-Output "project_docs init: $created file(s) created"
}

function Get-ContextBlock([string]$Path, [string]$Heading) {
    $lines = Get-Content -LiteralPath $Path
    $start = [Array]::IndexOf($lines, $Heading)
    if ($start -lt 0) { return @() }
    $result = [System.Collections.Generic.List[string]]::new()
    for ($i = $start; $i -lt $lines.Count; $i++) {
        $result.Add($lines[$i])
        if ($lines[$i] -eq "<!-- context:end -->") { break }
    }
    return $result
}

function Get-LatestEntries {
    $lines = @(Get-Content -LiteralPath (Join-Path $DocsDir "Agentslog.md"))
    $entriesSection = [Array]::IndexOf($lines, "## Entries")
    if ($entriesSection -lt 0) { return @() }
    $starts = @(
        for ($i = $entriesSection + 1; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match '^## \[') { $i }
        }
    )
    if ($starts.Count -eq 0) { return @() }
    $first = $starts[[Math]::Max(0, $starts.Count - 5)]
    return $lines[$first..($lines.Count - 1)]
}

function Get-LogEntryCount([string]$Path) {
    $lines = @(Get-Content -LiteralPath $Path)
    $entriesSection = [Array]::IndexOf($lines, "## Entries")
    if ($entriesSection -lt 0) { return 0 }
    return @(
        for ($i = $entriesSection + 1; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match '^## \[') { $i }
        }
    ).Count
}

function Get-HotContext {
    $agents = Join-Path $DocsDir "Agents.md"
    if (-not (Test-Path -LiteralPath $agents -PathType Leaf)) {
        throw "run init first"
    }
    $parts = [System.Collections.Generic.List[string]]::new()
    foreach ($line in @(Get-Content -LiteralPath $agents)) {
        $parts.Add([string]$line)
    }
    foreach ($item in @(
        @("ProductDescription.md", "## Operational summary"),
        @("Stack_Tecnologies.md", "## Operational summary"),
        @("Features.md", "## Operational summary"),
        @("Roadmap.md", "## Active work")
    )) {
        $parts.Add("")
        foreach ($line in @(Get-ContextBlock (Join-Path $DocsDir $item[0]) $item[1])) {
            $parts.Add([string]$line)
        }
    }
    $parts.Add("")
    $parts.Add("## Latest agent entries")
    foreach ($line in @(Get-LatestEntries)) {
        $parts.Add([string]$line)
    }
    $content = ($parts -join "`n") + "`n"
    $bytes = $Utf8.GetByteCount($content)
    if ($bytes -gt $ContextLimit) {
        throw "hot context is $bytes bytes; compact summaries below $ContextLimit"
    }
    return $content
}

function Invoke-Check {
    $requirements = @{
        "Agents.md" = @("## Repository rules", "## Startup", "## Close")
        "Agentslog.md" = @("## Entry format", "## Entries")
        "ProductDescription.md" = @("## Operational summary", "## Business rules")
        "Stack_Tecnologies.md" = @("## Operational summary", "## Decisions")
        "Roadmap.md" = @("## Active work", "## Near term")
        "Features.md" = @("## Operational summary", "## Verified capabilities")
    }
    $fail = $false
    foreach ($file in $RequiredFiles) {
        $path = Join-Path $DocsDir $file
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            Write-Error "MISSING: docs/$file" -ErrorAction Continue
            $fail = $true
            continue
        }
        $content = [System.IO.File]::ReadAllText($path)
        foreach ($marker in $requirements[$file]) {
            if (-not $content.Contains($marker)) {
                Write-Error "INVALID docs/$file`: missing '$marker'" -ErrorAction Continue
                $fail = $true
            }
        }
    }
    if (-not $fail) {
        try { $null = Get-HotContext } catch {
            Write-Error $_ -ErrorAction Continue
            $fail = $true
        }
    }
    $log = Join-Path $DocsDir "Agentslog.md"
    if (Test-Path -LiteralPath $log -PathType Leaf) {
        $bytes = (Get-Item -LiteralPath $log).Length
        $entries = Get-LogEntryCount $log
        if ($bytes -gt $LogBytesLimit -or $entries -gt $LogEntriesLimit) {
            Write-Error "ROTATE REQUIRED: Agentslog has $entries entries / $bytes bytes" -ErrorAction Continue
            $fail = $true
        }
    }
    if ($fail) { throw "project_docs check failed" }
    Write-Output "project_docs check: OK"
}

function ConvertTo-LogField([string]$Value) {
    return (($Value -replace '[\r\n]+', ' ') -replace '\|', '/').Trim()
}

function Invoke-AppendLog {
    if ($Arguments.Count -lt 6) {
        throw "append-log requires: agent task status summary files verify [follow-up]"
    }
    $fields = @($Arguments | ForEach-Object { ConvertTo-LogField $_ })
    $followUp = if ($fields.Count -ge 7) { $fields[6] } else { "none" }
    $timestamp = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
    $entry = @(
        "",
        "## [$timestamp] | $($fields[0]) | $($fields[1]) | $($fields[2])",
        "- Summary: $($fields[3])",
        "- Files: $($fields[4])",
        "- Verify: $($fields[5])",
        "- Follow-up: $followUp"
    ) -join "`n"
    [System.IO.File]::AppendAllText(
        (Join-Path $DocsDir "Agentslog.md"),
        $entry + "`n",
        $Utf8
    )
    Write-Output "project_docs append-log: entry added"
}

function Invoke-Rotate {
    $log = Join-Path $DocsDir "Agentslog.md"
    if (-not (Test-Path -LiteralPath $log -PathType Leaf)) { throw "run init first" }
    $bytes = (Get-Item -LiteralPath $log).Length
    $entries = Get-LogEntryCount $log
    if ($bytes -le $LogBytesLimit -and $entries -le $LogEntriesLimit) {
        Write-Output "project_docs rotate: not required"
        return
    }
    $history = Join-Path $DocsDir "history"
    New-Item -ItemType Directory -Path $history -Force | Out-Null
    $stamp = [DateTime]::UtcNow.ToString("yyyyMMdd")
    $sequence = 1
    do {
        $name = "Agentslog-$stamp-{0:D3}.md" -f $sequence
        $archive = Join-Path $history $name
        $sequence++
    } while (Test-Path -LiteralPath $archive)
    Copy-Item -LiteralPath $log -Destination $archive
    $sourceHash = (Get-FileHash -LiteralPath $log -Algorithm SHA256).Hash.ToLowerInvariant()
    $archiveHash = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($sourceHash -ne $archiveHash) { throw "archive hash verification failed" }
    $newContent = @"
# Agents log

Recent append-only ledger. Older segments live in ``docs/history/``.

## Entry format

``````markdown
## [YYYY-MM-DDTHH:mm:ssZ] | agent | TASK-ID | DONE
- Summary: observable outcome
- Files: compact paths or component names
- Verify: command and result
- Follow-up: none or one pointer
``````

## Previous segment

- Archive: ``docs/history/$name``
- SHA-256: ``$archiveHash``

## Entries
"@
    $temp = Join-Path $DocsDir ".Agentslog.md.tmp.$PID"
    Write-Utf8File $temp ($newContent + "`n")
    Move-Item -LiteralPath $temp -Destination $log -Force
    Write-Output "project_docs rotate: archived $name"
}

switch ($Command) {
    "init" { Invoke-Init }
    "check" { Invoke-Check }
    "context" { Get-HotContext }
    "append-log" { Invoke-AppendLog }
    "rotate" { Invoke-Rotate }
    default {
        Write-Output "Usage: project_docs.ps1 {init|check|context|append-log|rotate} <project> [args]"
    }
}
