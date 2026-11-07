# The step runner every Pivetta repo's scripts/check.ps1 uses (RepoKit, the deps/repokit submodule).
# A repo's check.ps1 keeps only its parameters and its steps:
#
#   param([string[]]$Only, [string[]]$Skip, [switch]$List)
#   $root = Split-Path -Parent $PSScriptRoot
#   $kit = Join-Path $root 'deps/repokit/check.ps1'
#   if (-not (Test-Path $kit)) { Write-Host 'deps/repokit is missing: git submodule update --init deps/repokit'; exit 2 }
#   . $kit
#   $steps = @(
#       @{ name = 'deps'; what = 'deps/ submodules (scripts/deps.mts check)'; run = { x node scripts/deps.mts check } }
#       @{ name = 'web';  what = 'web build'; dir = 'web'; run = { x npm.cmd run build } }
#   )
#   exit (Invoke-Check $steps $root $Only $Skip $List)
#
# A step: name, what (shown by -List), run (a script block), dir (relative to the root; default the
# root), warn = $true (a failure is reported but does not fail the run).
# -Only / -Skip take names, also as one comma-separated string (powershell -File passes "a,b" so).
# Keep this file ASCII: Windows PowerShell 5.1 reads a BOM-less file in the ANSI code page.

$ErrorActionPreference = 'Continue'

# Runs a native command and throws when it exits non-zero.
function x {
    $exe = $args[0]; $rest = @($args | Select-Object -Skip 1)
    & $exe @rest
    if ($LASTEXITCODE -ne 0) { throw "$exe $($rest -join ' ') exited $LASTEXITCODE" }
}

# Runs a block with environment variables set, restoring them afterwards.
function withEnv([hashtable]$vars, [scriptblock]$block) {
    $old = @{}
    foreach ($k in $vars.Keys) { $old[$k] = [Environment]::GetEnvironmentVariable($k); [Environment]::SetEnvironmentVariable($k, $vars[$k]) }
    try { & $block } finally { foreach ($k in $old.Keys) { [Environment]::SetEnvironmentVariable($k, $old[$k]) } }
}

# Runs a block with a vite dev server up on `port` (started from the current folder, which needs
# node_modules/vite), waiting until `url` answers; stopped afterwards.
function withDevServer([int]$port, [string]$url, [scriptblock]$block) {
    $vite = Start-Process -PassThru -WindowStyle Hidden -FilePath node -ArgumentList 'node_modules/vite/bin/vite.js', '--port', "$port", '--strictPort'
    try {
        $up = $false
        for ($i = 0; $i -lt 60 -and -not $up; $i++) {
            Start-Sleep -Seconds 1
            try { Invoke-WebRequest -UseBasicParsing -TimeoutSec 2 $url | Out-Null; $up = $true } catch {}
        }
        if (-not $up) { throw "the dev server did not come up on port $port ($url)" }
        & $block
    } finally {
        Stop-Process -Id $vite.Id -Force -ErrorAction SilentlyContinue
    }
}

# Runs the steps (filtered by -Only / -Skip; -List prints them) and returns the exit code:
# 0 all ok (or warn), 1 a step failed, 2 no step matched.
function Invoke-Check([object[]]$steps, [string]$root, [string[]]$Only, [string[]]$Skip, [bool]$List) {
    $Only = @($Only | ForEach-Object { $_ -split ',' } | Where-Object { $_ })
    $Skip = @($Skip | ForEach-Object { $_ -split ',' } | Where-Object { $_ })
    if ($List) {
        $steps | ForEach-Object { Write-Host ('{0,-12} {1}{2}' -f $_.name, $_.what, $(if ($_.warn) { ' (warn only)' } else { '' })) }
        return 0
    }
    $unknown = @($Only + $Skip | Where-Object { $n = $_; -not ($steps | Where-Object { $_.name -eq $n }) })
    if ($unknown) { Write-Host "no step named $($unknown -join ', '); -List shows them"; return 2 }
    $run = @($steps | Where-Object { (-not $Only -or $Only -contains $_.name) -and -not ($Skip -contains $_.name) })
    if (-not $run) { Write-Host 'no steps match; -List shows them'; return 2 }

    $results = @()
    foreach ($s in $run) {
        Write-Host "`n=== $($s.name): $($s.what)" -ForegroundColor Cyan
        $dir = if ($s.dir) { Join-Path $root $s.dir } else { $root }
        $clock = [Diagnostics.Stopwatch]::StartNew()
        Push-Location $dir
        # Out-Host: a step's output goes to the console as it comes, not into this function's result
        try { & $s.run | Out-Host; $ok = $true; $why = '' } catch { $ok = $false; $why = "$_" } finally { Pop-Location }
        $state = if ($ok) { 'ok' } elseif ($s.warn) { 'WARN' } else { 'FAIL' }
        $results += [pscustomobject]@{ step = $s.name; result = $state; seconds = [int]$clock.Elapsed.TotalSeconds; note = $why }
    }

    Write-Host "`n=== summary" -ForegroundColor Cyan
    $results | Format-Table -AutoSize | Out-String | Write-Host
    if ($results | Where-Object { $_.result -eq 'FAIL' }) { return 1 }
    return 0
}
