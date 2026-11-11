#!/usr/bin/env bash
# The step runner every Pivetta repo's scripts/check.sh uses (RepoKit, the deps/repokit submodule):
# check.ps1 for bash, with the same flags, output and exit codes. Sourced, not run.
# A repo's check.sh keeps only its steps:
#
#   #!/usr/bin/env bash
#   set -euo pipefail
#   root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
#   kit="$root/deps/repokit/check.sh"
#   [ -f "$kit" ] || { echo 'deps/repokit is missing: git submodule update --init deps/repokit'; exit 2; }
#   . "$kit"
#   step deps 'deps/ submodules (scripts/deps.mts check)'
#   run_deps() { x node scripts/deps.mts check; }
#   step web 'web build' dir=web
#   run_web() { x npm run build; }
#   invoke_check "$root" "$@"
#
# step NAME WHAT [dir=PATH] [warn]: dir is relative to the root (default the root); warn: a failure
# is reported but does not fail the run. run_NAME is the step's body. It runs in a subshell of its
# own, from its dir, with `set -e`: a failing command ends the step, and an `export` or `cd` stays
# inside it. Call invoke_check as a plain statement (not after `if`, `&&` or `||`, where bash
# switches `set -e` off).
# Flags: -Only a,b  -Skip a,b  -List (also --only, --skip, --list, --only=a,b; any case).
#
# Helpers, as in check.ps1:
#   x CMD ARGS...                   runs a command; a non-zero exit ends the step, noted in the summary
#   withEnv K=V [K=V...] -- CMD...  runs CMD with those variables set (only for CMD)
#   withDevServer PORT URL CMD...   runs CMD with a vite dev server up on PORT (started from the
#                                   current folder, which needs node_modules/vite), once URL answers
#                                   (curl); stopped afterwards

set -euo pipefail

_check_names=()
_check_whats=()
_check_dirs=()
_check_warns=()
_check_note=''

if [ -t 1 ]; then _check_cyan=$'\e[36m'; _check_off=$'\e[0m'; else _check_cyan=''; _check_off=''; fi

# Registers a step: step NAME WHAT [dir=PATH] [warn]; its body is the function run_NAME.
step() {
    local name=$1 what=$2 dir='' warn='' opt
    shift 2
    for opt in "$@"; do
        case $opt in
            dir=*) dir=${opt#dir=} ;;
            warn) warn=1 ;;
            *) echo "step $name: unknown option $opt" >&2; return 2 ;;
        esac
    done
    _check_names+=("$name"); _check_whats+=("$what"); _check_dirs+=("$dir"); _check_warns+=("$warn")
}

# Runs a command; when it exits non-zero, notes why and ends the step (check.ps1's throw).
x() {
    local rc=0
    "$@" || rc=$?
    if [ "$rc" -ne 0 ]; then
        if [ -n "$_check_note" ]; then printf '%s exited %s' "$*" "$rc" > "$_check_note"; fi
        exit "$rc"
    fi
}

# withEnv K=V [K=V...] -- CMD ARGS...: CMD with those variables set; they are gone afterwards.
withEnv() {
    local vars=()
    while [ $# -gt 0 ] && [ "$1" != -- ]; do vars+=("$1"); shift; done
    [ $# -gt 0 ] && shift
    local rc=0
    ( export "${vars[@]}"; "$@" ) || rc=$?
    if [ "$rc" -ne 0 ]; then exit "$rc"; fi
}

# withDevServer PORT URL CMD ARGS...: CMD with a vite dev server up on PORT, waiting until URL
# answers; stopped afterwards.
withDevServer() {
    local port=$1 url=$2 up='' i rc=0
    shift 2
    node node_modules/vite/bin/vite.js --port "$port" --strictPort > /dev/null 2>&1 &
    local vite=$!
    for ((i = 0; i < 60; i++)); do
        sleep 1
        if curl -fsS -o /dev/null --max-time 2 "$url" 2> /dev/null; then up=1; break; fi
    done
    if [ -z "$up" ]; then
        kill "$vite" 2> /dev/null || true
        if [ -n "$_check_note" ]; then printf 'the dev server did not come up on port %s (%s)' "$port" "$url" > "$_check_note"; fi
        exit 1
    fi
    ( "$@" ) || rc=$?
    kill "$vite" 2> /dev/null || true
    wait "$vite" 2> /dev/null || true
    if [ "$rc" -ne 0 ]; then exit "$rc"; fi
}

# Splits a comma-separated list into the named array: _check_split VAR "a,b".
_check_split() {
    local -n _into=$1
    local part
    local -a parts
    IFS=, read -ra parts <<< "$2"
    for part in "${parts[@]}"; do [ -n "$part" ] && _into+=("$part"); done
    return 0
}

_check_has() { # _check_has NAME LIST...
    local n=$1 e
    shift
    for e in "$@"; do [ "$e" = "$n" ] && return 0; done
    return 1
}

# Runs the steps (filtered by -Only / -Skip; -List prints them) and returns the exit code:
# 0 all ok (or warn), 1 a step failed, 2 no step matched.
invoke_check() {
    local root=$1
    shift
    local only=() skip=() list='' arg val
    while [ $# -gt 0 ]; do
        arg=${1,,}
        case $arg in
            -only=* | --only=* | -skip=* | --skip=*) val=${1#*=}; arg=${arg%%=*} ;;
            -only | --only | -skip | --skip)
                if [ $# -lt 2 ]; then echo "$1 needs a step name"; return 2; fi
                val=$2; shift ;;
            -list | --list) list=1; shift; continue ;;
            *) echo "unknown argument $1 (flags: -Only a,b  -Skip a,b  -List)"; return 2 ;;
        esac
        shift
        case $arg in
            *only) _check_split only "$val" ;;
            *) _check_split skip "$val" ;;
        esac
    done

    local n=${#_check_names[@]} i
    if [ -n "$list" ]; then
        for ((i = 0; i < n; i++)); do
            printf '%-12s %s%s\n' "${_check_names[i]}" "${_check_whats[i]}" "$([ -n "${_check_warns[i]}" ] && echo ' (warn only)')"
        done
        return 0
    fi
    local unknown=() name
    for name in "${only[@]}" "${skip[@]}"; do
        _check_has "$name" "${_check_names[@]}" || unknown+=("$name")
    done
    if [ ${#unknown[@]} -gt 0 ]; then
        local joined
        joined=$(printf '%s, ' "${unknown[@]}")
        echo "no step named ${joined%, }; -List shows them"
        return 2
    fi
    local run=()
    for ((i = 0; i < n; i++)); do
        name=${_check_names[i]}
        if { [ ${#only[@]} -eq 0 ] || _check_has "$name" "${only[@]}"; } && ! _check_has "$name" "${skip[@]}"; then run+=("$i"); fi
    done
    if [ ${#run[@]} -eq 0 ]; then echo 'no steps match; -List shows them'; return 2; fi

    local note errexit='' rc start state why
    note=$(mktemp)
    case $- in *e*) errexit=1 ;; esac
    local r_step=() r_result=() r_seconds=() r_note=()
    for i in "${run[@]}"; do
        name=${_check_names[i]}
        printf '\n%s=== %s: %s%s\n' "$_check_cyan" "$name" "${_check_whats[i]}" "$_check_off"
        local dir=$root
        if [ -n "${_check_dirs[i]}" ]; then dir=$root/${_check_dirs[i]}; fi
        : > "$note"
        start=$SECONDS
        set +e
        (
            set -e
            _check_note=$note
            cd "$dir"
            "run_$name"
        )
        rc=$?
        if [ -n "$errexit" ]; then set -e; fi
        why=''
        if [ "$rc" -eq 0 ]; then
            state=ok
        else
            why=$(cat "$note")
            if [ -z "$why" ]; then why="exited $rc"; fi
            if [ -n "${_check_warns[i]}" ]; then state=WARN; else state=FAIL; fi
        fi
        r_step+=("$name"); r_result+=("$state"); r_seconds+=("$((SECONDS - start))"); r_note+=("$why")
    done
    rm -f "$note"

    # the summary, laid out as PowerShell's Format-Table -AutoSize
    printf '\n%s=== summary%s\n\n' "$_check_cyan" "$_check_off"
    local w1=4 w2=6 w3=7 k
    for ((k = 0; k < ${#r_step[@]}; k++)); do
        ((${#r_step[k]} > w1)) && w1=${#r_step[k]}
        ((${#r_result[k]} > w2)) && w2=${#r_result[k]}
        ((${#r_seconds[k]} > w3)) && w3=${#r_seconds[k]}
    done
    printf "%-${w1}s %-${w2}s %${w3}s %s\n" step result seconds note
    printf "%-${w1}s %-${w2}s %${w3}s %s\n" ---- ------ ------- ----
    local failed=''
    for ((k = 0; k < ${#r_step[@]}; k++)); do
        printf "%-${w1}s %-${w2}s %${w3}s %s\n" "${r_step[k]}" "${r_result[k]}" "${r_seconds[k]}" "${r_note[k]}" | sed 's/ *$//'
        [ "${r_result[k]}" = FAIL ] && failed=1
    done
    echo
    if [ -n "$failed" ]; then return 1; fi
    return 0
}
