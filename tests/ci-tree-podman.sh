#!/usr/bin/env bash
# Checks what tests/ci-tree.sh can only fake: that real podman finds and removes
# what a run labelled, in an order that works while the container still uses the
# network and the volume, and nothing else. Everything it starts carries the
# label ci-tree-test=<this process> and is removed at exit.
#
#   tests/ci-tree-podman.sh
set -uo pipefail
. "$(dirname "$0")/ci-tree-common.sh"

export TEST_ID="$$"
export IMAGE=docker.io/library/busybox:1.37.0@sha256:66a6306db78bf2dbf3487f293aa8d6990d8e506fdffab9cc43fe422becf886e4

finish_test() {
  stop_leftovers
  local filter="label=ci-tree-test=$TEST_ID" ids
  podman rm --force --time 0 --ignore --volumes --filter "$filter" >/dev/null 2>&1
  ids="$(podman network ls -q --filter "$filter" 2>/dev/null)"
  # shellcheck disable=SC2086 # one name per word
  [[ -z $ids ]] || podman network rm --force $ids >/dev/null 2>&1
  ids="$(podman volume ls -q --filter "$filter" 2>/dev/null)"
  # shellcheck disable=SC2086
  [[ -z $ids ]] || podman volume rm --force $ids >/dev/null 2>&1
}
trap finish_test EXIT

podman image exists "$IMAGE" || podman pull -q "$IMAGE" >/dev/null || exit 2

# Starts a running container on its own network and volume, as a suite would.
START='. scripts/lib/ci-label.sh
name="ci-tree-test-$TEST_ID-${CI_RUN_ID:0:8}"
podman volume create "${CI_LABEL[@]}" --label "ci-tree-test=$TEST_ID" "$name-v" >/dev/null
podman network create "${CI_LABEL[@]}" --label "ci-tree-test=$TEST_ID" "$name-n" >/dev/null
podman run -d --log-driver=none "${CI_LABEL[@]}" --label "ci-tree-test=$TEST_ID" --name "$name-c" \
  --network "$name-n" -v "$name-v:/data" "$IMAGE" sleep 300 >/dev/null
echo "$name" >"$CASE/name"
'

exists() { # <prefix of the resources>: how many of the three exist
  local found=0
  podman container exists "$1-c" && found=$((found + 1))
  podman network exists "$1-n" && found=$((found + 1))
  podman volume exists "$1-v" && found=$((found + 1))
  echo "$found"
}

# Not this run's: the same label with another value, and a value this run's id
# is only a prefix of.
other="ci-tree-test-$TEST_ID-other"
podman volume create --label ci-tree.run=another-run --label "ci-tree-test=$TEST_ID" "$other-v" >/dev/null
podman network create --label ci-tree.run=another-run --label "ci-tree-test=$TEST_ID" "$other-n" >/dev/null
podman create --log-driver=none --label ci-tree.run=another-run --label "ci-tree-test=$TEST_ID" --name "$other-c" "$IMAGE" true >/dev/null

echo "--- a suite that leaves its container running"
new_repo <<<"$START"
run_ci
name="$(cat "$CASE/name")"
eq "the suite succeeds" "$rc" 0
eq "it posts success" "$(posted)" "pending success"
eq "the container, network and volume are gone" "$(exists "$name")" 0
eq "another run's resources are not" "$(exists "$other")" 3

echo "--- an id that only starts the same"
new_repo <<SUITE
$START
podman create --log-driver=none --label "ci-tree.run=\${CI_RUN_ID}x" --label "ci-tree-test=\$TEST_ID" \
  --name "\$name-prefixed" "\$IMAGE" true >/dev/null
SUITE
run_ci
name="$(cat "$CASE/name")"
eq "this run's are gone" "$(exists "$name")" 0
yes_that "the longer id is kept" podman container exists "$name-prefixed"

echo "--- a launcher that dies"
new_repo <<SUITE
$START
hold
SUITE
start_ci
wait_for "the suite" test -e "$CASE/started"
id="$(record_field run)"
pgid="$(record_field pgid)"
name="$(cat "$CASE/name")"
kill -KILL "$launcher"
finish "$launcher"
kill -KILL -- "-$pgid"
yes_that "the old suite is gone" wait_gone "-$pgid"
eq "its resources outlive it" "$(exists "$name")" 3
touch "$CASE/release"
run_ci
eq "the next run succeeds" "$rc" 0
has "after cleaning up" "$CASE/out" "cleaned up after run $id"
eq "and the old run's resources are gone" "$(exists "$name")" 0
eq "another run's still are not" "$(exists "$other")" 3

echo "--- a commit with another label"
new_repo <<SUITE
$START
hold
SUITE
echo 'CI_LABEL=(--label "fixture.previous-run=$CI_RUN_ID")' >"$repo/scripts/lib/ci-label.sh"
commit_all
start_ci
wait_for "the suite" test -e "$CASE/started"
name="$(cat "$CASE/name")"
kill -TERM "$launcher"
finish "$launcher"
eq "interrupting it posts error" "$(posted)" "pending error"
has "and quarantines the tree, instead of reporting a clean tree" "$tree.run" "reason=it ran a commit without the ci-tree.run label"
yes_that "its container cannot be found, so it is still there" podman container exists "$name-c"

summary
