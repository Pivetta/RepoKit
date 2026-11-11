#!/usr/bin/env bash
# Prunes what merged work leaves behind in one repo: worktrees whose branch is merged into main
# and that hold no changes, then local branches merged into main and checked out nowhere. Lists
# (never deletes) unmerged branches older than -StaleDays. prune.ps1 for bash, same flags and output.
#
#   bash deps/repokit/prune.sh [-Repo <path>] [-Main main] [-DryRun] [-StaleDays 60]
#   (also --repo, --main, --dry-run, --stale-days)
#
# Safe by construction:
# - a branch goes with `git branch -d` (git itself refuses an unmerged one), never -D;
# - a worktree goes only when its branch is merged and `git status --porcelain` (untracked files
#   too) is empty; a detached or locked worktree stays;
# - before `git worktree remove`, links inside it (node_modules symlinks to the main checkout)
#   are removed as links, so nothing deletes through them.
set -euo pipefail

repo=$PWD
main=main
dry=''
stale_days=60
usage() { echo 'usage: prune.sh [-Repo <path>] [-Main main] [-DryRun] [-StaleDays 60]' >&2; exit 2; }
while [ $# -gt 0 ]; do
    case ${1,,} in
        -repo | --repo) [ $# -ge 2 ] || usage; repo=$2; shift 2 ;;
        -main | --main) [ $# -ge 2 ] || usage; main=$2; shift 2 ;;
        -dryrun | --dryrun | --dry-run) dry=1; shift ;;
        -staledays | --staledays | --stale-days) [ $# -ge 2 ] || usage; stale_days=$2; shift 2 ;;
        *) usage ;;
    esac
done

git=${PIVETTA_GIT:-git}
command -v "$git" > /dev/null || { echo 'no git on PATH (or set PIVETTA_GIT)' >&2; exit 1; }
if [ -t 1 ]; then cyan=$'\e[36m'; yellow=$'\e[33m'; off=$'\e[0m'; else cyan=''; yellow=''; off=''; fi
G() {
    if ! "$git" -C "$repo" "$@"; then echo "git $* failed" >&2; exit 1; fi
}

top=$(G rev-parse --show-toplevel)
repo=$top
G rev-parse --verify -q "refs/heads/$main" > /dev/null
out=$(G for-each-ref --merged "refs/heads/$main" --format='%(refname:short)' refs/heads/)
merged=()
while IFS= read -r b; do
    if [ -n "$b" ] && [ "$b" != "$main" ]; then merged+=("$b"); fi
done <<< "$out"
echo "${cyan}== $repo (${#merged[@]} branch(es) merged into $main)${off}"

is_merged() {
    local b
    for b in "${merged[@]}"; do [ "$b" = "$1" ] && return 0; done
    return 1
}

# ---- worktrees: `git worktree list --porcelain` blocks
out=$(G worktree list --porcelain)
t_path=() t_branch=() t_locked=() t_detached=()
cur=''
br='' lk='' dt=''
while IFS= read -r line; do
    case $line in
        'worktree '*) cur=${line#worktree }; br=''; lk=''; dt='' ;;
        'branch refs/heads/'*) br=${line#branch refs/heads/} ;;
        detached) dt=1 ;;
        locked*) lk=1 ;;
        '')
            if [ -n "$cur" ]; then
                t_path+=("$cur"); t_branch+=("$br"); t_locked+=("$lk"); t_detached+=("$dt")
                cur=''
            fi
            ;;
    esac
done <<< "$out"$'\n'
main_tree=$(realpath "$top")

# Removes the symlinks under $1 down to two levels, and node_modules links a level below, as links.
remove_links() {
    local l
    # (find does not follow links, so nothing below a linked folder is looked at)
    { find "$1" -mindepth 1 -maxdepth 2 -type l; find "$1" -mindepth 3 -maxdepth 3 -type l -name node_modules; } 2> /dev/null | sort -u |
        while IFS= read -r l; do
            # rm on a symlink removes the link, not what it points to
            if [ -n "$dry" ]; then echo "   would unlink $l"; else rm -f -- "$l"; fi
        done
}

removed_trees=0
for ((i = 0; i < ${#t_path[@]}; i++)); do
    p=${t_path[i]}
    if [ "$(realpath -e -- "$p" 2> /dev/null || true)" = "$main_tree" ]; then continue; fi
    if [ ! -e "$p" ]; then echo "   stale entry $p (git worktree prune)"; continue; fi
    why=''
    if [ -n "${t_locked[i]}" ]; then why=locked
    elif [ -n "${t_detached[i]}" ]; then why=detached
    elif ! is_merged "${t_branch[i]}"; then why="${t_branch[i]} not merged"
    fi
    if [ -z "$why" ]; then
        if ! dirty=$("$git" -C "$p" status --porcelain 2> /dev/null); then why='git status failed'
        elif [ -n "$dirty" ]; then why='has changes'
        fi
    fi
    if [ -n "$why" ]; then echo "   keep   $p ($why)"; continue; fi
    echo "${yellow}   remove $p (${t_branch[i]}, merged, clean)${off}"
    if [ -z "$dry" ]; then
        remove_links "$p"
        G worktree remove --force "$p" > /dev/null
    fi
    removed_trees=$((removed_trees + 1))
done
if [ -z "$dry" ]; then G worktree prune > /dev/null; fi

# ---- branches: merged and checked out in no remaining worktree
out=$(G worktree list --porcelain)
busy=()
while IFS= read -r line; do
    case $line in 'branch refs/heads/'*) busy+=("${line#branch refs/heads/}") ;; esac
done <<< "$out"
is_busy() {
    local b
    for b in "${busy[@]}"; do [ "$b" = "$1" ] && return 0; done
    return 1
}
deleted=0
for b in "${merged[@]}"; do
    if is_busy "$b"; then echo "   keep   branch $b (checked out)"; continue; fi
    if [ -n "$dry" ]; then echo "   would delete branch $b"; else G branch -d "$b" > /dev/null; fi
    deleted=$((deleted + 1))
done

# ---- stale unmerged branches: listed only
cut=$(($(date -u +%s) - stale_days * 86400))
out=$(G for-each-ref --no-merged "refs/heads/$main" --format='%(committerdate:unix) %(refname:short)' refs/heads/)
stale=()
while IFS=' ' read -r when name; do
    if [ -n "$when" ] && [ "$when" -lt "$cut" ]; then stale+=("$name"); fi
done <<< "$out"
out=$(G for-each-ref --format='%(refname:short)' refs/heads/)
left=$(grep -c . <<< "$out" || true)
if [ -n "$dry" ]; then echo "   would remove $removed_trees worktree(s) and delete $deleted branch(es) ($left local branches today)"
else echo "   removed $removed_trees worktree(s), deleted $deleted branch(es); $left local branch(es) left"; fi
if [ ${#stale[@]} -gt 0 ]; then
    joined=$(printf '%s, ' "${stale[@]}")
    echo "   unmerged and older than $stale_days days (review by hand): ${joined%, }"
fi
