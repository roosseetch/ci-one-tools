#!/usr/bin/env bash
# A one-shot container stores no log, because its output can hold a secret and
# where a log goes depends on the machine's Podman configuration. Only a service
# (-d), which something may read back with `podman logs`, keeps one, so a service
# must not remove itself with --rm.
#
# Checks the tracked files of the repository this script is in, from wherever in
# that repository it sits. A launch split after `podman run` fails here, so the
# options stay on its line. Launches built at runtime, or through a variable, are
# not seen.
#
#   lib/check-one-shot-logs.sh
#
# Exits 1 on a launch that breaks the rule, 2 if the check itself can't work.
set -euo pipefail
cd "$(dirname "$0")"
prefix="$(git rev-parse --show-prefix)" || exit 2
self="$prefix$(basename "$0")"
cd "$(git rev-parse --show-toplevel)" || exit 2

label='"\$\{CI_LABEL\[@\]\}" '
launch='(^|[^`#a-z])podman([[:space:]]+--[a-z-]+[= ][^ ]+)*[[:space:]]+run\b'
one_shot="podman run (${label})?--rm --log-driver=none( |\$)"
detached=' --log-driver=none (-d|--detach)( |$)'
service="podman run (${label})?-d "
service_loses_log=' (--rm(=| |$)|--log-driver)'
comment='^[[:space:]]*#'

# violates <line of shell>: succeeds if the line breaks the rule.
violates() {
  [[ ! $1 =~ $comment && $1 =~ $launch ]] || return 1
  if [[ $1 =~ $service ]]; then
    [[ $1 =~ $service_loses_log ]]
  else
    [[ ! $1 =~ $one_shot || $1 =~ $detached ]]
  fi
}

# The patterns themselves, so a mistake in one cannot pass the whole tree.
rc=0
while IFS= read -r line; do
  if ! violates "$line"; then
    echo "check-one-shot-logs: control should fail: $line" >&2
    rc=2
  fi
done <<'BAD'
podman run img
podman run --rm img
podman run --rm -i --log-driver=none img
podman run --rm --log-driver none img
podman run "${CI_LABEL[@]}" --rm img
exec podman run "${CI_LABEL[@]}" --rm -i img
list | podman run --rm -i img
x="$(podman run --rm img)"
podman run \
podman run "${CI_LABEL[@]}" \
podman --log-level=debug run --rm --log-driver=none img
podman run --rm -d img
podman run "${CI_LABEL[@]}" --rm -d img
podman run -d --rm img
podman run "${CI_LABEL[@]}" -d --name x --rm img
podman  run --rm img
podman	run --rm img
podman run --rm --log-driver=none -d img
podman run --rm --log-driver=none --detach img
podman run -d --log-driver=none img
podman run -d --name x --log-driver none img
podman run -d --rm=true img
BAD
while IFS= read -r line; do
  if violates "$line"; then
    echo "check-one-shot-logs: control should pass: $line" >&2
    rc=2
  fi
done <<'GOOD'
podman run --rm --log-driver=none img
podman run --rm --log-driver=none -i img
exec podman run "${CI_LABEL[@]}" --rm --log-driver=none -i img
list | podman run --rm --log-driver=none -i img
x="$(podman run --rm --log-driver=none img)"
podman run -d --name x img
podman run "${CI_LABEL[@]}" -d --name x img
podman run --rm --log-driver=none img -d x
# podman run --rm img
  # podman run --rm img
hidden when stdout is not a terminal (`podman run` without `-t`)
podman runlabel x
podman exec x true
podman rm -f x
GOOD
((rc == 0)) || exit "$rc"

# Every tree here launches containers, so finding nothing means the search broke.
lines="$(git grep -InF podman -- . ':!*.md' ":!$self")" || {
  echo "check-one-shot-logs: git grep found nothing or failed (exit $?)" >&2
  exit 2
}
while IFS= read -r line; do
  text="${line#*:}"
  text="${text#*:}"
  if violates "$text"; then
    echo "check-one-shot-logs: $line" >&2
    rc=1
  fi
done <<<"$lines"
if ((rc)); then
  echo "check-one-shot-logs: one-shots start 'podman run [\"\${CI_LABEL[@]}\"] --rm --log-driver=none'; services start '-d' and have no --rm" >&2
fi
exit "$rc"
