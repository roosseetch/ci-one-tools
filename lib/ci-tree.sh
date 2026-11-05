# Install as scripts/lib/ci-tree.sh, next to scripts/lib/ci-label.sh, and source
# it from scripts/ci when CI_GH is set (README). Certifies one commit: runs that
# commit's own scripts/ci in the repository's CI tree and posts the result as
# the `ci/local` commit status. The checkout it is started from is only read,
# so editing it during a run cannot change what is tested.
#
# The CI tree is a repository of its own (`git init` and a local fetch, not a
# worktree, so pruning this checkout's worktrees cannot break it), kept
# between runs so target/ and node_modules/ stay warm. One run at a time per
# tree: a second one waits for the lock. Order: lock, `pending`, reset the
# tree to the commit, run, then one finalizer, still holding the lock: stop
# what is left of the suite's process group (TERM, 30 s, KILL), remove every
# container, network and volume labelled with this run's CI_RUN_ID
# (scripts/lib/ci-label.sh), check the tree is still the commit, and post
# `success` or `failure`. A setup error, a signal (even one arriving after
# the suite finished) or a suite that had to be stopped posts `error`
# instead. Reporting is best effort: SIGKILL, a power cut or GitHub being
# unreachable can leave `pending` behind.
#
# Before anything runs, the run is recorded in <tree>.run (its id, and the
# suite's process group, which the suite's own process writes before it
# starts and while it still holds the lock); no record, no run. The finalizer deletes the record only
# once the cleanup is verified. A record left behind (cleanup failed, or the
# launcher was killed) quarantines the tree: the next run retries the
# cleanup, carries on if the old process group is gone and its labelled
# resources are removed, and refuses to start otherwise. A record from another
# version of this library is never cleaned up automatically, as its containers
# may carry another label. A commit whose scripts/lib/ci-label.sh does not use
# this library's label (or that has none) still runs, but if it does not finish
# normally its containers cannot be found, so the tree stays quarantined until
# someone has checked it and deleted the record.
#
# On first use the tree is seeded from this checkout with reflink copies
# (btrfs: instant, and blocks are shared until rewritten): each Cargo profile
# directory in target/ while holding that profile's build lock, every
# node_modules/, and CI_TREE_SEED. Symlinked ones are skipped; the rest of
# target/ is rebuilt.
#
#   ci_tree_run   never returns
#
# Environment (on top of scripts/ci's CI_GH and CI_REPO):
#   CI_SHA   commit to test (default: HEAD); it must be on GitHub
#   CI_TREE  the CI tree (default: ~/.cache/ci-local/<repository name>); the
#            lock, a note of who holds it and the run record sit next to it
#   CI_TREE_STOP_SECONDS  how long the suite gets between TERM and KILL
#            (default: 30)
#
# Set by scripts/ci before sourcing:
#   CI_TREE_KEEP  ignored paths `git clean` keeps between runs: caches only,
#                 never generated inputs
#   CI_TREE_SEED  further ignored directories copied on first use
#
# Needs Linux (/proc), bash, git, podman, flock, setsid and coreutils. Reflink
# copies need a filesystem that has them; elsewhere the caches are rebuilt.

[[ -v CI_TREE_KEEP ]] || CI_TREE_KEEP=()
[[ -v CI_TREE_SEED ]] || CI_TREE_SEED=()

ct_label=ci-tree.run
# The line of scripts/lib/ci-label.sh that applies it. Both files come from one
# commit of this library, so a change there changes this too.
ct_label_line='[[ -z ${CI_RUN_ID:-} ]] || CI_LABEL=(--label "ci-tree.run=$CI_RUN_ID")'
ct_state=idle ct_error="setup failed: see the local run"
ct_child='' ct_waiter='' ct_cancel='' ct_cancelled='' ct_suite_rc='' ct_run_id=''
ct_forced='' ct_unsafe='' ct_labels='' ct_recorded='' ct_abnormal='' ct_suite_pgid=''
ct_r_v='' ct_r_run='' ct_r_pgid='' ct_r_labels='' ct_r_boot='' ct_r_reason=''
ct_started=$SECONDS ct_t_locked=$SECONDS ct_t_ready=$SECONDS

# ct_post <state> <description>: one retry; non-zero if both attempts failed.
ct_post() {
  local attempt
  for attempt in 1 2; do
    if "$ct_gh" api "repos/$CI_REPO/statuses/$ct_sha" -f state="$1" \
      -f context=ci/local -f description="$2" >/dev/null; then
      echo "ci: posted ci/local $1 on $ct_sha"
      return 0
    fi
    ((attempt == 2)) || sleep 3
  done
  echo "ci: could not post ci/local $1 on $ct_sha" >&2
  return 1
}

# A signal only records the cancellation and leaves; the finalizer does the
# rest. While a background process is being started, signals are latched in
# ct_cancel instead, so its PID is known before anyone has to stop it.
ct_on_signal() {
  ct_cancelled=1 ct_error="interrupted"
  exit 130
}
ct_latch() { trap 'ct_cancel=1' INT TERM HUP; }
ct_unlatch() {
  trap ct_on_signal INT TERM HUP
  [[ -z $ct_cancel ]] || ct_on_signal
}

# ct_lock_fd <fd>: an exclusive flock that a signal can interrupt (bash runs
# no trap while a foreground flock waits). The background flock locks the
# open file it shares with us, so the lock stays ours after it exits.
ct_lock_fd() {
  local rc=0
  ct_latch
  flock "$1" &
  ct_waiter=$!
  ct_unlatch
  wait "$ct_waiter" || rc=$?
  ct_waiter=
  return "$rc"
}

ct_alive() { kill -0 -- "-$1" 2>/dev/null || kill -0 "$1" 2>/dev/null; }

# ct_gone <pgid> <seconds>
ct_gone() {
  local until=$((SECONDS + $2))
  while ct_alive "$1"; do
    ((SECONDS < until)) || return 1
    sleep 0.2
  done
}

# ct_stop_suite <pgid>: TERM what is left of the group, KILL it after 30 s.
# The PID is signalled as well in case it has not made its session yet.
# (The 30 s is CI_TREE_STOP_SECONDS.)
ct_stop_suite() {
  ct_alive "$1" || return 0
  ct_forced=1
  echo "ci: stopping what is left of the suite (process group $1)" >&2
  kill -TERM -- "-$1" "$1" 2>/dev/null
  ct_gone "$1" "${CI_TREE_STOP_SECONDS:-30}" && return 0
  kill -KILL -- "-$1" "$1" 2>/dev/null
  ct_gone "$1" 5
}

# ct_remove_labelled <run id>: removes what that run started and did not
# remove itself.
ct_remove_labelled() {
  local filter="label=$ct_label=$1" ids ok=0
  podman rm --force --time 0 --ignore --volumes --filter "$filter" >/dev/null || ok=1
  ids="$(podman network ls -q --filter "$filter")" || ok=1
  # shellcheck disable=SC2086 # one name per word
  [[ -z $ids ]] || podman network rm --force $ids >/dev/null || ok=1
  ids="$(podman volume ls -q --filter "$filter")" || ok=1
  # shellcheck disable=SC2086
  [[ -z $ids ]] || podman volume rm --force $ids >/dev/null || ok=1
  return "$ok"
}

# The EXIT trap, and so the only way out once the lock is in sight: what to
# post follows from the recorded state, not from how we got here.
ct_finalize() {
  local rc=$? state desc dirty head took
  set +e
  trap '' INT TERM HUP
  trap - EXIT
  if [[ -n $ct_waiter ]]; then
    kill -TERM "$ct_waiter" 2>/dev/null
    wait "$ct_waiter" 2>/dev/null
  fi
  if [[ -n $ct_child ]]; then
    ct_stop_suite "$ct_child" || ct_unsafe="the suite's processes did not stop"
    # The suite's process writes its group before it starts: none means it
    # never started; anything but our child means the record is not ours.
    if ! ct_read_record || [[ $ct_r_run != "$ct_run_id" ]] ||
      [[ -n $ct_r_pgid && $ct_r_pgid != "$ct_child" ]]; then
      ct_unsafe="${ct_unsafe:-the run record does not name this run}"
    elif [[ -z $ct_r_pgid && -n $ct_suite_rc ]]; then
      ct_suite_rc='' ct_error="could not record the suite's process group"
    else
      ct_suite_pgid=$ct_r_pgid
    fi
  fi
  if [[ -n $ct_run_id ]]; then
    ct_remove_labelled "$ct_run_id" || ct_unsafe="${ct_unsafe:-its containers, networks or volumes could not be removed}"
  fi
  if [[ $ct_labels == no && -n $ct_suite_pgid && (-n $ct_cancelled || -n $ct_forced || -n $ct_abnormal || -z $ct_suite_rc) ]]; then
    ct_unsafe="${ct_unsafe:-it ran a commit without the $ct_label label and did not finish normally, so its containers cannot be found}"
  fi
  if [[ -n $ct_unsafe ]]; then
    # The record stays: that is the quarantine.
    echo "reason=$ct_unsafe" >>"$ct_tree.run"
    echo "ci: $ct_unsafe; the CI tree stays quarantined ($ct_tree.run)" >&2
    ct_error="the run could not be cleaned up: see the local run"
  elif [[ -n $ct_recorded ]]; then
    rm -f -- "$ct_tree.run"
  fi
  [[ $ct_state == pending ]] || exit "$rc"

  state=error desc=$ct_error
  if [[ -n $ct_suite_rc && -z $ct_unsafe && -z $ct_cancelled && -z $ct_abnormal ]]; then
    took=$((SECONDS - ct_t_ready))
    # The run must leave the tree as the commit it certifies.
    if [[ -n $ct_forced ]]; then
      state=error desc="the suite left processes running: see the local run"
    elif ! dirty="$(git -C "$ct_tree" status --porcelain --untracked-files=normal)" ||
      ! head="$(git -C "$ct_tree" rev-parse HEAD)"; then
      state=error desc="could not check the CI tree: see the local run"
    elif [[ -n $dirty || $head != "$ct_sha" ]]; then
      echo "ci: the run changed the CI tree, so it may not have tested $ct_sha:" >&2
      echo "$dirty" >&2
      state=failure desc="the run changed the CI tree"
    elif ((ct_suite_rc == 0)); then
      state=success desc="passed in $((took / 60))m$((took % 60))s"
    else
      state=failure desc="failed: see the local run"
    fi
    printf 'ci: waited %ds, prepared the tree in %ds, suite %ds, total %ds\n' \
      $((ct_t_locked - ct_started)) $((ct_t_ready - ct_t_locked)) "$took" $((SECONDS - ct_started))
  fi
  rc=1
  if ct_post "$state" "$desc"; then
    ct_state=posted
    [[ $state != success ]] || rc=0
  elif [[ $state != error ]]; then
    ct_post error "could not post $state: see the local run"
  fi
  exit "$rc"
}

# ct_copy <source dir> <destination>: a reflink copy, or nothing. Only for
# directories git tracks nothing in.
ct_copy() {
  [[ -d $1 && ! -L $1 ]] || return 0
  mkdir -p "$(dirname "$2")"
  rm -rf -- "$2"
  cp -a --reflink=always "$1" "$2" || {
    echo "ci: could not reflink-copy $1; it is rebuilt instead" >&2
    rm -rf -- "$2"
  }
}

# Copies of the checkout's caches, once per tree.
ct_seed() {
  [[ "$(git -C "$ct_tree" config --get ci-tree.seeded 2>/dev/null || :)" == true ]] && return 0
  local lock fd dir rel
  if [[ -d $ct_src/target && ! -L $ct_src/target ]]; then
    echo "ci: seeding $ct_tree/target from $ct_src (reflink copies, one Cargo profile at a time)"
    # Cargo holds a profile's .cargo-lock while it builds there: the copy
    # waits for a running build, and a build started meanwhile waits for it.
    while IFS= read -r -d '' lock; do
      dir="${lock%/.cargo-lock}"
      rel="${dir#"$ct_src"/}"
      exec {fd}<"$lock"
      ct_lock_fd "$fd"
      ct_copy "$dir" "$ct_tree/$rel"
      exec {fd}<&-
    done < <(find "$ct_src/target" -maxdepth 3 -type f -name .cargo-lock -print0)
  fi
  while IFS= read -r -d '' dir; do
    rel="${dir#"$ct_src"/}"
    [[ ! -d $ct_tree/$(dirname "$rel") ]] || ct_copy "$dir" "$ct_tree/$rel"
  done < <(find "$ct_src" \( -path "$ct_src/target" -o -path "$ct_src/.git" \) -prune \
    -o -name node_modules -type d -prune -print0)
  # Merged into place: these directories may hold tracked files. A failed copy
  # can leave part of itself behind, in paths that may be kept between runs, so
  # the directory goes back to what the commit has.
  for rel in "${CI_TREE_SEED[@]}"; do
    [[ -d $ct_src/$rel && ! -L $ct_src/$rel ]] || continue
    mkdir -p "$ct_tree/$rel"
    cp -a --reflink=always "$ct_src/$rel/." "$ct_tree/$rel/" && continue
    echo "ci: could not seed $rel; it is rebuilt instead" >&2
    git -C "$ct_tree" clean -q -ffdx -- "$rel"
    git -C "$ct_tree" checkout -q --force HEAD -- "$rel" 2>/dev/null || :
  done
  git -C "$ct_tree" config ci-tree.seeded true
}

ct_prepare() {
  if [[ ! -e $ct_tree ]]; then
    git init -q "$ct_tree"
    git -C "$ct_tree" config ci-tree.managed true
  fi
  # Only ever reset and clean a tree this script made.
  if [[ "$(git -C "$ct_tree" rev-parse --show-toplevel 2>/dev/null || :)" != "$ct_tree" ||
    "$(git -C "$ct_tree" config --get ci-tree.managed 2>/dev/null || :)" != true ]]; then
    echo "ci: $ct_tree is not a CI tree; move it away or set CI_TREE" >&2
    return 2
  fi
  git -C "$ct_tree" fetch -q --no-tags "$ct_common" "+$ct_sha:refs/ci/tested"
  git -C "$ct_tree" checkout -q --force --detach refs/ci/tested
  # A symlinked cache root is not a directory to git, so -x removes it too.
  local keep=() path
  for path in "${CI_TREE_KEEP[@]}"; do keep+=(-e "$path"); done
  git -C "$ct_tree" clean -q -ffdx "${keep[@]}"
  if [[ "$(git -C "$ct_tree" rev-parse HEAD)" != "$ct_sha" ]]; then
    echo "ci: $ct_tree is not at $ct_sha after the reset" >&2
    return 1
  fi
  ct_seed
}

# ct_read_record: parses <tree>.run into ct_r_*; non-zero unless it is a
# complete version-3 record: every line whole and known, each field but
# `reason` at most once, v, run, labels and boot present, and a process
# group, if any, a positive number.
ct_read_record() {
  local line key seen=' '
  ct_r_v='' ct_r_run='' ct_r_pgid='' ct_r_labels='' ct_r_boot='' ct_r_reason=''
  [[ -f $ct_tree.run && -r $ct_tree.run ]] || return 1
  while IFS= read -r line || { [[ -n $line ]] && return 1; }; do
    key=${line%%=*}
    [[ $line == *=* ]] || return 1
    case $key in
      v | run | pgid | labels | boot | sha | src)
        [[ $seen != *" $key "* ]] || return 1
        seen+="$key "
        ;;
      reason) ;;
      *) return 1 ;;
    esac
    case $key in
      v) ct_r_v=${line#*=} ;;
      run) ct_r_run=${line#*=} ;;
      pgid) ct_r_pgid=${line#*=} ;;
      labels) ct_r_labels=${line#*=} ;;
      boot) ct_r_boot=${line#*=} ;;
      reason) ct_r_reason=${line#*=} ;;
    esac
  done <"$ct_tree.run"
  [[ $ct_r_v == 3 && -n $ct_r_run && -n $ct_r_boot && ($ct_r_labels == yes || $ct_r_labels == no) ]] &&
    [[ $seen != *" pgid "* || $ct_r_pgid =~ ^[1-9][0-9]*$ ]]
}

# A record left by an earlier run: retry its cleanup, or refuse to start.
ct_recover() {
  [[ -e $ct_tree.run ]] || return 0
  local why=''
  if ! ct_read_record; then
    echo "ci: an earlier run did not finish cleanly; checking what it left" >&2
    why="its record $ct_tree.run cannot be read or is incomplete"
    [[ -z $ct_r_v || $ct_r_v == 3 ]] ||
      why="its record $ct_tree.run is from another version of this library, whose containers may carry another label"
  else
    echo "ci: run $ct_r_run did not finish cleanly (${ct_r_reason:-the launcher stopped before cleaning up}); checking what it left" >&2
    # No process group: the suite never started, and cannot start any more
    # (it would have written one while holding the lock we now hold), so
    # there is nothing to find, labels or not.
    if [[ -z $ct_r_pgid ]]; then
      :
    elif [[ $ct_r_boot == "$(cat /proc/sys/kernel/random/boot_id)" ]] && ct_alive "$ct_r_pgid"; then
      why="its process group $ct_r_pgid is still running"
    elif [[ $ct_r_labels != yes ]]; then
      why="it ran a commit without the $ct_label label, so its containers cannot be found"
    elif ! ct_remove_labelled "$ct_r_run"; then
      why="its containers, networks or volumes could not be removed"
    fi
  fi
  if [[ -n $why ]]; then
    echo "ci: the CI tree is quarantined: $why" >&2
    echo "ci: check for leftover processes and \`podman ps -a --filter label=$ct_label\`, then delete $ct_tree.run" >&2
    exit 2
  fi
  rm -f -- "$ct_tree.run"
  echo "ci: cleaned up after run $ct_r_run" >&2
  ct_r_run='' ct_r_pgid='' ct_r_labels='' ct_r_boot='' ct_r_reason=''
}

ci_tree_run() {
  # Resolve everything before leaving this checkout. A CI_GH path is
  # relative to the repository root, as scripts/ci has always read it.
  case "$CI_GH" in
    */*) ct_gh="$(cd "$(dirname "$CI_GH")" && pwd)/$(basename "$CI_GH")" ;;
    *) ct_gh="$(command -v "$CI_GH")" || { echo "ci: CI_GH=$CI_GH is not a command" >&2; exit 2; } ;;
  esac
  ct_src="$PWD"
  ct_common="$(git rev-parse --path-format=absolute --git-common-dir)"
  ct_sha="$(git rev-parse --verify "${CI_SHA:-HEAD}^{commit}")"
  ct_tree="$(realpath -m "${CI_TREE:-${XDG_CACHE_HOME:-$HOME/.cache}/ci-local/${CI_REPO#*/}}")"

  # A status needs the commit on GitHub; say so now, not after the run.
  if ! "$ct_gh" api "repos/$CI_REPO/commits/$ct_sha" --silent 2>/dev/null; then
    echo "ci: $ct_sha is not on GitHub yet; push the branch first" >&2
    exit 2
  fi
  if [[ -z ${CI_SHA:-} && -n "$(git status --porcelain --untracked-files=normal)" ]]; then
    echo "ci: testing the commit $ct_sha; uncommitted changes in $ct_src are not part of the run" >&2
  fi

  trap ct_finalize EXIT
  trap ct_on_signal INT TERM HUP
  mkdir -p "$(dirname "$ct_tree")"
  exec 9>>"$ct_tree.lock"
  if ! flock -n 9; then
    echo "ci: waiting for the run in $ct_tree: $(cat "$ct_tree.holder" 2>/dev/null || echo "holder unknown")" >&2
    ct_lock_fd 9
  fi
  ct_t_locked=$SECONDS
  ct_recover
  # Cleanup can only find what carries this label, and finding nothing looks
  # like success, so the commit's own helper decides. Only the exact line counts:
  # a comment or a longer label name is no label, and anything unfamiliar errs
  # towards quarantine.
  local helper
  helper="$(git cat-file -p "$ct_sha:scripts/lib/ci-label.sh" 2>/dev/null || :)"
  ct_labels=no
  if [[ $'\n'"$helper"$'\n' == *$'\n'"$ct_label_line"$'\n'* ]]; then
    ct_labels=yes
  else
    echo "ci: $ct_sha does not use the $ct_label container label; if this run does not finish normally, the CI tree stays quarantined" >&2
  fi
  ct_run_id="$(cat /proc/sys/kernel/random/uuid)"
  printf 'pid %s, run %s, testing %s from %s since %s\n' $$ "$ct_run_id" "$ct_sha" "$ct_src" "$(date -Is)" >"$ct_tree.holder"
  # No record, no run: a launcher that dies leaves it behind for the next.
  if ! printf 'v=3\nrun=%s\nsha=%s\nsrc=%s\nlabels=%s\nboot=%s\n' "$ct_run_id" "$ct_sha" "$ct_src" \
    "$ct_labels" "$(cat /proc/sys/kernel/random/boot_id)" >"$ct_tree.run"; then
    echo "ci: could not write $ct_tree.run; not starting" >&2
    exit 2
  fi
  ct_recorded=1

  ct_state=pending
  ct_post pending "running in the CI tree"
  ct_prepare
  ct_t_ready=$SECONDS

  ct_error="interrupted"
  echo "ci: running scripts/ci of $ct_sha in $ct_tree (run $ct_run_id)"
  # Its own session, so the finalizer can stop the suite as a whole. The
  # child records its PID, which setsid keeps as the group ID (no job
  # control, so it is no group leader and setsid does not fork), while it
  # still holds the lock; only then does it let go of the lock's descriptor,
  # which no container may inherit, and start the suite.
  set +m
  ct_latch
  (
    cd "$ct_tree" || exit 125
    printf 'pgid=%s\n' "$BASHPID" >>"$ct_tree.run" || exit 125
    exec 9>&-
    exec setsid env -u CI_GH -u CI_SHA -u CI_TREE CI_RUN_ID="$ct_run_id" ./scripts/ci
  ) </dev/null &
  ct_child=$!
  ct_unlatch
  local rc=0
  wait "$ct_child" || rc=$?
  ct_suite_rc=$rc
  # Bash reports death by signal N as 128 + N; a script's own `exit 130`
  # looks the same, so both count as abnormal.
  if ((rc > 128)); then
    ct_abnormal=1 ct_error="the suite ended abnormally (status $rc; possibly a signal)"
  fi
  exit 0
}
