#!/usr/bin/env bash
# Checks the audit image against fixtures with known results:
# - a Cargo.lock and a bun.lock without advisories pass;
# - a Cargo.lock with a vulnerable crate fails, and passes once that
#   advisory is accepted in a deny.toml;
# - scan-images reports a row per image and fails on an unscannable one.
#
#   tests/audit.sh IMAGE
set -euo pipefail
cd "$(dirname "$0")/.."
image="$1"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
cp -r tests/fixtures/. "$work"

run() {
  podman run --rm -i --security-opt label=disable -v ci-one-tools-cargo:/cargo -e CARGO_HOME=/cargo \
    -v ci-one-tools-trivy:/root/.cache/trivy -v "$work:/work" -w /work "$image" "$@"
}
fail=0
expect() { # <want: pass|fail> <description> <command...>
  local want="$1" what="$2" got=pass
  shift 2
  "$@" > "$work/out.log" 2>&1 || got=fail
  if [[ "$got" == "$want" ]]; then
    echo "ok: $what"
  else
    echo "FAILED: $what (wanted $want, got $got)"
    sed 's/^/    /' "$work/out.log" | tail -n 40
    fail=1
  fi
}

expect pass "clean lockfiles pass" run lockfile-audit --deny-config deny.toml clean
expect fail "a vulnerable crate fails" run lockfile-audit --deny-config deny.toml vulnerable
expect pass "an accepted advisory passes" run lockfile-audit --deny-config vulnerable/accept.toml vulnerable
expect fail "a directory without lockfiles is an error" run lockfile-audit empty
expect fail "an unscannable image fails its row" run scan-images ghcr.io/roosseetch/ci-one-tools/does-not-exist:0
grep -q '| failed | failed |' "$work/out.log" || { echo "FAILED: no failed row"; fail=1; }
exit "$fail"
