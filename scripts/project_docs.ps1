[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet("init", "check", "context", "append-log", "rotate", "migrate", "link", "claim", "pause", "handoff", "review", "assign", "done", "status", "mode", "checkpoint", "advance", "recall", "learn", "retro", "next", "digest", "help")]
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
        Add-FactoryDispatchSetup
    }
    Write-Output "project_docs init: $created file(s) created"
    Invoke-LinkAll $Project ""
}

# .factory/dispatch.md from the template, and the .gitignore block for the files the dispatcher
# generates. Additive and idempotent; says only what it adds and leaves the number of changes in
# $script:DispatchChanges.
function Add-FactoryDispatchSetup {
    $changes = 0
    $tpl = Join-Path $TemplatesDir "dispatch.md"
    if (-not (Test-Path -LiteralPath $tpl -PathType Leaf)) { throw "template missing: dispatch.md" }
    $cfg = Join-Path (Join-Path $Project ".factory") "dispatch.md"
    if (-not (Test-Path -LiteralPath $cfg -PathType Leaf)) {
        New-Item -ItemType Directory -Path (Split-Path -Parent $cfg) -Force | Out-Null
        Copy-Item -LiteralPath $tpl -Destination $cfg
        Write-Output "+ created: .factory/dispatch.md"
        $changes++
    }
    $gi = Join-Path $Project ".gitignore"
    $mark = "# project-documentation dispatcher (generated files)"
    $has = $false
    if (Test-Path -LiteralPath $gi -PathType Leaf) {
        foreach ($l in @(Get-ContentUtf8 -LiteralPath $gi)) {
            if (([string]$l).Trim().ToLowerInvariant() -ceq $mark) { $has = $true; break }
        }
    }
    if (-not $has) {
        $prefix = ""
        if ((Test-Path -LiteralPath $gi -PathType Leaf) -and (Get-Item -LiteralPath $gi).Length -gt 0) {
            $bytes = [System.IO.File]::ReadAllBytes($gi)
            if ($bytes[$bytes.Length - 1] -ne 10) { $prefix = "`n" }
            $prefix += "`n"
        }
        [System.IO.File]::AppendAllText($gi, $prefix + $mark + "`n.factory/state.md`n.factory/runs/`n", $Utf8)
        Write-Output "+ added: .gitignore block for .factory/state.md and .factory/runs/"
        $changes++
    }
    $script:DispatchChanges = $changes
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
    Add-FactoryDispatchSetup
    $changes += $script:DispatchChanges
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

function Get-LatestEntries([int]$Keep = 5) {
    $lines = @(Get-ContentUtf8 -LiteralPath (Join-Path $DocsDir "Agentslog.md"))
    $entriesSection = [Array]::IndexOf($lines, "## Entries")
    if ($entriesSection -lt 0) { return @() }
    $starts = @(
        for ($i = $entriesSection + 1; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match '^## \[') { $i }
        }
    )
    if ($starts.Count -eq 0) { return @() }
    $first = $starts[[Math]::Max(0, $starts.Count - $Keep)]
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
    $hold = @{}; $lastHandoff = @{}; $lastReview = @{}; $lastPhase = @{}; $specPass = @{}; $redSha = @{}; $testPaths = @{}; $attempts = @{}; $struggled = @{}; $laneOf = @{}; $baseSha = @{}; $crossOf = @{}; $auditedOf = @{}; $pauseDetail = @{}
    # The Factory lines of the ledger (Phase, Spec-pass, Red, Tests, Attempts) are read and
    # derived from only in Factory mode (BR-008).
    $fac = Test-FactoryOn
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
            if ($fac -and $status -ceq "AUDIT") { $auditedOf[$tid] = $true; $cur = $null; continue }
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
            $pauseDetail[$tid] = ""
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
        if ($fac -and $cur -and $line -cmatch '^- Red:\s*(.*?)\s*$') {
            $redSha[$cur] = $Matches[1]
            continue
        }
        if ($fac -and $cur -and $line -cmatch '^- Tests:\s*(.*?)\s*$') {
            $testPaths[$cur] = $Matches[1]
            continue
        }
        if ($fac -and $cur -and $line -cmatch '^- Cross-model:\s*(.*?)\s*$') {
            $crossOf[$cur] = $Matches[1]
            continue
        }
        if ($fac -and $cur -and $line -cmatch '^- Lane:\s*(.*?)\s*$') {
            $laneOf[$cur] = $Matches[1]
            if ($Matches[1] -cne "FAST") { $baseSha[$cur] = "" }
            continue
        }
        if ($fac -and $cur -and $line -cmatch '^- Base:\s*(.*?)\s*$') {
            $baseSha[$cur] = $Matches[1]
            continue
        }
        if ($fac -and $cur -and $line -cmatch '^- Struggled:') {
            $struggled[$cur] = $true
            continue
        }
        if ($fac -and $cur -and $line -cmatch '^- Attempts:\s*(.*?)\s*$') {
            $n = 0
            if ($Matches[1] -match '^[0-9]+') { $n = [int]$Matches[0] }
            $attempts[$cur] = $n
            continue
        }
        if ($fac -and $cur -and $line -cmatch '^- Spec-pass:\s*(.*?)\s*$') {
            $specPass[$cur] = $Matches[1]
            continue
        }
        if ($fac -and $cur -and $line -cmatch '^- Phase:\s*(.*?)\s*$') {
            if ($Matches[1] -ceq "SPEC" -and $lastPhase.ContainsKey($cur) -and $lastPhase[$cur] -and $lastPhase[$cur] -cne "SPEC") { $specPass[$cur] = "" }
            if ($Matches[1] -ceq "RED" -and $lastPhase.ContainsKey($cur) -and $lastPhase[$cur] -ceq "GREEN") { $attempts[$cur] = 1 + [int]$attempts[$cur]; $struggled[$cur] = $true }
            if ($Matches[1] -ceq "RED" -or $Matches[1] -ceq "SPEC") { $redSha[$cur] = ""; $testPaths[$cur] = "" }
            $lastPhase[$cur] = $Matches[1]
            continue
        }
        if ($cur -and $line -match '^- Review:\s*(.*)$') {
            $rbody = $Matches[1]
            $rdash = $rbody.IndexOf(" - ")
            if ($rdash -ge 0) { $lastReview[$cur] = $rbody.Substring(0, $rdash).TrimEnd() } else { $lastReview[$cur] = $rbody.TrimEnd() }
            if ($fac) { $crossOf[$cur] = "" }
            $reviewPhase = "SPEC"
            if ($lastPhase.ContainsKey($cur) -and $lastPhase[$cur]) { $reviewPhase = $lastPhase[$cur] }
            if ($fac -and $reviewPhase -ceq "SPEC") {
                if ($lastReview[$cur] -cmatch '^PASS') { $specPass[$cur] = $lastAgent[$cur] } else { $specPass[$cur] = "" }
            }
            if ($fac -and $lastReview[$cur] -cmatch '^FAIL') { $attempts[$cur] = 1 + [int]$attempts[$cur]; $struggled[$cur] = $true }
            continue
        }
        if ($cur -and $line -match '^- Pause: (.*)$') {
            $body = $Matches[1]
            $dashIdx = $body.IndexOf(" - ")
            if ($dashIdx -ge 0) { $lastPause[$cur] = $body.Substring(0, $dashIdx) } else { $lastPause[$cur] = $body }
            if ($fac -and $dashIdx -ge 0) { $pauseDetail[$cur] = $body.Substring($dashIdx + 3) }
            if ($fac -and $lastPause[$cur] -ceq "BLOQUEO") { $attempts[$cur] = 0; $struggled[$cur] = $true }
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
            SpecPass = $(if ($specPass.ContainsKey($t)) { $specPass[$t] } else { "" })
            Red = $(if ($redSha.ContainsKey($t)) { $redSha[$t] } else { "" })
            Tests = $(if ($testPaths.ContainsKey($t)) { $testPaths[$t] } else { "" })
            Attempts = [int]$attempts[$t]
            Struggled = [bool]$struggled[$t]
            Lane = $(if ($laneOf.ContainsKey($t)) { $laneOf[$t] } else { "" })
            Base = $(if ($baseSha.ContainsKey($t)) { $baseSha[$t] } else { "" })
            Cross = $(if ($crossOf.ContainsKey($t)) { $crossOf[$t] } else { "" })
            Audited = [bool]$auditedOf[$t]
            PauseDetail = $(if ($pauseDetail.ContainsKey($t)) { $pauseDetail[$t] } else { "" })
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
function Assert-PhaseRole([string]$Agent, [string]$Phase, [string]$Task, [string]$Verb = "claim") {
    $role = Get-RosterRole $Agent
    if (-not $role) {
        throw "$Verb failed: $Agent is not in the Agent identity table; Factory mode needs a role for each agent"
    }
    $norm = Get-RoleNorm $role
    $need = Get-PhaseRole $Phase
    if (-not $need) {
        throw "$Verb failed: $Task is in phase $Phase, which has no role (use SPEC, RED, GREEN or REVIEW)"
    }
    if ($norm -cne "BOTH" -and $norm -cne $need) {
        throw "$Verb failed: $Agent has role $role, but phase $Phase of $Task needs $need (or BOTH)"
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
    $base = $parts.ToArray()
    $keep = 5
    while ($true) {
        $all = [System.Collections.Generic.List[string]]::new()
        $all.AddRange([string[]]$base)
        if ($keep -lt 5) { $all.Add("## Latest agent entries (the latest $keep only, to stay within $ContextLimit bytes)") }
        else { $all.Add("## Latest agent entries") }
        foreach ($line in @(Get-LatestEntries $keep)) { $all.Add([string]$line) }
        $content = ($all -join "`n") + "`n"
        $bytes = $Utf8.GetByteCount($content)
        if ($bytes -le $ContextLimit) { return $content }
        # In Factory mode older entries give way before the command fails, so an agent that
        # starts with context always gets it; the summaries above are what has to be compacted.
        if ((Test-FactoryOn) -and $keep -gt 1) { $keep--; continue }
        throw "hot context is $bytes bytes; compact summaries below $ContextLimit"
    }
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
    $takeDir = $lockDir + ".takeover"
    $attempts = 0
    while ($true) {
        # cmd's mkdir fails when the directory exists and checks and creates in one call to the
        # system. New-Item checks first and creates after, so two processes could both win.
        & cmd.exe /d /c ('mkdir "' + $lockDir + '" 2>nul') | Out-Null
        if ($LASTEXITCODE -eq 0) { break }
        # The lock can be released between the Test-Path and the Get-Item, so a failure below only
        # means ask again. An old lock is taken over by one waiter at a time, who reads its age
        # again inside the takeover: two waiters that saw the same old lock could otherwise both
        # remove it, and the second would remove the new lock of the first.
        try {
            if (Test-Path -LiteralPath $lockDir -PathType Container) {
                $age = (Get-Date).ToUniversalTime() - (Get-Item -LiteralPath $lockDir -ErrorAction Stop).LastWriteTimeUtc
                if ($age.TotalSeconds -ge 30) {
                    & cmd.exe /d /c ('mkdir "' + $takeDir + '" 2>nul') | Out-Null
                    if ($LASTEXITCODE -eq 0) {
                        try {
                            if (Test-Path -LiteralPath $lockDir -PathType Container) {
                                $age2 = (Get-Date).ToUniversalTime() - (Get-Item -LiteralPath $lockDir -ErrorAction Stop).LastWriteTimeUtc
                                if ($age2.TotalSeconds -ge 30) { Remove-Item -LiteralPath $lockDir -Force -Recurse -ErrorAction SilentlyContinue }
                            }
                        } catch { }
                        Remove-Item -LiteralPath $takeDir -Force -Recurse -ErrorAction SilentlyContinue
                    }
                    elseif (Test-Path -LiteralPath $takeDir -PathType Container) {
                        # a takeover that died leaves its marker: it counts as old too
                        try {
                            $ageT = (Get-Date).ToUniversalTime() - (Get-Item -LiteralPath $takeDir -ErrorAction Stop).LastWriteTimeUtc
                            if ($ageT.TotalSeconds -ge 30) { Remove-Item -LiteralPath $takeDir -Force -Recurse -ErrorAction SilentlyContinue }
                        } catch { }
                    }
                }
            }
        } catch { }
        $attempts++
        if ($attempts -ge 50) { throw "could not acquire docs/.lock (busy); retry" }
        Start-Sleep -Milliseconds 100
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
        $claimLegacy = $false
        if (Test-FactoryOn) {
            $claimPhase = "SPEC"
            if ($state -and $state.Phase) { $claimPhase = $state.Phase }
            $prevLane = ""
            if ($state) { $prevLane = $state.Lane }
            $claimLane = "NORMAL"
            if ((Get-RoadmapRowField $task "Description").Contains("Lane: FAST")) { $claimLane = "FAST" }
            $claimBase = ""
            if ($claimLane -ceq "FAST") {
                if ($prevLane -cne "FAST" -and $state -and $state.Phase -and $claimPhase -cne "SPEC") {
                    throw "claim failed: $task already went through the normal lane (phase $claimPhase); take Lane: FAST out of its row"
                }
                $claimPhase = "GREEN"
                if ($prevLane -ceq "FAST" -and $state) { $claimBase = $state.Base }
                if (-not $claimBase -and (Test-GitReady)) {
                    $h = Invoke-GitProbe @("rev-parse", "HEAD")
                    if ($h.Code -eq 0) { $claimBase = $h.Out.Trim() }
                }
            } elseif ($prevLane -ceq "FAST") {
                $claimPhase = "SPEC"
            }
            # A task already started before the project moved to Factory mode has no phase and no lane
            # (ADR-090): its retake keeps it that way instead of putting it into SPEC, where done would
            # refuse it. A task that is new, assigned or from the fast lane always gets both.
            if ($state -and -not $state.Phase -and -not $prevLane -and $claimLane -ceq "NORMAL" -and $state.Status -cin @("IN_PROGRESS", "REVIEW", "PAUSE")) {
                $claimLegacy = $true
            }
            if (-not $claimLegacy) { Assert-PhaseRole $agent $claimPhase $task }
            $maxAttempts = [int](Get-FactoryNumber "Max fix attempts")
            if ($state -and [int]$state.Attempts -ge $maxAttempts) {
                throw "claim failed: $task used $($state.Attempts) of $maxAttempts fix attempts; pause it with BLOQUEO and write the lesson, or raise Max fix attempts"
            }
            $wipMax = [int](Get-FactoryNumber "WIP per agent")
            $busy = @(Get-TaskStates | Where-Object { $_.Status -eq "IN_PROGRESS" -and $_.Agent -ceq $agent -and $_.Task -cne $task })
            if ($busy.Count -ge $wipMax) {
                throw "claim failed: $agent already has $($busy.Count) task(s) in progress (WIP per agent is $wipMax): $((@($busy | ForEach-Object { $_.Task })) -join ', ')"
            }
        }
        $name = Assert-ValidName $task "claim"
        $timestamp = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
        $claimLines = @(
            "",
            "## [$timestamp] | $agent | $task | IN_PROGRESS | $name",
            "- Summary: $summary",
            "- Verify: pending"
        )
        if ((Test-FactoryOn) -and -not $claimLegacy) {
            $claimLines += "- Phase: $claimPhase"
            $claimLines += "- Lane: $claimLane"
            if ($claimBase) { $claimLines += "- Base: $claimBase" }
        }
        $entry = ($claimLines -join "`n") + "`n"
        [System.IO.File]::AppendAllText($log, $entry, $Utf8)
        Invoke-RoadmapClaimRow $task $agent $timestamp
        Write-Output "project_docs claim: $task claimed by $agent"
    } finally {
        Exit-DocsLock
    }
}

# Factory mode. The verify must carry exit=0.
function Assert-ExitZero([string]$Verb, [string]$Verify) {
    $n = Get-VerifyExit $Verify
    if (-not $n) { throw "$Verb failed: the verify needs exit=N (exit=0 when the checks pass)" }
    if (-not (Test-ExitIsZero $n)) { throw "$Verb failed: the verify says exit=$n, not exit=0" }
}

# Handoff in GREEN. The test files recorded at RED (the Tests line) must be as they were
# at the Red sha; without git it only warns.
function Assert-TestsUnchanged([string]$Task, $State) {
    if (-not $State.Tests) { return }
    if ($State.Red -and (Test-GitReady)) {
        $c = Invoke-GitProbe @("cat-file", "-e", "$($State.Red)^{commit}")
        if ($c.Code -ne 0) { throw "handoff failed: the Red sha $($State.Red) is not in this repository" }
        $d = Invoke-GitProbe @("-c", "core.quotepath=false", "diff", "--no-renames", "--relative", "--name-only", $State.Red)
        if ($d.Code -ne 0) { throw "handoff failed: git could not compare the files with the Red sha $($State.Red)" }
        $want = @{}
        foreach ($p in @($State.Tests -split ' ' | Where-Object { $_ })) { $want[$p] = $true }
        $changed = (@($d.Out -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -and $want.ContainsKey($_) })) -join " "
        if ($changed) { throw "handoff failed: test file(s) changed since RED ($($State.Red)): $changed; a wrong test goes back to SPEC with advance" }
    } else {
        [Console]::Error.WriteLine("WARN: git is not available here, so the tests cannot be checked as unchanged since RED; the reviewer must write 'tests unchanged' in the review note")
    }
}

# Review PASS of a GREEN handoff whose tests git could not check needs the words
# "tests unchanged" in the note.
function Assert-TestsNote([string]$Task, $State, [string]$Note) {
    if (-not $State.Tests) { return }
    if ($State.Phase -cne "GREEN") { return }
    if ($State.Red -and (Test-GitReady)) { return }
    if (-not $Note.ToLowerInvariant().Contains("tests unchanged")) {
        throw "review failed: git could not check the tests of $Task; the note must say 'tests unchanged'"
    }
}

# ---------------------------------------------------------------------------
# The brain: docs/Brain.md rows read by recall, written by learn and retro, archived by
# rotate (F06-E03-T03 to T05). Only Factory mode.
# ---------------------------------------------------------------------------
# The well-formed rows of the Entries table: Cells (the nine cells) and Line (as written).
function Get-BrainRows {
    $path = Join-Path $DocsDir "Brain.md"
    $rows = [System.Collections.Generic.List[object]]::new()
    $insec = $false
    foreach ($raw in @(Get-ContentUtf8 -LiteralPath $path)) {
        $line = ([string]$raw).Replace([string][char]9, " ")
        if ($line -ceq "## Entries") { $insec = $true; continue }
        if ($insec -and $line.StartsWith("## ")) { $insec = $false }
        if (-not ($insec -and $line.StartsWith("|"))) { continue }
        $c = @(Split-TableCells $line)
        if ($c.Count -ne 9 -or $c[0] -ceq "ID" -or $c[0] -match '^-+$' -or $c[0] -eq $EmDash) { continue }
        $rows.Add([PSCustomObject]@{ Cells = $c; Line = $line.TrimEnd() })
    }
    return $rows.ToArray()
}

# The next LRN id; ids of archived rows count, so an id is never reused.
function Get-BrainNextId {
    $max = 0
    $files = [System.Collections.Generic.List[string]]::new()
    $files.Add((Join-Path $DocsDir "Brain.md"))
    if (Test-Path -LiteralPath $HistoryDir -PathType Container) {
        foreach ($f in @(Get-ChildItem -LiteralPath $HistoryDir -File | Where-Object { $_.Name -clike "brain-archive-*.md" })) { $files.Add($f.FullName) }
    }
    foreach ($f in $files) {
        foreach ($l in @(Get-ContentUtf8 -LiteralPath $f)) {
            if ($l -cmatch '^\| LRN-([0-9]+) ') {
                $n = [decimal]$Matches[1]
                if ($n -gt $max) { $max = $n }
            }
        }
    }
    return ("LRN-{0:D3}" -f ([int]$max + 1))
}

# Lower case for the letters A to Z only (the sh launcher does the same under LC_ALL=C).
function ConvertTo-AsciiLower([string]$Text) {
    return [regex]::Replace($Text, '[A-Z]', [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $m.Value.ToLowerInvariant() })
}

# recall <project> <task-id>: what to read before working on a task, within the recall
# budget: the Roadmap row, the spec summary, the working memory and the brain rows
# whose Trigger matches the task, best first, whole rows only.
function Invoke-Recall {
    Assert-FactoryMode "recall"
    # The rows carry an em dash; with stdout and stderr in one file the console would turn it into a hyphen.
    [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
    if ($Arguments.Count -lt 1) { throw "recall requires: task-id" }
    $task = ConvertTo-CleanField $Arguments[0]
    if (-not (Test-Path -LiteralPath (Join-Path $DocsDir "Agentslog.md") -PathType Leaf)) { throw "run init first" }
    if (-not (Test-RoadmapHasId $task)) { throw "recall failed: $task not found in docs/Roadmap.md" }
    $budget = [int](Get-FactoryNumber "Recall budget bytes")
    $name = Get-RoadmapRowField $task "Name"
    $desc = Get-RoadmapRowField $task "Description"
    $acc = Get-RoadmapRowField $task "Acceptance check"
    $status = Get-RoadmapRowField $task "Status"
    $owner = Get-RoadmapRowField $task "Owner"
    $deps = Get-RoadmapRowField $task "Depends on"
    $spec = Join-Path (Join-Path $DocsDir "specs") "$task.md"
    $fixed = [System.Collections.Generic.List[string]]::new()
    $fixed.Add("## Task")
    $fixed.Add("- ID: $task")
    $fixed.Add("- Name: $name")
    $fixed.Add("- Description: $(if ($desc) { $desc } else { [string]$EmDash })")
    if ($acc) { $fixed.Add("- Acceptance check: $acc") }
    $fixed.Add("- Status: $(if ($status) { $status } else { [string]$EmDash }); Owner: $(if ($owner) { $owner } else { [string]$EmDash }); Depends on: $(if ($deps) { $deps } else { [string]$EmDash })")
    $fixed.Add("## Spec summary")
    $tags = ""
    if (Test-Path -LiteralPath $spec -PathType Leaf) {
        $insec = $false
        foreach ($l in @(Get-ContentUtf8 -LiteralPath $spec)) {
            if ($l.StartsWith("## ")) { $insec = ($l -ceq "## Summary"); continue }
            if ($insec -and $l -cne "<!-- context:end -->" -and $l -ne "") { $fixed.Add($l) }
            if ($l -cmatch '^- Tags:') { if (-not $tags) { $tags = ($l -creplace '^- Tags:[ \t]*', '') } }
        }
    } else {
        $fixed.Add("(no spec yet)")
    }
    $fixed.Add("## Now")
    if (Test-WorkingNow $task) {
        $insec = $false
        foreach ($l in @(Get-ContentUtf8 -LiteralPath (Get-WorkingMemoryPath $task))) {
            if ($l.StartsWith("## ")) { $insec = ($l -ceq "## Now"); continue }
            if ($insec -and $l -ne "") { $fixed.Add($l) }
        }
    } else {
        $fixed.Add("(no working memory yet)")
    }
    $fixed.Add("## Brain")
    $tokens = @{}
    foreach ($m in [regex]::Matches((ConvertTo-AsciiLower "$name $desc $deps"), '[a-z]+')) {
        if ($m.Value.Length -ge 4) { $tokens[$m.Value] = $true }
    }
    foreach ($t in @((ConvertTo-AsciiLower $tags) -split '[ \t]+')) { if ($t) { $tokens[$t] = $true } }
    $rows = @()
    if (Test-Path -LiteralPath (Join-Path $DocsDir "Brain.md") -PathType Leaf) { $rows = @(Get-BrainRows) }
    $total = $rows.Count
    $used = 0
    foreach ($l in $fixed) { $used += $Utf8.GetByteCount($l) + 1 }
    $minFinal = $Utf8.GetByteCount("recall: 0 of $total brain entries shown") + 1
    if (($used + $minFinal) -gt $budget) {
        throw "recall failed: the task, the spec summary and the working memory take $($used + $minFinal) bytes, over the Recall budget bytes of $budget; shorten the spec Summary or the working memory"
    }
    $scored = [System.Collections.Generic.List[object]]::new()
    foreach ($r in $rows) {
        $trig = ConvertTo-AsciiLower $r.Cells[3]
        $score = 0
        if ($trig -ceq "*") { $score = 1 }
        else {
            $seen = @{}
            foreach ($t in @($trig -split ' ')) {
                if (-not $t -or $seen.ContainsKey($t)) { continue }
                $seen[$t] = $true
                $hit = $false
                if ($t.Contains("/")) {
                    foreach ($x in $tokens.Keys) { if ($x.StartsWith($t, [System.StringComparison]::Ordinal)) { $hit = $true; break } }
                } elseif ($tokens.ContainsKey($t)) { $hit = $true }
                if ($hit) { $score++ }
            }
        }
        if ($score -ge 1) {
            $hits = [decimal]0
            if ($r.Cells[7] -match '^[0-9]+$') { $hits = [decimal]$r.Cells[7] }
            $scored.Add([PSCustomObject]@{ Score = $score; Hits = $hits; Id = $r.Cells[0]; Line = $r.Line })
        }
    }
    # best first: score, hits, then id in ordinal order (insertion sort, no culture involved)
    $sorted = [System.Collections.Generic.List[object]]::new()
    foreach ($item in $scored) {
        $pos = $sorted.Count
        for ($i = 0; $i -lt $sorted.Count; $i++) {
            $o = $sorted[$i]
            $before = ($item.Score -gt $o.Score) -or ($item.Score -eq $o.Score -and ($item.Hits -gt $o.Hits -or ($item.Hits -eq $o.Hits -and [string]::CompareOrdinal($item.Id, $o.Id) -lt 0)))
            if ($before) { $pos = $i; break }
        }
        $sorted.Insert($pos, $item)
    }
    $bytes = $used
    $picked = [System.Collections.Generic.List[string]]::new()
    for ($a = 0; $a -lt $sorted.Count; $a++) {
        $final = "recall: $($a + 1) of $total brain entries shown"
        if (($bytes + $Utf8.GetByteCount($sorted[$a].Line) + 1 + $Utf8.GetByteCount($final) + 1) -gt $budget) { break }
        $bytes += $Utf8.GetByteCount($sorted[$a].Line) + 1
        $picked.Add($sorted[$a].Line)
    }
    foreach ($l in $fixed) { Write-Output $l }
    foreach ($l in $picked) { Write-Output $l }
    Write-Output "recall: $($picked.Count) of $total brain entries shown"
}

# learn <project> <agent> <task-id> <kind> <name> <trigger> <lesson>: adds a lesson to the brain.
function Invoke-Learn {
    Assert-FactoryMode "learn"
    if ($Arguments.Count -lt 6) { throw "learn requires: agent task-id kind name trigger lesson" }
    foreach ($a in $Arguments) { if ($a.Contains("|")) { throw "learn failed: no argument may contain a vertical bar" } }
    $agent = Get-CanonicalAgent (ConvertTo-CleanField $Arguments[0])
    $task = ConvertTo-CleanField $Arguments[1]
    $kind = ConvertTo-CleanField $Arguments[2]
    $lname = ConvertTo-CleanField ($Arguments[3].Replace([string][char]9, " "))
    $trigger = ConvertTo-AsciiLower (ConvertTo-CleanField ($Arguments[4].Replace([string][char]9, " ")))
    $lesson = ConvertTo-CleanField ($Arguments[5].Replace([string][char]9, " "))
    if ($kind -cnotin @("PITFALL", "PATTERN", "RECIPE", "DEFAULT", "MAP")) { throw "learn failed: kind must be PITFALL, PATTERN, RECIPE, DEFAULT or MAP" }
    if (-not $lname) { throw "learn failed: the name is empty" }
    $words = Get-WordCount $lname
    if ($words -gt 10) { throw "learn failed: the name is $words words, over the 10-word limit" }
    if (-not $trigger) { throw "learn failed: the trigger is empty" }
    if (-not $lesson) { throw "learn failed: the lesson is empty" }
    if ($trigger -ceq "*" -and $kind -cne "DEFAULT") { throw "learn failed: the trigger * is only for DEFAULT lessons" }
    if (-not (Test-Path -LiteralPath (Join-Path $DocsDir "Agentslog.md") -PathType Leaf)) { throw "run init first" }
    $brain = Join-Path $DocsDir "Brain.md"
    if (-not (Test-Path -LiteralPath $brain -PathType Leaf)) { throw "learn failed: docs/Brain.md does not exist (run migrate --factory)" }
    if (-not (Test-RoadmapHasId $task) -and -not (Get-TaskState $task)) { throw "learn failed: $task is not a task of this project" }
    Enter-DocsLock
    try {
        $rows = @(Get-BrainRows)
        $max = [int](Get-FactoryNumber "Brain max entries")
        $want = ConvertTo-AsciiLower $lname
        foreach ($r in $rows) {
            if ((ConvertTo-AsciiLower $r.Cells[1]) -ceq $want) { throw "learn failed: $($r.Cells[0]) already has the name `"$lname`"" }
        }
        if ($rows.Count -ge $max) {
            throw "learn failed: the brain already has $($rows.Count) entries (Brain max entries is $max); run rotate to archive the least used"
        }
        $id = Get-BrainNextId
        $newRow = "| $id | $lname | $kind | $trigger | $lesson | log:$task | HYPOTHESIS | 0 | $EmDash |"
        $lines = @(Get-ContentUtf8 -LiteralPath $brain)
        $insec = $false
        $last = -1
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -ceq "## Entries") { $insec = $true }
            elseif ($insec -and $lines[$i].StartsWith("## ")) { $insec = $false }
            if ($insec -and $lines[$i].StartsWith("|")) { $last = $i }
        }
        $out = [System.Collections.Generic.List[string]]::new()
        for ($i = 0; $i -lt $lines.Count; $i++) {
            $l = [string]$lines[$i]
            if ($l.StartsWith("- Entries: ")) { $l = "- Entries: $($rows.Count + 1) of $max" }
            $out.Add($l)
            if ($i -eq $last) { $out.Add($newRow) }
        }
        Write-Utf8File $brain (ConvertTo-JoinedLines ([string[]]$out.ToArray()))
        Write-Output "project_docs learn: $id added"
    } finally {
        Exit-DocsLock
    }
}

# Validates a list of lesson ids (or the word none) and returns it sorted and without
# repeats, as "LRN-001, LRN-003" or "none".
function Get-BrainIds([string]$List) {
    $text = ($List -replace ',', ' ').Trim()
    if ($text -ceq "none" -or -not $text) { return "none" }
    $ids = [System.Collections.Generic.List[string]]::new()
    foreach ($t in @($text -split ' ' | Where-Object { $_ })) {
        if ($t -cnotmatch '^LRN-[0-9]{3,}$') { throw "retro failed: `"$t`" is not a lesson id like LRN-001 or the word none" }
        if (-not $ids.Contains($t)) { $ids.Add($t) }
    }
    $arr = $ids.ToArray()
    [System.Array]::Sort($arr, [System.StringComparer]::Ordinal)
    return ($arr -join ", ")
}

# retro <project> <agent> <task-id> <used-ids|none> <learned-ids|none>: records which lessons
# the task used and which it left behind in the ## Retro of its working memory.
function Invoke-Retro {
    Assert-FactoryMode "retro"
    if ($Arguments.Count -lt 4) { throw "retro requires: agent task-id used-ids|none learned-ids|none" }
    $agent = Get-CanonicalAgent (ConvertTo-CleanField $Arguments[0])
    $task = ConvertTo-CleanField $Arguments[1]
    if (-not (Test-Path -LiteralPath (Join-Path $DocsDir "Agentslog.md") -PathType Leaf)) { throw "run init first" }
    if (-not (Test-RoadmapHasId $task) -and -not (Get-TaskState $task)) { throw "retro failed: $task is not a task of this project" }
    if (-not (Test-WorkingNow $task)) { throw "retro failed: $task has no working memory yet (## Now); run checkpoint first" }
    $used = Get-BrainIds (ConvertTo-CleanField $Arguments[2])
    $learned = Get-BrainIds (ConvertTo-CleanField $Arguments[3])
    $rows = @()
    if (Test-Path -LiteralPath (Join-Path $DocsDir "Brain.md") -PathType Leaf) { $rows = @(Get-BrainRows) }
    if ($used -cne "none") {
        foreach ($id in @($used -split ', ')) {
            if (-not (@($rows | Where-Object { $_.Cells[0] -ceq $id }).Count)) { throw "retro failed: $id is not in docs/Brain.md" }
        }
    }
    if ($learned -cne "none") {
        foreach ($id in @($learned -split ', ')) {
            $row = @($rows | Where-Object { $_.Cells[0] -ceq $id })
            if ($row.Count -eq 0) { throw "retro failed: $id is not in docs/Brain.md" }
            if ($row[0].Cells[5] -cne "log:$task") { throw "retro failed: $id was not learned for $task (its Evidence is $($row[0].Cells[5]))" }
        }
    }
    if ($learned -ceq "none") {
        $st = Get-TaskState $task
        if ($st -and $st.Struggled) {
            throw "retro failed: $task had a Review: FAIL, a BLOQUEO or a move back to RED; record what was learned with learn first"
        }
    }
    Enter-DocsLock
    try {
        $wm = Get-WorkingMemoryPath $task
        $lines = @(Get-ContentUtf8 -LiteralPath $wm)
        $out = [System.Collections.Generic.List[string]]::new()
        $inretro = $false; $seen = $false; $done = $false
        foreach ($raw in $lines) {
            $l = [string]$raw
            if ($l.StartsWith("## ")) {
                $inretro = ($l -ceq "## Retro")
                if ($inretro) { $seen = $true }
                $out.Add($l)
                if ($inretro -and -not $done) { $out.Add("- Used: $used"); $out.Add("- Learned: $learned"); $done = $true }
                continue
            }
            if ($inretro -and ($l.StartsWith("- Used:") -or $l.StartsWith("- Learned:"))) { continue }
            $out.Add($l)
        }
        if (-not $seen) { throw "retro failed: docs/brain/tasks/$task.md has no ## Retro section" }
        Write-Utf8File $wm (ConvertTo-JoinedLines ([string[]]$out.ToArray()))
        Write-Output "project_docs retro: $task recorded (used: $used; learned: $learned)"
    } finally {
        Exit-DocsLock
    }
}

# Reads the recorded retro of a task into $script:DoneUsed and $script:DoneLearned; throws when
# there is none (done in Factory mode needs it).
function Read-TaskRetro([string]$Task) {
    $script:DoneUsed = ""
    $script:DoneLearned = ""
    $wm = Get-WorkingMemoryPath $Task
    if (Test-Path -LiteralPath $wm -PathType Leaf) {
        $insec = $false
        foreach ($l in @(Get-ContentUtf8 -LiteralPath $wm)) {
            if ($l.StartsWith("## ")) { $insec = ($l -ceq "## Retro"); continue }
            if ($insec -and $l.StartsWith("- Used:") -and -not $script:DoneUsed) { $script:DoneUsed = ($l -creplace '^- Used:[ \t]*', '') }
            if ($insec -and $l.StartsWith("- Learned:") -and -not $script:DoneLearned) { $script:DoneLearned = ($l -creplace '^- Learned:[ \t]*', '') }
        }
    }
    if (-not $script:DoneUsed -or $script:DoneUsed -eq $EmDash -or -not $script:DoneLearned -or $script:DoneLearned -eq $EmDash) {
        throw "done failed: $Task has no retro yet; run retro first"
    }
    if ($script:DoneLearned -ceq "none") {
        $st = Get-TaskState $Task
        if ($st -and $st.Struggled) {
            throw "done failed: $Task had a Review: FAIL, a BLOQUEO or a move back to RED, so its retro cannot say learned none; run learn and retro again"
        }
    }
}

# Adds one hit and the date to every lesson of the list (done in Factory mode).
function Set-BrainHits([string]$Ids, [string]$Day) {
    if ($Ids -ceq "none") { return }
    $brain = Join-Path $DocsDir "Brain.md"
    if (-not (Test-Path -LiteralPath $brain -PathType Leaf)) { return }
    $want = @{}
    foreach ($id in @($Ids -split ', ')) { $want[$id] = $true }
    $out = [System.Collections.Generic.List[string]]::new()
    $insec = $false
    foreach ($raw in @(Get-ContentUtf8 -LiteralPath $brain)) {
        $l = [string]$raw
        if ($l -ceq "## Entries") { $insec = $true }
        elseif ($insec -and $l.StartsWith("## ")) { $insec = $false }
        if ($insec -and $l.StartsWith("|")) {
            $c = @(Split-TableCells $l)
            if ($c.Count -eq 9 -and $want.ContainsKey($c[0])) {
                $c[7] = [string]([decimal]$c[7] + 1)
                $c[8] = $Day
                $out.Add("| " + ($c -join " | ") + " |")
                continue
            }
        }
        $out.Add($l)
    }
    Write-Utf8File $brain (ConvertTo-JoinedLines ([string[]]$out.ToArray()))
}

# rotate in Factory mode. When the brain has more rows than Brain max entries, archives the
# least used rows (fewest hits, then oldest last use, then lowest id; never a DEFAULT with the
# trigger *) to docs/history until 75 percent of the maximum is left. Returns $true and prints a
# line when it archived rows.
function Invoke-BrainGc {
    $script:BrainGcDone = $false
    if (-not (Test-FactoryOn)) { return }
    if (-not (Test-Path -LiteralPath (Join-Path $DocsDir "Brain.md") -PathType Leaf)) { return }
    Enter-DocsLock
    try { Invoke-BrainGcLocked } finally { Exit-DocsLock }
}
function Invoke-BrainGcLocked {
    $brain = Join-Path $DocsDir "Brain.md"
    $max = [int](Get-FactoryNumber "Brain max entries")
    $rows = @(Get-BrainRows)
    if ($rows.Count -le $max) { return }
    $target = [int][Math]::Floor($max * 75 / 100)
    $drop = $rows.Count - $target
    $cands = [System.Collections.Generic.List[object]]::new()
    foreach ($r in $rows) {
        if ($r.Cells[2] -ceq "DEFAULT" -and $r.Cells[3] -ceq "*") { continue }
        $day = $r.Cells[8]
        if ($day -eq $EmDash) { $day = "0000-00-00" }
        $hits = [decimal]0
        if ($r.Cells[7] -match '^[0-9]+$') { $hits = [decimal]$r.Cells[7] }
        $cands.Add([PSCustomObject]@{ Hits = $hits; Day = $day; Id = $r.Cells[0]; Line = $r.Line })
    }
    $ordered = [System.Collections.Generic.List[object]]::new()
    foreach ($item in $cands) {
        $pos = $ordered.Count
        for ($i = 0; $i -lt $ordered.Count; $i++) {
            $o = $ordered[$i]
            $cmpDay = [string]::CompareOrdinal($item.Day, $o.Day)
            $before = ($item.Hits -lt $o.Hits) -or ($item.Hits -eq $o.Hits -and ($cmpDay -lt 0 -or ($cmpDay -eq 0 -and [string]::CompareOrdinal($item.Id, $o.Id) -lt 0)))
            if ($before) { $pos = $i; break }
        }
        $ordered.Insert($pos, $item)
    }
    $take = [Math]::Min($drop, $ordered.Count)
    if ($take -le 0) { return }
    $moved = @{}
    for ($i = 0; $i -lt $take; $i++) { $moved[$ordered[$i].Id] = $ordered[$i].Line }
    $stamp = [DateTime]::UtcNow.ToString("yyyyMMdd")
    $today = [DateTime]::UtcNow.ToString("yyyy-MM-dd")
    New-Item -ItemType Directory -Path $HistoryDir -Force | Out-Null
    $seq = 1
    do {
        $aname = "brain-archive-$stamp-{0:D3}.md" -f $seq
        $archive = Join-Path $HistoryDir $aname
        $seq++
    } while (Test-Path -LiteralPath $archive)
    $body = [System.Collections.Generic.List[string]]::new()
    $body.Add("# Brain archive $today")
    $body.Add("")
    $body.Add("Rows archived from docs/Brain.md by rotate on $today. Their ids are never reused.")
    $body.Add("")
    $body.Add("| ID | Name | Kind | Trigger | Lesson | Evidence | Status | Hits | Last used |")
    $body.Add("|---|---|---|---|---|---|---|---|---|")
    foreach ($r in $rows) { if ($moved.ContainsKey($r.Cells[0])) { $body.Add($r.Line) } }
    $src = [System.IO.Path]::GetTempFileName()
    Write-Utf8File $src (ConvertTo-JoinedLines ([string[]]$body.ToArray()))
    Copy-Item -LiteralPath $src -Destination $archive
    $h1 = (Get-FileHash -LiteralPath $src -Algorithm SHA256).Hash.ToLowerInvariant()
    $h2 = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
    Remove-Item -LiteralPath $src -Force -ErrorAction SilentlyContinue
    if ($h1 -ne $h2) { throw "brain archive hash verification failed" }
    $left = $rows.Count - $take
    $out = [System.Collections.Generic.List[string]]::new()
    $insec = $false
    foreach ($raw in @(Get-ContentUtf8 -LiteralPath $brain)) {
        $l = [string]$raw
        if ($l -ceq "## Entries") { $insec = $true }
        elseif ($insec -and $l.StartsWith("## ")) { $insec = $false }
        if ($l.StartsWith("- Entries: ")) { $out.Add("- Entries: $left of $max"); continue }
        if ($l.StartsWith("- Last gc: ")) { $out.Add("- Last gc: $today ($take archived to docs/history/$aname, SHA-256 $h2)"); continue }
        if ($insec -and $l.StartsWith("|")) {
            $first = ($l.Substring(1) -split '\|')[0].Trim()
            if ($moved.ContainsKey($first)) { continue }
        }
        $out.Add($l)
    }
    Write-Utf8File $brain (ConvertTo-JoinedLines ([string[]]$out.ToArray()))
    Write-Output "project_docs rotate: brain archived $take entries to $aname"
    $script:BrainGcDone = $true
}

# handoff of a FAST task. The change since the Base sha must stay inside the lane: at most
# Fast lane max files files and Fast lane max lines lines, nothing under Fast lane protected
# paths, and for a BUG row at least one test file. The files the scripts maintain do not
# count. Without git it only warns.
function Assert-FastSize([string]$Task, $State) {
    if (-not $State.Base -or -not (Test-GitReady)) {
        [Console]::Error.WriteLine("WARN: git is not available here, so the size of the change cannot be checked; the reviewer must write 'fast lane ok' in the review note")
        return
    }
    $c = Invoke-GitProbe @("cat-file", "-e", "$($State.Base)^{commit}")
    if ($c.Code -ne 0) { throw "handoff failed: the Base sha $($State.Base) is not in this repository" }
    $spec = @(".", ":(exclude)docs/Agentslog.md", ":(exclude)docs/Roadmap.md", ":(exclude)docs/Features.md", ":(exclude)docs/Brain.md", ":(exclude)docs/brain", ":(exclude)docs/history", ":(exclude)docs/specs", ":(exclude)docs/.lock")
    $names = [System.Collections.Generic.List[string]]::new()
    $d = Invoke-GitProbe (@("-c", "core.quotepath=false", "diff", "--no-renames", "--relative", "--name-only", $State.Base, "--") + $spec)
    if ($d.Code -ne 0) { throw "handoff failed: git could not compare the change with the Base sha $($State.Base)" }
    foreach ($l in @($d.Out -split "`n")) { if ($l.Trim()) { $names.Add($l.Trim()) } }
    $u = Invoke-GitProbe (@("-c", "core.quotepath=false", "ls-files", "--others", "--exclude-standard", "--") + $spec)
    if ($u.Code -ne 0) { throw "handoff failed: git could not list the new files" }
    $untracked = @($u.Out -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    foreach ($l in $untracked) { if (-not $names.Contains($l)) { $names.Add($l) } }
    $sortedNames = $names.ToArray()
    [System.Array]::Sort($sortedNames, [System.StringComparer]::Ordinal)
    $files = $sortedNames.Count
    $lines = [decimal]0
    $ns = Invoke-GitProbe (@("diff", "--no-renames", "--relative", "--numstat", $State.Base, "--") + $spec)
    if ($ns.Code -ne 0) { throw "handoff failed: git could not count the lines changed since the Base sha $($State.Base)" }
    foreach ($l in @($ns.Out -split "`n")) {
        $f = $l.Split([char]9)
        if ($f.Count -ge 2 -and $f[0] -match '^[0-9]+$') { $lines += [decimal]$f[0] + [decimal]$f[1] }
    }
    foreach ($l in $untracked) {
        $p = Join-Path $Project $l
        # Windows PowerShell 5.1 rejects a path past 260 characters unless it has the \\?\ prefix
        $p = [System.IO.Path]::GetFullPath($p)
        if ($p.Length -ge 240 -and -not $p.StartsWith("\\")) { $p = "\\?\" + $p }
        if (-not [System.IO.File]::Exists($p)) { throw "handoff failed: the new file $l cannot be read, so its lines cannot be counted" }
        if ($true) {
            $text = [System.IO.File]::ReadAllText($p, $Utf8)
            if ($text.Length -gt 0) {
                $n = ($text.Split([char]10)).Count
                if ($text.EndsWith("`n")) { $n-- }
                $lines += $n
            }
        }
    }
    $maxFiles = [int](Get-FactoryNumber "Fast lane max files")
    $maxLines = [int](Get-FactoryNumber "Fast lane max lines")
    $hint = "save the work in the branch wip/$Task, take Lane: FAST out of its row, go back to $($State.Base) and move the task to SPEC with advance"
    if ($files -gt $maxFiles) { throw "handoff failed: task outgrew FAST lane ($files files, the limit is $maxFiles); $hint" }
    if ($lines -gt $maxLines) { throw "handoff failed: task outgrew FAST lane ($lines lines, the limit is $maxLines); $hint" }
    foreach ($p in @((Get-FactorySetting "Fast lane protected paths") -split ' ' | Where-Object { $_ })) {
        foreach ($n in $sortedNames) {
            if (("/" + $n).Contains("/" + $p)) { throw "handoff failed: task outgrew FAST lane (it touches the protected path $n); $hint" }
        }
    }
    if ($Task -cmatch '^F[0-9][0-9]-BUG-[0-9][0-9]') {
        $tests = 0
        foreach ($n in $sortedNames) {
            $s = "/" + $n
            if ($s.Contains(".spec.") -or $s.Contains(".test.") -or $s.Contains("/test/") -or $s.Contains("/tests/") -or $s.Contains("/e2e/")) { $tests++ }
        }
        if ($tests -eq 0) { throw "handoff failed: task outgrew FAST lane (a BUG needs a test file in the change); $hint" }
    }
}

# Review PASS of a FAST handoff whose size git could not check needs the words "fast lane ok".
function Assert-FastNote([string]$Task, $State, [string]$Note) {
    if ($State.Lane -cne "FAST") { return }
    if ($State.Base -and (Test-GitReady)) { return }
    if (-not $Note.ToLowerInvariant().Contains("fast lane ok")) {
        throw "review failed: git could not check the size of the change of $Task; the note must say 'fast lane ok'"
    }
}

# next <project> <agent>: the id of the task this agent should work on now, or none. Order: a
# task it already holds, a task assigned to it, a review waiting for it, a task paused by a
# quota limit that its role can resume, a task assigned to anyone in a phase of its role, and
# the first eligible TODO row of the Roadmap (Active work, Near term, Plan, Gaps).
function Invoke-Next {
    Assert-FactoryMode "next"
    if ($Arguments.Count -lt 1) { throw "next requires: agent" }
    $agent = Get-CanonicalAgent (ConvertTo-CleanField $Arguments[0])
    if (-not (Test-Path -LiteralPath (Join-Path $DocsDir "Agentslog.md") -PathType Leaf)) { throw "run init first" }
    $rawRole = Get-RosterRole $agent
    if (-not $rawRole) { throw "next failed: $agent is not in the Agent identity table; Factory mode needs a role for each agent" }
    $role = Get-RoleNorm $rawRole
    $maxAtt = [int](Get-FactoryNumber "Max fix attempts")
    $indep = Test-FactoryYes "Independent review"
    $states = @(Get-TaskStates)
    $best = ""
    $bestP = 99
    foreach ($s in $states) {
        $ph = $s.Phase
        $need = ""
        switch -CaseSensitive ($ph) {
            "" { $need = "SPEC" }
            "SPEC" { $need = "SPEC" }
            "RED" { $need = "TEST" }
            "GREEN" { $need = "DEV" }
            "REVIEW" { $need = "QA" }
        }
        $canWork = ($need -and ($role -ceq "BOTH" -or $role -ceq $need))
        $canReview = ($role -ceq "QA" -or $role -ceq "BOTH" -or (($ph -ceq "" -or $ph -ceq "SPEC") -and $role -ceq "SPEC"))
        $p = 99
        if ($s.Status -eq "IN_PROGRESS" -and $s.Agent -ceq $agent) { $p = 0 }
        elseif ($s.Status -eq "REVIEW" -and $s.Review -and $s.Holder -ceq $agent) { $p = 0 }
        elseif ($s.Status -eq "ASSIGNED" -and $s.Holder -ceq $agent -and $canWork -and $s.Attempts -lt $maxAtt) { $p = 1 }
        elseif ($s.Status -eq "REVIEW" -and -not $s.Review -and $canReview -and (-not $indep -or $s.Holder -cne $agent) -and ($s.Handoff -ceq $agent -or -not $s.Handoff -or $s.Handoff.ToUpperInvariant() -ceq $role -or ($role -ceq "BOTH" -and $s.Handoff.ToUpperInvariant() -ceq "QA"))) { $p = 2 }
        elseif ($s.Status -eq "PAUSE" -and $s.PauseCat -ceq "LIMITE" -and $canWork -and $s.Attempts -lt $maxAtt) { $p = 3 }
        elseif ($s.Status -eq "ASSIGNED" -and $s.Holder -cne $agent -and $canWork -and $s.Attempts -lt $maxAtt) { $p = 4 }
        if ($p -lt $bestP) { $best = $s.Task; $bestP = $p }
    }
    if ($best) { Write-Output $best; return }
    $known = @{}
    foreach ($s in $states) { $known[$s.Task] = $true }
    $rows = [System.Collections.Generic.List[object]]::new()
    $allIds = @{}
    $rank = 0
    $hdr = $false
    $si = -1; $di = -1; $ei = -1; $ni = -1
    foreach ($line in @(Get-ContentUtf8 -LiteralPath (Join-Path $DocsDir "Roadmap.md"))) {
        if ($line.StartsWith("## ")) {
            $rank = 0
            if ($line.StartsWith("## Active work")) { $rank = 1 }
            elseif ($line.StartsWith("## Near term")) { $rank = 2 }
            elseif ($line.StartsWith("## Plan")) { $rank = 3 }
            elseif ($line.StartsWith("## Gaps")) { $rank = 4 }
            $hdr = $false
            continue
        }
        if (-not $line.StartsWith("|")) { continue }
        $c = @(Split-TableCells $line)
        if ($c.Count -ge 1 -and $c[0] -ceq "ID") {
            $si = -1; $di = -1; $ei = -1; $ni = -1
            for ($i = 0; $i -lt $c.Count; $i++) {
                if ($c[$i] -ceq "Name") { $ni = $i }
                if ($c[$i] -ceq "Status") { $si = $i }
                if ($c[$i] -ceq "Depends on") { $ei = $i }
                if ($c[$i] -ceq "Description") { $di = $i }
            }
            $hdr = $true
            continue
        }
        if ($c.Count -lt 1 -or $c[0] -match '^-+$' -or -not $hdr) { continue }
        $allIds[$c[0]] = $true
        $stub = ($ni -ge 0 -and $ni -lt $c.Count -and $c[$ni] -ceq "UNKNOWN")
        if ($rank -gt 0 -and $c[0] -match '^[A-Za-z0-9]' -and -not $stub) {
            $rows.Add([PSCustomObject]@{
                Id = $c[0]
                Status = $(if ($si -ge 0 -and $si -lt $c.Count) { $c[$si] } else { "" })
                Deps = $(if ($ei -ge 0 -and $ei -lt $c.Count) { $c[$ei] } else { "" })
                Desc = $(if ($di -ge 0 -and $di -lt $c.Count) { $c[$di] } else { "" })
                Rank = $rank
            })
        }
    }
    for ($k = 1; $k -le 4; $k++) {
        foreach ($r in $rows) {
            if ($r.Rank -ne $k -or $r.Status -cne "TODO" -or $known.ContainsKey($r.Id)) { continue }
            $needRole = "SPEC"
            if ($r.Desc.Contains("Lane: FAST")) { $needRole = "DEV" }
            if ($role -cne "BOTH" -and $role -cne $needRole) { continue }
            $ok = $true
            foreach ($d in @($r.Deps -split '[ ,;]+' | Where-Object { $_ })) {
                if ($d -cmatch '^F[0-9][0-9]*-' -and $allIds.ContainsKey($d)) { $ok = $false; break }
            }
            if ($ok) { Write-Output $r.Id; return }
        }
    }
    $pref = Get-FactorySetting "Preferred reviewer"
    if ($pref -and $agent -ceq $pref) {
        foreach ($s in $states) {
            if ($s.Status -eq "DONE" -and $s.Lane -cne "FAST" -and $s.Cross -ceq "NO" -and -not $s.Audited) { Write-Output $s.Task; return }
        }
    }
    Write-Output "none"
}

# The Model cell of a roster id.
function Get-RosterModel([string]$Id) {
    foreach ($r in @(Get-RosterRows)) { if ($r.Id -ceq $Id) { return $r.Model } }
    return ""
}

# digest <project> [since]: what a human has to read, in at most 4 KiB: product guesses and
# decisions still HYPOTHESIS, open red lines, open gaps, new lessons, what closed, and the
# reviews (failures, reviews of one model, audits).
# The first N characters (code points) of a text; a pair of surrogates is never cut in two.
function Get-CutText([string]$Text, [int]$Chars) {
    $count = 0
    for ($i = 0; $i -lt $Text.Length; $i++) {
        if (-not [char]::IsLowSurrogate($Text[$i])) {
            $count++
            if ($count -gt $Chars) { return $Text.Substring(0, $i) }
        }
    }
    return $Text
}

function Invoke-Digest {
    Assert-FactoryMode "digest"
    # A rule or a decision can carry accents or an em dash; the console would turn them into other bytes.
    [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
    $since = ""
    if ($Arguments.Count -ge 1) { $since = ConvertTo-CleanField $Arguments[0] }
    if ($since) {
        $sinceOk = ($since -cmatch '^[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])(T([01][0-9]|2[0-3]):[0-5][0-9](:[0-5][0-9])?Z?)?$')
        if ($sinceOk) {
            $mm = $since.Substring(5, 2); $dd = [int]$since.Substring(8, 2)
            if ($mm -ceq "02" -and $dd -gt 29) { $sinceOk = $false }
            if (@("04", "06", "09", "11") -ccontains $mm -and $dd -gt 30) { $sinceOk = $false }
        }
        if (-not $sinceOk) { throw "digest requires an ISO date like 2026-10-27 or a timestamp like 2026-10-27T14:00:00Z" }
    }
    $log = Join-Path $DocsDir "Agentslog.md"
    if (-not (Test-Path -LiteralPath $log -PathType Leaf)) { throw "run init first" }
    $day = ""
    if ($since) { $day = $since.Substring(0, 10) }
    $states = @(Get-TaskStates)
    $out = [System.Collections.Generic.List[string]]::new()
    $out.Add("digest since $(if ($since) { $since } else { 'the start of the ledger' })")
    $out.Add("## Product guesses")
    $guesses = [System.Collections.Generic.List[string]]::new()
    $pd = Join-Path $DocsDir "ProductDescription.md"
    if (Test-Path -LiteralPath $pd -PathType Leaf) {
        foreach ($l in @(Get-ContentUtf8 -LiteralPath $pd)) {
            if (-not $l.StartsWith("|")) { continue }
            $c = @(Split-TableCells $l)
            if ($c.Count -ge 4 -and $c[0] -cmatch '^BR-[0-9]+$' -and $c[2] -ceq "HYPOTHESIS" -and $c[3].StartsWith("agent:")) {
                $t = Get-CutText $c[1] 80
                $guesses.Add("$($c[0]) | $t | $($c[3])")
            }
        }
    }
    $stack = Join-Path $DocsDir "Stack_Tecnologies.md"
    if (Test-Path -LiteralPath $stack -PathType Leaf) {
        foreach ($l in @(Get-ContentUtf8 -LiteralPath $stack)) {
            if (-not $l.StartsWith("|")) { continue }
            $c = @(Split-TableCells $l)
            if ($c.Count -ge 5 -and $c[0] -cmatch '^ADR-[0-9]+$' -and $c[3] -ceq "HYPOTHESIS" -and (-not $day -or [string]::CompareOrdinal($c[4], $day) -ge 0)) {
                $t = Get-CutText $c[1] 80
                $guesses.Add("$($c[0]) | $t | $($c[4])")
            }
        }
    }
    if ($guesses.Count -gt 0) { foreach ($g in $guesses) { $out.Add($g) } } else { $out.Add("(none)") }
    $out.Add("## Red lines")
    $red = @($states | Where-Object { $_.Status -eq "PAUSE" -and $_.PauseDetail.StartsWith("RED-LINE:", [System.StringComparison]::Ordinal) })
    if ($red.Count -gt 0) { foreach ($r in $red) { $out.Add("$($r.Task) | $($r.Agent) | $($r.PauseDetail)") } } else { $out.Add("(none)") }
    $out.Add("## Open gaps")
    $gaps = [System.Collections.Generic.List[string]]::new()
    $insec = $false; $hdr = $false; $ni = -1; $si = -1
    foreach ($l in @(Get-ContentUtf8 -LiteralPath (Join-Path $DocsDir "Roadmap.md"))) {
        if ($l.StartsWith("## ")) { $insec = $l.StartsWith("## Gaps"); $hdr = $false; continue }
        if (-not ($insec -and $l.StartsWith("|"))) { continue }
        $c = @(Split-TableCells $l)
        if ($c[0] -ceq "ID") {
            $ni = -1; $si = -1
            for ($i = 0; $i -lt $c.Count; $i++) { if ($c[$i] -ceq "Name") { $ni = $i }; if ($c[$i] -ceq "Status") { $si = $i } }
            $hdr = $true; continue
        }
        if (-not $hdr -or $c[0] -match '^-+$') { continue }
        if ($c[0].Contains("-GAP-") -and ($si -lt 0 -or $c[$si] -cne "DONE")) {
            $gn = ""; if ($ni -ge 0 -and $ni -lt $c.Count) { $gn = $c[$ni] }
            $gs = ""; if ($si -ge 0 -and $si -lt $c.Count) { $gs = $c[$si] }
            $gaps.Add("$($c[0]) | $gn | $gs")
        }
    }
    if ($gaps.Count -gt 0) { foreach ($g in $gaps) { $out.Add($g) } } else { $out.Add("(none)") }
    $out.Add("## New lessons")
    $lessons = @()
    if (Test-Path -LiteralPath (Join-Path $DocsDir "Brain.md") -PathType Leaf) { $lessons = @(Get-BrainRows | Where-Object { $_.Cells[6] -ceq "HYPOTHESIS" }) }
    if ($lessons.Count -gt 0) { foreach ($r in $lessons) { $out.Add("$($r.Cells[0]) | $($r.Cells[1]) | $($r.Cells[5])") } } else { $out.Add("(none)") }
    $out.Add("## Closed")
    $normal = 0; $fast = 0
    foreach ($s in $states) {
        if ($s.Status -eq "DONE" -and (-not $since -or [string]::CompareOrdinal($s.Ts, $since) -ge 0)) {
            if ($s.Lane -ceq "FAST") { $fast++ } else { $normal++ }
        }
    }
    $out.Add("NORMAL: $normal, FAST: $fast")
    $out.Add("## Reviews")
    $failed = 0; $on = $false
    foreach ($l in @(Get-ContentUtf8 -LiteralPath $log)) {
        if ($l.StartsWith("## [")) { $ts = $l.Substring(4, [Math]::Min(20, $l.Length - 4)); $on = (-not $since -or [string]::CompareOrdinal($ts, $since) -ge 0); continue }
        if ($on -and $l.StartsWith("- Review: FAIL")) { $failed++ }
    }
    $same = 0; $audited = 0
    foreach ($s in $states) {
        if ($s.Status -eq "DONE" -and $s.Lane -cne "FAST" -and $s.Cross -ceq "NO" -and (-not $since -or [string]::CompareOrdinal($s.Ts, $since) -ge 0)) { $same++; if ($s.Audited) { $audited++ } }
    }
    $out.Add("Failed reviews: $failed; NORMAL tasks closed with the same model reviewing: $same; audited by the preferred reviewer: $audited")
    $max = 4096
    # one very long line (a red line detail) must not push the sections after it out
    for ($i = 0; $i -lt $out.Count; $i++) {
        if ($Utf8.GetByteCount($out[$i]) -gt 800) { $out[$i] = (Get-CutText $out[$i] 197) + "..." }
    }
    $total = 0
    foreach ($l in $out) { $total += $Utf8.GetByteCount($l) + 1 }
    if ($total -le $max) { foreach ($l in $out) { Write-Output $l }; return }
    $bytes = 0; $k = 0
    for ($i = 0; $i -lt $out.Count; $i++) {
        $foot = "digest: truncated, $($out.Count - ($i + 1)) more lines, read the ledger and the Roadmap"
        if (($bytes + $Utf8.GetByteCount($out[$i]) + 1 + $Utf8.GetByteCount($foot) + 1) -gt $max) { break }
        $bytes += $Utf8.GetByteCount($out[$i]) + 1
        $k = $i + 1
    }
    for ($i = 0; $i -lt $k; $i++) { Write-Output $out[$i] }
    Write-Output "digest: truncated, $($out.Count - $k) more lines, read the ledger and the Roadmap"
}

# Commands that exist only in Factory mode refuse to run in classic mode.
function Assert-FactoryMode([string]$CommandName) {
    if (-not (Test-FactoryOn)) { throw "$CommandName needs Factory mode (see references/factory.md)" }
}

# The working memory of a task: docs/brain/tasks/<TASK-ID>.md (F06-E03-T02).
function Get-WorkingMemoryPath([string]$Task) {
    return (Join-Path (Join-Path (Join-Path $DocsDir "brain") "tasks") "$Task.md")
}

# True when the task has a working memory with a ## Now.
function Test-WorkingNow([string]$Task) {
    $f = Get-WorkingMemoryPath $Task
    if (-not (Test-Path -LiteralPath $f -PathType Leaf)) { return $false }
    foreach ($l in @(Get-ContentUtf8 -LiteralPath $f)) { if ($l -ceq "## Now") { return $true } }
    return $false
}

# How many times the task was sent back (Review: FAIL lines).
function Get-TaskAttempts([string]$Task) {
    $st = Get-TaskState $Task
    if (-not $st) { return 0 }
    return [int]$st.Attempts
}

# checkpoint <project> <agent> <task-id> <step> <next>: creates or updates the
# working memory of a task: rewrites ## Now and adds a line to ## Trail.
function Invoke-Checkpoint {
    Assert-FactoryMode "checkpoint"
    if ($Arguments.Count -lt 4) { throw "checkpoint requires: agent task-id step next" }
    $agent = Get-CanonicalAgent (ConvertTo-CleanField $Arguments[0])
    $task = ConvertTo-CleanField $Arguments[1]
    $step = ConvertTo-CleanField $Arguments[2]
    $nxt = ConvertTo-CleanField $Arguments[3]
    if (-not $step) { throw "checkpoint requires a non-empty step" }
    if (-not $nxt) { throw "checkpoint requires a non-empty next" }
    $log = Join-Path $DocsDir "Agentslog.md"
    if (-not (Test-Path -LiteralPath $log -PathType Leaf)) { throw "run init first" }
    if (-not (Test-RoadmapHasId $task)) { throw "checkpoint failed: $task not found in docs/Roadmap.md" }
    Enter-DocsLock
    try {
        $wm = Get-WorkingMemoryPath $task
        New-Item -ItemType Directory -Path (Split-Path -Parent $wm) -Force | Out-Null
        if (-not (Test-Path -LiteralPath $wm -PathType Leaf)) {
            $tpl = Join-Path $TemplatesDir "WorkingMemory.md"
            if (-not (Test-Path -LiteralPath $tpl -PathType Leaf)) { throw "template missing: WorkingMemory.md" }
            $fresh = [System.Collections.Generic.List[string]]::new()
            foreach ($l in @(Get-ContentUtf8 -LiteralPath $tpl)) {
                $i = $l.IndexOf("{TASK}")
                if ($i -ge 0) { $fresh.Add($l.Substring(0, $i) + $task + $l.Substring($i + 6)) } else { $fresh.Add($l) }
            }
            Write-Utf8File $wm (ConvertTo-JoinedLines ([string[]]$fresh.ToArray()))
        }
        $timestamp = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
        $attempts = Get-TaskAttempts $task
        $lines = @(Get-ContentUtf8 -LiteralPath $wm)
        $out = [System.Collections.Generic.List[string]]::new()
        $innow = $false; $intrail = $false; $added = $false; $hasNow = $false; $hasTrail = $false
        $held = 0
        $newTrail = "- $timestamp ${agent}: $step"
        for ($i = 0; $i -le $lines.Count; $i++) {
            $atEnd = ($i -eq $lines.Count)
            $line = ""
            if (-not $atEnd) { $line = [string]$lines[$i] }
            if ($atEnd -or $line.StartsWith("## ")) {
                if ($intrail -and -not $added) {
                    $out.Add($newTrail)
                    $added = $true
                    for ($b = 0; $b -lt $held; $b++) { $out.Add("") }
                    $held = 0
                }
                if ($atEnd) { break }
                $innow = $false
                $intrail = $false
                if ($line -ceq "## Now") {
                    $hasNow = $true
                    $innow = $true
                    $out.Add($line)
                    $out.Add("- Step: $step")
                    $out.Add("- Next: $nxt")
                    $out.Add("- Attempts: $attempts")
                    $out.Add("- Updated: $timestamp")
                    $out.Add("")
                    continue
                }
                if ($line -ceq "## Trail") { $intrail = $true; $hasTrail = $true }
                $out.Add($line)
                continue
            }
            if ($innow) { continue }
            if ($intrail) {
                if ($line -eq "") { $held++; continue }
                for ($b = 0; $b -lt $held; $b++) { $out.Add("") }
                $held = 0
                $out.Add($line)
                continue
            }
            $out.Add($line)
        }
        if (-not $hasNow -or -not $hasTrail) {
            throw "checkpoint failed: docs/brain/tasks/$task.md is not a working memory file (needs ## Now and ## Trail)"
        }
        Write-Utf8File $wm (ConvertTo-JoinedLines ([string[]]$out.ToArray()))
        Write-Output "project_docs checkpoint: $task saved"
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
        if ((Test-FactoryOn) -and $state.Status -eq "REVIEW") {
            if ($state.Holder -cne $agent) { throw "pause failed: $task is held by $($state.Holder), not $agent" }
        } else {
            if ($state.Status -ne "IN_PROGRESS") { throw "pause failed: $task is not IN_PROGRESS (current: $($state.Status))" }
            if ($state.Agent -cne $agent) { throw "pause failed: $task is owned by $($state.Agent), not $agent" }
        }
        if ((Test-FactoryOn) -and -not (Test-WorkingNow $task)) {
            throw "pause failed: $task has no working memory yet (## Now); run checkpoint first"
        }
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
        if (Test-FactoryOn) {
            $handoffPhase = "SPEC"
            if ($state.Phase) { $handoffPhase = $state.Phase }
            if ($handoffPhase -cne "SPEC" -and $handoffPhase -cne "GREEN") { throw "handoff failed: $task is in phase $handoffPhase; move it with advance" }
            Assert-ExitZero "handoff" $verify
            if (-not (Test-WorkingNow $task)) { throw "handoff failed: $task has no working memory yet (## Now); run checkpoint first" }
            if ($state.Lane -ceq "FAST") { Assert-FastSize $task $state }
            if ($handoffPhase -ceq "GREEN") { Assert-TestsUnchanged $task $state }
        }
        if ((Test-FactoryOn) -and -not $reviewer) {
            if ($state.Lane -ceq "FAST") { $reviewer = Get-FactorySetting "Fallback reviewer" } else { $reviewer = Get-FactorySetting "Preferred reviewer" }
            if ($reviewer -ceq $agent) { $reviewer = "" }
        }
        $name = Assert-ValidName $task "handoff"
        $timestamp = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
        $entryLines = @(
            "",
            "## [$timestamp] | $agent | $task | REVIEW | $name",
            "- Summary: $summary",
            "- Verify: $verify"
        )
        if ($reviewer) { $entryLines += "- Handoff: $reviewer" }
        $specFile = Join-Path (Join-Path $DocsDir "specs") "$task.md"
        if ((Test-FactoryOn) -and $handoffPhase -ceq "SPEC" -and (Test-Path -LiteralPath $specFile -PathType Leaf)) {
            $entryLines += "- Spec-sha: $((Get-FileHash -LiteralPath $specFile -Algorithm SHA256).Hash.ToLowerInvariant())"
        }
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
        if (Test-FactoryOn) {
            $reviewPhase = "SPEC"
            if ($state.Phase) { $reviewPhase = $state.Phase }
            if ($agent -ceq $state.Holder -and (Test-FactoryYes "Independent review")) {
                throw "review failed: $agent developed $task; an independent review is required"
            }
            $reviewRole = Get-RosterRole $agent
            if (-not $reviewRole) { throw "review failed: $agent is not in the Agent identity table; Factory mode needs a role for each agent" }
            $reviewNorm = Get-RoleNorm $reviewRole
            if ($reviewNorm -cne "QA" -and $reviewNorm -cne "BOTH" -and ($reviewPhase -cne "SPEC" -or $reviewNorm -cne "SPEC")) {
                throw "review failed: $agent has role $reviewRole, but a review of phase $reviewPhase needs QA (or BOTH)"
            }
            if ($result -ceq "PASS") {
                Assert-ExitZero "review" $verify
                Assert-TestsNote $task $state $note
                Assert-FastNote $task $state $note
            }
        }
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
        if (Test-FactoryOn) {
            $holderWord = ((Get-RosterModel $state.Holder) -split '\s+' | Where-Object { $_ } | Select-Object -First 1)
            $agentWord = ((Get-RosterModel $agent) -split '\s+' | Where-Object { $_ } | Select-Object -First 1)
            if ("$holderWord".ToLowerInvariant() -ceq "$agentWord".ToLowerInvariant()) { $entryLines += "- Cross-model: NO" }
        }
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
# Runs git quietly in the project: Code is the exit code, Out the standard output.
function Invoke-GitProbe([string[]]$GitArgs) {
    $old = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $out = & git -C $Project @GitArgs 2>$null
        return [PSCustomObject]@{ Code = $LASTEXITCODE; Out = (@($out) -join "`n") }
    } finally {
        $ErrorActionPreference = $old
    }
}

# True when git is installed and the project is inside a work tree.
function Test-GitReady {
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) { return $false }
    $r = Invoke-GitProbe @("rev-parse", "--is-inside-work-tree")
    return ($r.Code -eq 0 -and $r.Out.Trim() -ceq "true")
}

# The number after the first exit= marker of a verify string, or "".
function Get-VerifyExit([string]$Text) {
    if ($Text -cmatch '(?<![A-Za-z0-9_])exit=([0-9]+)(?![A-Za-z0-9_])') { return $Matches[1] }
    return ""
}

# True when the digits spell zero (leading zeros ignored).
function Test-ExitIsZero([string]$Digits) {
    return (-not $Digits.TrimStart('0'))
}

# True unless the setting says NO (any case).
function Test-FactoryYes([string]$Name) {
    return ((Get-FactorySetting $Name).ToUpperInvariant() -ne "NO")
}

# How many lines of a spec still say UNKNOWN.
function Get-SpecUnknownCount([string]$Path) {
    $n = 0
    foreach ($l in @(Get-ContentUtf8 -LiteralPath $Path)) { if ($l.Contains("UNKNOWN")) { $n++ } }
    return $n
}

# The test paths of the ## Tests section of a spec.
function Get-SpecTests([string]$Path) {
    $out = [System.Collections.Generic.List[string]]::new()
    $sec = ""
    foreach ($l in @(Get-ContentUtf8 -LiteralPath $Path)) {
        if ($l.StartsWith("## ")) { $sec = $l; continue }
        if ($sec -ceq "## Tests" -and $l.StartsWith("- ")) {
            $p = $l.Substring(2)
            $i = $p.IndexOf(' ')
            if ($i -ge 0) { $p = $p.Substring(0, $i) }
            $out.Add($p)
        }
    }
    return $out.ToArray()
}

# The first roster id whose role is the one of the phase, else the first BOTH.
function Get-DefaultAssignee([string]$Phase) {
    $need = Get-PhaseRole $Phase
    $exact = ""
    $both = ""
    foreach ($r in @(Get-RosterRows)) {
        $role = Get-RoleNorm $r.Role
        if (-not $exact -and $role -ceq $need) { $exact = $r.Id }
        if (-not $both -and $role -ceq "BOTH") { $both = $r.Id }
    }
    if ($exact) { return $exact }
    return $both
}

# Gate SPEC to RED: a valid spec without UNKNOWN and a review PASS from another agent.
function Assert-AdvanceGateSpec([string]$Task, [string]$Agent, $State) {
    $spec = Join-Path (Join-Path $DocsDir "specs") "$Task.md"
    if (-not (Test-Path -LiteralPath $spec -PathType Leaf)) { throw "advance failed: docs/specs/$Task.md does not exist (the SPEC phase produces it)" }
    $errs = @(Get-SpecReport $spec | Where-Object { $_.StartsWith("ERROR:") })
    if ($errs.Count -gt 0) {
        foreach ($e in $errs) { [Console]::Error.WriteLine($e) }
        throw "advance failed: docs/specs/$Task.md has errors (see above)"
    }
    $unk = Get-SpecUnknownCount $spec
    if ($unk -ne 0) { throw "advance failed: docs/specs/$Task.md still has $unk UNKNOWN field(s)" }
    if (Test-FactoryYes "Independent review") {
        $by = $State.SpecPass
        if (-not $by) { throw "advance failed: the spec of $Task has no Review: PASS yet (hand it off to a reviewer first)" }
        if ($by -ceq $Agent) { throw "advance failed: the Review: PASS of the spec of $Task comes from $Agent itself; another agent must review it" }
        $rec = Get-SpecSha $Task
        if ($rec) {
            $now = (Get-FileHash -LiteralPath $spec -Algorithm SHA256).Hash.ToLowerInvariant()
            if ($rec -cne $now) {
                throw "advance failed: docs/specs/$Task.md changed after it was handed off for review (the review saw $($rec.Substring(0, [Math]::Min(8, $rec.Length))), the file is $($now.Substring(0, 8)) now); hand it off for review again"
            }
        }
    }
}

# The SHA-256 of the spec that the last handoff of the task recorded, or "".
function Get-SpecSha([string]$Task) {
    $sha = ""
    $cur = $false
    foreach ($l in @(Get-ContentUtf8 -LiteralPath (Join-Path $DocsDir "Agentslog.md"))) {
        if ($l.StartsWith("## [")) {
            $h = $l -split ' \| '
            $cur = ($h.Count -ge 3 -and $h[2] -ceq $Task)
            continue
        }
        if ($cur -and $l.StartsWith("- Spec-sha: ")) { $sha = $l.Substring(12).Trim() }
    }
    return $sha
}

# Gate RED to GREEN: failing tests (exit not 0), listed in the spec, existing and
# committed. Leaves $script:AdvRedSha and $script:AdvTests for the ledger entry.
function Assert-AdvanceGateRed([string]$Task, [string]$Verify) {
    $n = Get-VerifyExit $Verify
    if (-not $n) { throw "advance failed: the verify of RED needs exit=N with N not 0 (the tests must fail first)" }
    if (Test-ExitIsZero $n) { throw "advance failed: RED needs failing tests, but the verify says exit=0" }
    $spec = Join-Path (Join-Path $DocsDir "specs") "$Task.md"
    if (-not (Test-Path -LiteralPath $spec -PathType Leaf)) { throw "advance failed: docs/specs/$Task.md does not exist" }
    $tests = @(Get-SpecTests $spec)
    if ($tests.Count -eq 0) { throw "advance failed: docs/specs/$Task.md ## Tests lists no test file" }
    $script:AdvRedSha = ""
    $git = Test-GitReady
    foreach ($p in $tests) {
        if (-not $p) { continue }
        if (-not (Test-Path -LiteralPath (Join-Path $Project $p) -PathType Leaf)) { throw "advance failed: test file '$p' does not exist" }
        if ($git) {
            $tracked = Invoke-GitProbe @("ls-files", "--error-unmatch", "--", $p)
            $dirty = Invoke-GitProbe @("status", "--porcelain", "--", $p)
            if ($tracked.Code -ne 0 -or $dirty.Out.Trim()) {
                throw "advance failed: test file '$p' is not committed (commit the failing tests before GREEN)"
            }
        }
    }
    $script:AdvTests = ($tests -join " ")
    if ($git) {
        $head = Invoke-GitProbe @("rev-parse", "HEAD")
        if ($head.Code -ne 0) { throw "advance failed: the repository has no commit yet (commit the failing tests before GREEN)" }
        $script:AdvRedSha = $head.Out.Trim()
    } else {
        [Console]::Error.WriteLine("WARN: git is not available here, so the tests cannot be checked as committed and no Red sha is recorded")
    }
}

# True when RED has nothing to prove failing (D-08, ADR-091): the spec has scenarios, every
# one is Level NONE (each already needs a Justification) and the ## Tests section lists no
# file. A BUG row never qualifies (ADR-030): its RED is a test.
function Test-AdvanceUntestable([string]$Task) {
    if ($Task -cmatch '^F[0-9][0-9]-BUG-[0-9][0-9]') { return $false }
    $spec = Join-Path (Join-Path $DocsDir "specs") "$Task.md"
    if (-not (Test-Path -LiteralPath $spec -PathType Leaf)) { return $false }
    $sec = ""
    $rows = 0
    $other = 0
    $tests = 0
    foreach ($l in @(Get-ContentUtf8 -LiteralPath $spec)) {
        if ($l.StartsWith("## ")) { $sec = $l; continue }
        if ($sec -ceq "## Scenarios" -and $l.StartsWith("|")) {
            $line = $l.Substring(1) -replace '\|[ \t]*$', ''
            $c = @($line.Split('|') | ForEach-Object { $_.Trim([char[]]@(' ', "`t")) })
            if ($c[0] -ceq "ID" -or $c[0] -cmatch '^-+$') { continue }
            $rows++
            if ($c.Count -lt 5 -or $c[4] -cne "NONE") { $other++ }
            continue
        }
        if ($sec -ceq "## Tests" -and $l.StartsWith("- ")) { $tests++ }
    }
    return ($rows -gt 0 -and $other -eq 0 -and $tests -eq 0)
}

# advance <project> <agent> <task-id> <next-phase> <verify> [to-agent]: moves the
# task to its next phase, checking the gate of the phase it leaves, and assigns it.
function Invoke-Advance {
    Assert-FactoryMode "advance"
    if ($Arguments.Count -lt 4) { throw "advance requires: agent task-id next-phase verify [to-agent]" }
    $agent = Get-CanonicalAgent (ConvertTo-CleanField $Arguments[0])
    $task = ConvertTo-CleanField $Arguments[1]
    $nextPhase = ConvertTo-CleanField $Arguments[2]
    $verify = ConvertTo-CleanField $Arguments[3]
    $toArg = ""
    if ($Arguments.Count -ge 5) { $toArg = Get-CanonicalAgent (ConvertTo-CleanField $Arguments[4]) }
    $log = Join-Path $DocsDir "Agentslog.md"
    if (-not (Test-Path -LiteralPath $log -PathType Leaf)) { throw "run init first" }
    if (-not $verify) { throw "advance requires a non-empty verify" }
    if (-not (Test-RoadmapHasId $task)) { throw "advance failed: $task not found in docs/Roadmap.md" }
    Enter-DocsLock
    try {
        $state = Get-TaskState $task
        if (-not $state) { throw "advance failed: $task has no IN_PROGRESS entry to advance" }
        if ($state.Status -ne "IN_PROGRESS") { throw "advance failed: $task is not IN_PROGRESS (current: $($state.Status))" }
        if ($state.Agent -cne $agent) { throw "advance failed: $task is owned by $($state.Agent), not $agent" }
        $curPhase = "SPEC"
        if ($state.Phase) { $curPhase = $state.Phase }
        $allowed = $false
        switch -CaseSensitive ("$($curPhase):$nextPhase") {
            { $_ -cin @("SPEC:RED", "RED:GREEN", "RED:SPEC", "GREEN:SPEC", "GREEN:RED") } { $allowed = $true }
            "SPEC:GREEN" { if (-not (Test-FactoryYes "Require TDD")) { $allowed = $true } }
        }
        if (-not $allowed) {
            throw "advance failed: $task cannot move from $curPhase to $nextPhase (allowed: SPEC to RED, RED to GREEN, back to SPEC or RED; GREEN to REVIEW is handoff)"
        }
        if (-not (Test-WorkingNow $task)) { throw "advance failed: $task has no working memory yet (## Now); run checkpoint first" }
        if ($state.Lane -ceq "FAST" -and $nextPhase -cne "SPEC") {
            throw "advance failed: $task is a FAST task; it only goes back to SPEC, when it outgrew the lane"
        }
        if ($toArg) {
            $toAgent = $toArg
            Assert-PhaseRole $toAgent $nextPhase $task "advance"
        } else {
            $toAgent = Get-DefaultAssignee $nextPhase
            if (-not $toAgent) { throw "advance failed: no agent in the Agent identity table has the role $(Get-PhaseRole $nextPhase) for phase $nextPhase; pass to-agent" }
        }
        $script:AdvRedSha = ""
        $script:AdvTests = ""
        if ($curPhase -ceq "SPEC") {
            Assert-AdvanceGateSpec $task $agent $state
        } elseif ("$($curPhase):$nextPhase" -ceq "RED:GREEN" -and (Test-FactoryYes "Require TDD")) {
            # a spec of Level NONE only has no test to fail: no Red sha and no test paths are recorded
            if (-not (Test-AdvanceUntestable $task)) { Assert-AdvanceGateRed $task $verify }
        }
        $name = Assert-ValidName $task "advance"
        $timestamp = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
        $lines = @(
            "",
            "## [$timestamp] | $agent | $task | ASSIGNED | $name",
            "- Summary: Moved to $nextPhase, assigned to $toAgent",
            "- Phase: $nextPhase",
            "- Assign: $toAgent",
            "- Verify: $verify"
        )
        if ($script:AdvRedSha) { $lines += "- Red: $($script:AdvRedSha)" }
        if ($script:AdvTests) { $lines += "- Tests: $($script:AdvTests)" }
        [System.IO.File]::AppendAllText($log, (($lines -join "`n") + "`n"), $Utf8)
        Set-RoadmapRowInPlace $task "IN_PROGRESS" "$toAgent@$timestamp" $EmDash
        Write-Output "project_docs advance: $task moved to $nextPhase, assigned to $toAgent"
    } finally {
        Exit-DocsLock
    }
}

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
    if (Test-FactoryOn) { Assert-ExitZero "done" $verify }
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
            if ((Test-FactoryOn) -and ($state.Status -ne "REVIEW" -or $state.Review -cne "PASS")) {
                $lastReview = "none"
                if ($state.Review) { $lastReview = $state.Review }
                throw "done failed: $task has no Review: PASS yet (status $($state.Status), last review $lastReview)"
            }
            if ($state.Status -eq "REVIEW" -and $state.Review -cne "PASS") {
                if ($state.Review -ceq "FAIL") {
                    [Console]::Error.WriteLine("WARN: ${task}: closing without a passing review (the last review was FAIL)")
                } else {
                    [Console]::Error.WriteLine("WARN: ${task}: closing without a passing review (the handoff is still pending)")
                }
            }
        }
        if ((Test-FactoryOn) -and -not $state) { throw "done failed: $task has no ledger entries; claim it first" }
        # BR-009: a task of the normal lane closes from GREEN, which only advance reaches, after a
        # reviewed spec and failing tests. A task with no phase at all was claimed before the project
        # moved to Factory mode and is not held to it; the fast lane starts in GREEN.
        if ((Test-FactoryOn) -and $state.Phase -and $state.Phase -cne "GREEN" -and $state.Lane -cne "FAST") {
            throw "done failed: $task is in phase $($state.Phase); a task of the normal lane closes from GREEN, after a reviewed spec and failing tests (advance moves it)"
        }
        $vlow = $verify.Trim().ToLowerInvariant()
        if ($vlow -in @("none", "n/a", "no run", "ninguno", [string]$EmDash, "unknown")) {
            [Console]::Error.WriteLine("WARN: verify `"$verify`" says nothing about what was checked")
        }
        $script:DoneUsed = ""
        $script:DoneLearned = ""
        $script:DoneCross = ""
        if (Test-FactoryOn) {
            Read-TaskRetro $task
            if ($state) { $script:DoneCross = $state.Cross }
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
        $doneLines = @(
            "",
            "## [$timestamp] | $agent | $task | DONE | $name",
            "- Summary: $summary",
            "- Files: $files",
            "- Verify: $verify"
        )
        if (Test-FactoryOn) { $doneLines += "- Brain: used $($script:DoneUsed); learned $($script:DoneLearned)" }
        if ((Test-FactoryOn) -and $script:DoneCross -ceq "NO") { $doneLines += "- Cross-model: NO" }
        $entry = ($doneLines -join "`n") + "`n"
        [System.IO.File]::AppendAllText($log, $entry, $Utf8)
        Remove-RoadmapRow $task
        Add-FeaturesCapability $task $summary $verify $timestamp
        if (Test-FactoryOn) {
            Set-BrainHits $script:DoneUsed $timestamp.Substring(0, 10)
            Remove-Item -LiteralPath (Get-WorkingMemoryPath $task) -Force -ErrorAction SilentlyContinue
        }
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
        if (Test-FactoryOn) {
            $sphase = if ($s.Phase) { $s.Phase } else { "SPEC" }
            if ($s.Status -eq "REVIEW") { $sphase = "REVIEW" }
            $slane = if ($s.Lane) { $s.Lane } else { "NORMAL" }
            Write-Output "$($s.Task) | $($s.Name) | $shown | $(Get-StageLabel $s.Status $s.Review $s.Handoff) | ${hrsStr}h$stale | $reason | $sphase $slane"
        } else {
            Write-Output "$($s.Task) | $($s.Name) | $shown | $(Get-StageLabel $s.Status $s.Review $s.Handoff) | ${hrsStr}h$stale | $reason"
        }
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
        if ($e.Status -notin @("IN_PROGRESS", "PAUSE", "DONE", "REVIEW", "ASSIGNED") -and -not ($e.Status -ceq "AUDIT" -and (Test-FactoryOn))) {
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
        if ($c[6] -ceq "CONFIRMED" -and $c[7] -match '^[0-9]+$') {
            $hitsText = $c[7].TrimStart('0')
            if ($hitsText.Length -gt 1 -or ($hitsText.Length -eq 1 -and [int]$hitsText -ge 5)) {
                [Console]::Error.WriteLine("WARN: docs/Brain.md row '$id' is CONFIRMED with $($c[7]) hits; promote it to a rule in AGENTS.md, an ADR or a BR")
            }
        }
    }
    if ($rows -gt $max) {
        [Console]::Error.WriteLine("ERROR: docs/Brain.md has $rows entries, over the Brain max entries limit of $max")
        $script:CheckFail = $true
    }
}

# Spec validation (Factory mode only, F06-E02-T01). A spec is docs/specs/<TASK-ID>.md
# (templates/Spec.md). Structure problems are errors; fields still UNKNOWN are
# one warning per spec, because a draft spec is normal during the SPEC phase.
# The cells of a table row, trimmed of spaces and tabs only (the sh launcher does
# the same), so a cell of non-breaking spaces is content in both.
function Split-SpecCells([string]$Line) {
    $line = $Line -replace '^\|', '' -replace '\|[ \t]*$', ''
    return @($line -split '\|' | ForEach-Object { $_.Trim(" `t") })
}

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
            if ($line.StartsWith("- Goal:")) { $hasGoal = $true; if (-not $line.Substring(7).Trim(" `t")) { $msgs.Add("$($pre)has an empty Goal") }; continue }
            if ($line.StartsWith("- Rules:")) { $hasRules = $true; if (-not $line.Substring(8).Trim(" `t")) { $msgs.Add("$($pre)has empty Rules") }; continue }
            if ($line.StartsWith("- Tags:")) { $hasTags = $true; if (-not $line.Substring(7).Trim(" `t")) { $msgs.Add("$($pre)has empty Tags") }; continue }
        }
        if ($sec -ceq "## Scenarios" -and $line.StartsWith("|")) {
            $c = @(Split-SpecCells $line)
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
        if ($path -match '^[\\/]' -or $path -match '^[A-Za-z]:' -or $path -match '(^|[\\/])\.\.([\\/]|$)') {
            $msgs.Add("$($pre)Tests entry '$path' must be a relative path inside the project (no absolute path, drive letter or .. segment)")
        }
        $r = $p.Substring($p.LastIndexOf(' (') + 2)
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
    [string[]]$names = @(Get-ChildItem -LiteralPath $dir -File | Where-Object { $_.Name.EndsWith(".md", [System.StringComparison]::Ordinal) -and -not $_.Name.StartsWith(".") } | ForEach-Object { $_.Name })
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

# Working memory validation (Factory mode only, F06-E03-T02): every file in
# docs/brain/tasks has the three sections and a well-formed ## Now.
function Get-MemoryReport([string]$Path) {
    $id = [System.IO.Path]::GetFileNameWithoutExtension($Path)
    $pre = "ERROR: docs/brain/tasks/$id.md "
    $msgs = [System.Collections.Generic.List[string]]::new()
    $sec = ""; $seen = @{}
    $hs = $false; $hn = $false; $ha = $false; $hu = $false
    $lines = @(Get-ContentUtf8 -LiteralPath $Path)
    for ($ln = 0; $ln -lt $lines.Count; $ln++) {
        $line = [string]$lines[$ln]
        if ($ln -eq 0) {
            $t = "# Working memory $id"
            if (-not $line.StartsWith($t, [System.StringComparison]::Ordinal) -or ($line.Length -gt $t.Length -and $line[$t.Length] -ne ' ')) {
                $msgs.Add("$($pre)title must start with '$t'")
            }
        }
        if ($line.StartsWith("## ")) { $sec = $line; $seen[$sec] = $true; continue }
        if ($sec -cne "## Now") { continue }
        if ($line.StartsWith("- Step:")) { $hs = $true; if (-not $line.Substring(7).Trim(" `t")) { $msgs.Add("$($pre)Now has an empty Step") }; continue }
        if ($line.StartsWith("- Next:")) { $hn = $true; if (-not $line.Substring(7).Trim(" `t")) { $msgs.Add("$($pre)Now has an empty Next") }; continue }
        if ($line.StartsWith("- Attempts:")) {
            $ha = $true
            $v = $line.Substring(11).Trim(" `t")
            if ($v -notmatch '^[0-9]+$') { $msgs.Add("$($pre)Now has invalid Attempts: $v") }
            continue
        }
        if ($line.StartsWith("- Updated:")) {
            $hu = $true
            $v = $line.Substring(10).Trim(" `t")
            if ($v -ne $EmDash -and $v -cnotmatch '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$') { $msgs.Add("$($pre)Now has invalid Updated: $v") }
            continue
        }
    }
    foreach ($req in @("## Now", "## Trail", "## Retro")) {
        if (-not $seen.ContainsKey($req)) { $msgs.Add("$($pre)is missing section '$req'") }
    }
    if ($seen.ContainsKey("## Now")) {
        if (-not $hs) { $msgs.Add("$($pre)Now is missing '- Step:'") }
        if (-not $hn) { $msgs.Add("$($pre)Now is missing '- Next:'") }
        if (-not $ha) { $msgs.Add("$($pre)Now is missing '- Attempts:'") }
        if (-not $hu) { $msgs.Add("$($pre)Now is missing '- Updated:'") }
    }
    return $msgs.ToArray()
}

function Test-WorkingMemory {
    $dir = Join-Path (Join-Path $DocsDir "brain") "tasks"
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { return }
    [string[]]$names = @(Get-ChildItem -LiteralPath $dir -File | Where-Object { $_.Name.EndsWith(".md", [System.StringComparison]::Ordinal) -and -not $_.Name.StartsWith(".") } | ForEach-Object { $_.Name })
    [System.Array]::Sort($names, [System.StringComparer]::Ordinal)
    foreach ($name in $names) {
        foreach ($m in @(Get-MemoryReport (Join-Path $dir $name))) {
            [Console]::Error.WriteLine($m)
            $script:CheckFail = $true
        }
    }
}

# A task in RED or GREEN of the normal lane has a spec without UNKNOWN fields (F06-E02-T06).
function Test-PhaseSpecs {
    foreach ($s in @(Get-OpenTaskStates)) {
        if (($s.Phase -ceq "RED" -or $s.Phase -ceq "GREEN") -and $s.Lane -cne "FAST") {
            $spec = Join-Path (Join-Path $DocsDir "specs") "$($s.Task).md"
            if (-not (Test-Path -LiteralPath $spec -PathType Leaf)) {
                [Console]::Error.WriteLine("ERROR: $($s.Task) is in phase $($s.Phase) but docs/specs/$($s.Task).md does not exist")
                $script:CheckFail = $true
            } else {
                $unk = Get-SpecUnknownCount $spec
                if ($unk -gt 0) {
                    [Console]::Error.WriteLine("ERROR: $($s.Task) is in phase $($s.Phase) but docs/specs/$($s.Task).md still has $unk UNKNOWN field(s)")
                    $script:CheckFail = $true
                }
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
    if (Test-FactoryOn) { Test-BrainRows; Test-Specs; Test-FactoryRoster; Test-WorkingMemory; Test-PhaseSpecs }

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
    # In Factory mode the statuses of the lifecycle belong to its commands: a hand-written entry
    # would start, hold or close a task with no phase, spec, tests or review (BR-009, ADR-093).
    # Only AUDIT is written, compared with the spaces around it removed (the fields are trimmed above).
    if ((Test-FactoryOn) -and $fields[2] -cne "AUDIT") {
        throw "append-log failed: $($fields[2]) is not AUDIT; in Factory mode the statuses of the lifecycle belong to claim, pause, handoff, review, advance, assign and done (append-log is only for entries outside the lifecycle, like AUDIT)"
    }
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
        Invoke-BrainGc
        if ($script:BrainGcDone) { return }
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
        $attCarry = [int]$s.Attempts
        if ($s.Status -eq "REVIEW" -and $s.Review -cmatch '^FAIL' -and $attCarry -gt 0) { $attCarry-- }
        if ($s.Status -eq "REVIEW") {
            # The developer who holds the task is not necessarily the agent of
            # the last entry (a reviewer wrote it), so re-open the holder first
            # and then the REVIEW entry with its handoff/review lines; otherwise
            # done by the holder would stop working after a rotation.
            $lines.Add("")
            $lines.Add("## [$($s.Ts)] | $($s.Holder) | $($s.Task) | IN_PROGRESS | $($s.Name)")
            $lines.Add("- Summary: carried forward from docs/history/$name at rotation")
            if ($s.Phase) { $lines.Add("- Phase: $($s.Phase)") }
            if ($s.SpecPass) { $lines.Add("- Spec-pass: $($s.SpecPass)") }
            $rotSha = Get-SpecSha $s.Task; if ($rotSha) { $lines.Add("- Spec-sha: $rotSha") }
            if ($s.Red) { $lines.Add("- Red: $($s.Red)") }
            if ($s.Tests) { $lines.Add("- Tests: $($s.Tests)") }
            if ($attCarry -gt 0) { $lines.Add("- Attempts: $attCarry") }
            if ($s.Struggled) { $lines.Add("- Struggled: yes") }
            if ($s.Lane) { $lines.Add("- Lane: $($s.Lane)") }
            if ($s.Base) { $lines.Add("- Base: $($s.Base)") }
        }
        $lines.Add("")
        $lines.Add("## [$($s.Ts)] | $($s.Agent) | $($s.Task) | $($s.Status) | $($s.Name)")
        $lines.Add("- Summary: carried forward from docs/history/$name at rotation")
        if ($s.Status -ne "REVIEW" -and $s.Phase) { $lines.Add("- Phase: $($s.Phase)") }
        if ($s.Status -ne "REVIEW" -and $s.SpecPass) { $lines.Add("- Spec-pass: $($s.SpecPass)") }
        if ($s.Status -ne "REVIEW") { $rotSha = Get-SpecSha $s.Task; if ($rotSha) { $lines.Add("- Spec-sha: $rotSha") } }
        if ($s.Status -ne "REVIEW" -and $s.Red) { $lines.Add("- Red: $($s.Red)") }
        if ($s.Status -ne "REVIEW" -and $s.Tests) { $lines.Add("- Tests: $($s.Tests)") }
        if ($s.Status -ne "REVIEW" -and $attCarry -gt 0) { $lines.Add("- Attempts: $attCarry") }
        if ($s.Status -ne "REVIEW" -and $s.Struggled) { $lines.Add("- Struggled: yes") }
        if ($s.Status -ne "REVIEW" -and $s.Lane) { $lines.Add("- Lane: $($s.Lane)") }
        if ($s.Status -ne "REVIEW" -and $s.Base) { $lines.Add("- Base: $($s.Base)") }
        if ($s.Status -eq "PAUSE") {
            if ($s.PauseDetail) { $lines.Add("- Pause: $($s.PauseCat) - $($s.PauseDetail)") } else { $lines.Add("- Pause: $($s.PauseCat) - see docs/history/$name for detail") }
        }
        if ($s.Status -eq "ASSIGNED") {
            $lines.Add("- Assign: $($s.Holder)")
        }
        if ($s.Status -eq "REVIEW") {
            $lines.Add("- Verify: carried forward from docs/history/$name")
            if ($s.Handoff) { $lines.Add("- Handoff: $($s.Handoff)") }
            if ($s.Review) { $lines.Add("- Review: $($s.Review) - carried forward from docs/history/$name") }
            if ($s.Cross) { $lines.Add("- Cross-model: $($s.Cross)") }
        }
    }
    # A closed task of the normal lane that one model reviewed and nobody audited yet stays in the
    # ledger as a DONE entry, so the audit queue of the preferred reviewer survives the rotation.
    # Only when a preferred reviewer is set (nobody else audits), and the 20 latest at most, so a
    # queue nobody works off cannot keep the ledger over its limit.
    if ((Test-FactoryOn) -and (Get-FactorySetting "Preferred reviewer")) {
        # the 20 latest by timestamp, then by task id, compared as plain characters like sort in sh
        $byKey = @{}
        foreach ($c in @(Get-TaskStates | Where-Object { $_.Status -eq "DONE" -and $_.Lane -cne "FAST" -and $_.Cross -ceq "NO" -and -not $_.Audited })) { $byKey["$($c.Ts)`t$($c.Task)"] = $c }
        $keys = [string[]]@($byKey.Keys)
        [System.Array]::Sort($keys, [System.StringComparer]::Ordinal)
        $queue = @($keys | Select-Object -Last 20 | ForEach-Object { $byKey[$_] })
        foreach ($s in $queue) {
            if ($true) {
                $lines.Add("")
                $lines.Add("## [$($s.Ts)] | $($s.Agent) | $($s.Task) | DONE | $($s.Name)")
                $lines.Add("- Summary: carried forward from docs/history/$name at rotation, still to be audited")
                $lines.Add("- Files: see docs/history/$name")
                $lines.Add("- Verify: carried forward from docs/history/$name")
                $lines.Add("- Cross-model: NO")
            }
        }
    }
    Write-Utf8File $log (ConvertTo-JoinedLines ([string[]]$lines))
    Write-Output "project_docs rotate: archived $name"
    Invoke-BrainGc
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
    "checkpoint" { Invoke-Checkpoint }
    "recall" { Invoke-Recall }
    "learn" { Invoke-Learn }
    "retro" { Invoke-Retro }
    "next" { Invoke-Next }
    "digest" { Invoke-Digest }
    "advance" { Invoke-Advance }
    "assign" { Invoke-Assign }
    "done" { Invoke-Done }
    "status" { Invoke-Status }
    default {
        Write-Output "Usage: project_docs.ps1 {init|check|context|append-log|rotate|migrate|link|claim|pause|handoff|review|assign|done|status|mode|checkpoint|advance|recall|learn|retro|next|digest} <project> [args]"
    }
}
