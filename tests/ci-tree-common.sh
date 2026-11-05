# Sourced by tests/ci-tree.sh and tests/ci-tree-podman.sh: throwaway repositories
# with the library installed, a fake GitHub client, and small assertions. Each
# case gets a directory of its own, named by CASE, which the fakes and the suite
# read. Nothing here touches a real tree, the network or the user's git settings.

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
n=0 fails=0 count=0 launcher='' rc=0 case_dir='' repo='' tree=''
launchers=() started_cases=()

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.invalid
export GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.invalid
REAL_CP="$(command -v cp)"
export REAL_CP

mkdir -p "$work/gh-bin"
cat >"$work/gh-bin/gh" <<'FAKE'
#!/usr/bin/env bash
# gh-no-commit: the commit is not on GitHub. gh-refuse: states that cannot be posted.
echo "$*" >>"$CASE/gh.log"
case "$*" in
  */commits/*) [[ ! -e $CASE/gh-no-commit ]] ;;
  */statuses/*)
    for state in $(cat "$CASE/gh-refuse" 2>/dev/null); do
      [[ "$* " != *"state=$state "* ]] || exit 1
    done
    ;;
esac
FAKE
chmod +x "$work/gh-bin/gh"
ci_path="$work/gh-bin:$PATH"

# Runs at exit: nothing a failed test started may outlive it. Only cases with a
# real launcher count: the records other cases make up name groups not ours.
stop_leftovers() {
  local pid started pgid
  for pid in ${launchers[@]+"${launchers[@]}"}; do kill -KILL "$pid" 2>/dev/null; done
  for started in ${started_cases[@]+"${started_cases[@]}"}; do
    pgid="$(sed -n 's/^pgid=//p' "$started/tree.run" 2>/dev/null)"
    [[ -z $pgid ]] || kill -KILL -- "-$pgid" 2>/dev/null
  done
  rm -rf "$work"
}

# new_repo: a case with a repository whose one commit has the library, and
# whose suite (stdin) runs as that commit's scripts/ci. The suite can call
# `hold`: say it has started, then wait for the test to release it.
new_repo() {
  n=$((n + 1))
  case_dir="$work/c$n"
  export CASE="$case_dir"
  repo="$case_dir/repo" tree="$case_dir/tree"
  mkdir -p "$repo/scripts/lib"
  git init -q "$repo"
  cp "$root/lib/ci-tree.sh" "$root/lib/ci-label.sh" "$repo/scripts/lib/"
  cat >"$repo/scripts/ci" <<'FIXTURE'
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -n ${CI_GH:-} ]]; then
  if [[ -z ${FIXTURE_BARE:-} ]]; then
    CI_TREE_KEEP=(/kept/ /target/ node_modules/ /seeded/)
    CI_TREE_SEED=(seeded)
  fi
  . scripts/lib/ci-tree.sh
  ci_tree_run
fi
hold() {
  echo "$CI_RUN_ID" >>"$CASE/runs"
  touch "$CASE/started"
  local i
  for i in {1..1200}; do
    [[ ! -e $CASE/release ]] || return 0
    sleep 0.05
  done
  exit 99
}
. scripts/suite
FIXTURE
  chmod +x "$repo/scripts/ci"
  cat >"$repo/scripts/suite"
  printf '/kept/\n/other/\n/target/\nnode_modules/\n/seeded/\n' >"$repo/.gitignore"
  commit_all
}

commit_all() {
  git -C "$repo" add -A
  git -C "$repo" commit -q --no-gpg-sign -m fixture
}

head_sha() { git -C "$repo" rev-parse HEAD; }

# run_ci [VAR=value...]: runs the launcher in the foreground; the status goes in rc.
run_ci() {
  rc=0
  (cd "$repo" && exec env PATH="$ci_path" CI_GH="$work/gh-bin/gh" CI_REPO=someone/example \
    CI_TREE="$tree" "$@" timeout -k 5 180 ./scripts/ci) >>"$CASE/out" 2>&1 || rc=$?
}

# start_ci [VAR=value...]: the same in the background; its PID goes in launcher.
start_ci() {
  (cd "$repo" && exec env PATH="$ci_path" CI_GH="$work/gh-bin/gh" CI_REPO=someone/example \
    CI_TREE="$tree" "$@" ./scripts/ci) >>"$CASE/out" 2>&1 &
  launcher=$!
  launchers+=("$launcher")
  started_cases+=("$CASE")
}

# finish <pid>: waits for a background launcher; the status goes in rc.
finish() {
  rc=0
  wait "$1" || rc=$?
}

# wait_for <what> <command...>: 30 s at most.
wait_for() {
  local what="$1" i
  shift
  for i in {1..600}; do
    "$@" 2>/dev/null && return 0
    sleep 0.05
  done
  echo "FAILED: timed out waiting for $what"
  sed 's/^/    /' "$CASE/out" 2>/dev/null | tail -n 20
  exit 1
}

# wait_gone <pid or -pgid>: 30 s at most.
wait_gone() {
  local i
  for i in {1..600}; do
    kill -0 -- "$1" 2>/dev/null || return 0
    sleep 0.05
  done
  return 1
}

record_field() { sed -n "s/^$1=//p" "$tree.run" 2>/dev/null; }
posted() { (grep -o 'state=[a-z]*' "$CASE/gh.log" 2>/dev/null || :) | cut -d= -f2 | paste -sd' ' -; }

note() {
  count=$((count + 1))
  if [[ $1 == ok ]]; then
    echo "ok: $2"
  else
    echo "FAILED: $2${3:+ ($3)}"
    sed 's/^/    /' "$CASE/out" 2>/dev/null | tail -n 20
    fails=1
  fi
}

# eq <what> <got> <wanted>
eq() {
  if [[ $2 == "$3" ]]; then note ok "$1"; else note failed "$1" "got '$2', wanted '$3'"; fi
}

# has / lacks <what> <file> <text>
has() {
  if grep -qF -- "$3" "$2" 2>/dev/null; then note ok "$1"; else note failed "$1" "'$3' not in ${2##*/}"; fi
}
lacks() {
  if grep -qF -- "$3" "$2" 2>/dev/null; then note failed "$1" "'$3' in ${2##*/}"; else note ok "$1"; fi
}

# yes_that / not_that <what> <command...>
yes_that() {
  local what="$1"
  shift
  if "$@" 2>/dev/null; then note ok "$what"; else note failed "$what"; fi
}
not_that() {
  local what="$1"
  shift
  if "$@" 2>/dev/null; then note failed "$what"; else note ok "$what"; fi
}

summary() {
  if ((fails)); then
    echo "$count checks, some FAILED"
    exit 1
  fi
  echo "$count checks passed"
}
