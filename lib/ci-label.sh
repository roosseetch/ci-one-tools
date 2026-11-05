# Sourced by every script that starts a container, network or volume during
# scripts/ci. In a CI-tree run (scripts/lib/ci-tree.sh) CI_RUN_ID names the
# run; each of them carries it as the label ci-tree.run, so the launcher can
# remove whatever a stopped run left behind. Empty outside such a run.
#
#   podman run "${CI_LABEL[@]}" ...
# shellcheck disable=SC2034 # used by the scripts that source this file
CI_LABEL=()
[[ -z ${CI_RUN_ID:-} ]] || CI_LABEL=(--label "ci-tree.run=$CI_RUN_ID")
