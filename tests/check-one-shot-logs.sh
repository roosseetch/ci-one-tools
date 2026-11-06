#!/usr/bin/env bash
# Runs lib/check-one-shot-logs.sh on throwaway repositories, from the two places
# it sits: lib/ here, scripts/lib/ in a repository that pins a copy. The launches
# are written through $p, because a literal one here would fail the check on this
# repository.
#
#   tests/check-one-shot-logs.sh
set -euo pipefail
cd "$(dirname "$0")/.."
script="$PWD/lib/check-one-shot-logs.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
p=podman

fail=0
expect() { # <want exit code> <description> <command...>
  local want="$1" what="$2" got=0
  shift 2
  "$@" > "$work/out.log" 2>&1 || got=$?
  if [[ $got == "$want" ]]; then
    echo "ok: $what"
  else
    echo "FAILED: $what (wanted exit $want, got $got)"
    sed 's/^/    /' "$work/out.log"
    fail=1
  fi
}

# repository <directory> <where the check goes>: a repository with one good launch.
repository() {
  mkdir -p "$1/$(dirname "$2")"
  cp "$script" "$1/$2"
  git init -q "$1"
  echo "$p run --rm --log-driver=none img" > "$1/good.sh"
  git -C "$1" add -A
}

for place in lib/check-one-shot-logs.sh scripts/lib/check-one-shot-logs.sh; do
  repo="$work/${place//\//-}"
  repository "$repo" "$place"
  expect 0 "$place: passes, its own controls not counted" "$repo/$place"
  expect 0 "$place: runs from another directory" bash -c 'cd / && "$1"' _ "$repo/$place"

  echo "$p run --rm img" > "$repo/bad.sh"
  expect 0 "$place: an untracked launch is not checked" "$repo/$place"
  git -C "$repo" add bad.sh
  expect 1 "$place: a tracked launch without the flag fails" "$repo/$place"
  grep -q 'bad.sh:1:' "$work/out.log" || { echo "FAILED: $place: the file is not named"; fail=1; }
  git -C "$repo" rm -qf bad.sh

  echo "$p run --rm img" > "$repo/notes.md"
  git -C "$repo" add notes.md
  expect 0 "$place: Markdown is not checked" "$repo/$place"
done

repo="$work/nothing"
repository "$repo" lib/check-one-shot-logs.sh
git -C "$repo" rm -qf good.sh
expect 2 "a tree with no launches means the search broke" "$repo/lib/check-one-shot-logs.sh"

mkdir -p "$work/no-git"
cp "$script" "$work/no-git/check"
expect 2 "outside a repository it can't work" "$work/no-git/check"
exit "$fail"
