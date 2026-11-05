#!/usr/bin/env bash
# Runs the bun-ignore-file reader of .github/workflows/security.yml, taken from
# the workflow itself, against good and bad lists, under the `bash -e` of a run
# step. What lockfile-audit does with the ids is tests/audit.sh's business.
#
#   tests/security-workflow.sh
set -euo pipefail
cd "$(dirname "$0")/.."
workflow=.github/workflows/security.yml
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

sed -n '/# bun-ignore-file reader: begin/,/# bun-ignore-file reader: end/p' "$workflow" > "$work/reader.sh"
[[ -s $work/reader.sh ]] || { echo "FAILED: no reader in $workflow"; exit 1; }

fail=0
check() { # <description> <want rc> <want ignores> <want in audit.log> [LOCKFILES]
  local what="$1" want_rc="$2" want_ids="$3" want_log="$4" lockfiles="${5:-true}" out
  out="$(cd "$work" && LOCKFILES="$lockfiles" bash -e -c '
    rc=0
    : > audit.log
    . ./reader.sh
    echo "rc=$rc ignores=${bun_ignores[*]:-}"')" || out="the reader stopped the step"
  if [[ -n $want_log ]]; then
    grep -qF -- "$want_log" "$work/audit.log" || out="$out, and no such line in the log: $want_log"
  elif [[ -s $work/audit.log ]]; then
    out="$out, and an unexpected log"
  fi
  if [[ "$out" == "rc=$want_rc ignores=$want_ids" ]]; then
    echo "ok: $what"
  else
    echo "FAILED: $what"
    printf '    got: %s\n' "$out"
    sed 's/^/    log: /' "$work/audit.log"
    fail=1
  fi
}

a=GHSA-3gc7-fjrx-p6mg b=GHSA-w5hq-g745-h8pq

export BUN_IGNORE_FILE=''
check "no list, no ignores" 0 '' ''

export BUN_IGNORE_FILE=list
printf '# why these\n\n   \n%s  a reason, with words\n  # indented comment\n%s\n' "$a" "$b" > "$work/list"
check "comments, blanks and reasons" 0 "--bun-ignore $a --bun-ignore $b" ''

printf '%s' "$a" > "$work/list"
check "a last line without a newline" 0 "--bun-ignore $a" ''

: > "$work/list"
check "an empty list" 0 '' ''

printf '%s\n--help\n' "$a" > "$work/list"
check "a line that would be an option fails" 1 "--bun-ignore $a" 'not a GHSA id: --help'

printf 'ghsa-3gc7-fjrx-p6mg\n' > "$work/list"
check "a lowercase id fails" 1 '' 'not a GHSA id'

printf 'GHSA-0000-aaaa-1111\n' > "$work/list"
check "letters outside GitHub's alphabet fail" 1 '' 'not a GHSA id'

printf 'GHSA-3gc7-fjrx\n' > "$work/list"
check "a short id fails" 1 '' 'not a GHSA id'

printf 'GHSA-3gc7-fjrx-p6mg-xxxx\n' > "$work/list"
check "a long id fails" 1 '' 'not a GHSA id'

export BUN_IGNORE_FILE=missing
check "a missing list fails" 1 '' "can't read missing"

export BUN_IGNORE_FILE=.
check "a directory fails" 1 '' "can't read ."

check "no lockfile check, list unread" 0 '' '' false

# The workflow has to hand the list over, and only through the environment.
grep -qF 'run lockfile-audit "${bun_ignores[@]}" $AUDIT_ARGS' "$workflow" \
  || { echo "FAILED: the audit does not get the ignores"; fail=1; }
grep -qF 'BUN_IGNORE_FILE: ${{ inputs.bun-ignore-file }}' "$workflow" \
  || { echo "FAILED: the input is not passed by the environment"; fail=1; }
[[ $(grep -c 'inputs.bun-ignore-file' "$workflow") == 1 ]] \
  || { echo "FAILED: the input is used outside the environment"; fail=1; }
exit "$fail"
