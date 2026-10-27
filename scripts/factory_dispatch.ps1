<#
.SYNOPSIS
Passes the turn between the agent CLIs of a Factory project.

.DESCRIPTION
factory_dispatch.ps1 <project> [--watch] [--once]

The ledger is the channel: for each agent of .factory/dispatch.md, in order, the dispatcher asks
`next <agent>` and runs the CLI of the first one that has work, one CLI at a time. It detects quota
limits in the output, puts the plan of that CLI in cooldown, writes the pause on behalf of the
agent that was cut off, and lets a covering agent take the reviews of an agent that is out.
It lives outside the project_docs core and has an identical twin, factory_dispatch.sh.

Tests: PROJECT_DOCS_DISPATCH_NO_SLEEP=1 prints "sleep until HH:MM" instead of waiting and stops.
#>
param(
    [Parameter(Position = 0)]
    [string]$Project = ".",
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Rest
)

$ErrorActionPreference = "Stop"
$Utf8 = New-Object System.Text.UTF8Encoding($false)
$EmDash = [char]0x2014
# the PowerShell that runs this script runs the core, and cmd.exe (Windows) or sh run the agent commands
$PsExe = (Get-Process -Id $PID).Path
$IsWin = ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT)

$options = [System.Collections.Generic.List[string]]::new()
if ($Project.StartsWith("-")) { $options.Add($Project); $Project = "." }
foreach ($r in @($Rest)) { if ($r) { $options.Add($r) } }
$Watch = $false
$Once = $false
foreach ($o in $options) {
    if ($o -ceq "--watch") { $Watch = $true }
    elseif ($o -ceq "--once") { $Once = $true }
    else { [Console]::Error.WriteLine("factory_dispatch: unknown option $o"); exit 2 }
}

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Core = Join-Path $ScriptDir "project_docs.ps1"
$PromptTemplate = Join-Path (Join-Path $ScriptDir "..") "templates/dispatch-prompt.md"
try { $Project = (Resolve-Path -LiteralPath $Project -ErrorAction Stop).Path } catch { [Console]::Error.WriteLine("factory_dispatch: project folder not found"); exit 1 }
$FDir = Join-Path $Project ".factory"
$Config = Join-Path $FDir "dispatch.md"
$StateFile = Join-Path $FDir "state.md"
$Runs = Join-Path $FDir "runs"
$StopFile = Join-Path $FDir "STOP"
$Ledger = Join-Path (Join-Path $Project "docs") "Agentslog.md"

function Stop-Dispatch([string]$Message) {
    [Console]::Error.WriteLine("factory_dispatch: $Message")
    exit 1
}
function Write-Log([string]$Message) { Write-Output "dispatch: $Message" }

# ---- processes ---------------------------------------------------------------------------------------
function ConvertTo-ArgText([string]$Text) {
    if ($Text -eq "") { return '""' }
    if ($Text -notmatch '[\s"]') { return $Text }
    $t = $Text -replace '(\\*)"', '$1$1\"'
    $t = $t -replace '(\\+)$', '$1$1'
    return '"' + $t + '"'
}

# Runs a program with its output captured. Code 124 means the timeout killed it.
function Invoke-Captured([string]$File, [string]$ArgLine, [string]$WorkDir, [hashtable]$EnvVars, [int]$TimeoutSec) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $File
    $psi.Arguments = $ArgLine
    $psi.WorkingDirectory = $WorkDir
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = $Utf8
    $psi.StandardErrorEncoding = $Utf8
    foreach ($k in $EnvVars.Keys) { $psi.EnvironmentVariables[[string]$k] = [string]$EnvVars[$k] }
    if ($EnvVars.ContainsKey("FACTORY_AGENT")) {
        foreach ($key in @("ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "GEMINI_API_KEY", "GOOGLE_API_KEY")) { $psi.EnvironmentVariables.Remove($key) }
    }
    $p = [System.Diagnostics.Process]::Start($psi)
    $so = $p.StandardOutput.ReadToEndAsync()
    $se = $p.StandardError.ReadToEndAsync()
    $code = 0
    if ($TimeoutSec -gt 0) {
        if (-not $p.WaitForExit($TimeoutSec * 1000)) {
            & taskkill.exe /PID $p.Id /T /F 2>$null | Out-Null
            $code = 124
        }
    }
    else { $p.WaitForExit() }
    [void]$so.Wait(5000)
    [void]$se.Wait(5000)
    if ($code -ne 124) { $code = $p.ExitCode }
    $out = ""
    $err = ""
    if ($so.IsCompleted) { $out = $so.Result }
    if ($se.IsCompleted) { $err = $se.Result }
    return [PSCustomObject]@{ Code = $code; Out = $out; Err = $err }
}

# One command of the project_docs core, as a child process so that its exit never ends this script.
function Invoke-Core([string[]]$CoreArgs) {
    $parts = @("-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", (ConvertTo-ArgText $Core))
    foreach ($a in $CoreArgs) { $parts += (ConvertTo-ArgText $a) }
    return Invoke-Captured $PsExe ($parts -join " ") $Project @{} 0
}

# ---- the configuration -----------------------------------------------------------------------------------
function Split-Row([string]$Line) {
    $t = $Line.Trim()
    if ($t.StartsWith("|")) { $t = $t.Substring(1) }
    if ($t.EndsWith("|")) { $t = $t.Substring(0, $t.Length - 1) }
    return @($t -split '\|' | ForEach-Object { $_.Trim() })
}

if (-not (Test-Path -LiteralPath $Config -PathType Leaf)) { Stop-Dispatch "$Config does not exist (run init or migrate --factory)" }
$modeLine = (Invoke-Core @("mode", $Project)).Out -split "`n" | Select-Object -First 1
if (-not $modeLine -or -not $modeLine.Contains(": FACTORY")) { Stop-Dispatch "the project is not in Factory mode" }

$ConfigLines = @([System.IO.File]::ReadAllLines($Config, $Utf8))

function Get-CfgSetting([string]$Name, [int]$Default) {
    $in = $false
    foreach ($l in $ConfigLines) {
        if ($l.StartsWith("## ")) { $in = ($l -ceq "## Settings"); continue }
        if ($in -and $l.StartsWith("|")) {
            $c = @(Split-Row $l)
            if ($c.Count -ge 2 -and $c[0] -ceq $Name) {
                if ($c[1] -match '^[0-9]+$') { return [int]$c[1] }
                return $Default
            }
        }
    }
    return $Default
}

# id, plan, command, limit text, cooldown minutes, max runs per day, covers for
function Get-Agents {
    $in = $false
    $list = [System.Collections.Generic.List[object]]::new()
    foreach ($l in $ConfigLines) {
        if ($l.StartsWith("## ")) { $in = ($l -ceq "## Agents"); continue }
        if (-not ($in -and $l.StartsWith("|"))) { continue }
        $c = @(Split-Row $l)
        if ($c.Count -lt 1 -or $c[0] -ceq "Agent id" -or $c[0] -match '^-+$' -or $c[0] -eq "") { continue }
        while ($c.Count -lt 7) { $c += "" }
        $cmd = $c[2]
        if ($cmd.StartsWith('`')) { $cmd = $cmd.Substring(1) }
        if ($cmd.EndsWith('`')) { $cmd = $cmd.Substring(0, $cmd.Length - 1) }
        $mr = $c[5]; if ($mr -ceq $EmDash) { $mr = "" }
        $cv = $c[6]; if ($cv -ceq $EmDash) { $cv = "" }
        $cool = 60
        if ($c[4] -match '^[0-9]+$') { $cool = [int]$c[4] }
        $list.Add([PSCustomObject]@{ Id = $c[0]; Plan = $c[1]; Command = $cmd; Limits = $c[3]; Cooldown = $cool; MaxRuns = $mr; Covers = $cv })
    }
    return $list.ToArray()
}

# ---- the state -----------------------------------------------------------------------------------------------
New-Item -ItemType Directory -Force -Path $Runs | Out-Null
if (-not (Test-Path -LiteralPath $StateFile -PathType Leaf)) {
    [System.IO.File]::WriteAllText($StateFile, "# Dispatcher state`n`nWritten by factory_dispatch and not committed.`n`n| Key | Value |`n|---|---|`n", $Utf8)
}
function Read-StateLines { return @([System.IO.File]::ReadAllLines($StateFile, $Utf8)) }
function Write-StateLines($Lines) {
    $text = ""
    if (@($Lines).Count -gt 0) { $text = ((@($Lines) -join "`n") + "`n") }
    [System.IO.File]::WriteAllText($StateFile, $text, $Utf8)
}
function Get-StateKeyValue([string]$Line) {
    if (-not $Line.StartsWith("|")) { return $null }
    $c = @(Split-Row $Line)
    if ($c.Count -lt 2) { return $null }
    return @($c[0], $c[1])
}
function Get-State([string]$Key) {
    foreach ($l in (Read-StateLines)) {
        $kv = Get-StateKeyValue $l
        if ($kv -and $kv[0] -ceq $Key) { return $kv[1] }
    }
    return ""
}
function Get-StateNumber([string]$Key) {
    $v = Get-State $Key
    if ($v -match '^[0-9]+') { return [long]$Matches[0] }
    return [long]0
}
function Set-State([string]$Key, [string]$Value) {
    $out = [System.Collections.Generic.List[string]]::new()
    $done = $false
    foreach ($l in (Read-StateLines)) {
        $kv = Get-StateKeyValue $l
        if ($kv -and $kv[0] -ceq $Key) {
            if (-not $done) { $out.Add("| $Key | $Value |") }
            $done = $true
            continue
        }
        $out.Add($l)
    }
    if (-not $done) { $out.Add("| $Key | $Value |") }
    Write-StateLines $out
}
function Remove-State([string]$Key) {
    $out = [System.Collections.Generic.List[string]]::new()
    foreach ($l in (Read-StateLines)) {
        $kv = Get-StateKeyValue $l
        if ($kv -and $kv[0] -ceq $Key) { continue }
        $out.Add($l)
    }
    Write-StateLines $out
}
# drops expired cooldowns and the run counters of other days
function Optimize-State {
    $out = [System.Collections.Generic.List[string]]::new()
    foreach ($l in (Read-StateLines)) {
        $kv = Get-StateKeyValue $l
        if ($kv) {
            if ($kv[0].StartsWith("cooldown:")) {
                $n = [long]0
                if ($kv[1] -match '^[0-9]+') { $n = [long]$Matches[0] }
                if ($n -le $script:Now) { continue }
            }
            if ($kv[0].StartsWith("runs:")) {
                $parts = $kv[0].Split(':')
                if ($parts[$parts.Count - 1] -cne $script:Today) { continue }
            }
        }
        $out.Add($l)
    }
    Write-StateLines $out
}
function Get-MinCooldown {
    $min = $null
    foreach ($l in (Read-StateLines)) {
        $kv = Get-StateKeyValue $l
        if ($kv -and $kv[0].StartsWith("cooldown:")) {
            $n = [long]0
            if ($kv[1] -match '^[0-9]+') { $n = [long]$Matches[0] }
            if ($null -eq $min -or $n -lt $min) { $min = $n }
        }
    }
    return $min
}

# ---- time --------------------------------------------------------------------------------------------------------
function Update-Clock {
    $script:Now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $d = Get-Date
    $script:Sod = [long]($d.Hour * 3600 + $d.Minute * 60 + $d.Second)
    $script:Today = $d.ToString("yyyy-MM-dd", [System.Globalization.CultureInfo]::InvariantCulture)
}
# the local HH:MM of a moment after Now
function Format-Hm([long]$Epoch) {
    $t = ($script:Sod + $Epoch - $script:Now) % 86400
    if ($t -lt 0) { $t += 86400 }
    return ("{0:00}:{1:00}" -f [int][math]::Floor($t / 3600), [int][math]::Floor(($t % 3600) / 60))
}
# the moment of "resets 3:45pm" in an output, or nothing
function Get-ResetEpoch([string]$Text) {
    foreach ($line in @($Text.ToLowerInvariant() -split "`n")) {
        $m = [regex]::Match($line, 'resets +[0-9][0-9]?(:[0-9][0-9])? *(am|pm)?')
        if (-not $m.Success) { continue }
        $s = $m.Value -replace '^resets +', ''
        $ap = ""
        if ($s.Contains("pm")) { $ap = "pm" } elseif ($s.Contains("am")) { $ap = "am" }
        $s = $s -replace ' *(am|pm)', ''
        $p = $s.Split(':')
        $h = [int]$p[0]
        $mi = 0
        if ($p.Count -gt 1 -and $p[1] -ne "") { $mi = [int]$p[1] }
        if ($ap -ceq "pm" -and $h -lt 12) { $h += 12 }
        if ($ap -ceq "am" -and $h -eq 12) { $h = 0 }
        $target = $script:Now - $script:Sod + $h * 3600 + $mi * 60
        if ($target -le $script:Now) { $target += 86400 }
        return [long]$target
    }
    return $null
}
function Test-LimitText([string]$Text, [string]$Patterns) {
    $flat = (@($Text.ToLowerInvariant() -split "`n") -join " ")
    foreach ($pat in @($Patterns.ToLowerInvariant() -split ';')) {
        $q = $pat.Trim()
        if ($q -ne "" -and $flat.Contains($q)) { return $true }
    }
    return $false
}

# ---- what the core says ----------------------------------------------------------------------------------
function Get-NextTask([string]$Agent) {
    $r = Invoke-Core @("next", $Project, $Agent)
    if ($r.Code -ne 0) { return "none" }
    $first = ($r.Out -split "`n" | Select-Object -First 1)
    if ($null -eq $first) { return "none" }
    $first = $first.Trim()
    if ($first -eq "") { return "none" }
    return $first
}
# the open-task line of status for a task, or nothing
function Get-StatusLine([string]$Task) {
    $r = Invoke-Core @("status", $Project)
    if ($r.Code -ne 0) { return "" }
    foreach ($l in @($r.Out -split "`n")) {
        $line = $l.TrimEnd("`r")
        $f = $line -split ' \| '
        if ($f.Count -ge 2 -and $f[0] -ceq $Task) { return $line }
    }
    return ""
}
function Get-AgentRole([string]$Agent) {
    $in = $false
    foreach ($l in @([System.IO.File]::ReadAllLines((Join-Path $Project "AGENTS.md"), $Utf8))) {
        if ($l.StartsWith("## ")) { $in = ($l -ceq "## Agent identity"); continue }
        if ($in -and $l.StartsWith("|")) {
            $c = @(Split-Row $l)
            if ($c.Count -ge 4 -and $c[0] -ceq $Agent) { return $c[3] }
        }
    }
    return ""
}
function Get-LedgerHash {
    return (Get-FileHash -LiteralPath $Ledger -Algorithm SHA256).Hash
}

# ---- one run -------------------------------------------------------------------------------------------------
$script:RunCount = 0
$script:OkCount = 0
$script:LimitCount = 0
$script:FailCount = 0
$TimeoutMin = Get-CfgSetting "Run timeout minutes" 60
$IdleSec = Get-CfgSetting "Idle seconds" 300

# true when the agent holds the task, working on it or with a review answered
function Test-AgentHolds([string]$Line, [string]$Agent) {
    if (-not $Line) { return $false }
    $f = $Line -split ' \| '
    return ($f.Count -ge 4 -and $f[2] -ceq $Agent -and ($f[3] -ceq "IN_PROGRESS" -or $f[3].StartsWith("REVIEW")))
}

function Invoke-AgentRun($Row, [string]$Task, [string]$Covered) {
    $agent = $Row.Id
    $script:RunCount++
    $n = $script:RunCount
    if ($Covered) { Write-Log "run ${n}: $agent on $Task (covers $Covered)" }
    else { Write-Log "run ${n}: $agent on $Task" }
    $runKey = "runs:${agent}:$($script:Today)"
    Set-State $runKey ([string]((Get-StateNumber $runKey) + 1))
    $runId = "{0}-{1:000}-{2}" -f (Get-Date).ToString("yyyyMMddTHHmmss", [System.Globalization.CultureInfo]::InvariantCulture), $n, $agent
    $promptFile = Join-Path $Runs "$runId.prompt.md"
    $outFile = Join-Path $Runs "$runId.out"
    $line = Get-StatusLine $Task
    $phase = "SPEC"
    $lane = "NORMAL"
    if ($line) {
        $tail = ($line -split ' \| ')[-1]
        if ($tail.Contains(" ")) {
            $phase = $tail.Substring(0, $tail.IndexOf(" "))
            $lane = $tail.Substring($tail.IndexOf(" ") + 1)
        }
    }
    else {
        foreach ($rl in @([System.IO.File]::ReadAllLines((Join-Path (Join-Path $Project "docs") "Roadmap.md"), $Utf8))) {
            if ($rl.Contains("| $Task |") -and $rl.Contains("Lane: FAST")) { $phase = "GREEN"; $lane = "FAST"; break }
        }
    }
    $role = Get-AgentRole $agent
    $name = Split-Path -Leaf $Project
    $text = [System.IO.File]::ReadAllText($PromptTemplate, $Utf8)
    $text = $text.Replace("{AGENT}", $agent).Replace("{ROLE}", $role).Replace("{PROJECT}", $name).Replace("{TASK}", $Task).Replace("{PHASE}", $phase).Replace("{LANE}", $lane)
    [System.IO.File]::WriteAllText($promptFile, $text, $Utf8)
    $final = $Row.Command.Replace("{PROMPT_FILE}", $promptFile)
    $before = Get-LedgerHash
    $envVars = @{ FACTORY_AGENT = $agent; FACTORY_TASK = $Task; FACTORY_PROJECT = $Project; FACTORY_PROMPT_FILE = $promptFile }
    if ($IsWin) { $res = Invoke-Captured "cmd.exe" ("/d /s /c " + '"' + $final + '"') $Project $envVars ($TimeoutMin * 60) }
    else { $res = Invoke-Captured "/bin/sh" ("-c " + (ConvertTo-ArgText $final)) $Project $envVars ($TimeoutMin * 60) }
    [System.IO.File]::WriteAllText($outFile, ($res.Out + $res.Err), $Utf8)
    $after = Get-LedgerHash
    Update-Clock
    $rc = $res.Code
    if ($rc -ne 0 -and (Test-LimitText ($res.Out + "`n" + $res.Err) $Row.Limits)) {
        $script:LimitCount++
        $until = Get-ResetEpoch ($res.Out + "`n" + $res.Err)
        if ($null -eq $until) { $until = $script:Now + [long]$Row.Cooldown * 60 }
        Set-State "cooldown:$($Row.Plan)" ([string]$until)
        Write-Log "run $n limit: $agent hit its limit, plan $($Row.Plan) in cooldown until $(Format-Hm $until)"
        $line = Get-StatusLine $Task
        if (Test-AgentHolds $line $agent) {
            [void](Invoke-Core @("checkpoint", $Project, $agent, $Task, "limit reached", "resume after the cooldown"))
            $pr = Invoke-Core @("pause", $Project, $agent, $Task, "LIMITE", "limit until $(Format-Hm $until)")
            if ($pr.Code -eq 0) { Write-Log "run $n paused $Task (LIMITE) for $agent" }
            else { Write-Log "run $n could not pause $Task for $agent (pause was refused)" }
        }
    }
    elseif ($rc -eq 0 -and $before -cne $after) {
        $script:OkCount++
        Remove-State "fails:${agent}:$Task"
        Write-Log "run $n ok"
    }
    else {
        $script:FailCount++
        $failKey = "fails:${agent}:$Task"
        $fails = (Get-StateNumber $failKey) + 1
        Set-State $failKey ([string]$fails)
        Write-Log "run $n failed (exit $rc), $fails failure(s) for $agent on $Task"
        $line = Get-StatusLine $Task
        if ($fails -ge 3 -and (Test-AgentHolds $line $agent)) {
            [void](Invoke-Core @("checkpoint", $Project, $agent, $Task, "three runs without progress", "needs a person"))
            $pr = Invoke-Core @("pause", $Project, $agent, $Task, "BLOQUEO", "dispatcher: 3 runs without progress")
            if ($pr.Code -eq 0) {
                Remove-State $failKey
                Write-Log "run $n blocked $Task after 3 failures"
            }
            else { Write-Log "run $n could not block $Task (pause was refused); $agent is skipped on it until the fails row of .factory/state.md is deleted" }
        }
    }
}

# ---- who runs next ----------------------------------------------------------------------------------------------
# true when the plan is not cooling down and the agent has runs left today
function Test-Available([string]$Plan, $Row) {
    $cd = Get-StateNumber "cooldown:$Plan"
    if ($cd -gt $script:Now) { return $false }
    if ($Row.MaxRuns -match '^[0-9]+$') {
        if ((Get-StateNumber "runs:$($Row.Id):$($script:Today)") -ge [long]$Row.MaxRuns) { return $false }
    }
    return $true
}
function Test-IsReview([string]$Task) {
    $f = (Get-StatusLine $Task) -split ' \| '
    return ($f.Count -ge 4 -and $f[3].StartsWith("REVIEW"))
}
# the agent row to run and its task, or nothing
function Select-Next {
    $agents = @(Get-Agents)
    foreach ($row in $agents) {
        if (-not (Test-Available $row.Plan $row)) { continue }
        $t = Get-NextTask $row.Id
        if ($t -ne "none") {
            $pf = Get-StateNumber "fails:$($row.Id):$t"
            if ($pf -ge 3) { $t = "none" }
            elseif ($pf -ge 2 -and (Test-IsReview $t)) { $t = "none" }
        }
        if ($t -ne "none") { return [PSCustomObject]@{ Row = $row; Task = $t; Covered = "" } }
        if ($row.Covers) {
            $cov = $agents | Where-Object { $_.Id -ceq $row.Covers } | Select-Object -First 1
            if (-not $cov) { continue }
            $ct = Get-NextTask $row.Covers
            if ($ct -ne "none" -and (Test-IsReview $ct) -and (Get-StateNumber "fails:$($row.Id):$ct") -lt 3) {
                $out = (-not (Test-Available $cov.Plan $cov))
                if ((Get-StateNumber "fails:$($row.Covers):$ct") -ge 2) { $out = $true }
                if ($out) { return [PSCustomObject]@{ Row = $row; Task = $ct; Covered = $row.Covers } }
            }
        }
    }
    return $null
}

# Sleeps in steps of 30 seconds at most and stops early when .factory/STOP appears.
function Wait-Steps([long]$Seconds) {
    $left = $Seconds
    while ($left -gt 0 -and -not (Test-Path -LiteralPath $StopFile)) {
        $step = [Math]::Min($left, 30)
        Start-Sleep -Seconds $step
        $left -= $step
    }
}

# ---- the loop ----------------------------------------------------------------------------------------------------
$noSleep = ($env:PROJECT_DOCS_DISPATCH_NO_SLEEP -ceq "1")
while ($true) {
    if (Test-Path -LiteralPath $StopFile) { Write-Log "stop requested"; break }
    Update-Clock
    Optimize-State
    $pick = Select-Next
    if ($pick) {
        Invoke-AgentRun $pick.Row $pick.Task $pick.Covered
        if ($Once) { break }
        continue
    }
    $soon = Get-MinCooldown
    if ($null -ne $soon) {
        Write-Log "sleep until $(Format-Hm $soon)"
        if ($noSleep -or $Once) { break }
        $wait = $soon - $script:Now
        if ($wait -le 0) { $wait = 1 }
        Wait-Steps $wait
        continue
    }
    if ($Watch -and -not $Once) {
        Write-Log "waiting $IdleSec seconds for new work"
        if ($noSleep) { break }
        Wait-Steps $IdleSec
        continue
    }
    Write-Log "nothing to do"
    break
}
Write-Log "summary: runs=$($script:RunCount) ok=$($script:OkCount) limits=$($script:LimitCount) failures=$($script:FailCount)"
