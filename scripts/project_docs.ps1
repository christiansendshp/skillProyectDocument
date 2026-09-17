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

# Computed, not stored: a per-entry YAML block has no natural "move between
# sections" operation, so unlike Product/Stack/Features (bounded physical
# sections) Active work is derived fresh from every entry's own `status`,
# capped so a large Plan can't blow the 8 KiB context budget on its own.
$ActiveSummaryCap = 20
function Get-RoadmapActiveSummary {
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("## Active work")
    $excluded = @("", "IDEA", "BACKLOG", "DONE", "CANCELLED", "DEFERRED", "DECIDED")
    $total = 0
    foreach ($e in @(Get-RoadmapEntries)) {
        if ($excluded -contains $e.Status) { continue }
        $total++
        if ($total -gt $ActiveSummaryCap) { continue }
        $title = $e.Title
        if ($title.Length -gt 50) { $title = $title.Substring(0, 47) + "..." }
        $lines.Add("$($e.Id) | $($e.Type) | $title | $($e.Status)")
    }
    if ($total -gt $ActiveSummaryCap) {
        $lines.Add("... and $($total - $ActiveSummaryCap) more (see docs/Roadmap.md)")
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
        @("Features.md", "## Operational summary")
    )) {
        $parts.Add("")
        foreach ($line in @(Get-ContextBlock (Join-Path $DocsDir $item[0]) $item[1])) { $parts.Add([string]$line) }
    }
    $parts.Add("")
    foreach ($line in @(Get-RoadmapActiveSummary)) { $parts.Add([string]$line) }
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
# Features.md stays a plain table (unchanged by the Roadmap rewrite below).
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

function Get-FeaturesIds { return Get-TableIds (Join-Path $DocsDir "Features.md") }

# ---------------------------------------------------------------------------
# Roadmap entries: each is a "### TYPE-ID -- Title" heading immediately
# followed by a fenced ```yaml block; the block is the source of truth,
# addressed by its top-level (column 0) `id:` line so nested keys (e.g. a
# `- id: AC-1` inside acceptance_criteria) never collide. See
# references/roadmap-schema.md for the full field/type reference.
# ---------------------------------------------------------------------------
function Get-RoadmapIds {
    $file = Join-Path $DocsDir "Roadmap.md"
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { return @() }
    $ids = [System.Collections.Generic.List[string]]::new()
    $inFence = $false
    foreach ($line in @(Get-ContentUtf8 -LiteralPath $file)) {
        if (-not $inFence) {
            if ($line -match '^```yaml') { $inFence = $true }
            continue
        }
        if ($line -match '^```[ \t]*$') { $inFence = $false; continue }
        if ($line -match '^id:[ \t]*(.*)$') { $ids.Add($Matches[1].Trim().Trim('"')) }
    }
    return $ids
}

function Test-RoadmapHasId([string]$Id) {
    return ((@(Get-RoadmapIds)) -contains $Id)
}

function ConvertFrom-YamlInlineList([string]$Value) {
    $s = $Value.Trim()
    if ($s -eq "") { return "" }
    if ($s.StartsWith("[") -and $s.EndsWith("]")) {
        $inner = $s.Substring(1, $s.Length - 2).Trim()
        if ($inner -eq "") { return "" }
        $items = @($inner -split ',' | ForEach-Object { $_.Trim().Trim('"') } | Where-Object { $_ -ne "" })
        return ($items -join ";")
    }
    return $s.Trim('"')
}

# One object per entry: Id, Type, Title, Status, Parent, DependsOn, Blocks,
# BlockedBy, Affects (list fields ';'-joined; both inline `[a, b]` and block
# `- a` / `- b` YAML list forms are accepted).
function Get-RoadmapEntries {
    $file = Join-Path $DocsDir "Roadmap.md"
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { return @() }
    $result = [System.Collections.Generic.List[object]]::new()
    $inFence = $false
    $id = ""; $type = ""; $title = ""; $status = ""; $parent = ""
    $dep = ""; $blk = ""; $bby = ""; $aff = ""; $pendKey = ""
    foreach ($line in @(Get-ContentUtf8 -LiteralPath $file)) {
        if (-not $inFence) {
            if ($line -match '^```yaml') {
                $inFence = $true
                $id = ""; $type = ""; $title = ""; $status = ""; $parent = ""
                $dep = ""; $blk = ""; $bby = ""; $aff = ""; $pendKey = ""
            }
            continue
        }
        if ($line -match '^```[ \t]*$') {
            $inFence = $false
            if ($id -ne "") {
                $result.Add([PSCustomObject]@{
                    Id = $id; Type = $type; Title = $title; Status = $status; Parent = $parent
                    DependsOn = $dep; Blocks = $blk; BlockedBy = $bby; Affects = $aff
                })
            }
            continue
        }
        if ($line -match '^([A-Za-z_][A-Za-z0-9_]*):[ \t]*(.*)$') {
            $key = $Matches[1]
            $val = $Matches[2].Trim()
            switch ($key) {
                "id" { $id = $val.Trim('"'); $pendKey = "" }
                "type" { $type = $val; $pendKey = "" }
                "title" { $title = $val.Trim('"'); $pendKey = "" }
                "status" { $status = $val; $pendKey = "" }
                "parent" { $parent = $val.Trim('"'); $pendKey = "" }
                "depends_on" { $dep = ConvertFrom-YamlInlineList $val; $pendKey = "dep" }
                "blocks" { $blk = ConvertFrom-YamlInlineList $val; $pendKey = "blk" }
                "blocked_by" { $bby = ConvertFrom-YamlInlineList $val; $pendKey = "bby" }
                "affects" { $aff = ConvertFrom-YamlInlineList $val; $pendKey = "aff" }
                default { $pendKey = "" }
            }
            continue
        }
        if ($pendKey -ne "" -and $line -match '^[ \t]+-[ \t]+(.*)$') {
            $item = $Matches[1].Trim().Trim('"')
            if ($item -ne "") {
                switch ($pendKey) {
                    "dep" { $dep = if ($dep -eq "") { $item } else { "$dep;$item" } }
                    "blk" { $blk = if ($blk -eq "") { $item } else { "$blk;$item" } }
                    "bby" { $bby = if ($bby -eq "") { $item } else { "$bby;$item" } }
                    "aff" { $aff = if ($aff -eq "") { $item } else { "$aff;$item" } }
                }
            }
            continue
        }
        if ($line -match '^[ \t]') { continue }
        $pendKey = ""
    }
    return $result
}

# 0-based, inclusive [start, end] line range of the yaml fence CONTENT
# (excluding the ``` markers) for the entry whose top-level id matches, or
# $null if not found.
function Get-RoadmapEntryRange([string]$Id) {
    $file = Join-Path $DocsDir "Roadmap.md"
    $lines = @(Get-ContentUtf8 -LiteralPath $file)
    $n = $lines.Count
    for ($i = 0; $i -lt $n; $i++) {
        if ($lines[$i] -match '^```yaml') {
            $fs = $i
            $fe = -1
            for ($j = $i + 1; $j -lt $n; $j++) { if ($lines[$j] -match '^```[ \t]*$') { $fe = $j; break } }
            if ($fe -lt 0) { break }
            $found = $false
            for ($k = $fs + 1; $k -lt $fe; $k++) {
                if ($lines[$k] -match '^id:[ \t]*(.*)$') {
                    if ($Matches[1].Trim().Trim('"') -eq $Id) { $found = $true }
                }
            }
            if ($found) { return @(($fs + 1), ($fe - 1)) }
            $i = $fe
        }
    }
    return $null
}

function Get-RoadmapField([string]$Id, [string]$Key) {
    $range = Get-RoadmapEntryRange $Id
    if (-not $range) { return $null }
    $file = Join-Path $DocsDir "Roadmap.md"
    $lines = @(Get-ContentUtf8 -LiteralPath $file)
    $pattern = '^' + [regex]::Escape($Key) + ':[ \t]*(.*)$'
    for ($i = $range[0]; $i -le $range[1]; $i++) {
        if ($lines[$i] -match $pattern) { return $Matches[1] }
    }
    return $null
}

# Double-quote a value for safe embedding as a YAML scalar (used for
# free-form values such as an agent name, never for script-controlled enums).
function ConvertTo-YamlQuote([string]$Value) {
    return ($Value -replace '\\', '\\\\' -replace '"', '\"')
}

function Set-RoadmapField([string]$Id, [string]$Key, [string]$Value) {
    $range = Get-RoadmapEntryRange $Id
    if (-not $range) { throw "Set-RoadmapField: $Id not found in docs/Roadmap.md" }
    $file = Join-Path $DocsDir "Roadmap.md"
    $lines = @(Get-ContentUtf8 -LiteralPath $file)
    $pattern = '^' + [regex]::Escape($Key) + ':'
    $hasKey = $false
    $idLineIdx = -1
    for ($i = $range[0]; $i -le $range[1]; $i++) {
        if ($lines[$i] -match '^id:') { $idLineIdx = $i }
        if ($lines[$i] -match $pattern) { $lines[$i] = $Key + ": " + $Value; $hasKey = $true }
    }
    if (-not $hasKey) {
        $newLines = [System.Collections.Generic.List[string]]::new()
        for ($i = 0; $i -lt $lines.Count; $i++) {
            $newLines.Add([string]$lines[$i])
            if ($i -eq $idLineIdx) { $newLines.Add($Key + ": " + $Value) }
        }
        $lines = $newLines.ToArray()
    }
    Write-Utf8File $file (ConvertTo-JoinedLines ([string[]]$lines))
}

# Remove a whole entry: its "### TYPE-ID -- Title" heading through the
# closing yaml fence, plus one trailing blank line. A no-op if the ID isn't
# a Roadmap entry (mirrors the old table version's tolerance of unknown IDs).
function Remove-RoadmapEntry([string]$Id) {
    $file = Join-Path $DocsDir "Roadmap.md"
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { return }
    $lines = @(Get-ContentUtf8 -LiteralPath $file)
    $n = $lines.Count
    $delStart = -1; $delEnd = -1
    for ($i = 0; $i -lt $n; $i++) {
        if ($lines[$i] -match '^```yaml') {
            $fs = $i
            $fe = -1
            for ($j = $i + 1; $j -lt $n; $j++) { if ($lines[$j] -match '^```[ \t]*$') { $fe = $j; break } }
            if ($fe -lt 0) { break }
            $found = $false
            for ($k = $fs + 1; $k -lt $fe; $k++) {
                if ($lines[$k] -match '^id:[ \t]*(.*)$') {
                    if ($Matches[1].Trim().Trim('"') -eq $Id) { $found = $true }
                }
            }
            if ($found) {
                $h = $fs - 1
                $crossed = $false
                while ($h -ge 0 -and $lines[$h] -notmatch '^### ') {
                    if ($lines[$h] -match '^## ' -or $lines[$h] -match '^```') { $crossed = $true; break }
                    $h--
                }
                $delStart = if ($crossed -or $h -lt 0 -or $lines[$h] -notmatch '^### ') { $fs } else { $h }
                $delEnd = $fe
                if ($delEnd + 1 -lt $n -and $lines[$delEnd + 1] -match '^[ \t]*$') { $delEnd = $delEnd + 1 }
            }
            $i = $fe
        }
    }
    if ($delStart -lt 0) { return }
    $result = [System.Collections.Generic.List[string]]::new()
    for ($i = 0; $i -lt $n; $i++) {
        if ($i -ge $delStart -and $i -le $delEnd) { continue }
        $result.Add([string]$lines[$i])
    }
    Write-Utf8File $file (ConvertTo-JoinedLines ([string[]]$result))
}

# True if some other entry's top-level `parent:` still names ParentId.
function Test-RoadmapHasChildOf([string]$ParentId) {
    foreach ($e in @(Get-RoadmapEntries)) { if ($e.Parent -eq $ParentId) { return $true } }
    return $false
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

# Records a closed entry in Features.md. When it was the last direct child
# (by `parent`) of an EPIC entry, also rolls the epic up: a Features row, a
# normal synthetic DONE log entry (so check needs no epic-shape special case
# going forward), and removal of the epic's own now-closed Roadmap entry.
function Add-FeaturesCapability([string]$Id, [string]$Summary, [string]$Verify, [string]$Timestamp, [string]$Parent = "") {
    $file = Join-Path $DocsDir "Features.md"
    $dateOnly = $Timestamp.Split('T')[0]
    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($line in @(Get-ContentUtf8 -LiteralPath $file)) {
        if ($line -eq "| $EmDash | $EmDash | $EmDash | $EmDash | $EmDash |") { continue }
        $lines.Add($line)
    }
    $lines.Add("| $Id | $Summary | $Verify | log:$Id | $dateOnly |")
    if ($Parent) {
        $ptype = Get-RoadmapField $Parent "type"
        $existingIds = @(Get-TableIds $file)
        if ($ptype -eq "EPIC" -and -not (Test-RoadmapHasChildOf $Parent) -and -not ($existingIds -contains $Parent)) {
            $lines.Add("| $Parent | Epic complete | all tasks DONE | log:$Id | $dateOnly |")
            $log = Join-Path $DocsDir "Agentslog.md"
            $entry = (@(
                "",
                "## [$Timestamp] | rollup | $Parent | DONE",
                "- Summary: all direct children of $Parent are DONE",
                "- Files: -",
                "- Verify: rollup from $Id"
            ) -join "`n") + "`n"
            [System.IO.File]::AppendAllText($log, $entry, $Utf8)
            Remove-RoadmapEntry $Parent
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
    if ((Get-RoadmapField $task "type") -eq "DECISION") {
        throw "claim failed: $task is a DECISION; resolve it by hand (see references/roadmap-schema.md #9), not with claim"
    }
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
        if (Test-RoadmapHasId $task) {
            Set-RoadmapField $task "status" "IN_PROGRESS"
            Set-RoadmapField $task "executor" "AI"
            Set-RoadmapField $task "assigned_agent" ('"' + (ConvertTo-YamlQuote $agent) + '"')
            Set-RoadmapField $task "updated_at" $timestamp
        }
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
        if (Test-RoadmapHasId $task) {
            $newStatus = if ($category -eq "LIMITE" -or $category -eq "OTRO") { "READY" } else { "BLOCKED" }
            Set-RoadmapField $task "status" $newStatus
            Set-RoadmapField $task "updated_at" $timestamp
        }
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
        $parent = Get-RoadmapField $task "parent"
        if (-not $parent) { $parent = "" }
        Remove-RoadmapEntry $task
        Add-FeaturesCapability $task $summary $verify $timestamp $parent
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
# True if docs/Roadmap.md still uses the pre-rewrite table format (any of
# its three old section headings). A file already in the new per-entry YAML
# format, or a fresh one just scaffolded from the template, has none of
# these, so this is also the idempotency check for the conversion below.
function Test-RoadmapNeedsTableMigration {
    $file = Join-Path $DocsDir "Roadmap.md"
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { return $false }
    foreach ($line in @(Get-ContentUtf8 -LiteralPath $file)) {
        if ($line -eq "## Active work" -or $line -eq "## Near term" -or $line -eq "## Gaps and defects") { return $true }
    }
    return $false
}

function ConvertTo-MigratedStatus([string]$S) {
    switch ($S.Trim()) {
        "TODO" { return "BACKLOG" }
        "IN_PROGRESS" { return "IN_PROGRESS" }
        "PAUSE" { return "BLOCKED" }
        "DONE" { return "DONE" }
        default { return "BACKLOG" }
    }
}

function Test-PlaceholderCell([string]$V) {
    $v = $V.Trim()
    return ($v -eq "" -or $v -eq $EmDash -or $v -eq "-" -or $v -match '^-+$')
}

function Get-AgentFromOwnerCell([string]$Owner) {
    $v = $Owner.Trim()
    if (Test-PlaceholderCell $v) { return "" }
    $at = $v.IndexOf("@")
    if ($at -ge 0) { return $v.Substring(0, $at) }
    return $v
}

function ConvertTo-DepsList([string]$D) {
    $v = $D.Trim()
    if (Test-PlaceholderCell $v) { return "" }
    $v = $v -replace ',\s*', ';'
    $v = $v -replace '\s+', ';'
    return $v
}

function Split-TableCells([string]$Line) {
    $line = $Line -replace '^\|', '' -replace '\|[ \t]*$', ''
    return @($line -split '\|' | ForEach-Object { $_.Trim() })
}

# Emits one "### TYPE-ID -- Title" heading + fenced yaml block, in the same
# shape as templates/Roadmap.md, as a list of lines.
function New-RoadmapEntryLines {
    param(
        [string]$Id, [string]$Type, [string]$Title, [string]$Status, [string]$Parent,
        [string]$Description, [string]$Acceptance, [string]$AssignedAgent, [string]$Deps,
        [string]$Severity, [string]$Phase
    )
    $sep = " " + $EmDash + " "
    $out = [System.Collections.Generic.List[string]]::new()
    $out.Add("")
    $out.Add("### " + $Id + $sep + $Title)
    $out.Add("")
    $out.Add('```yaml')
    $out.Add("id: " + $Id)
    $out.Add("type: " + $Type)
    $out.Add("title: " + $Title)
    $out.Add("status: " + $Status)
    if ($Parent) { $out.Add("parent: " + $Parent) }
    if ($AssignedAgent) { $out.Add('assigned_agent: "' + (ConvertTo-YamlQuote $AssignedAgent) + '"') }
    if ($Deps) {
        $out.Add("depends_on:")
        foreach ($d in ($Deps -split ';')) { if ($d) { $out.Add("  - " + $d) } }
    }
    if ($Severity) { $out.Add("severity: " + $Severity) }
    if ($Phase) { $out.Add("phase: " + $Phase) }
    if ($Description) { $out.Add("description: >"); $out.Add("  " + $Description) }
    if ($Acceptance) {
        $out.Add("acceptance_criteria:")
        $out.Add("  - id: AC-1")
        $out.Add("    description: " + $Acceptance)
        $out.Add("    status: pending")
    }
    $out.Add('```')
    return $out
}

# Non-destructive table -> per-entry YAML conversion (references/roadmap-
# schema.md #18). Old "## Active work"/"## Plan" rows and Fase/Epic headings
# become PHASE/EPIC/TASK entries under the new "## Plan"; "## Gaps and
# defects" rows become GAP entries under "## Cross-cutting". IDs are kept
# exactly as written (ADR-001); Outcome -> description, Acceptance check ->
# one acceptance_criteria item, Owner's agent part -> assigned_agent (the
# old cell mixed agent+timestamp and was never the accountability `owner`
# this schema defines, so `owner` is left for a human to fill in), Depends
# on -> depends_on, Severity/Phase (Gaps and defects only) -> their own
# fields. `type` is inferred TASK for Active work/Plan/Near term rows and
# GAP for Gaps and defects rows regardless of what the row's ID or
# description imply; adjust by hand afterward if a row is really a BUG.
function Convert-RoadmapTableToYaml {
    $file = Join-Path $DocsDir "Roadmap.md"
    if (-not (Test-RoadmapNeedsTableMigration)) { return $false }
    $sep = " " + $EmDash + " "
    $planOut = [System.Collections.Generic.List[string]]::new()
    $crossOut = [System.Collections.Generic.List[string]]::new()
    $section = ""
    $phaseId = ""
    $epicId = ""
    foreach ($line in @(Get-ContentUtf8 -LiteralPath $file)) {
        if ($line -eq "## Active work") { $section = "active"; continue }
        if ($line -eq "## Near term") { $section = "near"; continue }
        if ($line -eq "## Plan") { $section = "plan"; continue }
        if ($line -eq "## Gaps and defects") { $section = "gaps"; continue }
        if ($line -eq "<!-- context:end -->") { continue }

        if ($section -eq "plan" -and $line -match '^### (.*)$') {
            $headingText = $Matches[1]
            $dash = $headingText.IndexOf($sep)
            if ($dash -ge 0) { $hid = $headingText.Substring(0, $dash).Trim(); $htitle = $headingText.Substring($dash + $sep.Length).Trim() }
            else { $hid = $headingText.Trim(); $htitle = $hid }
            $phaseId = $hid; $epicId = ""
            $planOut.AddRange([string[]](New-RoadmapEntryLines $hid "PHASE" $htitle "BACKLOG" "" "" "" "" "" "" ""))
            continue
        }
        if ($section -eq "plan" -and $line -match '^#### (.*)$') {
            $headingText = $Matches[1]
            $dash = $headingText.IndexOf($sep)
            if ($dash -ge 0) { $hid = $headingText.Substring(0, $dash).Trim(); $htitle = $headingText.Substring($dash + $sep.Length).Trim() }
            else { $hid = $headingText.Trim(); $htitle = $hid }
            $epicId = $hid
            $planOut.AddRange([string[]](New-RoadmapEntryLines $hid "EPIC" $htitle "BACKLOG" $phaseId "" "" "" "" "" ""))
            continue
        }
        if ($line.StartsWith("|")) {
            $cells = @(Split-TableCells $line)
            if ($cells.Count -lt 1) { continue }
            if ($cells[0] -eq "ID" -or (Test-PlaceholderCell $cells[0])) { continue }
            if ($section -eq "active" -or ($section -eq "plan" -and $cells.Count -eq 7)) {
                $id = $cells[0]; $outcome = $cells[1]; $accept = $cells[2]; $status = $cells[3]; $owner = $cells[4]; $deps = $cells[5]
                $planOut.AddRange([string[]](New-RoadmapEntryLines $id "TASK" $outcome (ConvertTo-MigratedStatus $status) $epicId $outcome $accept (Get-AgentFromOwnerCell $owner) (ConvertTo-DepsList $deps) "" ""))
                continue
            }
            if ($section -eq "near" -and $cells.Count -eq 5) {
                $id = $cells[0]; $outcome = $cells[1]; $accept = $cells[2]; $status = $cells[3]; $deps = $cells[4]
                $planOut.AddRange([string[]](New-RoadmapEntryLines $id "TASK" $outcome (ConvertTo-MigratedStatus $status) "" $outcome $accept "" (ConvertTo-DepsList $deps) "" ""))
                continue
            }
            if ($section -eq "gaps" -and $cells.Count -eq 8) {
                $id = $cells[0]; $sevv = $cells[1]; $ph = $cells[2]; $desc = $cells[3]; $status = $cells[4]; $owner = $cells[5]; $deps = $cells[6]
                $crossOut.AddRange([string[]](New-RoadmapEntryLines $id "GAP" $desc (ConvertTo-MigratedStatus $status) "" $desc "" (Get-AgentFromOwnerCell $owner) (ConvertTo-DepsList $deps) $sevv $ph))
                continue
            }
        }
    }
    $intro = [System.Collections.Generic.List[string]]::new()
    foreach ($tline in @(Get-ContentUtf8 -LiteralPath (Join-Path $TemplatesDir "Roadmap.md"))) {
        if ($tline -eq "## Plan") { break }
        $intro.Add([string]$tline)
    }
    $final = [System.Collections.Generic.List[string]]::new()
    $final.AddRange([string[]]$intro)
    $final.Add("## Plan")
    $final.AddRange([string[]]$planOut)
    $final.Add("")
    $final.Add("## Cross-cutting")
    if ($crossOut.Count -gt 0) {
        $final.AddRange([string[]]$crossOut)
    } else {
        $final.Add("")
        $noEntriesLine = 'No entries yet. Add a `### TYPE-ID ' + $EmDash + ' Title` heading and `yaml` block here for a GAP, BUG, DECISION, BLOCKER, or other cross-cutting entry when one is found.'
        $final.Add($noEntriesLine)
    }
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
    if (Convert-RoadmapTableToYaml) {
        $changed++
        Write-Output "= converted: docs/Roadmap.md table rows -> per-entry YAML (references/roadmap-schema.md)"
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
            [Console]::Error.WriteLine($e.ConflictMsg)
            $script:CheckFail = $true
        }
        if ($e.Status -notin @("IN_PROGRESS", "PAUSE", "DONE")) {
            [Console]::Error.WriteLine("ERROR: invalid status in entry: $($e.Hdr)")
            $script:CheckFail = $true
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

# Structural validation of every Roadmap entry (references/roadmap-schema.md
# #2, #6): unknown `type`, `status` outside its vocabulary (DECISION uses
# PENDING/DECIDED/CANCELLED instead of the base one), and a `parent`/
# `depends_on`/`blocks`/`blocked_by`/`affects` value that names no known ID
# in either Roadmap.md or Features.md.
# A fenced yaml block with no top-level `id:` line is invisible to every
# other primitive (Get-RoadmapIds/Get-RoadmapEntries skip it), so it would
# otherwise fail silently instead of erroring.
function Test-RoadmapHeadlessBlocks {
    $file = Join-Path $DocsDir "Roadmap.md"
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { return }
    $inFence = $false
    $fenceStart = 0
    $hasId = $false
    $lineNo = 0
    foreach ($line in @(Get-ContentUtf8 -LiteralPath $file)) {
        $lineNo++
        if (-not $inFence) {
            if ($line -match '^```yaml') { $inFence = $true; $fenceStart = $lineNo; $hasId = $false }
            continue
        }
        if ($line -match '^```[ \t]*$') {
            $inFence = $false
            if (-not $hasId) {
                [Console]::Error.WriteLine("ERROR: yaml block starting at Roadmap.md:$fenceStart has no top-level id: field")
                $script:CheckFail = $true
            }
            continue
        }
        if ($line -match '^id: ') { $hasId = $true }
    }
}

function Test-RoadmapEntries {
    $validTypes = @("VISION", "PHASE", "THEME", "EPIC", "FEATURE", "TASK", "SUBTASK", "GAP", "BUG", "IMPROVEMENT", "REFACTOR", "SPIKE", "DECISION", "BLOCKER", "DEPENDENCY", "TECH_DEBT", "DOC", "TEST", "SECURITY", "UX")
    $validStatuses = @("IDEA", "BACKLOG", "READY", "IN_PROGRESS", "REVIEW", "TESTING", "BLOCKED", "DONE", "CANCELLED", "DEFERRED")
    $validDecisionStatuses = @("PENDING", "DECIDED", "CANCELLED")
    $known = @{}
    foreach ($rid in @(Get-RoadmapIds)) { $known[$rid] = $true }
    foreach ($fid in @(Get-FeaturesIds)) { $known[$fid] = $true }
    foreach ($e in @(Get-RoadmapEntries)) {
        if (-not $e.Id) { continue }
        if ($validTypes -notcontains $e.Type) {
            [Console]::Error.WriteLine("ERROR: $($e.Id) has unknown type: $($e.Type)")
            $script:CheckFail = $true
        }
        if ($e.Type -eq "DECISION") {
            if ($validDecisionStatuses -notcontains $e.Status) {
                [Console]::Error.WriteLine("ERROR: $($e.Id) (DECISION) has invalid status: $($e.Status)")
                $script:CheckFail = $true
            }
        } elseif ($validStatuses -notcontains $e.Status) {
            [Console]::Error.WriteLine("ERROR: $($e.Id) has invalid status: $($e.Status)")
            $script:CheckFail = $true
        }
        if ($e.Parent -and -not $known.ContainsKey($e.Parent)) {
            [Console]::Error.WriteLine("ERROR: $($e.Id) parent references unknown ID: $($e.Parent)")
            $script:CheckFail = $true
        }
        foreach ($ref in @(
            @($e.DependsOn, "depends_on"),
            @($e.Blocks, "blocks"),
            @($e.BlockedBy, "blocked_by"),
            @($e.Affects, "affects")
        )) {
            $field = $ref[0]; $label = $ref[1]
            if (-not $field) { continue }
            foreach ($rid in ($field -split ';')) {
                if ($rid -and -not $known.ContainsKey($rid)) {
                    [Console]::Error.WriteLine("ERROR: $($e.Id) $label references unknown ID: $rid")
                    $script:CheckFail = $true
                }
            }
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
    Test-Need "docs/Roadmap.md" @("## Plan", "## Cross-cutting")
    Test-Need "docs/Features.md" @("## Operational summary", "## Verified capabilities")

    if (Test-RoadmapNeedsTableMigration) {
        [Console]::Error.WriteLine("MIGRATION REQUIRED: docs/Roadmap.md still uses the table format; run 'migrate'")
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
    }

    if (Test-Path -LiteralPath (Join-Path $DocsDir "Roadmap.md") -PathType Leaf) {
        Test-RoadmapHeadlessBlocks
        Test-RoadmapEntries
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
