#!/usr/bin/env bash
# Runs bin/check-image-tags on a copy of the tree, with the reusable workflow's
# audit tag current, one behind, two behind and unpinned.
#
#   tests/check-image-tags.sh
set -euo pipefail
cd "$(dirname "$0")/.."
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/.github/workflows"
cp -r bin images "$work"
cp .github/workflows/security.yml "$work/.github/workflows"
workflow="$work/.github/workflows/security.yml"

hash="$(bin/image-tags --hash audit)"
current="$(bin/image-tags audit)"
# Two newer tags, so the current one has a tag before it and a tag before that.
printf 'audit test.1 %s\naudit test.2 %s\n' "$hash" "$hash" >> "$work/images/tags"

use() { sed -i "s|\(AUDIT_IMAGE: .*/audit:\)[^@]*@|\1$1@|" "$workflow"; }

fail=0
expect() { # <want: pass|fail> <description>
  local got=pass
  "$work/bin/check-image-tags" > "$work/out.log" 2>&1 || got=fail
  if [[ $got == "$1" ]]; then
    echo "ok: $2"
  else
    echo "FAILED: $2 (wanted $1, got $got)"
    sed 's/^/    /' "$work/out.log"
    fail=1
  fi
}

use test.2
expect pass "the current tag"
use test.1
expect pass "the tag before it"
use "$current"
expect fail "two tags behind"
use test.2
sed -i 's|\(AUDIT_IMAGE: .*/audit:[^@]*\)@sha256:[0-9a-f]*|\1|' "$workflow"
expect fail "a tag without a digest"
exit "$fail"
