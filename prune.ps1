# Prunes what merged work leaves behind in one repo: worktrees whose branch is merged into main
# and that hold no changes, then local branches merged into main and checked out nowhere. Lists
# (never deletes) unmerged branches older than -StaleDays.
#
#   powershell -File deps/repokit/prune.ps1 [-Repo <path>] [-Main main] [-DryRun] [-StaleDays 60]
#
# Safe by construction:
# - a branch goes with `git branch -d` (git itself refuses an unmerged one), never -D;
# - a worktree goes only when its branch is merged and `git status --porcelain` (untracked files
#   too) is empty; a detached or locked worktree stays;
# - before `git worktree remove`, links inside it (node_modules junctions to the main checkout,
#   scripts/worktree.ps1) are removed as links, so nothing deletes through them.
# Keep this file ASCII: Windows PowerShell 5.1 reads a BOM-less file in the ANSI code page.
param(
    [string]$Repo = (Get-Location).Path,
    [string]$Main = 'main',
    [switch]$DryRun,
    [int]$StaleDays = 60
)
$ErrorActionPreference = 'Stop'

function Get-Git {
    if ($env:PIVETTA_GIT) { return $env:PIVETTA_GIT }
    $all = @(Get-Command git -All -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source)
    $win = $all | Where-Object { $_ -match '\\cmd\\git\.exe$' } | Select-Object -First 1
    if ($win) { return $win }
    if ($all) { return $all[0] }
    throw 'no git on PATH (or set PIVETTA_GIT)'
}
$git = Get-Git
function G { $out = & $git -C $Repo @args; if ($LASTEXITCODE -ne 0) { throw "git $($args -join ' ') failed" }; $out }

$top = "$(G rev-parse --show-toplevel)".Trim()
$Repo = $top
G rev-parse --verify -q "refs/heads/$Main" | Out-Null
$merged = @(G for-each-ref --merged "refs/heads/$Main" --format='%(refname:short)' refs/heads/ | Where-Object { $_ -and $_ -ne $Main })
Write-Host "== $Repo ($($merged.Count) branch(es) merged into $Main)" -ForegroundColor Cyan

# ---- worktrees: `git worktree list --porcelain` blocks
$trees = @(); $cur = $null
foreach ($line in @(G worktree list --porcelain) + '') {
    if ($line -like 'worktree *') { $cur = @{ path = $line.Substring(9); branch = $null; locked = $false; detached = $false } }
    elseif ($line -like 'branch refs/heads/*') { $cur.branch = $line.Substring(18) }
    elseif ($line -eq 'detached') { $cur.detached = $true }
    elseif ($line -like 'locked*') { $cur.locked = $true }
    elseif ($line -eq '' -and $cur) { $trees += $cur; $cur = $null }
}
$mainTree = (Resolve-Path $top).Path

# Removes the links (junctions, symlinks) under $dir down to two levels, as links.
function Remove-Links([string]$dir) {
    $items = @(Get-ChildItem -LiteralPath $dir -Force -Directory -ErrorAction SilentlyContinue)
    $items += @($items | Where-Object { -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) } | ForEach-Object { Get-ChildItem -LiteralPath $_.FullName -Force -Directory -ErrorAction SilentlyContinue })
    $items += @($items | Where-Object { -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) } | ForEach-Object { Get-ChildItem -LiteralPath $_.FullName -Force -Directory -Filter node_modules -ErrorAction SilentlyContinue })
    foreach ($i in $items | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint } | Sort-Object FullName -Unique) {
        # Directory.Delete on a reparse point removes the link, not what it points to
        if ($DryRun) { Write-Host "   would unlink $($i.FullName)" } else { [IO.Directory]::Delete($i.FullName) }
    }
}

$removedTrees = 0
foreach ($t in $trees) {
    $p = $t.path -replace '/', '\'
    if ((Resolve-Path -LiteralPath $p -ErrorAction SilentlyContinue).Path -eq $mainTree) { continue }
    if (-not (Test-Path -LiteralPath $p)) { Write-Host "   stale entry $p (git worktree prune)"; continue }
    $why = if ($t.locked) { 'locked' } elseif ($t.detached) { 'detached' } elseif ($merged -notcontains $t.branch) { "$($t.branch) not merged" } else { $null }
    if (-not $why) {
        $dirty = "$(& $git -C $p status --porcelain 2>$null)".Trim()
        if ($LASTEXITCODE -ne 0) { $why = 'git status failed' } elseif ($dirty) { $why = 'has changes' }
    }
    if ($why) { Write-Host "   keep   $p ($why)"; continue }
    Write-Host "   remove $p ($($t.branch), merged, clean)" -ForegroundColor Yellow
    if (-not $DryRun) {
        Remove-Links $p
        G worktree remove --force $p | Out-Null
    }
    $removedTrees++
}
if (-not $DryRun) { G worktree prune | Out-Null }

# ---- branches: merged and checked out in no remaining worktree
$busy = @(G worktree list --porcelain | Where-Object { $_ -like 'branch refs/heads/*' } | ForEach-Object { $_.Substring(18) })
$deleted = 0
foreach ($b in $merged) {
    if ($busy -contains $b) { Write-Host "   keep   branch $b (checked out)"; continue }
    if ($DryRun) { Write-Host "   would delete branch $b" } else { G branch -d $b | Out-Null }
    $deleted++
}

# ---- stale unmerged branches: listed only
$cut = [DateTimeOffset]::UtcNow.AddDays(-$StaleDays).ToUnixTimeSeconds()
$stale = @(G for-each-ref --no-merged "refs/heads/$Main" --format='%(committerdate:unix) %(refname:short)' refs/heads/ | Where-Object { $_ } | ForEach-Object {
    $parts = $_ -split ' ', 2; if ([int64]$parts[0] -lt $cut) { $parts[1] } })
$left = @(G for-each-ref --format='%(refname:short)' refs/heads/).Count
if ($DryRun) { Write-Host "   would remove $removedTrees worktree(s) and delete $deleted branch(es) ($left local branches today)" }
else { Write-Host "   removed $removedTrees worktree(s), deleted $deleted branch(es); $left local branch(es) left" }
if ($stale) { Write-Host "   unmerged and older than $StaleDays days (review by hand): $($stale -join ', ')" }
