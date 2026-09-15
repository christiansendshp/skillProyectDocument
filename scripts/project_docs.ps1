[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet("init", "check", "context", "append-log", "rotate", "migrate", "link", "claim", "pause", "done", "status", "help")]
    [string]$Command = "help",

    [Parameter(Position = 1)]
    [string]$Project = ".",

    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Arguments
)

$ErrorActionPreference = "Stop"
$ScriptDir = $PSScriptRoot
$TemplatesDir = Join-Path $ScriptDir "..\templates"
$AdaptersDir = Join-Path $ScriptDir "..\adapters"
$DocsDir = Join-Path $Project "docs"
$HistoryDir = Join-Path $DocsDir "history"
$ContractFiles = @(
    "AGENTS.md",
    "docs/Agentslog.md",
    "docs/ProductDescription.md",
    "docs/Stack_Tecnologies.md",
    "docs/Roadmap.md",
    "docs/Features.md"
)
$LinkTargetsDefault = @("claude", "gemini", "cursor", "windsurf", "cline", "copilot", "antigravity")
$ContextLimit = 8192
$LogBytesLimit = 131072
$LogEntriesLimit = 200
$StaleHours = if ($env:PROJECT_DOCS_STALE_HOURS) { [int]$env:PROJECT_DOCS_STALE_HOURS } else { 24 }
$BlockStart = "<!-- project-documentation:start -->"
$BlockEnd = "<!-- project-documentation:end -->"
$Utf8 = [System.Text.UTF8Encoding]::new($false)
# Windows PowerShell 5.1 reads a BOM-less .ps1 file using the system ANSI
# codepage, not UTF-8, so non-ASCII literals in the script SOURCE corrupt
# parsing. Build the em dash used in placeholder cells from its code point
# instead of writing it literally. Data files (templates, docs) are exempt:
# they are always read/written through $Utf8 explicitly.
$EmDash = [char]0x2014

function Write-Utf8File([string]$Path, [string]$Content) {
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [System.IO.File]::WriteAllText($Path, $Content, $script:Utf8)
}

function Read-TextLines([string]$Path) {
    return @(Get-ContentUtf8 -LiteralPath $Path)
}

# Windows PowerShell 5.1's Get-Content auto-detects encoding for a BOM-less
# file and falls back to the system ANSI codepage, silently corrupting any
# non-ASCII byte (the em dash placeholder included). Every read of a project
# data file (templates, docs) in this script goes through this wrapper
# instead, which always decodes as UTF-8.
function Get-ContentUtf8 {
    param([Parameter(Mandatory = $true)][string]$LiteralPath)
    if (-not (Test-Path -LiteralPath $LiteralPath -PathType Leaf)) { return @() }
    $text = [System.IO.File]::ReadAllText($LiteralPath, $Utf8)
    if ($text.Length -eq 0) { return @() }
    $lines = [System.Collections.Generic.List[string]]($text -split "`r`n|`n|`r")
    if ($lines.Count -gt 0 -and $lines[$lines.Count - 1] -eq "") {
        $lines.RemoveAt($lines.Count - 1)
    }
    # A function's `return` unrolls a collection onto the pipeline, so a
    # 0- or 1-item result becomes $null or a scalar for a caller that
    # assigns it directly. Every call site below wraps the call in @(...)
    # instead of relying on the comma operator here, which would otherwise
    # nest when a caller ALSO wraps with @(...).
    return $lines
}

function ConvertTo-JoinedLines([string[]]$Lines) {
    return (($Lines -join "`n") + "`n")
}

function Require-Templates {
    if (-not (Test-Path -LiteralPath $TemplatesDir -PathType Container)) {
        throw "templates directory not found: $TemplatesDir"
    }
}

function Require-Adapters {
    if (-not (Test-Path -LiteralPath $AdaptersDir -PathType Container)) {
        throw "adapters directory not found: $AdaptersDir"
    }
}

function ConvertTo-CleanField([string]$Value) {
    return (($Value -replace '[\r\n]+', ' ') -replace '\|', '/').Trim()
}

# ---------------------------------------------------------------------------
# Idempotent marker block: ContentFile is a path (mirrors the sh primitive,
# which also takes a content FILE, to avoid ambiguity around a string's
# trailing newline when splitting into lines). Returns $true if Target
# changed, $false if it already matched.
# ---------------------------------------------------------------------------
function Set-Block([string]$Target, [string]$ContentFile) {
    $blockLines = @($BlockStart) + @(Get-ContentUtf8 -LiteralPath $ContentFile) + @($BlockEnd)
    if (-not (Test-Path -LiteralPath $Target -PathType Leaf)) {
        $dir = Split-Path -Parent $Target
        if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        Write-Utf8File $Target (ConvertTo-JoinedLines $blockLines)
        return $true
    }
    $lines = @(Read-TextLines $Target)
    $sIdx = -1
    for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -ceq $BlockStart) { $sIdx = $i; break } }
    $eIdx = -1
    if ($sIdx -ge 0) {
        for ($i = $sIdx + 1; $i -lt $lines.Count; $i++) { if ($lines[$i] -ceq $BlockEnd) { $eIdx = $i; break } }
    }
    $result = [System.Collections.Generic.List[string]]::new()
    if ($sIdx -ge 0 -and $eIdx -ge 0) {
        for ($i = 0; $i -lt $sIdx; $i++) { $result.Add([string]$lines[$i]) }
        $result.AddRange([string[]]$blockLines)
        for ($i = $eIdx + 1; $i -lt $lines.Count; $i++) { $result.Add([string]$lines[$i]) }
    } else {
        $result.AddRange([string[]]$blockLines)
        $result.Add("")
        $result.AddRange([string[]]$lines)
    }
    $newContent = ConvertTo-JoinedLines ([string[]]$result)
    $oldContent = [System.IO.File]::ReadAllText($Target, $Utf8)
    if ([string]::Equals($oldContent, $newContent, [System.StringComparison]::Ordinal)) { return $false }
    Write-Utf8File $Target $newContent
    return $true
}

function Test-HasBlock([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    return ([System.IO.File]::ReadAllText($Path, $Utf8)).Contains($BlockStart)
}

# ---------------------------------------------------------------------------
# Case-variant helpers
# ---------------------------------------------------------------------------
function Get-CaseVariants([string]$Dir, [string]$Name) {
    if (-not (Test-Path -LiteralPath $Dir -PathType Container)) { return @() }
    $lname = $Name.ToLowerInvariant()
    return @(Get-ChildItem -LiteralPath $Dir -File -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name.ToLowerInvariant() -eq $lname } |
        ForEach-Object { $_.Name })
}

function Find-CaseVariant([string]$Dir, [string]$Name) {
    $variants = @(Get-CaseVariants $Dir $Name)
    if ($variants.Count -gt 0) { return $variants[0] }
    return $null
}

# Under $ErrorActionPreference = "Stop", PowerShell 5.1 turns any stderr
# line from a redirected native command into a terminating NativeCommandError
# regardless of where the redirect points, so every git call here runs with
# a locally relaxed preference instead.
function Invoke-GitQuiet {
    param([string[]]$GitArgs)
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = "SilentlyContinue"
    try {
        & git @GitArgs *> $null
        return ($LASTEXITCODE -eq 0)
    } catch {
        return $false
    } finally {
        $ErrorActionPreference = $prevEap
    }
}

function Test-InGitRepo {
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) { return $false }
    return Invoke-GitQuiet @("-C", $Project, "rev-parse", "--is-inside-work-tree")
}

function Rename-CaseVariant([string]$From, [string]$To) {
    $dir = Split-Path -Parent $From
    $tmp = Join-Path $dir ".project-docs-rename-tmp"
    if (Test-InGitRepo) {
        if (-not (Invoke-GitQuiet @("-C", $Project, "mv", $From, $tmp))) { Move-Item -LiteralPath $From -Destination $tmp -Force }
        if (-not (Invoke-GitQuiet @("-C", $Project, "mv", $tmp, $To))) { Move-Item -LiteralPath $tmp -Destination $To -Force }
    } else {
        Move-Item -LiteralPath $From -Destination $tmp -Force
        Move-Item -LiteralPath $tmp -Destination $To -Force
    }
}

function Remove-ManagedFile([string]$Path) {
    if (Test-InGitRepo) {
        if (-not (Invoke-GitQuiet @("-C", $Project, "rm", "-q", "--", $Path))) {
            Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
        }
    } else {
        Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------------------
# init / link
# ---------------------------------------------------------------------------
function Invoke-Init {
    Require-Templates
    $created = 0
    foreach ($rel in $ContractFiles) {
        $target = Join-Path $Project $rel
        $base = Split-Path -Leaf $rel
        $dir = Split-Path -Parent $target
        if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $existed = Test-Path -LiteralPath $target -PathType Leaf
        if ($base -eq "AGENTS.md") {
            if ($existed) {
                if (Test-HasBlock $target) {
                    Write-Output "= preserved: $rel"
                } else {
                    Set-Block $target (Join-Path $TemplatesDir "AGENTS.md") | Out-Null
                    Write-Output "= merged skill block: $rel"
                }
            } else {
                Set-Block $target (Join-Path $TemplatesDir "AGENTS.md") | Out-Null
                Write-Output "+ created: $rel"
                $created++
            }
        } else {
            if ($existed) {
                Write-Output "= preserved: $rel"
            } else {
                Copy-Item -LiteralPath (Join-Path $TemplatesDir $base) -Destination $target
                Write-Output "+ created: $rel"
                $created++
            }
        }
    }
    Write-Output "project_docs init: $created file(s) created"
    Invoke-LinkAll $Project ""
}

function Get-LinkTargetPath([string]$Name) {
    switch ($Name) {
        "claude" { return "CLAUDE.md" }
        "gemini" { return "GEMINI.md" }
        "cursor" { return ".cursorrules" }
        "windsurf" { return ".windsurfrules" }
        "cline" { return ".clinerules" }
        "copilot" { return ".github/copilot-instructions.md" }
        "antigravity" { return ".antigravity/rules.md" }
    }
}

function Get-LinkSourceFile([string]$Name) {
    switch ($Name) {
        "claude" { return Join-Path $AdaptersDir "CLAUDE.md" }
        "antigravity" { return Join-Path $AdaptersDir ".antigravity/rules.md" }
        default { return Join-Path $AdaptersDir "redirect.md" }
    }
}

function Invoke-LinkAll([string]$ProjectPath, [string]$CreateList) {
    Require-Adapters
    $createNames = @()
    if ($CreateList) { $createNames = @($CreateList -split ',' | ForEach-Object { $_.Trim() }) }
    foreach ($name in $LinkTargetsDefault) {
        $rel = Get-LinkTargetPath $name
        $full = Join-Path $ProjectPath $rel
        $create = $createNames -contains $name
        if ($name -eq "cursor" -and -not (Test-Path -LiteralPath $full -PathType Leaf) -and (Test-Path -LiteralPath (Join-Path $ProjectPath ".cursor/rules") -PathType Container)) {
            $full = Join-Path $ProjectPath ".cursor/rules/project-documentation.mdc"
            $rel = ".cursor/rules/project-documentation.mdc"
            $create = $true
        }
        if ((Test-Path -LiteralPath $full -PathType Leaf) -or $create) {
            $src = Get-LinkSourceFile $name
            Set-Block $full $src | Out-Null
            Write-Output "= linked: $rel"
        }
    }
}

function Invoke-Link {
    $createList = ""
    for ($i = 0; $i -lt $Arguments.Count; $i++) {
        if ($Arguments[$i] -eq "--create" -and ($i + 1) -lt $Arguments.Count) {
            $createList = $Arguments[$i + 1]
            $i++
        }
    }
    Invoke-LinkAll $Project $createList
    Write-Output "project_docs link: done"
}

# ---------------------------------------------------------------------------
# context extraction
# ---------------------------------------------------------------------------
function Get-ContextBlock([string]$Path, [string]$Heading) {
    $lines = @(Get-ContentUtf8 -LiteralPath $Path)
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
    $lines = @(Get-ContentUtf8 -LiteralPath (Join-Path $DocsDir "Agentslog.md"))
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
    $lines = @(Get-ContentUtf8 -LiteralPath $Path)
    $entriesSection = [Array]::IndexOf($lines, "## Entries")
    if ($entriesSection -lt 0) { return 0 }
    return @(
        for ($i = $entriesSection + 1; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match '^## \[') { $i }
        }
    ).Count
}

# ---------------------------------------------------------------------------
# Agentslog scanner: reused by claim/pause/done/status/context/check/rotate.
# ---------------------------------------------------------------------------
function Get-TaskStates {
    $log = Join-Path $DocsDir "Agentslog.md"
    if (-not (Test-Path -LiteralPath $log -PathType Leaf)) { return @() }
    $lines = @(Get-ContentUtf8 -LiteralPath $log)
    $inEntries = $false
    $order = [System.Collections.Generic.List[string]]::new()
    $lastStatus = @{}; $lastAgent = @{}; $lastTs = @{}; $lastPause = @{}; $everDone = @{}; $conflict = @{}
    $cur = $null
    foreach ($line in $lines) {
        if ($line -eq "## Entries") { $inEntries = $true; continue }
        if (-not $inEntries) { continue }
        if ($line -match '^## \[([^\]]*)\] \| ([^|]*) \| ([^|]*) \| (.*)$') {
            $ts = $Matches[1].Trim()
            $agent = $Matches[2].Trim()
            $tid = $Matches[3].Trim()
            $status = $Matches[4].Trim()
            if (-not $lastStatus.ContainsKey($tid)) { $order.Add($tid) }
            if ($status -eq "IN_PROGRESS" -and $lastStatus[$tid] -eq "IN_PROGRESS" -and $lastAgent[$tid] -ne $agent) {
                $conflict[$tid] = "$($lastAgent[$tid]) vs $agent"
            }
            if ($status -eq "DONE") { $everDone[$tid] = $true }
            $lastStatus[$tid] = $status
            $lastAgent[$tid] = $agent
            $lastTs[$tid] = $ts
            $lastPause[$tid] = ""
            $cur = $tid
            continue
        }
        if ($cur -and $line -match '^- Pause: (.*)$') {
            $body = $Matches[1]
            $dashIdx = $body.IndexOf(" - ")
            if ($dashIdx -ge 0) { $lastPause[$cur] = $body.Substring(0, $dashIdx) } else { $lastPause[$cur] = $body }
            continue
        }
    }
    $result = [System.Collections.Generic.List[object]]::new()
    foreach ($t in $order) {
        $result.Add([PSCustomObject]@{
            Task = $t
            Status = $lastStatus[$t]
            Agent = $lastAgent[$t]
            Ts = $lastTs[$t]
            PauseCat = $lastPause[$t]
            Conflict = $(if ($conflict.ContainsKey($t)) { $conflict[$t] } else { "" })
            EverDone = [bool]$everDone[$t]
        })
    }
    return $result
}

function Get-TaskState([string]$Task) {
    return (Get-TaskStates | Where-Object { $_.Task -eq $Task } | Select-Object -First 1)
}

function Get-AgeHours([string]$Ts) {
    try {
        $styles = [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor [System.Globalization.DateTimeStyles]::AssumeUniversal
        $dt = [DateTime]::Parse($Ts, [System.Globalization.CultureInfo]::InvariantCulture, $styles)
        return [int][Math]::Floor(([DateTime]::UtcNow - $dt).TotalHours)
    } catch {
        return $null
    }
}

function Test-Stale([string]$Task) {
    $state = Get-TaskState $Task
    if (-not $state) { return $false }
    $hrs = Get-AgeHours $state.Ts
    if ($null -ne $hrs -and $hrs -ge $StaleHours) { return $true }
    return $false
}

function Get-OpenTasksLines {
    $log = Join-Path $DocsDir "Agentslog.md"
    if (-not (Test-Path -LiteralPath $log -PathType Leaf)) { return @() }
    $states = @(Get-TaskStates | Where-Object { $_.Status -eq "IN_PROGRESS" -or $_.Status -eq "PAUSE" })
    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($s in $states) {
        $hrs = Get-AgeHours $s.Ts
        $hrsStr = if ($null -ne $hrs) { "$hrs" } else { "?" }
        $reason = if ($s.Status -eq "PAUSE") { $s.PauseCat } else { "-" }
        $lines.Add("$($s.Task) | $($s.Agent) | $($s.Status) | ${hrsStr}h | $reason")
    }
    return $lines
}

function Get-HotContext {
    $agents = Join-Path $Project "AGENTS.md"
    if (-not (Test-Path -LiteralPath $agents -PathType Leaf)) {
        throw "run init first"
    }
    $parts = [System.Collections.Generic.List[string]]::new()
    foreach ($line in @(Get-ContentUtf8 -LiteralPath $agents)) { $parts.Add([string]$line) }
    foreach ($item in @(
        @("ProductDescription.md", "## Operational summary"),
        @("Stack_Tecnologies.md", "## Operational summary"),
        @("Features.md", "## Operational summary"),
        @("Roadmap.md", "## Active work")
    )) {
        $parts.Add("")
        foreach ($line in @(Get-ContextBlock (Join-Path $DocsDir $item[0]) $item[1])) { $parts.Add([string]$line) }
    }
    $parts.Add("")
    $parts.Add("## Open tasks")
    foreach ($line in @(Get-OpenTasksLines)) { $parts.Add([string]$line) }
    $parts.Add("")
    $parts.Add("## Latest agent entries")
    foreach ($line in @(Get-LatestEntries)) { $parts.Add([string]$line) }
    $content = ($parts -join "`n") + "`n"
    $bytes = $Utf8.GetByteCount($content)
    if ($bytes -gt $ContextLimit) {
        throw "hot context is $bytes bytes; compact summaries below $ContextLimit"
    }
    return $content
}

# ---------------------------------------------------------------------------
# Roadmap/Features table rows. Every table this tool edits ends in the same
# four trailing columns (Status, Owner, Depends on, Pause reason), so cells
# are addressed from the end regardless of how many columns precede them.
# ---------------------------------------------------------------------------
function Get-TableIds([string]$File) {
    if (-not (Test-Path -LiteralPath $File -PathType Leaf)) { return @() }
    $ids = [System.Collections.Generic.List[string]]::new()
    foreach ($line in @(Get-ContentUtf8 -LiteralPath $File)) {
        if ($line.StartsWith("|")) {
            $cells = @($line -split '\|')
            if ($cells.Count -lt 2) { continue }
            $id = $cells[1].Trim()
            if ($id -eq "" -or $id -eq "ID" -or $id -eq $EmDash -or $id -match '^-+$') { continue }
            $ids.Add($id)
        }
    }
    return $ids
}

function Get-RoadmapIds { return Get-TableIds (Join-Path $DocsDir "Roadmap.md") }
function Get-FeaturesIds { return Get-TableIds (Join-Path $DocsDir "Features.md") }

function Test-RoadmapHasId([string]$Id) {
    return ((@(Get-RoadmapIds)) -contains $Id)
}

function Test-RoadmapHasIdPrefix([string]$Prefix) {
    foreach ($id in @(Get-RoadmapIds)) { if ($id.StartsWith($Prefix)) { return $true } }
    return $false
}

function Get-RoadmapSectionOf([string]$Id) {
    $file = Join-Path $DocsDir "Roadmap.md"
    $sect = ""
    foreach ($line in @(Get-ContentUtf8 -LiteralPath $file)) {
        if ($line -match '^## Active work') { $sect = "active"; continue }
        if ($line -match '^## Plan') { $sect = "plan"; continue }
        if ($line -match '^## Gaps and defects') { $sect = "gaps"; continue }
        if ($line -match '^## Near term') { $sect = "near"; continue }
        if ($line.StartsWith("|")) {
            $cells = @($line -split '\|')
            if ($cells.Count -ge 2 -and $cells[1].Trim() -eq $Id) { return $sect }
        }
    }
    return ""
}

function Set-RoadmapRowInPlace([string]$Id, [string]$Status, [string]$Owner, [string]$PauseReason) {
    $file = Join-Path $DocsDir "Roadmap.md"
    $lines = @(Get-ContentUtf8 -LiteralPath $file)
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i].StartsWith("|")) {
            $cells = @($lines[$i] -split '\|')
            if ($cells.Count -ge 2 -and $cells[1].Trim() -eq $Id) {
                $n = $cells.Count
                $cells[$n - 5] = " $Status "
                $cells[$n - 4] = " $Owner "
                $cells[$n - 2] = " $PauseReason "
                $lines[$i] = ($cells -join '|')
            }
        }
    }
    Write-Utf8File $file (ConvertTo-JoinedLines $lines)
}

function Move-RoadmapRowToActive([string]$Id, [string]$Status, [string]$Owner, [string]$PauseReason) {
    $file = Join-Path $DocsDir "Roadmap.md"
    $lines = @(Get-ContentUtf8 -LiteralPath $file)
    $rowIdx = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i].StartsWith("|")) {
            $cells = @($lines[$i] -split '\|')
            if ($cells.Count -ge 2 -and $cells[1].Trim() -eq $Id) { $rowIdx = $i; break }
        }
    }
    if ($rowIdx -lt 0) { return }
    $cells = @($lines[$rowIdx] -split '\|')
    $n = $cells.Count
    $cells[$n - 5] = " $Status "
    $cells[$n - 4] = " $Owner "
    $cells[$n - 2] = " $PauseReason "
    $newRow = ($cells -join '|')
    $result = [System.Collections.Generic.List[string]]::new()
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($i -eq $rowIdx) { continue }
        if ($lines[$i] -eq "<!-- context:end -->") { $result.Add($newRow) }
        $result.Add($lines[$i])
    }
    Write-Utf8File $file (ConvertTo-JoinedLines ([string[]]$result))
}

function Remove-RoadmapRow([string]$Id) {
    $file = Join-Path $DocsDir "Roadmap.md"
    $result = [System.Collections.Generic.List[string]]::new()
    foreach ($line in @(Get-ContentUtf8 -LiteralPath $file)) {
        if ($line.StartsWith("|")) {
            $cells = @($line -split '\|')
            if ($cells.Count -ge 2 -and $cells[1].Trim() -eq $Id) { continue }
        }
        $result.Add($line)
    }
    Write-Utf8File $file (ConvertTo-JoinedLines ([string[]]$result))
}

function Invoke-RoadmapClaimRow([string]$Id, [string]$Agent, [string]$Timestamp) {
    $owner = "$Agent@$Timestamp"
    $section = Get-RoadmapSectionOf $Id
    if ($section -eq "plan") {
        Move-RoadmapRowToActive $Id "IN_PROGRESS" $owner $EmDash
    } else {
        Set-RoadmapRowInPlace $Id "IN_PROGRESS" $owner $EmDash
    }
}

function Update-FeaturesSummary([string]$Verify, [string]$DateOnly) {
    $file = Join-Path $DocsDir "Features.md"
    $count = (@(Get-TableIds $file)).Count
    $lines = @(Get-ContentUtf8 -LiteralPath $file)
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^- Verified capabilities:') { $lines[$i] = "- Verified capabilities: $count" }
        elseif ($lines[$i] -match '^- Latest verification:') { $lines[$i] = "- Latest verification: ``$Verify`` ($DateOnly)" }
    }
    Write-Utf8File $file (ConvertTo-JoinedLines $lines)
}

function Add-FeaturesCapability([string]$Id, [string]$Summary, [string]$Verify, [string]$Timestamp) {
    $file = Join-Path $DocsDir "Features.md"
    $dateOnly = $Timestamp.Split('T')[0]
    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($line in @(Get-ContentUtf8 -LiteralPath $file)) {
        if ($line -eq "| $EmDash | $EmDash | $EmDash | $EmDash | $EmDash |") { continue }
        $lines.Add($line)
    }
    $lines.Add("| $Id | $Summary | $Verify | log:$Id | $dateOnly |")
    if ($Id -match '^(F\d+-E\d+)-') {
        $epic = $Matches[1]
        $prefix = "$epic-"
        $existingIds = @(Get-TableIds $file)
        if (-not (Test-RoadmapHasIdPrefix $prefix) -and -not ($existingIds -contains $epic)) {
            $lines.Add("| $epic | Epic complete | all tasks DONE | log:$Id | $dateOnly |")
        }
    }
    Write-Utf8File $file (ConvertTo-JoinedLines ([string[]]$lines))
    Update-FeaturesSummary $Verify $dateOnly
}

# ---------------------------------------------------------------------------
# Lock: claim/pause/done mutate Agentslog.md and Roadmap.md together. Locking
# is atomic only within one working copy; across machines, commit and push
# the claim entry immediately so other agents see it before they claim.
# ---------------------------------------------------------------------------
function Enter-DocsLock {
    $lockDir = Join-Path $DocsDir ".lock"
    $attempts = 0
    while ($true) {
        try {
            New-Item -ItemType Directory -Path $lockDir -ErrorAction Stop | Out-Null
            break
        } catch {
            if (Test-Path -LiteralPath $lockDir -PathType Container) {
                $age = (Get-Date).ToUniversalTime() - (Get-Item -LiteralPath $lockDir).LastWriteTimeUtc
                if ($age.TotalSeconds -ge 30) {
                    Remove-Item -LiteralPath $lockDir -Force -Recurse -ErrorAction SilentlyContinue
                    continue
                }
            }
            $attempts++
            if ($attempts -ge 50) { throw "could not acquire docs/.lock (busy); retry" }
            Start-Sleep -Milliseconds 100
        }
    }
    $script:LockDir = $lockDir
}

function Exit-DocsLock {
    if ($script:LockDir -and (Test-Path -LiteralPath $script:LockDir)) {
        Remove-Item -LiteralPath $script:LockDir -Force -Recurse -ErrorAction SilentlyContinue
    }
}

function Invoke-Claim {
    if ($Arguments.Count -lt 3) { throw "claim requires: agent task-id summary" }
    $agent = ConvertTo-CleanField $Arguments[0]
    $task = ConvertTo-CleanField $Arguments[1]
    $summary = ConvertTo-CleanField $Arguments[2]
    $log = Join-Path $DocsDir "Agentslog.md"
    if (-not (Test-Path -LiteralPath $log -PathType Leaf)) { throw "run init first" }
    if (-not (Test-RoadmapHasId $task)) { throw "claim failed: $task not found in docs/Roadmap.md" }
    Enter-DocsLock
    try {
        $state = Get-TaskState $task
        if ($state) {
            if ($state.Status -eq "IN_PROGRESS") {
                if ($state.Agent -ne $agent -and -not (Test-Stale $task)) {
                    throw "claim failed: $task is IN_PROGRESS, owned by $($state.Agent)"
                }
            } elseif ($state.Status -eq "PAUSE") {
                if ($state.PauseCat -ne "LIMITE" -and $state.Agent -ne $agent) {
                    throw "claim failed: $task is PAUSE ($($state.PauseCat)); resolvable only by $($state.Agent) until the reason clears"
                }
            }
        }
        $timestamp = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
        $entry = (@(
            "",
            "## [$timestamp] | $agent | $task | IN_PROGRESS",
            "- Summary: $summary",
            "- Verify: pending"
        ) -join "`n") + "`n"
        [System.IO.File]::AppendAllText($log, $entry, $Utf8)
        Invoke-RoadmapClaimRow $task $agent $timestamp
        Write-Output "project_docs claim: $task claimed by $agent"
    } finally {
        Exit-DocsLock
    }
}

function Invoke-Pause {
    if ($Arguments.Count -lt 4) { throw "pause requires: agent task-id category detail" }
    $agent = ConvertTo-CleanField $Arguments[0]
    $task = ConvertTo-CleanField $Arguments[1]
    $category = ConvertTo-CleanField $Arguments[2]
    $detail = ConvertTo-CleanField $Arguments[3]
    if ($category -notin @("LIMITE", "ESPERA_RESPUESTA", "BLOQUEO", "OTRO")) {
        throw "pause requires category one of LIMITE, ESPERA_RESPUESTA, BLOQUEO, OTRO"
    }
    if (-not $detail) { throw "pause requires a non-empty detail" }
    Enter-DocsLock
    try {
        $state = Get-TaskState $task
        if (-not $state) { throw "pause failed: $task has no IN_PROGRESS entry to pause" }
        if ($state.Status -ne "IN_PROGRESS") { throw "pause failed: $task is not IN_PROGRESS (current: $($state.Status))" }
        if ($state.Agent -ne $agent) { throw "pause failed: $task is owned by $($state.Agent), not $agent" }
        $timestamp = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
        $log = Join-Path $DocsDir "Agentslog.md"
        $entry = (@(
            "",
            "## [$timestamp] | $agent | $task | PAUSE",
            "- Pause: $category - $detail"
        ) -join "`n") + "`n"
        [System.IO.File]::AppendAllText($log, $entry, $Utf8)
        Set-RoadmapRowInPlace $task "PAUSE" "$agent@$timestamp" $category
        Write-Output "project_docs pause: $task paused ($category)"
    } finally {
        Exit-DocsLock
    }
}

function Invoke-Done {
    if ($Arguments.Count -lt 5) { throw "done requires: agent task-id summary files verify" }
    $agent = ConvertTo-CleanField $Arguments[0]
    $task = ConvertTo-CleanField $Arguments[1]
    $summary = ConvertTo-CleanField $Arguments[2]
    $files = ConvertTo-CleanField $Arguments[3]
    $verify = ConvertTo-CleanField $Arguments[4]
    if (-not $verify) { throw "done requires a non-empty verify" }
    Enter-DocsLock
    try {
        $timestamp = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
        $log = Join-Path $DocsDir "Agentslog.md"
        $entry = (@(
            "",
            "## [$timestamp] | $agent | $task | DONE",
            "- Summary: $summary",
            "- Files: $files",
            "- Verify: $verify"
        ) -join "`n") + "`n"
        [System.IO.File]::AppendAllText($log, $entry, $Utf8)
        Remove-RoadmapRow $task
        Add-FeaturesCapability $task $summary $verify $timestamp
        Write-Output "project_docs done: $task closed"
    } finally {
        Exit-DocsLock
    }
}

function Invoke-Status {
    $log = Join-Path $DocsDir "Agentslog.md"
    if (-not (Test-Path -LiteralPath $log -PathType Leaf)) { throw "run init first" }
    $states = @(Get-TaskStates | Where-Object { $_.Status -eq "IN_PROGRESS" -or $_.Status -eq "PAUSE" })
    foreach ($s in $states) {
        $hrs = Get-AgeHours $s.Ts
        $hrsStr = if ($null -ne $hrs) { "$hrs" } else { "?" }
        $reason = if ($s.Status -eq "PAUSE") { $s.PauseCat } else { "-" }
        $stale = ""
        if ($s.Status -eq "IN_PROGRESS" -and $null -ne $hrs -and $hrs -ge $StaleHours) { $stale = " (stale)" }
        Write-Output "$($s.Task) | $($s.Agent) | $($s.Status) | ${hrsStr}h$stale | $reason"
    }
}

# ---------------------------------------------------------------------------
# migrate
# ---------------------------------------------------------------------------
function Set-RoadmapSectionsEnsured {
    $file = Join-Path $DocsDir "Roadmap.md"
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { return }
    $content = [System.IO.File]::ReadAllText($file, $Utf8)
    $changed = $false
    if (-not $content.Contains("## Plan")) {
        $content += "`n## Plan`n`nFull Fase -> Epic -> Tarea -> Subtarea hierarchy for pending work.`n"
        $changed = $true
    }
    if (-not $content.Contains("## Gaps and defects")) {
        $content += "`n## Gaps and defects`n`n| ID | Severity | Phase | Description | Status | Owner | Depends on | Pause reason |`n|---|---|---|---|---|---|---|---|`n| $EmDash | $EmDash | $EmDash | $EmDash | $EmDash | $EmDash | $EmDash | $EmDash |`n"
        $changed = $true
    }
    if ($changed) { Write-Utf8File $file $content }
    $lines = @(Get-ContentUtf8 -LiteralPath $file)
    $activeHasPauseReason = $false
    $activeCheck = $false
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^## Active work') { $activeCheck = $true; continue }
        if ($lines[$i] -match '^## Near term') { break }
        if ($activeCheck -and $lines[$i] -match '^\| ID \|') {
            $activeHasPauseReason = $lines[$i].Contains("Pause reason")
            break
        }
    }
    if (-not $activeHasPauseReason) {
        $active = $false
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match '^## Active work') { $active = $true; continue }
            if ($lines[$i] -match '^## (Near term|Plan)') { $active = $false; continue }
            if ($active -and $lines[$i] -match '^\| ID \|') { $lines[$i] = $lines[$i] + " Pause reason |"; continue }
            if ($active -and $lines[$i] -match '^\|---') { $lines[$i] = $lines[$i] + "---|"; continue }
            if ($active -and $lines[$i].StartsWith("|")) { $lines[$i] = $lines[$i] -replace '\|\s*$', "| $EmDash |"; continue }
        }
        Write-Utf8File $file (ConvertTo-JoinedLines $lines)
    }
}

function Invoke-Migrate {
    Require-Templates
    $changed = 0
    $variant = Find-CaseVariant $Project "AGENTS.md"
    if ($variant -and $variant -cne "AGENTS.md") {
        Rename-CaseVariant (Join-Path $Project $variant) (Join-Path $Project "AGENTS.md")
        $changed++
        Write-Output "= renamed: $variant -> AGENTS.md"
    }
    # Ensure base files (and a plain AGENTS.md block) exist first; the legacy
    # merge below runs last so its combined content is not clobbered by
    # init's own template-only block write.
    Invoke-Init
    $legacy = Find-CaseVariant $DocsDir "Agents.md"
    if ($legacy) {
        $legacyPath = Join-Path $DocsDir $legacy
        $target = Join-Path $Project "AGENTS.md"
        $tmpLegacy = [System.IO.Path]::GetTempFileName()
        $combined = [System.IO.File]::ReadAllText((Join-Path $TemplatesDir "AGENTS.md"), $Utf8)
        $combined += "`n<!-- migrated from docs/$legacy -->`n"
        $combined += [System.IO.File]::ReadAllText($legacyPath, $Utf8)
        Write-Utf8File $tmpLegacy $combined
        Set-Block $target $tmpLegacy | Out-Null
        Remove-Item -LiteralPath $tmpLegacy -Force -ErrorAction SilentlyContinue
        Remove-ManagedFile $legacyPath
        $changed++
        Write-Output "= migrated: docs/$legacy -> AGENTS.md (content preserved, file removed)"
    }
    Set-RoadmapSectionsEnsured
    Write-Output "project_docs migrate: $changed change(s)"
}

# ---------------------------------------------------------------------------
# check
# ---------------------------------------------------------------------------
function Test-Need([string]$Rel, [string[]]$Markers) {
    $path = Join-Path $Project $Rel
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        Write-Error "MISSING: $Rel" -ErrorAction Continue
        $script:CheckFail = $true
        return
    }
    $content = [System.IO.File]::ReadAllText($path, $Utf8)
    foreach ($marker in $Markers) {
        if (-not $content.Contains($marker)) {
            Write-Error "INVALID $Rel`: missing '$marker'" -ErrorAction Continue
            $script:CheckFail = $true
        }
    }
}

function Test-LogRotationNeeded {
    $log = Join-Path $DocsDir "Agentslog.md"
    $bytes = (Get-Item -LiteralPath $log).Length
    $entries = Get-LogEntryCount $log
    if ($bytes -gt $LogBytesLimit -or $entries -gt $LogEntriesLimit) {
        Write-Error "ROTATE REQUIRED: Agentslog has $entries entries / $bytes bytes" -ErrorAction Continue
        $script:CheckFail = $true
    }
}

function Test-LogEntries {
    $log = Join-Path $DocsDir "Agentslog.md"
    $lines = @(Get-ContentUtf8 -LiteralPath $log)
    $inEntries = $false
    $entries = [System.Collections.Generic.List[object]]::new()
    $cur = $null
    $lastStatus = @{}; $lastAgent = @{}
    foreach ($line in $lines) {
        if ($line -eq "## Entries") { $inEntries = $true; continue }
        if (-not $inEntries) { continue }
        if ($line -match '^## \[([^\]]*)\] \| ([^|]*) \| ([^|]*) \| (.*)$') {
            $agentnow = $Matches[2].Trim()
            $tidnow = $Matches[3].Trim()
            $status = $Matches[4].Trim()
            $conflictMsg = $null
            if ($status -eq "IN_PROGRESS" -and $lastStatus.ContainsKey($tidnow) -and $lastStatus[$tidnow] -eq "IN_PROGRESS" -and $lastAgent[$tidnow] -ne $agentnow) {
                $conflictMsg = "ERROR: conflicting concurrent claim on $tidnow`: $($lastAgent[$tidnow]) and $agentnow"
            }
            $lastStatus[$tidnow] = $status
            $lastAgent[$tidnow] = $agentnow
            $cur = [PSCustomObject]@{ Hdr = $line; Status = $status; PauseLine = $null; VerifyLine = $null; ConflictMsg = $conflictMsg }
            $entries.Add($cur)
            continue
        }
        if ($cur -and $line -match '^- Pause:') { $cur.PauseLine = $line; continue }
        if ($cur -and $line -match '^- Verify:') { $cur.VerifyLine = $line; continue }
    }
    foreach ($e in $entries) {
        if ($e.ConflictMsg) {
            Write-Error $e.ConflictMsg -ErrorAction Continue
            $script:CheckFail = $true
        }
        if ($e.Status -notin @("IN_PROGRESS", "PAUSE", "DONE")) {
            Write-Error "ERROR: invalid status in entry: $($e.Hdr)" -ErrorAction Continue
            $script:CheckFail = $true
        }
        if ($e.Status -eq "PAUSE") {
            if (-not $e.PauseLine) {
                Write-Error "ERROR: PAUSE entry missing Pause line: $($e.Hdr)" -ErrorAction Continue
                $script:CheckFail = $true
            } else {
                $body = $e.PauseLine -replace '^- Pause: ', ''
                $dash = $body.IndexOf(" - ")
                if ($dash -ge 0) { $cat = $body.Substring(0, $dash); $detail = $body.Substring($dash + 3) } else { $cat = $body; $detail = "" }
                if ($cat -notin @("LIMITE", "ESPERA_RESPUESTA", "BLOQUEO", "OTRO")) {
                    Write-Error "ERROR: PAUSE entry has invalid category: $($e.Hdr)" -ErrorAction Continue
                    $script:CheckFail = $true
                }
                if (-not $detail) {
                    Write-Error "ERROR: PAUSE entry missing detail: $($e.Hdr)" -ErrorAction Continue
                    $script:CheckFail = $true
                }
            }
        }
        if ($e.Status -eq "DONE") {
            if (-not $e.VerifyLine) {
                Write-Error "ERROR: DONE entry missing Verify line: $($e.Hdr)" -ErrorAction Continue
                $script:CheckFail = $true
            } else {
                $body = ($e.VerifyLine -replace '^- Verify: ', '').Trim()
                if (-not $body -or $body -eq "pending") {
                    Write-Error "ERROR: DONE entry has empty or pending Verify: $($e.Hdr)" -ErrorAction Continue
                    $script:CheckFail = $true
                }
            }
        }
    }
}

function Test-FileMatchesPattern([string]$Path, [string]$Pattern) {
    foreach ($line in @(Get-ContentUtf8 -LiteralPath $Path)) {
        if ($line -match $Pattern) { return $true }
    }
    return $false
}

function Test-HistoryHasDone([string]$Id) {
    if (-not (Test-Path -LiteralPath $HistoryDir -PathType Container)) { return $false }
    $pattern = "^## \[[^\]]*\] \| [^|]* \| " + [regex]::Escape($Id) + " \| DONE"
    foreach ($f in Get-ChildItem -LiteralPath $HistoryDir -Filter "*.md" -File -ErrorAction SilentlyContinue) {
        if (Test-FileMatchesPattern $f.FullName $pattern) { return $true }
    }
    return $false
}

function Test-EpicHistoryDone([string]$Epic) {
    $prefix = "$Epic-"
    foreach ($s in @(Get-TaskStates)) {
        if ($s.Task.StartsWith($prefix) -and $s.EverDone) { return $true }
    }
    if (Test-Path -LiteralPath $HistoryDir -PathType Container) {
        $pattern = "^## \[[^\]]*\] \| [^|]* \| " + [regex]::Escape($prefix) + "\S* \| DONE"
        foreach ($f in Get-ChildItem -LiteralPath $HistoryDir -Filter "*.md" -File -ErrorAction SilentlyContinue) {
            if (Test-FileMatchesPattern $f.FullName $pattern) { return $true }
        }
    }
    return $false
}

function Test-RoadmapFeaturesIds {
    $rmIds = @(Get-RoadmapIds)
    $ftIds = @(Get-FeaturesIds)
    $states = @(Get-TaskStates)
    foreach ($s in $states) {
        if (-not ($rmIds -contains $s.Task) -and -not ($ftIds -contains $s.Task)) {
            Write-Error "ERROR: log ID $($s.Task) not found in Roadmap or Features" -ErrorAction Continue
            $script:CheckFail = $true
        }
    }
    foreach ($fid in $ftIds) {
        $stateForId = $states | Where-Object { $_.Task -eq $fid } | Select-Object -First 1
        if ($stateForId -and $stateForId.EverDone) { continue }
        $ok = $false
        if ($fid -match '^F\d+-E\d+$') {
            if (Test-EpicHistoryDone $fid) { $ok = $true }
        } else {
            if (Test-HistoryHasDone $fid) { $ok = $true }
        }
        if (-not $ok) {
            Write-Error "ERROR: Features ID $fid has no DONE entry in the log" -ErrorAction Continue
            $script:CheckFail = $true
        }
    }
}

function Write-CheckWarnings {
    $unknownCount = 0
    foreach ($f in @("docs/ProductDescription.md", "docs/Stack_Tecnologies.md", "docs/Features.md")) {
        $path = Join-Path $Project $f
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            foreach ($l in @(Get-ContextBlock $path "## Operational summary")) {
                $unknownCount += ([regex]::Matches($l, "UNKNOWN")).Count
            }
        }
    }
    if ($unknownCount -gt 0) {
        [Console]::Error.WriteLine("WARN: $unknownCount UNKNOWN field(s) in Operational summaries")
    }
    foreach ($name in $LinkTargetsDefault) {
        $rel = Get-LinkTargetPath $name
        $full = Join-Path $Project $rel
        if ((Test-Path -LiteralPath $full -PathType Leaf) -and -not (Test-HasBlock $full)) {
            [Console]::Error.WriteLine("WARN: $rel has no project-documentation redirect block; run 'link'")
        }
    }
    $log = Join-Path $DocsDir "Agentslog.md"
    if (Test-Path -LiteralPath $log -PathType Leaf) {
        foreach ($s in @(Get-TaskStates | Where-Object { $_.Status -eq "IN_PROGRESS" })) {
            $hrs = Get-AgeHours $s.Ts
            if ($null -ne $hrs -and $hrs -ge $StaleHours) {
                [Console]::Error.WriteLine("WARN: $($s.Task) has been IN_PROGRESS for ${hrs}h (>= ${StaleHours}h)")
            }
        }
    }
}

function Invoke-Check {
    $script:CheckFail = $false
    Test-Need "AGENTS.md" @("## Repository rules", "## Startup", "## Close")
    $legacy = Find-CaseVariant $DocsDir "Agents.md"
    if ($legacy) {
        [Console]::Error.WriteLine("MIGRATION REQUIRED: docs/$legacy found; run 'migrate'")
        $script:CheckFail = $true
    }
    $rootVariants = (@(Get-CaseVariants $Project "AGENTS.md")).Count
    if ($rootVariants -gt 1) {
        [Console]::Error.WriteLine("ERROR: multiple case variants of AGENTS.md coexist at project root")
        $script:CheckFail = $true
    }
    Test-Need "docs/Agentslog.md" @("## Entry format", "## Entries")
    Test-Need "docs/ProductDescription.md" @("## Operational summary", "## Business rules")
    Test-Need "docs/Stack_Tecnologies.md" @("## Operational summary", "## Decisions")
    Test-Need "docs/Roadmap.md" @("## Active work", "## Near term", "## Plan", "## Gaps and defects")
    Test-Need "docs/Features.md" @("## Operational summary", "## Verified capabilities")

    if (-not $script:CheckFail) {
        try { $null = Get-HotContext } catch {
            Write-Error $_ -ErrorAction Continue
            $script:CheckFail = $true
        }
    }

    $log = Join-Path $DocsDir "Agentslog.md"
    if (Test-Path -LiteralPath $log -PathType Leaf) {
        Test-LogRotationNeeded
        Test-LogEntries
        Test-RoadmapFeaturesIds
    }

    Write-CheckWarnings

    if ($script:CheckFail) { throw "project_docs check failed" }
    Write-Output "project_docs check: OK"
}

# ---------------------------------------------------------------------------
# append-log (legacy/manual escape hatch, unchanged contract), rotate
# ---------------------------------------------------------------------------
function Invoke-AppendLog {
    if ($Arguments.Count -lt 6) {
        throw "append-log requires: agent task status summary files verify [follow-up]"
    }
    $fields = @($Arguments | ForEach-Object { ConvertTo-CleanField $_ })
    $followUp = if ($fields.Count -ge 7) { $fields[6] } else { "none" }
    $timestamp = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
    $entry = (@(
        "",
        "## [$timestamp] | $($fields[0]) | $($fields[1]) | $($fields[2])",
        "- Summary: $($fields[3])",
        "- Files: $($fields[4])",
        "- Verify: $($fields[5])",
        "- Follow-up: $followUp"
    ) -join "`n") + "`n"
    [System.IO.File]::AppendAllText((Join-Path $DocsDir "Agentslog.md"), $entry, $Utf8)
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
    New-Item -ItemType Directory -Path $HistoryDir -Force | Out-Null
    $stamp = [DateTime]::UtcNow.ToString("yyyyMMdd")
    $sequence = 1
    do {
        $name = "Agentslog-$stamp-{0:D3}.md" -f $sequence
        $archive = Join-Path $HistoryDir $name
        $sequence++
    } while (Test-Path -LiteralPath $archive)
    Copy-Item -LiteralPath $log -Destination $archive
    $sourceHash = (Get-FileHash -LiteralPath $log -Algorithm SHA256).Hash.ToLowerInvariant()
    $archiveHash = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($sourceHash -ne $archiveHash) { throw "archive hash verification failed" }

    $openStates = @(Get-TaskStates | Where-Object { $_.Status -eq "IN_PROGRESS" -or $_.Status -eq "PAUSE" })

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("# Agents log")
    $lines.Add("")
    $lines.Add("Append-only ledger and the source of truth for task ownership. Older")
    $lines.Add("segments live in ``docs/history/``.")
    $lines.Add("")
    $lines.Add("## Entry format")
    $lines.Add("")
    $lines.Add('```markdown')
    $lines.Add("## [YYYY-MM-DDTHH:mm:ssZ] | agent | TASK-ID | IN_PROGRESS")
    $lines.Add("- Summary: what the agent will do or did")
    $lines.Add("- Files: paths or component names (optional)")
    $lines.Add('- Verify: command and result, or "pending" (required for DONE)')
    $lines.Add("- Pause: CATEGORY - detail (required for PAUSE)")
    $lines.Add('```')
    $lines.Add("")
    $lines.Add("## Previous segment")
    $lines.Add("")
    $lines.Add("- Archive: ``docs/history/$name``")
    $lines.Add("- SHA-256: ``$archiveHash``")
    $lines.Add("")
    $lines.Add("## Entries")
    foreach ($s in $openStates) {
        $lines.Add("")
        $lines.Add("## [$($s.Ts)] | $($s.Agent) | $($s.Task) | $($s.Status)")
        $lines.Add("- Summary: carried forward from docs/history/$name at rotation")
        if ($s.Status -eq "PAUSE") {
            $lines.Add("- Pause: $($s.PauseCat) - see docs/history/$name for detail")
        }
    }
    Write-Utf8File $log (ConvertTo-JoinedLines ([string[]]$lines))
    Write-Output "project_docs rotate: archived $name"
}

switch ($Command) {
    "init" { Invoke-Init }
    "check" { Invoke-Check }
    "context" { Get-HotContext }
    "append-log" { Invoke-AppendLog }
    "rotate" { Invoke-Rotate }
    "migrate" { Invoke-Migrate }
    "link" { Invoke-Link }
    "claim" { Invoke-Claim }
    "pause" { Invoke-Pause }
    "done" { Invoke-Done }
    "status" { Invoke-Status }
    default {
        Write-Output "Usage: project_docs.ps1 {init|check|context|append-log|rotate|migrate|link|claim|pause|done|status} <project> [args]"
    }
}
