[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet("init", "check", "context", "append-log", "rotate", "migrate", "link", "claim", "pause", "handoff", "review", "assign", "done", "status", "mode", "help")]
    [string]$Command = "help",

    [Parameter(Position = 1)]
    [string]$Project = ".",

    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Arguments
)

$ErrorActionPreference = "Stop"
# init and migrate take flags (--classic, --factory); with no project given the
# first argument is already a flag, so the project is the current folder.
if (($Command -eq "init" -or $Command -eq "migrate") -and $Project.StartsWith("--")) {
    $Arguments = @($Project) + @($Arguments)
    $Project = "."
}
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
# Factory or classic for init (ADR-047). A project the skill does not manage yet
# starts in Factory mode; --classic or PROJECT_DOCS_MODE=classic keep the
# six-file project. A project it already manages never switches mode on its own:
# with a Factory section its Mode decides, without one it stays classic
# (BR-008). migrate --factory is the way to switch an existing one.
function Get-InitKind([bool]$ClassicFlag) {
    if ($ClassicFlag) { return "classic" }
    if ("$env:PROJECT_DOCS_MODE".ToLowerInvariant() -eq "classic") { return "classic" }
    if (Test-FactorySectionExists) {
        if ((Get-FactorySetting "Mode").ToUpperInvariant() -eq "FACTORY") { return "factory" }
        return "classic"
    }
    $agents = Join-Path $Project "AGENTS.md"
    if ((Test-Path -LiteralPath $agents -PathType Leaf) -and (Test-HasBlock $agents)) { return "classic" }
    foreach ($rel in $ContractFiles) {
        if ($rel -eq "AGENTS.md") { continue }
        if (Test-Path -LiteralPath (Join-Path $Project $rel) -PathType Leaf) { return "classic" }
    }
    return "factory"
}

function Invoke-Init {
    Invoke-InitRun (Get-InitKind (@($Arguments) -ccontains "--classic"))
}

function Invoke-InitRun([string]$Kind) {
    Require-Templates
    $created = 0
    $initFiles = @($ContractFiles)
    $agentsTpl = Join-Path $TemplatesDir "AGENTS.md"
    if ($Kind -eq "factory") {
        $initFiles = @($ContractFiles) + @("docs/Brain.md")
        $agentsTpl = Join-Path $TemplatesDir "AGENTS.factory.md"
        if (-not (Test-Path -LiteralPath $agentsTpl -PathType Leaf)) { throw "template missing: AGENTS.factory.md" }
    }
    foreach ($rel in $initFiles) {
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
                    Set-Block $target $agentsTpl | Out-Null
                    Write-Output "= merged skill block: $rel"
                }
            } else {
                Set-Block $target $agentsTpl | Out-Null
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
    if ($Kind -eq "factory") {
        New-Item -ItemType Directory -Path (Join-Path $DocsDir "specs") -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path (Join-Path $DocsDir "brain") "tasks") -Force | Out-Null
    }
    Write-Output "project_docs init: $created file(s) created"
    Invoke-LinkAll $Project ""
}

# The heading line and everything up to (not including) the next "## " heading.
function Get-TemplateSection([string]$Path, [string]$Heading) {
    $out = [System.Collections.Generic.List[string]]::new()
    $p = $false
    foreach ($line in @(Get-ContentUtf8 -LiteralPath $Path)) {
        if ($line -ceq $Heading) { $p = $true; $out.Add($line); continue }
        if ($p -and $line.StartsWith("## ")) { break }
        if ($p) { $out.Add($line) }
    }
    return $out.ToArray()
}

# Puts the section before the given heading when it exists, else before the
# managed-block end marker, else at the end of the file. Nothing already in the
# target is changed or removed.
function Add-SectionToFile([string]$Target, [string[]]$Section, [string]$BeforeHeading) {
    $lines = @(Get-ContentUtf8 -LiteralPath $Target)
    $sec = [System.Collections.Generic.List[string]]::new()
    $sec.AddRange([string[]]$Section)
    while ($sec.Count -gt 0 -and $sec[$sec.Count - 1] -eq "") { $sec.RemoveAt($sec.Count - 1) }
    $pos = -1
    if ($BeforeHeading) {
        for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -ceq $BeforeHeading) { $pos = $i; break } }
    }
    if ($pos -lt 0) {
        for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -ceq $BlockEnd) { $pos = $i; break } }
    }
    if ($pos -lt 0) { $pos = $lines.Count }
    $result = [System.Collections.Generic.List[string]]::new()
    for ($i = 0; $i -lt $pos; $i++) { $result.Add([string]$lines[$i]) }
    if ($pos -gt 0 -and $lines[$pos - 1] -ne "") { $result.Add("") }
    $result.AddRange([string[]]$sec.ToArray())
    if ($pos -lt $lines.Count) { $result.Add("") }
    for ($i = $pos; $i -lt $lines.Count; $i++) { $result.Add([string]$lines[$i]) }
    Write-Utf8File $Target (ConvertTo-JoinedLines ([string[]]$result.ToArray()))
}

# What migrate --factory adds to an existing project. Idempotent and additive:
# the Factory section, the default roster when there is none, docs/Brain.md and
# the docs/specs and docs/brain/tasks folders. Leaves the number of changes in
# $script:FactoryChanges (a return value would swallow the messages).
function Add-FactoryAdditions {
    $changes = 0
    $tpl = Join-Path $TemplatesDir "AGENTS.factory.md"
    if (-not (Test-Path -LiteralPath $tpl -PathType Leaf)) { throw "template missing: AGENTS.factory.md" }
    $agents = Join-Path $Project "AGENTS.md"
    # The edits below match whole lines, so a CRLF AGENTS.md is made LF first (and
    # said so); the check and the other commands read either ending.
    $rawAgents = [System.IO.File]::ReadAllText($agents, $Utf8)
    if ($rawAgents.Contains([string][char]13)) {
        Write-Utf8File $agents $rawAgents.Replace([string][char]13, "")
        Write-Output "= normalized: AGENTS.md line endings (CRLF to LF)"
        $changes++
    }
    if (-not (Test-FactorySectionExists)) {
        Add-SectionToFile $agents (Get-TemplateSection $tpl "## Factory") "## Agent identity"
        Write-Output "+ added: ## Factory section in AGENTS.md"
        $changes++
    } elseif ((Get-FactorySetting "Mode").ToUpperInvariant() -ne "FACTORY") {
        Write-Output "= kept: Mode is not FACTORY in AGENTS.md (set it to FACTORY to switch)"
    }
    $hasRoster = $false
    foreach ($line in @(Get-ContentUtf8 -LiteralPath $agents)) { if ($line -ceq "## Agent identity") { $hasRoster = $true; break } }
    if (-not $hasRoster) {
        Add-SectionToFile $agents (Get-TemplateSection $tpl "## Agent identity") ""
        Write-Output "+ added: ## Agent identity section with the default roster in AGENTS.md"
        $changes++
    } elseif (@(Get-RosterRows).Count -eq 0) {
        $rows = @(Get-TemplateSection $tpl "## Agent identity" | Where-Object { $_.StartsWith("|") -and -not $_.StartsWith("| Agent id") -and -not $_.StartsWith("|---") })
        $lines = @(Get-ContentUtf8 -LiteralPath $agents)
        $result = [System.Collections.Generic.List[string]]::new()
        $insec = $false; $done = $false
        $placeholder = "| $EmDash | $EmDash | $EmDash | $EmDash | $EmDash |"
        $ph = $lines -ccontains $placeholder
        foreach ($line in $lines) {
            if ($line -ceq "## Agent identity") { $insec = $true; $result.Add([string]$line); continue }
            if ($insec -and $line.StartsWith("## ")) { $insec = $false }
            if ($insec -and -not $done -and $line -ceq $placeholder) {
                foreach ($r in $rows) { $result.Add([string]$r) }
                $done = $true
                continue
            }
            $result.Add([string]$line)
            if ($insec -and -not $done -and -not $ph -and $line.StartsWith("|-")) {
                foreach ($r in $rows) { $result.Add([string]$r) }
                $done = $true
            }
        }
        if ($done) {
            Write-Utf8File $agents (ConvertTo-JoinedLines ([string[]]$result.ToArray()))
            Write-Output "+ added: default agent roster in AGENTS.md"
            $changes++
        }
    }
    # The classic block tells agents to escalate to a human; in Factory mode the
    # autonomy policy replaces that. Add the pointer after the bullet, never edit it.
    $ptr = '- In Factory mode the autonomy policy in `## Factory` replaces asking a human.'
    $lines = @(Get-ContentUtf8 -LiteralPath $agents)
    if (-not ($lines -ccontains $ptr)) {
        $result = [System.Collections.Generic.List[string]]::new()
        $f = $false; $inserted = $false
        foreach ($line in $lines) {
            $result.Add([string]$line)
            if ($f -and $line.Contains("record the outcome either way.")) { $result.Add($ptr); $f = $false; $inserted = $true }
            if ($line.StartsWith("- Escalate to the human when a choice affects product behavior, cost,", [System.StringComparison]::Ordinal)) { $f = $true }
        }
        if ($inserted) {
            Write-Utf8File $agents (ConvertTo-JoinedLines ([string[]]$result.ToArray()))
            Write-Output "+ added: Factory pointer in Technical and product decisions"
            $changes++
        }
    }
    if (-not (Test-Path -LiteralPath (Join-Path $DocsDir "Brain.md") -PathType Leaf)) {
        Copy-Item -LiteralPath (Join-Path $TemplatesDir "Brain.md") -Destination (Join-Path $DocsDir "Brain.md")
        Write-Output "+ created: docs/Brain.md"
        $changes++
    }
    foreach ($rel in @("specs", "brain/tasks")) {
        $d = Join-Path $DocsDir $rel
        if (-not (Test-Path -LiteralPath $d -PathType Container)) {
            New-Item -ItemType Directory -Path $d -Force | Out-Null
            Write-Output "+ created: docs/$rel/"
            $changes++
        }
    }
    $script:FactoryChanges = $changes
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
    $lastStatus = @{}; $lastAgent = @{}; $lastTs = @{}; $lastPause = @{}; $everDone = @{}; $conflict = @{}; $lastName = @{}
    $hold = @{}; $lastHandoff = @{}; $lastReview = @{}; $lastPhase = @{}
    $cur = $null
    foreach ($line in $lines) {
        if ($line -eq "## Entries") { $inEntries = $true; continue }
        if (-not $inEntries) { continue }
        if ($line -match '^## \[([^\]]*)\] \| ([^|]*) \| ([^|]*) \| ([^|]*)(?:\|\s*(.*))?$') {
            $ts = $Matches[1].Trim()
            $agent = $Matches[2].Trim()
            $tid = $Matches[3].Trim()
            $status = $Matches[4].Trim()
            $name = if ($Matches[5]) { $Matches[5].Trim() } else { "" }
            if (-not $lastStatus.ContainsKey($tid)) { $order.Add($tid) }
            if ($status -eq "IN_PROGRESS") {
                if ($lastStatus[$tid] -eq "IN_PROGRESS" -and $lastAgent[$tid] -cne $agent) {
                    $conflict[$tid] = "$($lastAgent[$tid]) vs $agent"
                } elseif ($lastStatus[$tid] -eq "REVIEW" -and $hold.ContainsKey($tid) -and $hold[$tid] -cne $agent -and -not (Test-IsOld $lastTs[$tid] $ts)) {
                    $conflict[$tid] = "$($hold[$tid]) vs $agent"
                }
                $hold[$tid] = $agent
                $lastHandoff[$tid] = ""
            }
            if ($status -eq "ASSIGNED") { $lastHandoff[$tid] = "" }
            if ($status -eq "DONE") { $everDone[$tid] = $true }
            $lastStatus[$tid] = $status
            $lastAgent[$tid] = $agent
            $lastTs[$tid] = $ts
            $lastPause[$tid] = ""
            $lastReview[$tid] = ""
            if ($name -ne "") { $lastName[$tid] = $name }
            $cur = $tid
            continue
        }
        if ($cur -and $line -match '^- Assign:\s*(.*?)\s*$') {
            if ($lastStatus[$cur] -eq "ASSIGNED" -and $Matches[1]) {
                $hold[$cur] = $Matches[1]
                $lastHandoff[$cur] = $Matches[1]
            }
            continue
        }
        if ($cur -and $line -match '^- Handoff:\s*(.*?)\s*$') {
            $lastHandoff[$cur] = $Matches[1]
            continue
        }
        if ($cur -and $line -match '^- Phase:\s*(.*?)\s*$') {
            $lastPhase[$cur] = $Matches[1]
            continue
        }
        if ($cur -and $line -match '^- Review:\s*(.*)$') {
            $rbody = $Matches[1]
            $rdash = $rbody.IndexOf(" - ")
            if ($rdash -ge 0) { $lastReview[$cur] = $rbody.Substring(0, $rdash).TrimEnd() } else { $lastReview[$cur] = $rbody.TrimEnd() }
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
            Name = $(if ($lastName.ContainsKey($t)) { $lastName[$t] } else { "" })
            Holder = $(if ($hold.ContainsKey($t)) { $hold[$t] } else { $lastAgent[$t] })
            Handoff = $(if ($lastHandoff.ContainsKey($t)) { $lastHandoff[$t] } else { "" })
            Review = $(if ($lastReview.ContainsKey($t)) { $lastReview[$t] } else { "" })
            Phase = $(if ($lastPhase.ContainsKey($t)) { $lastPhase[$t] } else { "" })
        })
    }
    return $result
}

# True when the gap between two entry timestamps is at least the stale
# threshold (PROJECT_DOCS_STALE_HOURS). Unparseable timestamps are never old.
function Test-IsOld([string]$Prev, [string]$Cur) {
    try {
        $styles = [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor [System.Globalization.DateTimeStyles]::AssumeUniversal
        $fmt = "yyyy-MM-ddTHH:mm:ssZ"
        $inv = [System.Globalization.CultureInfo]::InvariantCulture
        $a = [DateTime]::ParseExact($Prev, $fmt, $inv, $styles)
        $b = [DateTime]::ParseExact($Cur, $fmt, $inv, $styles)
        return (($b - $a).TotalSeconds -ge ($StaleHours * 3600))
    } catch {
        return $false
    }
}

# The stage text status and context print. ASCII "->" so sh and PowerShell
# print the same bytes whatever the console code page. A Review: FAIL means
# the task is back with its holder, i.e. IN_PROGRESS.
function Get-StageLabel([string]$Status, [string]$Review, [string]$Handoff) {
    if ($Status -eq "ASSIGNED") {
        if ($Handoff) { return "ASSIGNED->$Handoff" }
        return "ASSIGNED"
    }
    if ($Status -ne "REVIEW") { return $Status }
    if ($Review -eq "FAIL") { return "IN_PROGRESS" }
    $label = "REVIEW"
    if ($Review -eq "PASS") { $label = "REVIEW(PASS)" }
    if ($Handoff) { $label = "$label->$Handoff" }
    return $label
}

# Open tasks: last entry IN_PROGRESS, PAUSE or REVIEW (a REVIEW task stays
# open until DONE, including after a Review: FAIL, when it is back with its
# holder).
function Get-OpenTaskStates {
    return @(Get-TaskStates | Where-Object { $_.Status -eq "IN_PROGRESS" -or $_.Status -eq "PAUSE" -or $_.Status -eq "REVIEW" -or $_.Status -eq "ASSIGNED" })
}

# ---------------------------------------------------------------------------
# Agent identity. The optional "## Agent identity" table in the project root
# AGENTS.md lists one stable id per agent plus aliases. With at least one data
# row, claim/pause/handoff/review/done normalise the agent name to its Agent id
# (case-insensitive match against id and aliases); an unknown name only warns
# and is used as typed. Without the section or rows nothing changes: no
# normalisation, no warnings.
# ---------------------------------------------------------------------------
# Get-RosterRows: one object per data row (Id, Kind, Model, Role, Aliases).
function Get-RosterRows {
    $path = Join-Path $Project "AGENTS.md"
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return @() }
    $rows = [System.Collections.Generic.List[object]]::new()
    $insec = $false
    foreach ($line in @(Get-ContentUtf8 -LiteralPath $path)) {
        if ($line -eq "## Agent identity") { $insec = $true; continue }
        if ($insec -and $line.StartsWith("## ")) { $insec = $false }
        if ($insec -and $line.StartsWith("|")) {
            $c = @(Split-TableCells $line)
            if ($c.Count -lt 1) { continue }
            $id = $c[0]
            if ($id -eq "" -or $id -eq "Agent id" -or $id -eq $EmDash -or $id -match '^-+$') { continue }
            $rows.Add([PSCustomObject]@{
                Id = $id
                Kind = $(if ($c.Count -gt 1) { $c[1] } else { "" })
                Model = $(if ($c.Count -gt 2) { $c[2] } else { "" })
                Role = $(if ($c.Count -gt 3) { $c[3] } else { "" })
                Aliases = $(if ($c.Count -gt 4) { $c[4] } else { "" })
            })
        }
    }
    return $rows
}

function Get-RosterAliases($Row) {
    $out = [System.Collections.Generic.List[string]]::new()
    foreach ($a in @($Row.Aliases -split ',')) {
        $x = $a.Trim()
        if ($x -ne "" -and $x -ne $EmDash) { $out.Add($x) }
    }
    return $out
}

function Get-CanonicalAgent([string]$Raw) {
    $rows = @(Get-RosterRows)
    if ($rows.Count -eq 0) { return $Raw }
    foreach ($r in $rows) {
        if ($r.Id -ieq $Raw) { return $r.Id }
        foreach ($a in @(Get-RosterAliases $r)) { if ($a -ieq $Raw) { return $r.Id } }
    }
    [Console]::Error.WriteLine("WARN: unknown agent `"$Raw`" (not in the Agent identity table)")
    return $Raw
}

# DEVELOPER is the legacy name of DEV (D-05).
function Get-RoleNorm([string]$Role) {
    if ($Role -ceq "DEVELOPER") { return "DEV" }
    return $Role
}

# The roster role that works in a phase (D-05).
function Get-PhaseRole([string]$Phase) {
    switch -CaseSensitive ($Phase) {
        "SPEC" { return "SPEC" }
        "RED" { return "TEST" }
        "GREEN" { return "DEV" }
        "REVIEW" { return "QA" }
        default { return "" }
    }
}

# Factory mode only. The agent must be in the roster with the role of the phase,
# or BOTH.
function Assert-PhaseRole([string]$Agent, [string]$Phase, [string]$Task) {
    $role = Get-RosterRole $Agent
    if (-not $role) {
        throw "claim failed: $Agent is not in the Agent identity table; Factory mode needs a role for each agent"
    }
    $norm = Get-RoleNorm $role
    $need = Get-PhaseRole $Phase
    if ($norm -cne "BOTH" -and $norm -cne $need) {
        throw "claim failed: $Agent has role $role, but phase $Phase of $Task needs $need (or BOTH)"
    }
}

# Get-RosterRole ID: the Role (DEVELOPER, QA or BOTH) of a roster id, or "".
function Get-RosterRole([string]$Id) {
    foreach ($r in @(Get-RosterRows)) { if ($r.Id -ceq $Id) { return $r.Role } }
    return ""
}

# Seconds between two ledger timestamps, or -1 when either does not parse.
function Get-GapSeconds([string]$A, [string]$B) {
    try {
        $styles = [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor [System.Globalization.DateTimeStyles]::AssumeUniversal
        $fmt = "yyyy-MM-ddTHH:mm:ssZ"
        $inv = [System.Globalization.CultureInfo]::InvariantCulture
        $x = [DateTime]::ParseExact($A, $fmt, $inv, $styles)
        $y = [DateTime]::ParseExact($B, $fmt, $inv, $styles)
        return [long][Math]::Floor(($y - $x).TotalSeconds)
    } catch {
        return -1
    }
}

# "3s" under a minute, otherwise "2m".
function Get-GapLabel([long]$Seconds) {
    if ($Seconds -lt 60) { return "${Seconds}s" }
    return "$([long][Math]::Floor($Seconds / 60))m"
}

# Timestamp of the first IN_PROGRESS entry of a task in the hot ledger.
function Get-FirstClaimTs([string]$Task) {
    $log = Join-Path $DocsDir "Agentslog.md"
    if (-not (Test-Path -LiteralPath $log -PathType Leaf)) { return "" }
    $inEntries = $false
    foreach ($line in @(Get-ContentUtf8 -LiteralPath $log)) {
        if ($line -eq "## Entries") { $inEntries = $true; continue }
        if (-not $inEntries) { continue }
        if ($line -match '^## \[([^\]]*)\] \| ([^|]*) \| ([^|]*) \| ([^|]*)') {
            if ($Matches[3].Trim() -eq $Task -and $Matches[4].Trim() -eq "IN_PROGRESS") { return $Matches[1].Trim() }
        }
    }
    return ""
}

# ---------------------------------------------------------------------------
# Factory mode (F06, ADR-023). The optional "## Factory" section of the project
# AGENTS.md holds a "Setting | Value" table the scripts read. Without the
# section, or with Mode CLASSIC, nothing in this block changes any behavior
# (BR-008). PROJECT_DOCS_MODE=classic or factory overrides the file (tests).
# A missing row, or a value of just an em dash, takes its default (ADR-025).
# ---------------------------------------------------------------------------
$script:FactoryMode = $null
$script:FactoryModeSource = $null

function Get-FactorySettingNames {
    return @("Mode", "Require TDD", "Independent review", "WIP per agent", "Max fix attempts",
        "Fast lane max files", "Fast lane max lines", "Fast lane protected paths",
        "Preferred reviewer", "Fallback reviewer", "Recall budget bytes", "Brain max entries")
}

function Get-FactoryDefault([string]$Name) {
    switch -CaseSensitive ($Name) {
        "Mode" { return "FACTORY" }
        "Require TDD" { return "YES" }
        "Independent review" { return "YES" }
        "WIP per agent" { return "1" }
        "Max fix attempts" { return "3" }
        "Fast lane max files" { return "5" }
        "Fast lane max lines" { return "150" }
        "Fast lane protected paths" { return "prisma/ migrations/ auth/ rls/ security/" }
        "Recall budget bytes" { return "4096" }
        "Brain max entries" { return "80" }
        default { return "" }
    }
}

# True when AGENTS.md has a "## Factory" heading.
function Test-FactorySectionExists {
    $path = Join-Path $Project "AGENTS.md"
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $false }
    foreach ($line in @(Get-ContentUtf8 -LiteralPath $path)) { if ($line -ceq "## Factory") { return $true } }
    return $false
}

# The trimmed value cell of the row, or empty.
function Get-FactoryRawValue([string]$Name) {
    $path = Join-Path $Project "AGENTS.md"
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return "" }
    $insec = $false
    foreach ($line in @(Get-ContentUtf8 -LiteralPath $path)) {
        if ($line -ceq "## Factory") { $insec = $true; continue }
        if ($insec -and $line.StartsWith("## ")) { $insec = $false }
        if ($insec -and $line.StartsWith("|")) {
            $c = @(Split-TableCells $line)
            if ($c.Count -ge 2 -and $c[0] -ceq $Name) {
                if ($c[1] -eq $EmDash) { return "" }
                return $c[1]
            }
        }
    }
    return ""
}

# The effective value (the row, else the default).
function Get-FactorySetting([string]$Name) {
    $v = Get-FactoryRawValue $Name
    if (-not $v) { $v = Get-FactoryDefault $Name }
    return $v
}

# The setting as a positive integer of at most nine digits without leading
# zeros; anything else (text, zero, a huge number) is the default.
function Get-FactoryNumber([string]$Name) {
    $v = Get-FactorySetting $Name
    if ($v -notmatch '^[0-9]+$') { return (Get-FactoryDefault $Name) }
    $v = $v.TrimStart('0')
    if (-not $v -or $v.Length -gt 9) { return (Get-FactoryDefault $Name) }
    return $v
}

# Sets FactoryMode (FACTORY or CLASSIC) and FactoryModeSource (env, AGENTS.md or
# default). An unknown Mode value is CLASSIC: the conservative reading.
function Resolve-FactoryMode {
    $envv = "$env:PROJECT_DOCS_MODE".ToLowerInvariant()
    if ($envv -eq "factory") { $script:FactoryMode = "FACTORY"; $script:FactoryModeSource = "env"; return }
    if ($envv -eq "classic") { $script:FactoryMode = "CLASSIC"; $script:FactoryModeSource = "env"; return }
    if (Test-FactorySectionExists) {
        $m = (Get-FactorySetting "Mode").ToUpperInvariant()
        $script:FactoryMode = $(if ($m -eq "FACTORY") { "FACTORY" } else { "CLASSIC" })
        $script:FactoryModeSource = "AGENTS.md"
    } else {
        $script:FactoryMode = "CLASSIC"
        $script:FactoryModeSource = "default"
    }
}

# True in Factory mode (resolved once per process).
function Test-FactoryOn {
    if (-not $script:FactoryMode) { Resolve-FactoryMode }
    return ($script:FactoryMode -eq "FACTORY")
}

# mode: which mode applies, and in Factory mode the effective settings.
function Invoke-Mode {
    Resolve-FactoryMode
    Write-Output "project_docs mode: $($script:FactoryMode) ($($script:FactoryModeSource))"
    if ($script:FactoryMode -eq "FACTORY") {
        foreach ($n in @(Get-FactorySettingNames)) {
            $val = $(if ($n -ceq "Mode") { $script:FactoryMode } else { Get-FactorySetting $n })
            if (-not $val) { Write-Output "$n =" } else { Write-Output "$n = $val" }
        }
    }
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
    $states = @(Get-OpenTaskStates)
    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($s in $states) {
        $hrs = Get-AgeHours $s.Ts
        $hrsStr = if ($null -ne $hrs) { "$hrs" } else { "?" }
        $reason = if ($s.Status -eq "PAUSE") { $s.PauseCat } else { "-" }
        $shown = if ($s.Status -eq "REVIEW") { $s.Holder } else { $s.Agent }
        $lines.Add("$($s.Task) | $shown | $(Get-StageLabel $s.Status $s.Review $s.Handoff) | ${hrsStr}h | $reason")
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
# Table row helpers, shared by Roadmap.md and Features.md.
# ---------------------------------------------------------------------------
function Split-TableCells([string]$Line) {
    $line = $Line -replace '^\|', '' -replace '\|[ \t]*$', ''
    return @($line -split '\|' | ForEach-Object { $_.Trim() })
}

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

function Get-FeaturesIds { return Get-TableIds (Join-Path $DocsDir "Features.md") }

# ---------------------------------------------------------------------------
# Roadmap/Features table rows. Every table this tool edits ends in the same
# four trailing columns (Status, Owner, Depends on, Pause reason), so cells
# are addressed from the end regardless of how many columns precede them.
# ---------------------------------------------------------------------------
function Get-RoadmapIds { return Get-TableIds (Join-Path $DocsDir "Roadmap.md") }

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
        if ($line -match '^## Gaps, Bugs & Technical Debt') { $sect = "gaps"; continue }
        if ($line -match '^## Near term') { $sect = "near"; continue }
        if ($line.StartsWith("|")) {
            $cells = @($line -split '\|')
            if ($cells.Count -ge 2 -and $cells[1].Trim() -eq $Id) { return $sect }
        }
    }
    return ""
}

# ---------------------------------------------------------------------------
# Name/Description taxonomy. Every Roadmap table carries a short, descriptive
# "Name" cell (<= 10 words; the rest of the detail goes in "Description" or
# the table's own free-text column) in the column right after ID. claim/
# pause/done refuse a task whose Name is missing or too long instead of
# silently copying it into the log; check sweeps every table the same way.
# ---------------------------------------------------------------------------
function Get-WordCount([string]$Text) {
    $parts = @($Text -split '\s+' | Where-Object { $_ -ne "" })
    return $parts.Count
}

# Returns the trimmed cell under the column named $ColName ("Name") of the
# row whose ID equals $Id, wherever that row lives in docs/Roadmap.md.
# Header-detected per table (the first "|" row after a non-"|" line), same
# convention as Test-TableStatusEnum, so it works regardless of table shape.
function Get-RoadmapRowField([string]$Id, [string]$ColName) {
    $file = Join-Path $DocsDir "Roadmap.md"
    $expectHeader = $true
    $col = -1
    foreach ($line in @(Get-ContentUtf8 -LiteralPath $file)) {
        if (-not $line.StartsWith("|")) { $expectHeader = $true; continue }
        $cells = @(Split-TableCells $line)
        if ($expectHeader) {
            $col = -1
            for ($i = 0; $i -lt $cells.Count; $i++) { if ($cells[$i] -eq $ColName) { $col = $i } }
            $expectHeader = $false
            continue
        }
        if ($cells.Count -ge 1 -and $cells[0] -eq $Id -and $col -ge 0 -and $col -lt $cells.Count) {
            return $cells[$col]
        }
    }
    return ""
}

# Emits one Id/Name pair per row, file-wide, for every table that has a Name
# column (same header detection as Get-RoadmapRowField). Used to cross-check
# Agentslog entries against the Roadmap's current Name for each ID.
function Get-RoadmapAllNames {
    $file = Join-Path $DocsDir "Roadmap.md"
    $expectHeader = $true
    $namecol = -1
    $result = @{}
    foreach ($line in @(Get-ContentUtf8 -LiteralPath $file)) {
        if (-not $line.StartsWith("|")) { $expectHeader = $true; continue }
        $cells = @(Split-TableCells $line)
        if ($expectHeader) {
            $namecol = -1
            for ($i = 0; $i -lt $cells.Count; $i++) { if ($cells[$i] -eq "Name") { $namecol = $i } }
            $expectHeader = $false
            continue
        }
        if ($cells.Count -lt 1) { continue }
        $id = $cells[0]
        if ($id -eq "" -or $id -eq $EmDash -or $id -match '^-+$') { continue }
        if ($namecol -ge 0 -and $namecol -lt $cells.Count) { $result[$id] = $cells[$namecol] }
    }
    return $result
}

# Throws if the Roadmap row for $Task has no usable Name: missing, empty, or
# over the 10-word limit. Called by claim/pause/done before they touch the
# log, so a bad Name blocks the action instead of propagating into Agentslog.
function Assert-ValidName([string]$Task, [string]$Action = "claim") {
    $name = Get-RoadmapRowField $Task "Name"
    if ($name -eq "") { throw "$Action failed: $Task has no Name cell in docs/Roadmap.md (missing row, or the table predates the Name column; run migrate)" }
    $wc = Get-WordCount $name
    if ($wc -gt 10) { throw "$Action failed: $Task Name is $wc words, over the 10-word limit: `"$name`" -- shorten it and move the rest into Description" }
    return $name
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
    # The row becomes the LAST row of the Active work table (walking back from
    # the context:end marker over the blank line that separates them), not a
    # line just above the marker, which would detach it from the table and
    # break Markdown rendering. The empty-table placeholder row goes away.
    $aw = -1; $m = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($aw -lt 0 -and $lines[$i] -eq "## Active work") { $aw = $i }
        if ($m -lt 0 -and $lines[$i] -eq "<!-- context:end -->") { $m = $i }
    }
    $k = -1
    if ($m -ge 0) {
        for ($i = $m - 1; $i -ge 0; $i--) {
            if ($lines[$i].StartsWith("|")) { $k = $i; break }
            if ($lines[$i].StartsWith("#")) { break }
        }
    }
    $result = [System.Collections.Generic.List[string]]::new()
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($i -eq $rowIdx) { continue }
        $skip = $false
        if ($aw -ge 0 -and $m -ge 0 -and $i -gt $aw -and $i -lt $m -and $lines[$i].StartsWith("|")) {
            if (($lines[$i] -replace "[|\s$EmDash]", "") -eq "") { $skip = $true }
        }
        if ($k -lt 0 -and $i -eq $m) { $result.Add($newRow) }
        if (-not $skip) { $result.Add($lines[$i]) }
        if ($i -eq $k) { $result.Add($newRow) }
    }
    if ($m -lt 0) { $result.Add($newRow) }
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

# Records a closed task in Features.md. When its ID is a task under an EPIC
# (`F01-E01-T01`, inferred from the ID shape, not a stored field) and no
# other Roadmap row still shares that epic prefix, also rolls the epic up
# with its own Features row.
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
    $agent = Get-CanonicalAgent (ConvertTo-CleanField $Arguments[0])
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
                if ($state.Agent -cne $agent -and -not (Test-Stale $task)) {
                    throw "claim failed: $task is IN_PROGRESS, owned by $($state.Agent)"
                }
            } elseif ($state.Status -eq "PAUSE") {
                if ($state.PauseCat -ne "LIMITE" -and $state.Agent -cne $agent) {
                    throw "claim failed: $task is PAUSE ($($state.PauseCat)); resolvable only by $($state.Agent) until the reason clears"
                }
            } elseif ($state.Status -eq "REVIEW") {
                # During REVIEW the developer is still the holder: they may take
                # it back (after a FAIL, or to withdraw the handoff); anyone else
                # only once the last entry is stale.
                if ($state.Holder -and $state.Holder -cne $agent -and -not (Test-Stale $task)) {
                    throw "claim failed: $task is in REVIEW, held by $($state.Holder)"
                }
            } elseif ($state.Status -eq "ASSIGNED") {
                # An assignment is a request, not a lock: another agent may still
                # take the task, but is told it was assigned to someone else.
                if ($state.Holder -and $state.Holder -cne $agent -and -not (Test-FactoryOn)) {
                    [Console]::Error.WriteLine("WARN: $task is assigned to $($state.Holder), not $agent")
                }
            }
        }
        $claimPhase = ""
        if (Test-FactoryOn) {
            $claimPhase = "SPEC"
            if ($state -and $state.Phase) { $claimPhase = $state.Phase }
            Assert-PhaseRole $agent $claimPhase $task
        }
        $name = Assert-ValidName $task "claim"
        $timestamp = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
        $claimLines = @(
            "",
            "## [$timestamp] | $agent | $task | IN_PROGRESS | $name",
            "- Summary: $summary",
            "- Verify: pending"
        )
        if (Test-FactoryOn) { $claimLines += "- Phase: $claimPhase" }
        $entry = ($claimLines -join "`n") + "`n"
        [System.IO.File]::AppendAllText($log, $entry, $Utf8)
        Invoke-RoadmapClaimRow $task $agent $timestamp
        Write-Output "project_docs claim: $task claimed by $agent"
    } finally {
        Exit-DocsLock
    }
}

function Invoke-Pause {
    if ($Arguments.Count -lt 4) { throw "pause requires: agent task-id category detail" }
    $agent = Get-CanonicalAgent (ConvertTo-CleanField $Arguments[0])
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
        if ($state.Agent -cne $agent) { throw "pause failed: $task is owned by $($state.Agent), not $agent" }
        $name = Assert-ValidName $task "pause"
        $timestamp = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
        $log = Join-Path $DocsDir "Agentslog.md"
        $entry = (@(
            "",
            "## [$timestamp] | $agent | $task | PAUSE | $name",
            "- Pause: $category - $detail"
        ) -join "`n") + "`n"
        [System.IO.File]::AppendAllText($log, $entry, $Utf8)
        Set-RoadmapRowInPlace $task "PAUSE" "$agent@$timestamp" $category
        Write-Output "project_docs pause: $task paused ($category)"
    } finally {
        Exit-DocsLock
    }
}

# handoff <agent> <task-id> <summary> <verify> [reviewer]
# The developer says the code is complete and their own verification passed.
# Written as a REVIEW entry (the Roadmap row stays IN_PROGRESS with the same
# Owner: the stage lives in the ledger only). Same ownership checks as pause.
function Invoke-Handoff {
    if ($Arguments.Count -lt 4) { throw "handoff requires: agent task-id summary verify [reviewer]" }
    $agent = Get-CanonicalAgent (ConvertTo-CleanField $Arguments[0])
    $task = ConvertTo-CleanField $Arguments[1]
    $summary = ConvertTo-CleanField $Arguments[2]
    $verify = ConvertTo-CleanField $Arguments[3]
    $reviewer = if ($Arguments.Count -ge 5) { ConvertTo-CleanField $Arguments[4] } else { "" }
    $log = Join-Path $DocsDir "Agentslog.md"
    if (-not (Test-Path -LiteralPath $log -PathType Leaf)) { throw "run init first" }
    if (-not $summary) { throw "handoff requires a non-empty summary" }
    if (-not $verify -or $verify -eq "pending") { throw "handoff requires a verify that is not empty or pending" }
    Enter-DocsLock
    try {
        $state = Get-TaskState $task
        if (-not $state) { throw "handoff failed: $task has no IN_PROGRESS entry to hand off" }
        if ($state.Status -ne "IN_PROGRESS") { throw "handoff failed: $task is not IN_PROGRESS (current: $($state.Status))" }
        if ($state.Agent -cne $agent) { throw "handoff failed: $task is owned by $($state.Agent), not $agent" }
        $name = Assert-ValidName $task "handoff"
        $timestamp = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
        $entryLines = @(
            "",
            "## [$timestamp] | $agent | $task | REVIEW | $name",
            "- Summary: $summary",
            "- Verify: $verify"
        )
        if ($reviewer) { $entryLines += "- Handoff: $reviewer" }
        $entry = ($entryLines -join "`n") + "`n"
        [System.IO.File]::AppendAllText($log, $entry, $Utf8)
        if ($reviewer) {
            Write-Output "project_docs handoff: $task handed to review ($reviewer)"
        } else {
            Write-Output "project_docs handoff: $task handed to review"
        }
    } finally {
        Exit-DocsLock
    }
}

# review <agent> <task-id> <PASS|FAIL> <note> [verify]
# A reviewer answers a pending handoff. Written as a REVIEW entry in the
# reviewer's name carrying a "- Review: PASS|FAIL - note" line; the Roadmap row
# is not touched. After FAIL the task is back with its holder, who retakes it
# with claim. Reviewing your own handoff warns (a single-agent project must not
# freeze) unless PROJECT_DOCS_REQUIRE_INDEPENDENT_REVIEW=1.
function Invoke-Review {
    if ($Arguments.Count -lt 4) { throw "review requires: agent task-id PASS|FAIL note [verify]" }
    $agent = Get-CanonicalAgent (ConvertTo-CleanField $Arguments[0])
    $task = ConvertTo-CleanField $Arguments[1]
    $result = ConvertTo-CleanField $Arguments[2]
    $note = ConvertTo-CleanField $Arguments[3]
    $verify = if ($Arguments.Count -ge 5) { ConvertTo-CleanField $Arguments[4] } else { "" }
    $log = Join-Path $DocsDir "Agentslog.md"
    if (-not (Test-Path -LiteralPath $log -PathType Leaf)) { throw "run init first" }
    if ($result -cne "PASS" -and $result -cne "FAIL") { throw "review requires PASS or FAIL as the result" }
    if (-not $note) { throw "review requires a non-empty note" }
    if ($verify -eq "pending") { throw "review verify must not be pending" }
    if ($result -ceq "PASS" -and -not $verify) { throw "review PASS requires a verify that is not empty or pending" }
    Enter-DocsLock
    try {
        $state = Get-TaskState $task
        if (-not $state) { throw "review failed: $task has no handoff to review" }
        if ($state.Status -ne "REVIEW") { throw "review failed: $task has no pending handoff (current: $($state.Status))" }
        if ($state.Review) { throw "review failed: $task was already reviewed ($($state.Review)); the holder must claim it again" }
        if ($agent -ceq $state.Holder) {
            if ($env:PROJECT_DOCS_REQUIRE_INDEPENDENT_REVIEW -eq "1") {
                throw "review failed: $agent developed $task; an independent review is required"
            }
            [Console]::Error.WriteLine("WARN: self-review: $agent reviews its own handoff of $task")
        }
        if ((Get-RosterRole $agent) -ceq "DEVELOPER") {
            [Console]::Error.WriteLine("WARN: $agent has role DEVELOPER in the Agent identity table, not QA or BOTH")
        }
        $name = Assert-ValidName $task "review"
        $timestamp = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
        $entryLines = @(
            "",
            "## [$timestamp] | $agent | $task | REVIEW | $name",
            "- Summary: Review of the handoff from $($state.Holder)"
        )
        if ($verify) { $entryLines += "- Verify: $verify" }
        $entryLines += "- Review: $result - $note"
        $entry = ($entryLines -join "`n") + "`n"
        [System.IO.File]::AppendAllText($log, $entry, $Utf8)
        Write-Output "project_docs review: $task $result by $agent"
    } finally {
        Exit-DocsLock
    }
}

# assign <agent> <task-id> <to-agent>
# Records that <agent> assigned the task to <to-agent> (an ASSIGNED entry with a
# "- Assign:" line) and sets the Roadmap Owner to <to-agent>@<timestamp>. The
# row stays TODO and no work starts: the assignee still has to claim. A task
# somebody is already working on (IN_PROGRESS, PAUSE, REVIEW) cannot be assigned.
function Invoke-Assign {
    if ($Arguments.Count -lt 3) { throw "assign requires: agent task-id to-agent" }
    $agent = Get-CanonicalAgent (ConvertTo-CleanField $Arguments[0])
    $task = ConvertTo-CleanField $Arguments[1]
    $toAgent = Get-CanonicalAgent (ConvertTo-CleanField $Arguments[2])
    $log = Join-Path $DocsDir "Agentslog.md"
    if (-not (Test-Path -LiteralPath $log -PathType Leaf)) { throw "run init first" }
    if (-not $toAgent) { throw "assign requires a non-empty to-agent" }
    if (-not (Test-RoadmapHasId $task)) { throw "assign failed: $task not found in docs/Roadmap.md" }
    Enter-DocsLock
    try {
        $state = Get-TaskState $task
        if ($state -and $state.Status -in @("IN_PROGRESS", "PAUSE", "REVIEW")) {
            throw "assign failed: $task is $($state.Status), held by $($state.Holder)"
        }
        $name = Assert-ValidName $task "assign"
        $timestamp = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
        $entry = (@(
            "",
            "## [$timestamp] | $agent | $task | ASSIGNED | $name",
            "- Summary: Assigned to $toAgent",
            "- Assign: $toAgent"
        ) -join "`n") + "`n"
        [System.IO.File]::AppendAllText($log, $entry, $Utf8)
        Set-RoadmapRowInPlace $task "TODO" "$toAgent@$timestamp" $EmDash
        Write-Output "project_docs assign: $task assigned to $toAgent"
    } finally {
        Exit-DocsLock
    }
}

function Invoke-Done {
    if ($Arguments.Count -lt 5) { throw "done requires: agent task-id summary files verify" }
    $agent = Get-CanonicalAgent (ConvertTo-CleanField $Arguments[0])
    $task = ConvertTo-CleanField $Arguments[1]
    $summary = ConvertTo-CleanField $Arguments[2]
    $files = ConvertTo-CleanField $Arguments[3]
    $verify = ConvertTo-CleanField $Arguments[4]
    if (-not $verify) { throw "done requires a non-empty verify" }
    Enter-DocsLock
    try {
        # Who may close a task: nobody has an entry for it (retroactive close,
        # the normal case for batches), the holder, the reviewer who left
        # Review: PASS, anyone once the last entry is stale, or anyone with
        # PROJECT_DOCS_FORCE=1.
        $state = Get-TaskState $task
        if ($state) {
            $allowed = $false
            if ($agent -ceq $state.Holder) { $allowed = $true }
            elseif ($state.Status -eq "REVIEW" -and $state.Review -ceq "PASS" -and $agent -ceq $state.Agent) { $allowed = $true }
            elseif ($env:PROJECT_DOCS_FORCE -eq "1") { $allowed = $true }
            elseif (Test-Stale $task) { $allowed = $true }
            if (-not $allowed) { throw "done failed: $task is held by $($state.Holder)" }
            if ($state.Status -eq "REVIEW" -and $state.Review -cne "PASS") {
                if ($state.Review -ceq "FAIL") {
                    [Console]::Error.WriteLine("WARN: ${task}: closing without a passing review (the last review was FAIL)")
                } else {
                    [Console]::Error.WriteLine("WARN: ${task}: closing without a passing review (the handoff is still pending)")
                }
            }
        }
        $vlow = $verify.Trim().ToLowerInvariant()
        if ($vlow -in @("none", "n/a", "no run", "ninguno", [string]$EmDash, "unknown")) {
            [Console]::Error.WriteLine("WARN: verify `"$verify`" says nothing about what was checked")
        }
        $name = Assert-ValidName $task "done"
        $timestamp = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
        $claimTs = Get-FirstClaimTs $task
        if ($claimTs) {
            $minWork = 5
            if ($env:PROJECT_DOCS_MIN_WORK_MINUTES -match '^\d+$') { $minWork = [int]$env:PROJECT_DOCS_MIN_WORK_MINUTES }
            $gap = Get-GapSeconds $claimTs $timestamp
            if ($gap -ge 0 -and $gap -lt ($minWork * 60)) {
                [Console]::Error.WriteLine("WARN: $task was claimed and closed $(Get-GapLabel $gap) apart; claim before the first edit so the work is visible while it happens")
            }
        }
        $log = Join-Path $DocsDir "Agentslog.md"
        $entry = (@(
            "",
            "## [$timestamp] | $agent | $task | DONE | $name",
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
    $states = @(Get-OpenTaskStates)
    foreach ($s in $states) {
        $hrs = Get-AgeHours $s.Ts
        $hrsStr = if ($null -ne $hrs) { "$hrs" } else { "?" }
        $reason = if ($s.Status -eq "PAUSE") { $s.PauseCat } else { "-" }
        $stale = ""
        if ($s.Status -ne "PAUSE" -and $s.Status -ne "ASSIGNED" -and $null -ne $hrs -and $hrs -ge $StaleHours) { $stale = " (stale)" }
        $shown = if ($s.Status -eq "REVIEW") { $s.Holder } else { $s.Agent }
        Write-Output "$($s.Task) | $($s.Name) | $shown | $(Get-StageLabel $s.Status $s.Review $s.Handoff) | ${hrsStr}h$stale | $reason"
    }
}

# ---------------------------------------------------------------------------
# migrate
# ---------------------------------------------------------------------------
# True if docs/Roadmap.md still uses the pre-rewrite table format (any of
# its three old section headings). A file already in the new per-entry YAML
# format, or a fresh one just scaffolded from the template, has none of
# these, so this is also the idempotency check for the conversion below.
function Set-RoadmapSectionsEnsured {
    $file = Join-Path $DocsDir "Roadmap.md"
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { return }
    $content = [System.IO.File]::ReadAllText($file, $Utf8)
    $changed = $false
    if (-not $content.Contains("## Plan")) {
        $content += "`n## Plan`n`nFull PHASE -> EPIC -> TASK -> SUBTASK hierarchy for pending work.`n"
        $changed = $true
    }
    if (-not $content.Contains("## Gaps, Bugs & Technical Debt")) {
        $content += "`n## Gaps, Bugs & Technical Debt`n`n| ID | Name | Severity | Phase | Description | Status | Owner | Depends on | Pause reason |`n|---|---|---|---|---|---|---|---|---|`n| $EmDash | $EmDash | $EmDash | $EmDash | $EmDash | $EmDash | $EmDash | $EmDash | $EmDash |`n"
        $changed = $true
    }
    if (-not $content.Contains("## Out of scope")) {
        $content += "`n## Out of scope`n`n- ``UNKNOWN```n"
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

function Get-FirstNWords([string]$Text, [int]$N) {
    $words = @($Text -split '\s+' | Where-Object { $_ -ne "" })
    if ($words.Count -eq 0) { return "UNKNOWN" }
    $take = [Math]::Min($N, $words.Count)
    return ($words[0..($take - 1)] -join " ")
}

# Non-destructive, idempotent: inserts a short "Name" column (<= 10 words;
# the rest of the detail stays in Description or the table's own free-text
# column) into every Roadmap table that doesn't have one yet. Detects each
# table's kind by its header (same convention as Test-TableStatusEnum), not
# by position, so it runs after Set-RoadmapSectionsEnsured has already
# normalized Active work's column count and also catches whatever shape
# Convert-RoadmapYamlToTable just emitted, in the same migrate run:
#   - Active work / Plan task rows (Outcome + Owner): Outcome is preserved
#     verbatim as Description; Name is derived as its first 10 words.
#   - Near term rows (Outcome, no Owner): Outcome -> Name, renamed in place,
#     not truncated (no Description column there) -- a row whose old Outcome
#     exceeds 10 words will still fail check's word limit until shortened by
#     hand, same as any other flagged-for-review migration output.
#   - Gaps/Bugs/Technical Debt rows (Severity + Phase): Description is
#     preserved verbatim; Name is derived as its first 10 words.
# A table that already has a Name column, or has no ID column at all (not
# one of ours), passes through byte-for-byte.
function Add-RoadmapNameColumn {
    $file = Join-Path $DocsDir "Roadmap.md"
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { return $false }
    $lines = @(Get-ContentUtf8 -LiteralPath $file)
    $out = [System.Collections.Generic.List[string]]::new()
    $expectHeader = $true
    $expectSep = $false
    $state = "none"
    foreach ($line in $lines) {
        if (-not $line.StartsWith("|")) {
            $out.Add($line)
            $expectHeader = $true
            $expectSep = $false
            continue
        }
        if ($expectHeader) {
            $cells = @(Split-TableCells $line)
            $hasId = $cells -contains "ID"
            $hasName = $cells -contains "Name"
            $hasOutcome = $cells -contains "Outcome"
            $hasOwner = $cells -contains "Owner"
            $hasSev = $cells -contains "Severity"
            $hasPhase = $cells -contains "Phase"
            $expectHeader = $false
            if ((-not $hasId) -or $hasName) {
                $state = "other"; $out.Add($line); continue
            }
            if ($hasOutcome -and $hasOwner) {
                $state = "task"
                $out.Add("| ID | Name | Description | Acceptance check | Status | Owner | Depends on | Pause reason |")
                $expectSep = $true; continue
            }
            if ($hasOutcome) {
                $state = "nearterm"
                $out.Add("| ID | Name | Acceptance check | Status | Depends on |")
                $expectSep = $true; continue
            }
            if ($hasSev -and $hasPhase) {
                $state = "gaps"
                $out.Add("| ID | Name | Severity | Phase | Description | Status | Owner | Depends on | Pause reason |")
                $expectSep = $true; continue
            }
            $state = "other"; $out.Add($line); continue
        }
        if ($expectSep) {
            $expectSep = $false
            if ($state -eq "task") { $out.Add("|---|---|---|---|---|---|---|---|") }
            elseif ($state -eq "nearterm") { $out.Add("|---|---|---|---|---|") }
            elseif ($state -eq "gaps") { $out.Add("|---|---|---|---|---|---|---|---|---|") }
            else { $out.Add($line) }
            continue
        }
        if ($state -eq "task") {
            $c = @(Split-TableCells $line)
            $name = Get-FirstNWords $c[1] 10
            $out.Add("| $($c[0]) | $name | $($c[1]) | $($c[2]) | $($c[3]) | $($c[4]) | $($c[5]) | $($c[6]) |")
            continue
        }
        if ($state -eq "nearterm") {
            $c = @(Split-TableCells $line)
            $out.Add("| $($c[0]) | $($c[1]) | $($c[2]) | $($c[3]) | $($c[4]) |")
            continue
        }
        if ($state -eq "gaps") {
            $c = @(Split-TableCells $line)
            $name = Get-FirstNWords $c[3] 10
            $out.Add("| $($c[0]) | $name | $($c[1]) | $($c[2]) | $($c[3]) | $($c[4]) | $($c[5]) | $($c[6]) | $($c[7]) |")
            continue
        }
        $out.Add($line)
    }
    $newContent = ConvertTo-JoinedLines ([string[]]$out)
    $oldContent = ConvertTo-JoinedLines $lines
    if ($newContent -eq $oldContent) { return $false }
    Write-Utf8File $file $newContent
    return $true
}

# True if docs/Roadmap.md still uses the per-entry YAML block format from the
# short-lived schema this skill used before reverting to Markdown tables.
function Test-RoadmapNeedsYamlMigration {
    $file = Join-Path $DocsDir "Roadmap.md"
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { return $false }
    foreach ($line in @(Get-ContentUtf8 -LiteralPath $file)) {
        if ($line -match '^```yaml[ \t]*$') { return $true }
    }
    return $false
}

function ConvertTo-MigratedWfStatus([string]$S) {
    switch ($S.Trim()) {
        { $_ -in @("IDEA", "BACKLOG", "READY", "PENDING") } { return "TODO" }
        { $_ -in @("IN_PROGRESS", "REVIEW", "TESTING") } { return "IN_PROGRESS" }
        "BLOCKED" { return "PAUSE" }
        { $_ -in @("DONE", "DECIDED") } { return "DONE" }
        { $_ -in @("CANCELLED", "DEFERRED") } { return "TODO" }
        default { return "TODO" }
    }
}

# Non-destructive per-entry YAML -> table conversion. Every entry keeps its
# ID; PHASE/THEME/EPIC/FEATURE become headings (the spine's `parent` chain
# is walked, up to 8 hops, to place each heading under its nearest PHASE and
# each TASK/SUBTASK/FEATURE row under its nearest EPIC); cross-cutting
# entries (GAP/BUG/DECISION/BLOCKER/...) become rows in "## Gaps, Bugs &
# Technical Debt" (a DECISION's question/options/decision fields have no
# table equivalent and are dropped after converting its ID and title).
# TASK/SUBTASK/FEATURE rows mapped to IN_PROGRESS/PAUSE are routed into
# "## Active work" instead of their Plan-section table. An entry whose
# parent chain never reaches a PHASE lands under a synthesized
# "F00-ORPHANED" phase for manual placement, never silently dropped.
function Convert-RoadmapYamlToTable {
    $file = Join-Path $DocsDir "Roadmap.md"
    if (-not (Test-RoadmapNeedsYamlMigration)) { return $false }

    $etype = @{}; $etitle = @{}; $estatus = @{}; $eparent = @{}; $eagent = @{}
    $edesc = @{}; $eaccept = @{}; $esev = @{}; $ephase = @{}; $edeps = @{}; $esection = @{}
    $order = [System.Collections.Generic.List[string]]::new()
    $seen = @{}

    $inSection = ""; $inFence = $false
    $id = ""; $type = ""; $title = ""; $status = ""; $parent = ""; $agent = ""
    $desc = ""; $accept = ""; $sev = ""; $ph = ""; $deps = ""; $pendKey = ""; $capturedAc = $false

    foreach ($line in @(Get-ContentUtf8 -LiteralPath $file)) {
        if ($line -eq "## Plan") { $inSection = "plan"; continue }
        if ($line -eq "## Cross-cutting") { $inSection = "cross"; continue }
        if (-not $inFence) {
            if ($line -match '^```yaml') {
                $inFence = $true
                $id = ""; $type = ""; $title = ""; $status = ""; $parent = ""; $agent = ""
                $desc = ""; $accept = ""; $sev = ""; $ph = ""; $deps = ""; $pendKey = ""; $capturedAc = $false
            }
            continue
        }
        if ($line -match '^```[ \t]*$') {
            $inFence = $false
            if ($id -ne "" -and -not $seen.ContainsKey($id)) {
                $seen[$id] = $true; $order.Add($id)
                $etype[$id] = $type; $etitle[$id] = $title; $estatus[$id] = $status; $eparent[$id] = $parent
                $eagent[$id] = $agent; $edesc[$id] = $desc; $eaccept[$id] = $accept; $esev[$id] = $sev
                $ephase[$id] = $ph; $edeps[$id] = $deps; $esection[$id] = $inSection
            }
            continue
        }
        if ($line -match '^([A-Za-z_][A-Za-z0-9_]*):[ \t]*(.*)$') {
            $key = $Matches[1]; $val = $Matches[2].Trim()
            $pendKey = ""
            switch ($key) {
                "id" { $id = $val }
                "type" { $type = $val }
                "title" { $title = $val.Trim('"') }
                "status" { $status = $val }
                "parent" { $parent = $val.Trim('"') }
                "assigned_agent" { $agent = $val.Trim('"') }
                "severity" { $sev = $val }
                "phase" { $ph = $val }
                "depends_on" { $pendKey = "dep" }
                "description" {
                    if ($val -eq "" -or $val -eq ">" -or $val -eq "|") { $pendKey = "desc"; $desc = "" }
                    else { $desc = $val.Trim('"') }
                }
                "acceptance_criteria" { $pendKey = "ac"; $capturedAc = $false }
            }
            continue
        }
        if ($line -match '^[ \t]+-[ \t]+(.*)$') {
            $item = $Matches[1].Trim().Trim('"')
            if ($pendKey -eq "dep") { if ($item) { $deps = if ($deps -eq "") { $item } else { "$deps;$item" } } }
            elseif ($pendKey -eq "ac") { $capturedAc = $true }
            continue
        }
        if ($pendKey -eq "desc" -and $line -match '^[ \t]+(.*)$') {
            $t = $Matches[1].Trim()
            $desc = if ($desc -eq "") { $t } else { "$desc $t" }
            continue
        }
        if ($pendKey -eq "ac" -and $capturedAc -and $line -match '^[ \t]+description:[ \t]*(.*)$') {
            $t = $Matches[1].Trim().Trim('"')
            if ($accept -eq "") { $accept = $t }
            continue
        }
        if ($line -match '^[ \t]') { continue }
        $pendKey = ""
    }

    function Get-WalkUpForType([string]$StartId, [string]$WantType) {
        $cur = $StartId; $hops = 0
        while ($cur -and $hops -lt 8) {
            if ($etype.ContainsKey($cur) -and $etype[$cur] -eq $WantType) { return $cur }
            $cur = if ($eparent.ContainsKey($cur)) { $eparent[$cur] } else { "" }
            $hops++
        }
        return ""
    }
    function Get-OrField([string]$V) { if ($V -eq "") { return $EmDash } else { return $V } }
    function Get-OrStr([string]$V, [string]$Fb) { if ($V -eq "") { return $Fb } else { return $V } }
    function Format-RoadmapRow([string]$Id) {
        $st = ConvertTo-MigratedWfStatus $estatus[$Id]
        $ag = Get-OrField $eagent[$Id]
        $dp = (Get-OrField $edeps[$Id]) -replace ';', ', '
        return "| $Id | $(Get-OrStr $edesc[$Id] $etitle[$Id]) | $(Get-OrStr $eaccept[$Id] 'UNKNOWN') | $st | $ag | $dp | $EmDash |"
    }
    function Format-GapRow([string]$Id) {
        $st = ConvertTo-MigratedWfStatus $estatus[$Id]
        $ag = Get-OrField $eagent[$Id]
        $dp = (Get-OrField $edeps[$Id]) -replace ';', ', '
        return "| $Id | $(Get-OrField $esev[$Id]) | $(Get-OrField $ephase[$Id]) | $(Get-OrStr $edesc[$Id] $etitle[$Id]) | $st | $ag | $dp | $EmDash |"
    }

    $epicPhase = @{}; $themePhase = @{}; $rowEpic = @{}; $rowPhase = @{}; $isActive = @{}
    foreach ($eid in $order) {
        if ($esection[$eid] -ne "plan") { continue }
        $t = $etype[$eid]
        if ($t -eq "EPIC") { $epicPhase[$eid] = Get-WalkUpForType $eparent[$eid] "PHASE" }
        elseif ($t -eq "THEME") { $themePhase[$eid] = Get-WalkUpForType $eparent[$eid] "PHASE" }
        elseif ($t -in @("TASK", "SUBTASK", "FEATURE")) {
            $rowEpic[$eid] = Get-WalkUpForType $eparent[$eid] "EPIC"
            if ($rowEpic[$eid] -eq "") { $rowPhase[$eid] = Get-WalkUpForType $eparent[$eid] "PHASE" }
            $wfst = ConvertTo-MigratedWfStatus $estatus[$eid]
            if ($wfst -eq "IN_PROGRESS" -or $wfst -eq "PAUSE") { $isActive[$eid] = $true }
        }
    }

    $out = [System.Collections.Generic.List[string]]::new()
    $out.Add("## Active work"); $out.Add("")
    $out.Add("| ID | Outcome | Acceptance check | Status | Owner | Depends on | Pause reason |")
    $out.Add("|---|---|---|---|---|---|---|")
    $activeCount = 0
    foreach ($eid in $order) { if ($isActive.ContainsKey($eid)) { $out.Add((Format-RoadmapRow $eid)); $activeCount++ } }
    if ($activeCount -eq 0) { $out.Add("| $EmDash | $EmDash | $EmDash | $EmDash | $EmDash | $EmDash | $EmDash |") }
    $out.Add(""); $out.Add("<!-- context:end -->"); $out.Add("")
    $nearStarted = $false
    foreach ($tline in @(Get-ContentUtf8 -LiteralPath (Join-Path $TemplatesDir "Roadmap.md"))) {
        if ($tline -eq "## Plan") { break }
        if ($tline -eq "## Near term") { $nearStarted = $true }
        if ($nearStarted) { $out.Add([string]$tline) }
    }
    $out.Add("## Plan"); $out.Add("")
    $visionId = ""
    foreach ($eid in $order) { if ($etype[$eid] -eq "VISION") { $visionId = $eid; break } }
    if ($visionId -ne "") { $out.Add("**Vision:** $(Get-OrStr $edesc[$visionId] $etitle[$visionId])") }
    else { $out.Add("**Vision:** ``UNKNOWN``") }
    $out.Add("")
    $anyPhase = $false
    foreach ($eid in $order) { if ($esection[$eid] -eq "plan" -and $etype[$eid] -eq "PHASE") { $anyPhase = $true } }
    if (-not $anyPhase) {
        $out.Add("### F01 $EmDash UNKNOWN phase name"); $out.Add("")
        $out.Add("#### F01-E01 $EmDash UNKNOWN epic name"); $out.Add("")
        $out.Add("| ID | Outcome | Acceptance check | Status | Owner | Depends on | Pause reason |")
        $out.Add("|---|---|---|---|---|---|---|")
        $out.Add("| F01-E01-T01 | UNKNOWN | UNKNOWN | TODO | $EmDash | $EmDash | $EmDash |")
    }
    foreach ($phid in $order) {
        if ($esection[$phid] -ne "plan" -or $etype[$phid] -ne "PHASE") { continue }
        $out.Add(""); $out.Add("### $phid $EmDash $($etitle[$phid])")
        if ($edesc[$phid] -and $edesc[$phid] -ne $etitle[$phid]) { $out.Add(""); $out.Add($edesc[$phid]) }
        foreach ($tid in $order) {
            if ($esection[$tid] -eq "plan" -and $etype[$tid] -eq "THEME" -and $themePhase[$tid] -eq $phid) {
                $out.Add(""); $out.Add("#### $tid $EmDash $($etitle[$tid])")
                if ($edesc[$tid] -and $edesc[$tid] -ne $etitle[$tid]) { $out.Add(""); $out.Add($edesc[$tid]) }
            }
        }
        $directRows = @($order | Where-Object { $esection[$_] -eq "plan" -and $etype[$_] -in @("TASK", "SUBTASK", "FEATURE") -and $rowPhase.ContainsKey($_) -and $rowPhase[$_] -eq $phid -and -not $isActive.ContainsKey($_) })
        if ($directRows.Count -gt 0) {
            $out.Add("")
            $out.Add("| ID | Outcome | Acceptance check | Status | Owner | Depends on | Pause reason |")
            $out.Add("|---|---|---|---|---|---|---|")
            foreach ($rid in $directRows) { $out.Add((Format-RoadmapRow $rid)) }
        }
        foreach ($eid in $order) {
            if ($esection[$eid] -eq "plan" -and $etype[$eid] -eq "EPIC" -and $epicPhase[$eid] -eq $phid) {
                $out.Add(""); $out.Add("##### $eid $EmDash $($etitle[$eid])")
                if ($edesc[$eid] -and $edesc[$eid] -ne $etitle[$eid]) { $out.Add(""); $out.Add($edesc[$eid]) }
                $out.Add("")
                $out.Add("| ID | Outcome | Acceptance check | Status | Owner | Depends on | Pause reason |")
                $out.Add("|---|---|---|---|---|---|---|")
                $epicRows = @($order | Where-Object { $esection[$_] -eq "plan" -and $etype[$_] -in @("TASK", "SUBTASK", "FEATURE") -and $rowEpic.ContainsKey($_) -and $rowEpic[$_] -eq $eid -and -not $isActive.ContainsKey($_) })
                foreach ($rid in $epicRows) { $out.Add((Format-RoadmapRow $rid)) }
                if ($epicRows.Count -eq 0) { $out.Add("| $EmDash | $EmDash | $EmDash | $EmDash | $EmDash | $EmDash | $EmDash |") }
            }
        }
    }
    $orphanHdr = $false
    foreach ($eid in $order) {
        if ($esection[$eid] -ne "plan" -or $isActive.ContainsKey($eid)) { continue }
        $t = $etype[$eid]; $isOrphan = $false
        if ($t -eq "EPIC" -and $epicPhase[$eid] -eq "") { $isOrphan = $true }
        elseif ($t -eq "THEME" -and $themePhase[$eid] -eq "") { $isOrphan = $true }
        elseif ($t -in @("TASK", "SUBTASK", "FEATURE") -and $rowEpic[$eid] -eq "" -and $rowPhase[$eid] -eq "") { $isOrphan = $true }
        if ($isOrphan) {
            if (-not $orphanHdr) {
                $out.Add(""); $out.Add("### F00-ORPHANED $EmDash Migrated entries needing manual placement"); $out.Add("")
                $out.Add("| ID | Outcome | Acceptance check | Status | Owner | Depends on | Pause reason |")
                $out.Add("|---|---|---|---|---|---|---|")
                $orphanHdr = $true
            }
            $out.Add((Format-RoadmapRow $eid))
        }
    }
    $out.Add("")
    $out.Add("## Gaps, Bugs & Technical Debt"); $out.Add("")
    $out.Add("Errors, defects, or significant technical debt found by any agent. Same")
    $out.Add("trailing columns as above, so an entry can be ``claim``ed and ``done`` like any")
    $out.Add("task. ID prefix marks the kind: ``Fxx-GAP-xx`` (missing capability),")
    $out.Add("``Fxx-BUG-xx`` (defect), ``Fxx-DEBT-xx`` (technical debt).")
    $out.Add("")
    $out.Add("| ID | Severity | Phase | Description | Status | Owner | Depends on | Pause reason |")
    $out.Add("|---|---|---|---|---|---|---|---|")
    $gapRows = @($order | Where-Object { $esection[$_] -eq "cross" })
    foreach ($gid in $gapRows) { $out.Add((Format-GapRow $gid)) }
    if ($gapRows.Count -eq 0) { $out.Add("| $EmDash | $EmDash | $EmDash | $EmDash | $EmDash | $EmDash | $EmDash | $EmDash |") }
    $out.Add(""); $out.Add("## Out of scope"); $out.Add(""); $out.Add("- ``UNKNOWN``")

    $intro = [System.Collections.Generic.List[string]]::new()
    foreach ($tline in @(Get-ContentUtf8 -LiteralPath (Join-Path $TemplatesDir "Roadmap.md"))) {
        if ($tline -eq "## Active work") { break }
        $intro.Add([string]$tline)
    }
    $final = [System.Collections.Generic.List[string]]::new()
    $final.AddRange([string[]]$intro)
    $final.AddRange([string[]]$out)
    Write-Utf8File $file (ConvertTo-JoinedLines ([string[]]$final))
    return $true
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
    Invoke-InitRun "classic"
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
    if (Convert-RoadmapYamlToTable) {
        $changed++
        Write-Output "= converted: docs/Roadmap.md per-entry YAML -> tables (IDs preserved; review"
        Write-Output "  DECISION entries and any F00-ORPHANED rows by hand)"
    }
    Set-RoadmapSectionsEnsured
    if (Add-RoadmapNameColumn) {
        $changed++
        Write-Output "= converted: docs/Roadmap.md rows now have a Name column (derived from the"
        Write-Output "  first 10 words of the prior Outcome/Description text; review each Name by"
        Write-Output "  hand, including any Near term row that may still exceed 10 words)"
    }
    if (@($Arguments) -ccontains "--factory") {
        Add-FactoryAdditions
        $changed += $script:FactoryChanges
    }
    Write-Output "project_docs migrate: $changed change(s)"
}

# ---------------------------------------------------------------------------
# check
# ---------------------------------------------------------------------------
function Test-Need([string]$Rel, [string[]]$Markers) {
    $path = Join-Path $Project $Rel
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        [Console]::Error.WriteLine("MISSING: $Rel")
        $script:CheckFail = $true
        return
    }
    $content = [System.IO.File]::ReadAllText($path, $Utf8)
    foreach ($marker in $Markers) {
        if (-not $content.Contains($marker)) {
            [Console]::Error.WriteLine("INVALID $Rel`: missing '$marker'")
            $script:CheckFail = $true
        }
    }
}

function Test-LogRotationNeeded {
    $log = Join-Path $DocsDir "Agentslog.md"
    $bytes = (Get-Item -LiteralPath $log).Length
    $entries = Get-LogEntryCount $log
    if ($bytes -gt $LogBytesLimit -or $entries -gt $LogEntriesLimit) {
        [Console]::Error.WriteLine("ROTATE REQUIRED: Agentslog has $entries entries / $bytes bytes")
        $script:CheckFail = $true
    }
}

function Test-LogEntries {
    $log = Join-Path $DocsDir "Agentslog.md"
    $lines = @(Get-ContentUtf8 -LiteralPath $log)
    $inEntries = $false
    $entries = [System.Collections.Generic.List[object]]::new()
    $cur = $null
    $lastStatus = @{}; $lastAgent = @{}; $lastTsMap = @{}; $holdMap = @{}
    foreach ($line in $lines) {
        if ($line -eq "## Entries") { $inEntries = $true; continue }
        if (-not $inEntries) { continue }
        if ($line -match '^## \[([^\]]*)\] \| ([^|]*) \| ([^|]*) \| ([^|]*)(?:\|\s*(.*))?$') {
            $agentnow = $Matches[2].Trim()
            $tidnow = $Matches[3].Trim()
            $status = $Matches[4].Trim()
            $name = if ($Matches[5]) { $Matches[5].Trim() } else { "" }
            $tsnow = $Matches[1].Trim()
            $conflictMsg = $null
            if ($status -eq "IN_PROGRESS" -and $lastStatus.ContainsKey($tidnow) -and $lastStatus[$tidnow] -eq "IN_PROGRESS" -and $lastAgent[$tidnow] -cne $agentnow) {
                $conflictMsg = "ERROR: conflicting concurrent claim on $tidnow`: $($lastAgent[$tidnow]) and $agentnow"
            } elseif ($status -eq "IN_PROGRESS" -and $lastStatus.ContainsKey($tidnow) -and $lastStatus[$tidnow] -eq "REVIEW" -and $holdMap.ContainsKey($tidnow) -and $holdMap[$tidnow] -cne $agentnow -and -not (Test-IsOld $lastTsMap[$tidnow] $tsnow)) {
                # Two REVIEW entries by different agents (developer, reviewer)
                # are normal; only a third agent starting work on a task that is
                # held by someone else, and not stale, is a conflict.
                $conflictMsg = "ERROR: conflicting concurrent claim on $tidnow`: $($holdMap[$tidnow]) and $agentnow"
            }
            if ($status -eq "IN_PROGRESS") { $holdMap[$tidnow] = $agentnow }
            $lastStatus[$tidnow] = $status
            $lastAgent[$tidnow] = $agentnow
            $lastTsMap[$tidnow] = $tsnow
            $cur = [PSCustomObject]@{ Hdr = $line; Status = $status; PauseLine = $null; VerifyLine = $null; SummaryLine = $null; HandoffLine = $null; ReviewLine = $null; AssignLine = $null; ConflictMsg = $conflictMsg; Name = $name }
            $entries.Add($cur)
            continue
        }
        if ($cur -and $line -match '^- Pause:') { $cur.PauseLine = $line; continue }
        if ($cur -and $line -match '^- Verify:') { $cur.VerifyLine = $line; continue }
        if ($cur -and $line -match '^- Summary:') { $cur.SummaryLine = $line; continue }
        if ($cur -and $line -match '^- Handoff:') { $cur.HandoffLine = $line; continue }
        if ($cur -and $line -match '^- Review:') { $cur.ReviewLine = $line; continue }
        if ($cur -and $line -match '^- Assign:') { $cur.AssignLine = $line; continue }
    }
    foreach ($e in $entries) {
        if ($e.ConflictMsg) {
            [Console]::Error.WriteLine($e.ConflictMsg)
            $script:CheckFail = $true
        }
        if ($e.Status -notin @("IN_PROGRESS", "PAUSE", "DONE", "REVIEW", "ASSIGNED")) {
            [Console]::Error.WriteLine("ERROR: invalid status in entry (expected IN_PROGRESS, PAUSE, REVIEW, ASSIGNED or DONE): $($e.Hdr)")
            $script:CheckFail = $true
        }
        if ($e.Status -eq "ASSIGNED") {
            $abody = if ($e.AssignLine) { ($e.AssignLine -replace '^- Assign:\s*', '').Trim() } else { "" }
            if (-not $abody) {
                [Console]::Error.WriteLine("ERROR: ASSIGNED entry missing Assign target: $($e.Hdr)")
                $script:CheckFail = $true
            }
        }
        if ($e.Status -eq "REVIEW") {
            $rres = ""; $rdetail = ""
            if ($e.ReviewLine) {
                $rbody = $e.ReviewLine -replace '^- Review:\s*', ''
                $rdash = $rbody.IndexOf(" - ")
                if ($rdash -ge 0) { $rres = $rbody.Substring(0, $rdash).Trim(); $rdetail = $rbody.Substring($rdash + 3).Trim() } else { $rres = $rbody.Trim() }
                if ($rres -notin @("PASS", "FAIL")) {
                    [Console]::Error.WriteLine("ERROR: REVIEW entry has invalid Review result (expected PASS or FAIL): $($e.Hdr)")
                    $script:CheckFail = $true
                }
                if (-not $rdetail) {
                    [Console]::Error.WriteLine("ERROR: REVIEW entry missing Review detail: $($e.Hdr)")
                    $script:CheckFail = $true
                }
            }
            $sbody = if ($e.SummaryLine) { ($e.SummaryLine -replace '^- Summary:\s*', '').Trim() } else { "" }
            if (-not $sbody) {
                [Console]::Error.WriteLine("ERROR: REVIEW entry missing Summary: $($e.Hdr)")
                $script:CheckFail = $true
            }
            # A handoff and a Review: PASS say what was verified; a Review: FAIL
            # may carry no Verify (the reviewer verified nothing that passed).
            if (-not $e.VerifyLine) {
                if ($rres -ne "FAIL") {
                    [Console]::Error.WriteLine("ERROR: REVIEW entry missing Verify line: $($e.Hdr)")
                    $script:CheckFail = $true
                }
            } else {
                $vbody = ($e.VerifyLine -replace '^- Verify:\s*', '').Trim()
                if (-not $vbody -or $vbody -eq "pending") {
                    [Console]::Error.WriteLine("ERROR: REVIEW entry has empty or pending Verify: $($e.Hdr)")
                    $script:CheckFail = $true
                }
            }
        }
        if ($e.Status -eq "PAUSE") {
            if (-not $e.PauseLine) {
                [Console]::Error.WriteLine("ERROR: PAUSE entry missing Pause line: $($e.Hdr)")
                $script:CheckFail = $true
            } else {
                $body = $e.PauseLine -replace '^- Pause: ', ''
                $dash = $body.IndexOf(" - ")
                if ($dash -ge 0) { $cat = $body.Substring(0, $dash); $detail = $body.Substring($dash + 3) } else { $cat = $body; $detail = "" }
                if ($cat -notin @("LIMITE", "ESPERA_RESPUESTA", "BLOQUEO", "OTRO")) {
                    [Console]::Error.WriteLine("ERROR: PAUSE entry has invalid category: $($e.Hdr)")
                    $script:CheckFail = $true
                }
                if (-not $detail) {
                    [Console]::Error.WriteLine("ERROR: PAUSE entry missing detail: $($e.Hdr)")
                    $script:CheckFail = $true
                }
            }
        }
        if ($e.Status -eq "DONE") {
            if (-not $e.VerifyLine) {
                [Console]::Error.WriteLine("ERROR: DONE entry missing Verify line: $($e.Hdr)")
                $script:CheckFail = $true
            } else {
                $body = ($e.VerifyLine -replace '^- Verify: ', '').Trim()
                if (-not $body -or $body -eq "pending") {
                    [Console]::Error.WriteLine("ERROR: DONE entry has empty or pending Verify: $($e.Hdr)")
                    $script:CheckFail = $true
                }
            }
        }
        if ($e.Name) {
            $wc = Get-WordCount $e.Name
            if ($wc -gt 10) {
                [Console]::Error.WriteLine("ERROR: entry Name is $wc words, over the 10-word limit: $($e.Hdr)")
                $script:CheckFail = $true
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
            [Console]::Error.WriteLine("ERROR: log ID $($s.Task) not found in Roadmap or Features")
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
            [Console]::Error.WriteLine("ERROR: Features ID $fid has no DONE entry in the log")
            $script:CheckFail = $true
        }
    }
}

# For every ID that has a Name in docs/Roadmap.md, the most recent Agentslog
# entry that carried a Name for that ID must agree with it -- claim/pause/
# done write the Roadmap Name into the log automatically, so a mismatch
# means either was hand-edited out of sync afterward. An entry with no Name
# field at all (pre-feature history, or an append-log entry) is not a
# mismatch.
function Test-AgentslogRoadmapNames {
    $roadmapNames = Get-RoadmapAllNames
    foreach ($s in @(Get-TaskStates)) {
        if (-not $s.Name) { continue }
        if ($roadmapNames.ContainsKey($s.Task) -and $roadmapNames[$s.Task] -ne $s.Name) {
            [Console]::Error.WriteLine("ERROR: $($s.Task) Agentslog Name (`"$($s.Name)`") does not match docs/Roadmap.md Name (`"$($roadmapNames[$s.Task])`")")
            $script:CheckFail = $true
        }
    }
}

# ---------------------------------------------------------------------------
# Epistemic taxonomy and canonical-ID hardening. Two disjoint Status
# vocabularies exist by design: fact tables in ProductDescription.md and
# Stack_Tecnologies.md use the epistemic one (CONFIRMED/HYPOTHESIS/UNKNOWN);
# work-item tables in Roadmap.md use the workflow one
# (TODO/IN_PROGRESS/PAUSE/DONE). Never mix the two.
# ---------------------------------------------------------------------------

# Validates every table's Status column in $Rel against $Allowed, file-wide.
# Detects each table's own header (the first `|` row after a non-`|` line)
# so it re-locates the Status column per table instead of assuming a fixed
# position; placeholder rows (id blank/em-dash/dashes) are skipped.
function Test-TableStatusEnum([string]$Rel, [string[]]$Allowed, [string]$Label) {
    $path = Join-Path $Project $Rel
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return }
    $expectHeader = $true
    $statusCol = -1
    foreach ($line in @(Get-ContentUtf8 -LiteralPath $path)) {
        if (-not $line.StartsWith("|")) { $expectHeader = $true; continue }
        $cells = @(Split-TableCells $line)
        if ($expectHeader) {
            $statusCol = -1
            for ($i = 0; $i -lt $cells.Count; $i++) { if ($cells[$i] -eq "Status") { $statusCol = $i } }
            $expectHeader = $false
            continue
        }
        if ($cells.Count -lt 1) { continue }
        $id = $cells[0]
        if ($id -eq "" -or $id -eq $EmDash -or $id -match '^-+$') { continue }
        if ($statusCol -ge 0 -and $statusCol -lt $cells.Count) {
            $st = $cells[$statusCol]
            if ($Allowed -notcontains $st) {
                [Console]::Error.WriteLine("ERROR: $Rel row '$id' has invalid $Label Status: $st")
                $script:CheckFail = $true
            }
        }
    }
}

# Every Roadmap table's row carries a short, descriptive Name (<= 10 words;
# the rest of the detail goes in Description or the table's own free-text
# column) in the column right after ID. Same per-table header detection as
# Test-TableStatusEnum. A table that has an ID column but no Name column at
# all (not yet migrated) is reported once, by its header, rather than
# silently skipped.
function Test-TableNameWordLimit([string]$Rel, [int]$Max) {
    $path = Join-Path $Project $Rel
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return }
    $expectHeader = $true
    $nameCol = -1
    foreach ($line in @(Get-ContentUtf8 -LiteralPath $path)) {
        if (-not $line.StartsWith("|")) { $expectHeader = $true; continue }
        $cells = @(Split-TableCells $line)
        if ($expectHeader) {
            $idCol = -1; $nameCol = -1
            for ($i = 0; $i -lt $cells.Count; $i++) {
                if ($cells[$i] -eq "ID") { $idCol = $i }
                if ($cells[$i] -eq "Name") { $nameCol = $i }
            }
            if ($idCol -ge 0 -and $nameCol -lt 0) {
                [Console]::Error.WriteLine("ERROR: $Rel table `"$line`" has no Name column; run migrate")
                $script:CheckFail = $true
            }
            $expectHeader = $false
            continue
        }
        if ($cells.Count -lt 1) { continue }
        $id = $cells[0]
        if ($id -eq "" -or $id -eq $EmDash -or $id -match '^-+$') { continue }
        if ($nameCol -ge 0 -and $nameCol -lt $cells.Count) {
            $nm = $cells[$nameCol]
            if ($nm -eq "") {
                [Console]::Error.WriteLine("ERROR: $Rel row '$id' has an empty Name")
                $script:CheckFail = $true
            } else {
                $wc = Get-WordCount $nm
                if ($wc -gt $Max) {
                    [Console]::Error.WriteLine("ERROR: $Rel row '$id' Name is $wc words, over the $Max-word limit: $nm")
                    $script:CheckFail = $true
                }
            }
        }
    }
}

# Validates every row's ID (first column) under the exact "## <heading>"
# section of $Rel against regex $Pattern.
# Rows under "### F00-ORPHANED" are exempt: migrate places them there
# verbatim (ID preserved, not reshaped) specifically for manual review, so a
# legacy ID that doesn't fit the current convention is expected, not an error.
function Test-IdFormatInSection([string]$Rel, [string]$Heading, [string]$Pattern, [string]$Label) {
    $path = Join-Path $Project $Rel
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return }
    $inSec = $false
    $orphan = $false
    foreach ($line in @(Get-ContentUtf8 -LiteralPath $path)) {
        if ($line -eq $Heading) { $inSec = $true; continue }
        if ($inSec -and $line -match '^## ') { $inSec = $false; $orphan = $false }
        if ($inSec -and $line -match '^### F00-ORPHANED') { $orphan = $true }
        elseif ($inSec -and $orphan -and $line -match '^#') { $orphan = $false }
        if ($inSec -and $line.StartsWith("|")) {
            $cells = @(Split-TableCells $line)
            if ($cells.Count -lt 1) { continue }
            $id = $cells[0]
            if ($id -eq "" -or $id -eq "ID" -or $id -eq $EmDash -or $id -match '^-+$') { continue }
            if ($orphan) { continue }
            if ($id -notmatch $Pattern) {
                [Console]::Error.WriteLine("ERROR: $Rel $Label has invalid ID format: $id")
                $script:CheckFail = $true
            }
        }
    }
}

# Warns (never fails) about agent names in the hot ledger that are neither an
# Agent id nor an alias, at most 10 of them plus a count. Silent without a roster.
function Write-RosterWarnings {
    $rows = @(Get-RosterRows)
    if ($rows.Count -eq 0) { return }
    $log = Join-Path $DocsDir "Agentslog.md"
    if (-not (Test-Path -LiteralPath $log -PathType Leaf)) { return }
    $known = @{}
    foreach ($r in $rows) {
        $known[$r.Id.ToLowerInvariant()] = $true
        foreach ($a in @(Get-RosterAliases $r)) { $known[$a.ToLowerInvariant()] = $true }
    }
    $seen = @{}
    $unknown = [System.Collections.Generic.List[string]]::new()
    $inEntries = $false
    foreach ($line in @(Get-ContentUtf8 -LiteralPath $log)) {
        if ($line -eq "## Entries") { $inEntries = $true; continue }
        if (-not $inEntries) { continue }
        if ($line -match '^## \[([^\]]*)\] \| ([^|]*) \|') {
            $ag = $Matches[2].Trim()
            if (-not $known.ContainsKey($ag.ToLowerInvariant()) -and -not $seen.ContainsKey($ag)) {
                $seen[$ag] = $true
                $unknown.Add($ag)
            }
        }
    }
    for ($i = 0; $i -lt $unknown.Count -and $i -lt 10; $i++) {
        [Console]::Error.WriteLine("WARN: unknown agent `"$($unknown[$i])`" in the ledger (not in the Agent identity table)")
    }
    if ($unknown.Count -gt 10) {
        [Console]::Error.WriteLine("WARN: $($unknown.Count - 10) more unknown agent name(s) in the ledger")
    }
}

# One summary line plus at most the 5 most recent tasks closed within
# PROJECT_DOCS_MIN_WORK_MINUTES (default 5) of their first claim. Closing a
# batch afterwards is legitimate: this only says so. Never fails.
function Write-InstantCloseWarnings {
    $log = Join-Path $DocsDir "Agentslog.md"
    if (-not (Test-Path -LiteralPath $log -PathType Leaf)) { return }
    $minWork = 5
    if ($env:PROJECT_DOCS_MIN_WORK_MINUTES -match '^\d+$') { $minWork = [int]$env:PROJECT_DOCS_MIN_WORK_MINUTES }
    $first = @{}; $counted = @{}
    $closed = 0
    $quick = [System.Collections.Generic.List[object]]::new()
    $inEntries = $false
    foreach ($line in @(Get-ContentUtf8 -LiteralPath $log)) {
        if ($line -eq "## Entries") { $inEntries = $true; continue }
        if (-not $inEntries) { continue }
        if ($line -match '^## \[([^\]]*)\] \| ([^|]*) \| ([^|]*) \| ([^|]*)') {
            $ts = $Matches[1].Trim(); $tid = $Matches[3].Trim(); $st = $Matches[4].Trim()
            if ($st -eq "IN_PROGRESS" -and -not $first.ContainsKey($tid)) { $first[$tid] = $ts }
            if ($st -eq "DONE" -and $first.ContainsKey($tid) -and -not $counted.ContainsKey($tid)) {
                $counted[$tid] = $true
                $g = Get-GapSeconds $first[$tid] $ts
                if ($g -ge 0) {
                    $closed++
                    if ($g -lt ($minWork * 60)) { $quick.Add([PSCustomObject]@{ Id = $tid; Gap = $g }) }
                }
            }
        }
    }
    if ($quick.Count -gt 0) {
        [Console]::Error.WriteLine("WARN: $($quick.Count) of $closed closed tasks were closed within $minWork min of their claim")
        $start = [Math]::Max(0, $quick.Count - 5)
        for ($i = $start; $i -lt $quick.Count; $i++) {
            [Console]::Error.WriteLine("WARN: $($quick[$i].Id) was claimed and closed $(Get-GapLabel $quick[$i].Gap) apart; claim before the first edit so the work is visible while it happens")
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
    Write-RosterWarnings
    Write-InstantCloseWarnings
    foreach ($name in $LinkTargetsDefault) {
        $rel = Get-LinkTargetPath $name
        $full = Join-Path $Project $rel
        if ((Test-Path -LiteralPath $full -PathType Leaf) -and -not (Test-HasBlock $full)) {
            [Console]::Error.WriteLine("WARN: $rel has no project-documentation redirect block; run 'link'")
        }
    }
    $log = Join-Path $DocsDir "Agentslog.md"
    if (Test-Path -LiteralPath $log -PathType Leaf) {
        # A REVIEW whose last entry says Review: FAIL is back with its holder,
        # so it is reported as IN_PROGRESS; a pending or passed REVIEW as REVIEW.
        foreach ($s in @(Get-TaskStates | Where-Object { $_.Status -eq "IN_PROGRESS" -or $_.Status -eq "REVIEW" })) {
            $hrs = Get-AgeHours $s.Ts
            if ($null -ne $hrs -and $hrs -ge $StaleHours) {
                if ($s.Status -eq "REVIEW" -and $s.Review -ne "FAIL") {
                    [Console]::Error.WriteLine("WARN: $($s.Task) has been in REVIEW for ${hrs}h (>= ${StaleHours}h)")
                } else {
                    [Console]::Error.WriteLine("WARN: $($s.Task) has been IN_PROGRESS for ${hrs}h (>= ${StaleHours}h)")
                }
            }
        }
    }
}

# Brain.md validation (Factory mode only, F06-E03-T01). One row per lesson; the
# vertical bar never appears inside a cell, so a row with a different column
# count is itself an error.
function Test-BrainRows {
    $path = Join-Path $DocsDir "Brain.md"
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return }
    $max = [int](Get-FactoryNumber "Brain max entries")
    $insec = $false
    $rows = 0
    $seen = @{}
    foreach ($line in @(Get-ContentUtf8 -LiteralPath $path)) {
        if ($line -ceq "## Entries") { $insec = $true; continue }
        if ($insec -and $line.StartsWith("## ")) { $insec = $false }
        if (-not ($insec -and $line.StartsWith("|"))) { continue }
        $c = @(Split-TableCells $line)
        $id = $c[0]
        if ($id -ceq "ID" -or $id -match '^-+$' -or $id -eq $EmDash) { continue }
        $rows++
        $pre = "ERROR: docs/Brain.md row '$id' "
        $errs = [System.Collections.Generic.List[string]]::new()
        if ($c.Count -ne 9) { [Console]::Error.WriteLine("$($pre)has $($c.Count) columns, expected 9"); $script:CheckFail = $true; continue }
        if ($id -cnotmatch '^LRN-[0-9][0-9][0-9]+$') { $errs.Add("$($pre)has invalid ID format (expected LRN-xxx)") }
        if ($seen.ContainsKey($id)) { $errs.Add("ERROR: docs/Brain.md duplicate ID: $id") }
        $seen[$id] = $true
        if (-not $c[1]) { $errs.Add("$($pre)has an empty Name") }
        else {
            $wc = Get-WordCount $c[1]
            if ($wc -gt 10) { $errs.Add("$($pre)Name is $wc words, over the 10-word limit") }
        }
        if ($c[2] -cnotin @("PITFALL", "PATTERN", "RECIPE", "DEFAULT", "MAP")) { $errs.Add("$($pre)has invalid Kind: $($c[2])") }
        if (-not $c[3]) { $errs.Add("$($pre)has an empty Trigger") }
        if (-not $c[4]) { $errs.Add("$($pre)has an empty Lesson") }
        if (-not $c[5]) { $errs.Add("$($pre)has an empty Evidence") }
        if ($c[6] -cnotin @("CONFIRMED", "HYPOTHESIS")) { $errs.Add("$($pre)has invalid Status: $($c[6])") }
        if ($c[7] -notmatch '^[0-9]+$') { $errs.Add("$($pre)has invalid Hits: $($c[7])") }
        if ($c[8] -ne $EmDash -and $c[8] -notmatch '^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$') { $errs.Add("$($pre)has invalid Last used: $($c[8])") }
        foreach ($e in $errs) { [Console]::Error.WriteLine($e); $script:CheckFail = $true }
    }
    if ($rows -gt $max) {
        [Console]::Error.WriteLine("ERROR: docs/Brain.md has $rows entries, over the Brain max entries limit of $max")
        $script:CheckFail = $true
    }
}

# Spec validation (Factory mode only, F06-E02-T01). A spec is docs/specs/<TASK-ID>.md
# (templates/Spec.md). Structure problems are errors; fields still UNKNOWN are
# one warning per spec, because a draft spec is normal during the SPEC phase.
function Get-SpecReport([string]$Path) {
    $id = [System.IO.Path]::GetFileNameWithoutExtension($Path)
    $msgs = [System.Collections.Generic.List[string]]::new()
    $pre = "ERROR: docs/specs/$id.md "
    $sec = ""; $seen = @{}; $scid = @{}
    $unk = 0; $marker = $false; $hasGoal = $false; $hasRules = $false; $hasTags = $false
    $hdr = $false; $rows = 0
    $tests = [System.Collections.Generic.List[string]]::new()
    $lines = @(Get-ContentUtf8 -LiteralPath $Path)
    for ($ln = 0; $ln -lt $lines.Count; $ln++) {
        $line = [string]$lines[$ln]
        if ($ln -eq 0) {
            $t = "# Spec $id"
            if (-not $line.StartsWith($t, [System.StringComparison]::Ordinal) -or ($line.Length -gt $t.Length -and $line[$t.Length] -ne ' ')) {
                $msgs.Add("$($pre)title must start with '$t'")
            }
        }
        if ($line.Contains("UNKNOWN")) { $unk++ }
        if ($line.StartsWith("## ")) { $sec = $line; $seen[$sec] = $true; continue }
        if ($line -ceq "<!-- context:end -->") { if ($sec -ceq "## Summary") { $marker = $true }; continue }
        if ($sec -ceq "## Summary") {
            if ($line.StartsWith("- Goal:")) { $hasGoal = $true; if (-not $line.Substring(7).Trim()) { $msgs.Add("$($pre)has an empty Goal") }; continue }
            if ($line.StartsWith("- Rules:")) { $hasRules = $true; if (-not $line.Substring(8).Trim()) { $msgs.Add("$($pre)has empty Rules") }; continue }
            if ($line.StartsWith("- Tags:")) { $hasTags = $true; if (-not $line.Substring(7).Trim()) { $msgs.Add("$($pre)has empty Tags") }; continue }
        }
        if ($sec -ceq "## Scenarios" -and $line.StartsWith("|")) {
            $c = @(Split-TableCells $line)
            if ($c[0] -ceq "ID") {
                $hdr = $true
                if ($c.Count -ne 6 -or $c[1] -cne "Given" -or $c[2] -cne "When" -or $c[3] -cne "Then" -or $c[4] -cne "Level" -or $c[5] -cne "Justification") { $msgs.Add("$($pre)has an invalid Scenarios header") }
                continue
            }
            if ($c[0] -match '^-+$') { continue }
            $rows++
            $sid = $c[0]
            if ($c.Count -ne 6) { $msgs.Add("$($pre)scenario row '$sid' has $($c.Count) columns, expected 6"); continue }
            if ($sid -cnotmatch '^S[0-9][0-9]+$') { $msgs.Add("$($pre)scenario ID '$sid' is not S01 style") }
            if ($scid.ContainsKey($sid)) { $msgs.Add("$($pre)duplicate scenario ID: $sid") }
            $scid[$sid] = $true
            if (-not $c[1]) { $msgs.Add("$($pre)scenario '$sid' has an empty Given") }
            if (-not $c[2]) { $msgs.Add("$($pre)scenario '$sid' has an empty When") }
            if (-not $c[3]) { $msgs.Add("$($pre)scenario '$sid' has an empty Then") }
            $lv = $c[4]
            if ($lv -cnotin @("UNIT", "INTEGRATION", "CONTRACT", "E2E", "NONE")) { $msgs.Add("$($pre)scenario '$sid' has invalid Level: $lv") }
            elseif ($lv -ceq "NONE" -and (-not $c[5] -or $c[5] -eq $EmDash)) { $msgs.Add("$($pre)scenario '$sid' has Level NONE without a Justification") }
            continue
        }
        if ($sec -ceq "## Tests" -and $line.StartsWith("- ")) { $tests.Add($line) }
    }
    foreach ($req in @("## Summary", "## Scenarios", "## Tests", "## Out of scope")) {
        if (-not $seen.ContainsKey($req)) { $msgs.Add("$($pre)is missing section '$req'") }
    }
    if ($seen.ContainsKey("## Summary")) {
        if (-not $hasGoal) { $msgs.Add("$($pre)Summary is missing '- Goal:'") }
        if (-not $hasRules) { $msgs.Add("$($pre)Summary is missing '- Rules:'") }
        if (-not $hasTags) { $msgs.Add("$($pre)Summary is missing '- Tags:'") }
        if (-not $marker) { $msgs.Add("$($pre)has no '<!-- context:end -->' marker inside ## Summary") }
    }
    if ($seen.ContainsKey("## Scenarios")) {
        if (-not $hdr) { $msgs.Add("$($pre)is missing the Scenarios header row") }
        if ($rows -eq 0) { $msgs.Add("$($pre)has no scenarios") }
    }
    foreach ($e in $tests) {
        if ($e -cnotmatch '^- [^ ]+ \(S[0-9][0-9]+(, S[0-9][0-9]+)*\)$') { $msgs.Add("$($pre)Tests entry '$($e.Substring(2))' is not '- path (S01, S02)'"); continue }
        $p = $e.Substring(2)
        $path = $p.Substring(0, $p.IndexOf(' '))
        $r = $p.Substring($p.IndexOf('(') + 1)
        $r = $r.Substring(0, $r.Length - 1)
        foreach ($ref in ($r -split ', ')) {
            if (-not $scid.ContainsKey($ref)) { $msgs.Add("$($pre)Tests entry '$path' refers to unknown scenario $ref") }
        }
    }
    if ($unk -gt 0) { $msgs.Add("WARN: docs/specs/$id.md has $unk UNKNOWN field(s)") }
    return $msgs.ToArray()
}

function Test-Specs {
    $dir = Join-Path $DocsDir "specs"
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { return }
    [string[]]$names = @(Get-ChildItem -LiteralPath $dir -Filter "*.md" -File | ForEach-Object { $_.Name })
    [System.Array]::Sort($names, [System.StringComparer]::Ordinal)
    foreach ($name in $names) {
        foreach ($m in @(Get-SpecReport (Join-Path $dir $name))) {
            [Console]::Error.WriteLine($m)
            if ($m.StartsWith("ERROR:")) { $script:CheckFail = $true }
        }
    }
}

# Roster rules of Factory mode (F06-E02-T03): valid roles, at least two agents and
# one that can review.
function Test-FactoryRoster {
    $rows = @(Get-RosterRows)
    $qa = $false
    foreach ($r in $rows) {
        if ($r.Role -cnotin @("SPEC", "TEST", "DEV", "QA", "OPS", "BOTH", "DEVELOPER")) {
            [Console]::Error.WriteLine("ERROR: Agent identity row '$($r.Id)' has invalid Role: $($r.Role)")
            $script:CheckFail = $true
        }
        if ($r.Role -ceq "QA" -or $r.Role -ceq "BOTH") { $qa = $true }
    }
    if ($rows.Count -lt 2) {
        [Console]::Error.WriteLine("ERROR: Agent identity needs at least 2 agents in Factory mode (found $($rows.Count))")
        $script:CheckFail = $true
    }
    if (-not $qa) {
        [Console]::Error.WriteLine("ERROR: Agent identity needs an agent with role QA (or BOTH) in Factory mode")
        $script:CheckFail = $true
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
    Test-Need "docs/ProductDescription.md" @(
        "## Operational summary", "<!-- context:end -->",
        "## Users and outcomes", "| User or role | Needed outcome | Status | Source |",
        "## Business rules", "| ID | Rule | Status | Source or verification |",
        "## Main flows", "| Flow | Start -> outcome | Status |",
        "## Glossary", "| Term | Meaning | Status |",
        "## Out of scope"
    )
    Test-Need "docs/Stack_Tecnologies.md" @(
        "## Operational summary", "<!-- context:end -->",
        "## Architecture & Data",
        "## Critical commands",
        "## Environment variables & secrets", "| Variable | Purpose | Required | Example (Non-secret) |",
        "## Technical decisions (ADRs)", "| ID | Decision | Context/Reason | Status | Date |",
        "## Out of scope"
    )
    Test-Need "docs/Roadmap.md" @(
        "## Active work", "<!-- context:end -->",
        "## Near term", "## Plan", "## Gaps, Bugs & Technical Debt", "## Out of scope"
    )
    Test-Need "docs/Features.md" @("## Operational summary", "## Verified capabilities")
    if (Test-FactoryOn) {
        Test-Need "docs/Brain.md" @("## Operational summary", "<!-- context:end -->", "## Entries", "| ID | Name | Kind | Trigger | Lesson | Evidence | Status | Hits | Last used |")
    }

    if (Test-RoadmapNeedsYamlMigration) {
        [Console]::Error.WriteLine("MIGRATION REQUIRED: docs/Roadmap.md still uses the per-entry YAML format; run 'migrate'")
        $script:CheckFail = $true
    }

    if (-not $script:CheckFail) {
        try { $null = Get-HotContext } catch {
            [Console]::Error.WriteLine($_)
            $script:CheckFail = $true
        }
    }

    $log = Join-Path $DocsDir "Agentslog.md"
    if (Test-Path -LiteralPath $log -PathType Leaf) {
        Test-LogRotationNeeded
        Test-LogEntries
        Test-RoadmapFeaturesIds
        Test-AgentslogRoadmapNames
    }

    Test-IdFormatInSection "docs/ProductDescription.md" "## Business rules" '^BR-[0-9][0-9][0-9]+$' "Business rules"
    Test-IdFormatInSection "docs/Stack_Tecnologies.md" "## Technical decisions (ADRs)" '^ADR-[0-9][0-9][0-9]+$' "Technical decisions"
    Test-IdFormatInSection "docs/Roadmap.md" "## Plan" '^F[0-9]' "Plan"
    Test-TableStatusEnum "docs/ProductDescription.md" @("CONFIRMED", "HYPOTHESIS", "UNKNOWN") "epistemic"
    Test-TableStatusEnum "docs/Stack_Tecnologies.md" @("CONFIRMED", "HYPOTHESIS", "UNKNOWN") "epistemic"
    Test-TableStatusEnum "docs/Roadmap.md" @("TODO", "IN_PROGRESS", "PAUSE", "DONE") "workflow"
    Test-TableNameWordLimit "docs/Roadmap.md" 10
    if (Test-FactoryOn) { Test-BrainRows; Test-Specs; Test-FactoryRoster }

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

    $openStates = @(Get-OpenTaskStates)

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("# Agents log")
    $lines.Add("")
    $lines.Add("Append-only ledger and the source of truth for task ownership. Older")
    $lines.Add("segments live in ``docs/history/``.")
    $lines.Add("")
    $lines.Add("## Entry format")
    $lines.Add("")
    $lines.Add('```markdown')
    $lines.Add("## [YYYY-MM-DDTHH:mm:ssZ] | agent | TASK-ID | IN_PROGRESS | Name")
    $lines.Add("- Summary: what the agent will do or did")
    $lines.Add("- Files: paths or component names (optional)")
    $lines.Add('- Verify: command and result, or "pending" (required for DONE and REVIEW)')
    $lines.Add("- Pause: CATEGORY - detail (required for PAUSE)")
    $lines.Add("- Handoff: reviewer agent or role (optional, REVIEW)")
    $lines.Add("- Review: PASS|FAIL - detail (optional, REVIEW)")
    $lines.Add("- Assign: agent (required for ASSIGNED)")
    $lines.Add('```')
    $lines.Add("")
    $lines.Add("## Previous segment")
    $lines.Add("")
    $lines.Add("- Archive: ``docs/history/$name``")
    $lines.Add("- SHA-256: ``$archiveHash``")
    $lines.Add("")
    $lines.Add("## Entries")
    foreach ($s in $openStates) {
        if ($s.Status -eq "REVIEW") {
            # The developer who holds the task is not necessarily the agent of
            # the last entry (a reviewer wrote it), so re-open the holder first
            # and then the REVIEW entry with its handoff/review lines; otherwise
            # done by the holder would stop working after a rotation.
            $lines.Add("")
            $lines.Add("## [$($s.Ts)] | $($s.Holder) | $($s.Task) | IN_PROGRESS | $($s.Name)")
            $lines.Add("- Summary: carried forward from docs/history/$name at rotation")
        }
        $lines.Add("")
        $lines.Add("## [$($s.Ts)] | $($s.Agent) | $($s.Task) | $($s.Status) | $($s.Name)")
        $lines.Add("- Summary: carried forward from docs/history/$name at rotation")
        if ($s.Status -eq "PAUSE") {
            $lines.Add("- Pause: $($s.PauseCat) - see docs/history/$name for detail")
        }
        if ($s.Status -eq "ASSIGNED") {
            $lines.Add("- Assign: $($s.Holder)")
        }
        if ($s.Status -eq "REVIEW") {
            $lines.Add("- Verify: carried forward from docs/history/$name")
            if ($s.Handoff) { $lines.Add("- Handoff: $($s.Handoff)") }
            if ($s.Review) { $lines.Add("- Review: $($s.Review) - carried forward from docs/history/$name") }
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
    "handoff" { Invoke-Handoff }
    "review" { Invoke-Review }
    "mode" { Invoke-Mode }
    "assign" { Invoke-Assign }
    "done" { Invoke-Done }
    "status" { Invoke-Status }
    default {
        Write-Output "Usage: project_docs.ps1 {init|check|context|append-log|rotate|migrate|link|claim|pause|handoff|review|assign|done|status|mode} <project> [args]"
    }
}
