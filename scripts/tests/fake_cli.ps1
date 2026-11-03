<#
.SYNOPSIS
A stand-in for the claude and gemini CLIs in the dispatcher tests.

.DESCRIPTION
fake_cli.ps1 <prompt-file>

It never touches a real quota. It reads one line per run from the file named by FAKE_CLI_SCRIPT,
the first line that starts with "<agent>: " where the agent is FACTORY_AGENT (the dispatcher
exports it), and removes that line. A line is a list of actions separated by " ;; ":

  ok:<command of project_docs>   the project argument is added after the command, for example
                                 ok:handoff claude-dev F01-E01-T01 "done" exit=0 gemini-qa
  tryok:<command of project_docs> the same, but a failure does not end the line
  exec:<command line>            runs a command in the project (a test, sed...); its exit code
                                 is the value of {EXIT} in the actions that follow
  env:<NAME>                     prints NAME=<value>, or NAME=unset (to see what the dispatcher hands over)
  write:<path>=<text>            writes a file in the project; \n in the text is a new line (only that)
  git:<arguments>                runs git in the project
  limit:<text>                   prints the text and exits 1, like a CLI that hit its quota
  fail:<text>                    prints the text on stderr and exits 1

Arguments are plain words or "double quoted" strings, so the same line works in fake_cli.sh.
A run with no line left for its agent exits 3. FAKE_CLI_LOG, if set, gets one line per run.
#>
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Rest
)

$ErrorActionPreference = "Stop"
$Utf8 = New-Object System.Text.UTF8Encoding($false)
$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
$Core = Join-Path (Join-Path $Here "..") "project_docs.ps1"
$Agent = [string]$env:FACTORY_AGENT
$Task = [string]$env:FACTORY_TASK
$Project = [string]$env:FACTORY_PROJECT
if (-not $Project) { $Project = "." }
$ScriptFile = [string]$env:FAKE_CLI_SCRIPT
$PsExe = (Get-Process -Id $PID).Path
$IsWin = ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT)

# plain words and "double quoted" strings
function Split-Words([string]$Text) {
    $words = [System.Collections.Generic.List[string]]::new()
    foreach ($m in [regex]::Matches($Text, '"([^"]*)"|(\S+)')) {
        if ($m.Groups[1].Success) { $words.Add($m.Groups[1].Value) } else { $words.Add($m.Groups[2].Value) }
    }
    return $words.ToArray()
}

if (-not $ScriptFile -or -not (Test-Path -LiteralPath $ScriptFile -PathType Leaf)) {
    [Console]::Error.WriteLine("fake_cli: FAKE_CLI_SCRIPT does not name a file")
    exit 3
}
$lines = @([System.IO.File]::ReadAllLines($ScriptFile, $Utf8))
$prefix = "$Agent`: "
$hit = -1
for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i].StartsWith($prefix, [System.StringComparison]::Ordinal)) { $hit = $i; break }
}
if ($hit -lt 0) {
    [Console]::Error.WriteLine("fake_cli: no action left for $Agent")
    exit 3
}
$line = $lines[$hit].Substring($prefix.Length)
$keep = [System.Collections.Generic.List[string]]::new()
for ($i = 0; $i -lt $lines.Count; $i++) { if ($i -ne $hit) { $keep.Add($lines[$i]) } }
$text = ""
if ($keep.Count -gt 0) { $text = (($keep.ToArray()) -join "`n") + "`n" }
[System.IO.File]::WriteAllText($ScriptFile, $text, $Utf8)
if ($env:FAKE_CLI_LOG) { [System.IO.File]::AppendAllText($env:FAKE_CLI_LOG, "$Agent $Task $line`n", $Utf8) }

$lastExit = 0
foreach ($act in @($line -split ' ;; ')) {
    $colon = $act.IndexOf(":")
    $kind = $act
    $payload = ""
    if ($colon -ge 0) { $kind = $act.Substring(0, $colon); $payload = $act.Substring($colon + 1) }
    $payload = $payload.Replace("{EXIT}", [string]$lastExit)
    switch -CaseSensitive ($kind) {
        { $_ -ceq "ok" -or $_ -ceq "tryok" } {
            $w = @(Split-Words $payload)
            $cmdArgs = @("-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", $Core, $w[0], $Project)
            if ($w.Count -gt 1) { $cmdArgs += $w[1..($w.Count - 1)] }
            & $PsExe @cmdArgs
            $rc = $LASTEXITCODE
            if ($kind -ceq "tryok") { $lastExit = $rc } elseif ($rc -ne 0) { exit 1 }
        }
        "exec" {
            if ($IsWin) { & cmd.exe /d /s /c ('cd /d "' + $Project + '" && ' + $payload) }
            else { & /bin/sh -c ('cd "' + $Project + '" && ' + $payload) }
            $lastExit = $LASTEXITCODE
        }
        "env" {
            $v = [Environment]::GetEnvironmentVariable($payload)
            if ($v) { [Console]::Out.WriteLine("$payload=$v") } else { [Console]::Out.WriteLine("$payload=unset") }
        }
        "write" {
            $eq = $payload.IndexOf("=")
            $path = $payload.Substring(0, $eq)
            $body = $payload.Substring($eq + 1).Replace('\n', "`n")
            $full = Join-Path $Project $path
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $full) | Out-Null
            [System.IO.File]::WriteAllText($full, $body + "`n", $Utf8)
        }
        "git" {
            $w = @(Split-Words $payload)
            & git -C $Project @w
            if ($LASTEXITCODE -ne 0) { exit 1 }
        }
        "limit" {
            [Console]::Out.WriteLine($payload)
            exit 1
        }
        "fail" {
            if (-not $payload) { $payload = "fake_cli: failed" }
            [Console]::Error.WriteLine($payload)
            exit 1
        }
        default {
            [Console]::Error.WriteLine("fake_cli: unknown action $kind")
            exit 2
        }
    }
}
exit 0
