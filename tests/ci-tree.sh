#!/usr/bin/env bash
# Checks lib/ci-tree.sh and lib/ci-label.sh with real git, locks, signals and
# process groups, and fake podman, GitHub and reflink copies. Real podman is
# tests/ci-tree-podman.sh.
#
#   tests/ci-tree.sh
set -uo pipefail
. "$(dirname "$0")/ci-tree-common.sh"
trap stop_leftovers EXIT

mkdir -p "$work/fake-bin"
cat >"$work/fake-bin/podman" <<'FAKE'
#!/usr/bin/env bash
# podman-refuse: lines of "<word> <word>" that fail. networks, volumes: what ls lists.
echo "$*" >>"$CASE/podman.log"
if [[ -e $CASE/podman-refuse ]] && grep -qxF "$1 $2" "$CASE/podman-refuse"; then exit 1; fi
case "$1 $2" in
  "network ls") cat "$CASE/networks" 2>/dev/null ;;
  "volume ls") cat "$CASE/volumes" 2>/dev/null ;;
esac
exit 0
FAKE
cat >"$work/fake-bin/cp" <<'FAKE'
#!/usr/bin/env bash
# Plain copies, so the tests do not depend on the filesystem; cp-fail leaves a
# partial destination and fails, like a filesystem without reflinks.
if [[ -e $CASE/cp-fail ]]; then
  mkdir -p "${@: -1}"
  ln -sf /nowhere "${@: -1}/partial"
  [[ ! -e ${*: -1}/tracked ]] || echo damaged >"${@: -1}/tracked"
  exit 1
fi
args=()
for a; do [[ $a == --reflink=always ]] || args+=("$a"); done
exec "$REAL_CP" "${args[@]}"
FAKE
chmod +x "$work/fake-bin/podman" "$work/fake-bin/cp"
ci_path="$work/fake-bin:$ci_path"

boot="$(cat /proc/sys/kernel/random/boot_id)"
bash -c 'exit 0' &
dead=$!
wait "$dead"

echo "--- a certified run"
new_repo <<'SUITE'
echo "$PWD" >"$CASE/pwd"
echo "$CI_RUN_ID" >"$CASE/run-id"
env | cut -d= -f1 | grep -E '^CI_(GH|SHA|TREE)$' >"$CASE/env-left" || :
[[ ! -e /proc/$$/fd/9 ]] || touch "$CASE/lock-inherited"
SUITE
sha="$(head_sha)"
echo 'exit 1' >>"$repo/scripts/suite"
run_ci
id="$(cat "$CASE/run-id")"
eq "a passing suite exits 0" "$rc" 0
eq "it posts pending, then success" "$(posted)" "pending success"
has "the status is on the commit" "$CASE/gh.log" "repos/someone/example/statuses/$sha"
eq "it runs in the tree" "$(cat "$CASE/pwd")" "$(realpath "$tree")"
has "uncommitted changes are reported, not run" "$CASE/out" "uncommitted changes"
yes_that "CI_GH, CI_SHA and CI_TREE do not reach the suite" test ! -s "$CASE/env-left"
not_that "the suite does not inherit the lock" test -e "$CASE/lock-inherited"
not_that "the record is gone" test -e "$tree.run"
has "containers of this run are removed" "$CASE/podman.log" "rm --force --time 0 --ignore --volumes --filter label=ci-tree.run=$id"
has "networks of this run are listed" "$CASE/podman.log" "network ls -q --filter label=ci-tree.run=$id"
has "volumes of this run are listed" "$CASE/podman.log" "volume ls -q --filter label=ci-tree.run=$id"

echo "--- what the suite's result turns into"
new_repo <<<'exit 3'
run_ci
eq "a failing suite exits 1" "$rc" 1
eq "it posts failure" "$(posted)" "pending failure"
not_that "no record is left" test -e "$tree.run"

new_repo <<<'exit 137'
run_ci
eq "a status above 128 exits 1" "$rc" 1
eq "it posts error, not failure" "$(posted)" "pending error"
has "it says it ended abnormally" "$CASE/gh.log" "ended abnormally"

new_repo <<<'echo changed >>scripts/suite'
run_ci
eq "changing a tracked file posts failure" "$(posted)" "pending failure"
has "with the reason" "$CASE/gh.log" "the run changed the CI tree"

new_repo <<<'echo new >stray'
run_ci
eq "leaving an untracked file posts failure" "$(posted)" "pending failure"

new_repo <<<'git commit -q --no-gpg-sign --allow-empty -m moved'
run_ci
eq "moving HEAD posts failure" "$(posted)" "pending failure"

echo "--- which commit runs"
new_repo <<<'echo first >"$CASE/ran"'
first="$(head_sha)"
echo 'echo second >"$CASE/ran"' >"$repo/scripts/suite"
commit_all
run_ci CI_SHA="$first"
eq "CI_SHA runs that commit's own suite" "$(cat "$CASE/ran")" first
has "and posts on it" "$CASE/gh.log" "statuses/$first"

new_repo <<<':'
touch "$CASE/gh-no-commit"
run_ci
eq "a commit not on GitHub exits 2" "$rc" 2
eq "it posts nothing" "$(posted)" ""
not_that "it makes no tree" test -e "$tree"

new_repo <<<':'
run_ci CI_GH=gh
eq "CI_GH can be a command name" "$rc" 0
run_ci CI_GH=no-such-command
eq "a CI_GH that is no command exits 2" "$rc" 2
has "and says so" "$CASE/out" "is not a command"

echo "--- the tree"
new_repo <<'SUITE'
[[ -e kept/a ]] && echo yes >"$CASE/kept-seen" || echo no >"$CASE/kept-seen"
[[ -e other/b ]] && echo yes >"$CASE/other-seen" || echo no >"$CASE/other-seen"
mkdir -p kept other
touch kept/a other/b
SUITE
run_ci
run_ci
eq "the second run succeeds" "$rc" 0
eq "CI_TREE_KEEP survives between runs" "$(cat "$CASE/kept-seen")" yes
eq "other ignored files do not" "$(cat "$CASE/other-seen")" no

new_repo <<<'echo "$PWD" >"$CASE/pwd"'
run_ci CI_TREE= XDG_CACHE_HOME="$CASE/cache"
eq "the default tree is under ci-local, by repository name" "$(cat "$CASE/pwd")" "$(realpath "$CASE/cache/ci-local/example")"
run_ci CI_TREE=
eq "without CI_TREE, a test's tree still stays in its own directory" "$(cat "$CASE/pwd")" "$(realpath "$work/cache/ci-local/example")"

new_repo <<<':'
mkdir -p "$tree"
echo precious >"$tree/file"
run_ci
eq "a directory it did not make is an error" "$(posted)" "pending error"
eq "and it is left alone" "$(cat "$tree/file")" precious

new_repo <<<':'
run_ci FIXTURE_BARE=1
eq "CI_TREE_KEEP and CI_TREE_SEED are optional" "$rc" 0

echo "--- seeding"
new_repo <<'SUITE'
: >"$CASE/seen"
for path in target/debug/x target/release/y target/stray sub/node_modules/pkg/f \
  untracked/node_modules/pkg/f linked/node_modules/f seeded/a seeded/later sub/node_modules/pkg/later; do
  [[ ! -e $path ]] || echo "$path" >>"$CASE/seen"
done
SUITE
mkdir -p "$repo/sub" "$repo/linked"
touch "$repo/sub/.keep" "$repo/linked/.keep"
commit_all
mkdir -p "$repo/target/debug" "$repo/target/release" "$repo/sub/node_modules/pkg" \
  "$repo/untracked/node_modules/pkg" "$repo/seeded" "$case_dir/elsewhere"
touch "$repo/target/debug/.cargo-lock" "$repo/target/debug/x" "$repo/target/release/.cargo-lock" \
  "$repo/target/release/y" "$repo/target/stray" "$repo/sub/node_modules/pkg/f" \
  "$repo/untracked/node_modules/pkg/f" "$repo/seeded/a" "$case_dir/elsewhere/f"
ln -s "$case_dir/elsewhere" "$repo/linked/node_modules"
run_ci
eq "a seeded run succeeds" "$rc" 0
seen="$(cat "$CASE/seen")"
for path in target/debug/x target/release/y sub/node_modules/pkg/f seeded/a; do
  yes_that "$path is seeded" grep -qx "$path" <<<"$seen"
done
for path in target/stray untracked/node_modules/pkg/f linked/node_modules/f; do
  not_that "$path is not" grep -qx "$path" <<<"$seen"
done
touch "$repo/seeded/later" "$repo/sub/node_modules/pkg/later"
run_ci
seen="$(cat "$CASE/seen")"
not_that "the seed runs once per tree" grep -qx seeded/later <<<"$seen"

new_repo <<'SUITE'
[[ ! -e node_modules ]] || touch "$CASE/partial"
[[ ! -L seeded/partial ]] || touch "$CASE/partial-seed"
cat seeded/tracked >"$CASE/tracked"
SUITE
mkdir -p "$repo/node_modules/pkg" "$repo/seeded"
echo committed >"$repo/seeded/tracked"
git -C "$repo" add -f seeded/tracked
commit_all
touch "$repo/node_modules/pkg/f" "$repo/seeded/a" "$CASE/cp-fail"
run_ci
eq "a failed reflink copy does not stop the run" "$rc" 0
not_that "and leaves nothing partial" test -e "$CASE/partial"
not_that "nor of a CI_TREE_SEED directory" test -e "$CASE/partial-seed"
eq "and tracked files go back to the commit" "$(cat "$CASE/tracked")" committed
has "it says the cache is rebuilt" "$CASE/out" "it is rebuilt instead"
has "and that a seed failed" "$CASE/out" "could not seed seeded; it is rebuilt instead"

echo "--- stopping the suite"
new_repo <<'SUITE'
sleep 300 &
echo $! >"$CASE/left"
SUITE
run_ci
eq "a process left behind posts error" "$(posted)" "pending error"
has "with the reason" "$CASE/gh.log" "left processes running"
not_that "and it is stopped" kill -0 "$(cat "$CASE/left")"
not_that "no record is left" test -e "$tree.run"

new_repo <<'SUITE'
(
  trap '' TERM
  echo $BASHPID >"$CASE/left"
  exec sleep 300
) &
sleep 0.2
SUITE
run_ci CI_TREE_STOP_SECONDS=1
eq "one that ignores TERM posts error" "$(posted)" "pending error"
not_that "and is killed" kill -0 "$(cat "$CASE/left")"

new_repo <<<'hold'
start_ci
wait_for "the suite" test -e "$CASE/started"
pgid="$(record_field pgid)"
yes_that "the suite has its own process group" kill -0 -- "-$pgid"
kill -TERM "$launcher"
finish "$launcher"
eq "a signal during the suite exits 1" "$rc" 1
eq "it posts error" "$(posted)" "pending error"
has "it says interrupted" "$CASE/gh.log" "description=interrupted"
yes_that "the suite's group is stopped" wait_gone "-$pgid"
not_that "the record is gone, the cleanup having worked" test -e "$tree.run"

echo "--- one run at a time"
new_repo <<<'hold'
start_ci
first_run=$launcher
wait_for "the first suite" test -e "$CASE/started"
start_ci
second_run=$launcher
wait_for "the second to wait" grep -q 'waiting for the run' "$CASE/out"
sleep 0.3
eq "the second has not started its suite" "$(wc -l <"$CASE/runs")" 1
eq "or posted anything" "$(posted)" "pending"
touch "$CASE/release"
finish "$first_run"
eq "the first succeeds" "$rc" 0
finish "$second_run"
eq "then the second does" "$rc" 0
eq "each ran once" "$(sort -u "$CASE/runs" | wc -l)" 2
eq "nothing overlapped" "$(posted)" "pending success pending success"

new_repo <<<'hold'
start_ci
first_run=$launcher
wait_for "the first suite" test -e "$CASE/started"
before="$(cat "$tree.run")"
start_ci
second_run=$launcher
wait_for "the second to wait" grep -q 'waiting for the run' "$CASE/out"
wait_for "its lock waiter" pgrep -P "$second_run" -x flock
waiter="$(pgrep -P "$second_run" -x flock)"
kill -TERM "$second_run"
finish "$second_run"
eq "a signal while waiting exits 130" "$rc" 130
not_that "it stops its lock waiter" kill -0 "$waiter"
eq "it leaves the run's record alone" "$(cat "$tree.run")" "$before"
yes_that "and the run" kill -0 "$first_run"
eq "and posts nothing" "$(posted)" "pending"
touch "$CASE/release"
finish "$first_run"
eq "the run succeeds" "$rc" 0
run_ci
eq "and no waiter is left holding the lock" "$rc" 0

echo "--- a launcher that dies"
new_repo <<<'hold'
start_ci
wait_for "the suite" test -e "$CASE/started"
id="$(record_field run)"
pgid="$(record_field pgid)"
kill -KILL "$launcher"
finish "$launcher"
run_ci
eq "while the suite still runs, the next run exits 2" "$rc" 2
has "it says why" "$CASE/out" "is still running"
eq "the record stays" "$(record_field run)" "$id"
kill -KILL -- "-$pgid"
yes_that "the old suite is gone" wait_gone "-$pgid"
touch "$CASE/release"
run_ci
eq "after that, the next run cleans up and succeeds" "$rc" 0
has "it says so" "$CASE/out" "cleaned up after run $id"
has "it removed that run's containers" "$CASE/podman.log" "label=ci-tree.run=$id"
not_that "the record is gone" test -e "$tree.run"

echo "--- records that quarantine: exit 2, nothing cleaned, the record kept"
# <what> <expected message> <record, with \n>
quarantined() {
  new_repo <<<'touch "$CASE/ran"'
  printf "$3" >"$tree.run"
  local before
  before="$(cat "$tree.run")"
  run_ci
  eq "$1: exits 2" "$rc" 2
  has "$1: says why" "$CASE/out" "$2"
  has "$1: says what to check" "$CASE/out" "label=ci-tree.run"
  eq "$1: the record is kept" "$(cat "$tree.run")" "$before"
  not_that "$1: no suite ran" test -e "$CASE/ran"
  not_that "$1: nothing was removed" test -e "$CASE/podman.log"
  eq "$1: nothing was posted" "$(posted)" ""
}
good="run=r1\nsha=a\nsrc=b\nlabels=yes\nboot=$boot\npgid=$dead\n"
quarantined "another version" "from another version" "v=2\n$good"
quarantined "a truncated line" "cannot be read" "v=3\nrun=r1\nlabels=yes\nboot=$boot\npgid=$dead"
quarantined "a duplicate field" "cannot be read" "v=3\nv=3\n$good"
quarantined "an unknown field" "cannot be read" "v=3\n${good}extra=1\n"
quarantined "a bad process group" "cannot be read" "v=3\nrun=r1\nlabels=yes\nboot=$boot\npgid=abc\n"
quarantined "no boot id" "cannot be read" "v=3\nrun=r1\nlabels=yes\npgid=$dead\n"
quarantined "a bad labels field" "cannot be read" "v=3\nrun=r1\nlabels=maybe\nboot=$boot\npgid=$dead\n"
quarantined "an empty record" "cannot be read" ""
quarantined "a live group on this boot" "is still running" "v=3\nrun=r1\nlabels=yes\nboot=$boot\npgid=$$\n"
quarantined "an unlabelled commit that ran" "without the ci-tree.run label" "v=3\nrun=r1\nlabels=no\nboot=$boot\npgid=$dead\n"

echo "--- records that recover"
recovered() { # <what> <wanted podman calls for r1: yes|no> <record, with \n>
  new_repo <<<':'
  printf "$3" >"$tree.run"
  run_ci
  eq "$1: the run succeeds" "$rc" 0
  has "$1: says it cleaned up" "$CASE/out" "cleaned up after run r1"
  if [[ $2 == yes ]]; then
    has "$1: removes that run's resources" "$CASE/podman.log" "label=ci-tree.run=r1"
  else
    lacks "$1: nothing to remove" "$CASE/podman.log" "label=ci-tree.run=r1"
  fi
}
recovered "a finished group" yes "v=3\nrun=r1\nlabels=yes\nboot=$boot\npgid=$dead\n"
recovered "a process group from another boot" yes "v=3\nrun=r1\nlabels=yes\nboot=other\npgid=$$\n"
recovered "a suite that never started" no "v=3\nrun=r1\nlabels=yes\nboot=$boot\n"
recovered "an unlabelled suite that never started" no "v=3\nrun=r1\nlabels=no\nboot=$boot\n"

new_repo <<<':'
printf "v=3\nrun=r1\nlabels=yes\nboot=$boot\npgid=$dead\n" >"$tree.run"
echo 'volume rm' >"$CASE/podman-refuse"
echo gone-volume >"$CASE/volumes"
run_ci
eq "a failed removal quarantines: exits 2" "$rc" 2
has "it says why" "$CASE/out" "could not be removed"
eq "the record is kept" "$(record_field run)" r1

echo "--- removing what a run labelled"
new_repo <<<'echo "$CI_RUN_ID" >"$CASE/run-id"'
printf 'n1\nn2\n' >"$CASE/networks"
printf 'v1\n' >"$CASE/volumes"
run_ci
eq "a run with resources to remove succeeds" "$rc" 0
has "networks go by name" "$CASE/podman.log" "network rm --force n1 n2"
has "volumes go by name" "$CASE/podman.log" "volume rm --force v1"

for refused in 'rm --force' 'network ls' 'network rm' 'volume ls' 'volume rm'; do
  new_repo <<<':'
  printf 'n1\n' >"$CASE/networks"
  printf 'v1\n' >"$CASE/volumes"
  echo "$refused" >"$CASE/podman-refuse"
  run_ci
  eq "'podman $refused' failing posts error" "$(posted)" "pending error"
  eq "'podman $refused' failing exits 1" "$rc" 1
  has "'podman $refused' failing keeps the record" "$tree.run" "reason="
done

echo "--- commits whose helper does not use this label"
expect_unlabelled() { # <what>; the repository is set up
  run_ci
  eq "$1: runs and succeeds" "$rc" 0
  has "$1: warns" "$CASE/out" "does not use the ci-tree.run container label"
  has "$1: records labels=no" "$CASE/record" "labels=no"
  not_that "$1: a normal finish leaves no record" test -e "$tree.run"
}
new_repo <<<'cp "$PWD.run" "$CASE/record"'
git -C "$repo" rm -q scripts/lib/ci-label.sh
commit_all
expect_unlabelled "no helper"

new_repo <<<'cp "$PWD.run" "$CASE/record"'
echo 'CI_LABEL=(--label "fixture.previous-run=$CI_RUN_ID")' >"$repo/scripts/lib/ci-label.sh"
commit_all
expect_unlabelled "another label"

new_repo <<<'cp "$PWD.run" "$CASE/record"'
echo 'CI_LABEL=(--label "fixture.ci-tree.run=$CI_RUN_ID")' >"$repo/scripts/lib/ci-label.sh"
commit_all
expect_unlabelled "a longer label ending in this one"

new_repo <<<'cp "$PWD.run" "$CASE/record"'
printf '# was: --label "ci-tree.run=$CI_RUN_ID"\nCI_LABEL=(--label "fixture.previous-run=$CI_RUN_ID")\n' >"$repo/scripts/lib/ci-label.sh"
commit_all
expect_unlabelled "this label only in a comment"

new_repo <<<'hold'
echo 'CI_LABEL=(--label "fixture.previous-run=$CI_RUN_ID")' >"$repo/scripts/lib/ci-label.sh"
commit_all
start_ci
wait_for "the suite" test -e "$CASE/started"
kill -TERM "$launcher"
finish "$launcher"
eq "interrupting one posts error" "$(posted)" "pending error"
has "and quarantines it" "$tree.run" "reason=it ran a commit without the ci-tree.run label"
run_ci
eq "the next run exits 2" "$rc" 2
has "and says why" "$CASE/out" "the CI tree is quarantined"

new_repo <<<'cp "$PWD.run" "$CASE/record"'
run_ci
has "a commit with this library's helper records labels=yes" "$CASE/record" "labels=yes"
has "in a version 3 record" "$CASE/record" "v=3"

echo "--- the helper"
got="$(CI_RUN_ID=abc bash -c '. "$1"; echo "${CI_LABEL[*]}"' _ "$root/lib/ci-label.sh")"
eq "a run labels with ci-tree.run" "$got" "--label ci-tree.run=abc"
got="$(env -u CI_RUN_ID bash -c '. "$1"; echo "${#CI_LABEL[@]}"' _ "$root/lib/ci-label.sh")"
eq "outside a run there is no label" "$got" 0

echo "--- reporting"
new_repo <<<'touch "$CASE/ran"'
echo pending >"$CASE/gh-refuse"
run_ci
eq "pending that cannot be posted exits 1" "$rc" 1
not_that "and no suite runs" test -e "$CASE/ran"

new_repo <<<':'
echo success >"$CASE/gh-refuse"
run_ci
eq "success that cannot be posted exits 1" "$rc" 1
has "it posts error instead" "$CASE/gh.log" "description=could not post success"

summary
