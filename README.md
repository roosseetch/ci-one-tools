# ci-one-tools

Container images for building, testing and auditing Rust, Solana and
Node/Bun projects. The repo also has a reusable GitHub workflow that scans a
repository's lockfiles and images for known vulnerabilities. Everything runs
in Podman, on a laptop or a runner, with nothing installed on the host.

## Images

Published to GHCR as public packages. Pull them without logging in:

| Image | What's in it |
|---|---|
| `ghcr.io/roosseetch/ci-one-tools/sbf` | Rust 1.97.1, Agave 4.3.0 (`cargo-build-sbf`, `solana`, `solana-keygen`), platform-tools v1.57, Anchor CLI 1.2.1, Trident CLI 0.12.0, rustfmt, clippy |
| `ghcr.io/roosseetch/ci-one-tools/rust` | Rust 1.97.1 (slim Debian), pkg-config, rustfmt, clippy: the sbf toolchain without the Solana tools, for services and libraries |
| `ghcr.io/roosseetch/ci-one-tools/node` | Node 26 (LTS, Alpine), Bun 1.4.3 |
| `ghcr.io/roosseetch/ci-one-tools/web-test` | the node image plus Chromium, for Playwright |
| `ghcr.io/roosseetch/ci-one-tools/audit` | cargo-deny 0.20.2, Bun 1.4.3, Trivy 0.76.1, and the `lockfile-audit` and `scan-images` scripts |

`images/tags` lists every tag with the hash of the directory it was built
from. A tag is published once and never overwritten. Pin a tag and its
digest, for example `…/node:26.13.0-1@sha256:…`; the run summary of the
Images workflow lists the digest of each new tag.

### Tags

Tags are `<main upstream version>-<revision>`. For the audit image, which
bundles several tools, they are semantic versions. Any change under
`images/NAME` needs a new tag: append `NAME <tag> <hash>` to `images/tags`.
`bin/check-image-tags` prints the line to add. The reusable workflow pins the
audit image by digest, which exists only once the tag is published, so a new
audit tag takes two changes: the tag, then the pin; the check allows the
workflow to run the tag before the current one meanwhile.

A rebuild with no other change
(to take Debian's or Alpine's fixes) is a new revision too: change a comment
in the Containerfile and add the tag.

## Checking a repository

`lockfile-audit` runs cargo-deny advisories wherever a `Cargo.lock` is and
`bun audit` wherever a `bun.lock` is:

```bash
podman run --rm --log-driver=none -v "$PWD:/work" -w /work -v cargo-home:/cargo -e CARGO_HOME=/cargo \
  ghcr.io/roosseetch/ci-one-tools/audit:1.0.1 \
  lockfile-audit --deny-config deny.toml . frontend
```

Accepted advisories go in your own cargo-deny configuration (`[advisories]
ignore`, each with a reason) and in `--bun-ignore GHSA-…`.

`scan-images` scans images straight from their registries and prints a
Markdown table of HIGH and CRITICAL findings that have a fixed version. Only
a fixable CRITICAL finding, or an image it could not scan, makes it exit
non-zero:

```bash
printf '%s\n' docker.io/library/postgres:18.6 | podman run --rm --log-driver=none -i \
  ghcr.io/roosseetch/ci-one-tools/audit:1.0.1 scan-images
```

### The reusable workflow

`.github/workflows/security.yml` runs both checks and keeps one issue open in
the calling repository while findings remain. A clean run closes it. Pin it
by commit:

```yaml
name: Security
on:
  schedule: [{ cron: "17 5 * * *" }]
  workflow_dispatch:
jobs:
  security:
    permissions: { contents: read, issues: write }
    uses: roosseetch/ci-one-tools/.github/workflows/security.yml@<commit sha>
    with:
      audit-args: --deny-config deny.toml .
      bun-ignore-file: audit/bun-ignore.txt   # optional: advisories bun audit may report
      images: |
        docker.io/library/postgres:18.6
      images-command: ./scripts/list-images   # optional: more images, one per line
      checks: ./scripts/check-something       # optional: fails the run like a lockfile finding
```

`bun-ignore-file` holds the accepted advisories, so your local check can read
the same list. One per line: the GHSA id, then anything, such as the reason.
Blank lines and `#` comments are skipped. A file it can't read, or a line that
doesn't start with a well-formed GHSA id, fails the run.

Lockfile findings, failed checks and images that could not be scanned
fail the run. An image that fails to scan (a registry rate limit, the
network) is retried twice before that. Image findings only show up in the
report and the issue, because upstream images gain findings without any
change of yours.

### Containers that keep no log

`lib/check-one-shot-logs.sh` holds a repository's tracked files to one rule. A
one-shot container starts `podman run --rm --log-driver=none`, with
`"${CI_LABEL[@]}"` first if it has the label, so Podman stores none of its
output, which can hold a secret, whatever the machine's configuration. The
output still goes to the caller. A service (`podman run -d`) keeps its log, for
`podman logs`, and has no `--rm`.

Copy the file anywhere into your repository, keeping it executable, record the
commit and hash as for the CI tree library below, and run it from CI. It needs
bash and git, exits 1 on a launch that breaks the rule, and exits 2 if it can't
do the check. Markdown is skipped, and a launch built at runtime or through a
variable is not seen.

## Certifying a commit locally

`lib/ci-tree.sh` runs a repository's CI on your own machine and posts the result
as the `ci/local` commit status on GitHub. It runs the commit, not your working
copy: the commit's own `scripts/ci` runs in a separate, persistent tree, so you
can keep editing, and `target/` and `node_modules/` stay warm between runs. One
run per tree at a time; a second one waits.

It needs Linux, bash, git, Podman, `flock`, `setsid`, coreutils and a GitHub
client with an `api` command, such as `gh`. On a filesystem with reflinks
(btrfs, XFS), the first run seeds the tree's caches from your checkout instantly;
elsewhere they are rebuilt.

Copy both files from one commit of this repository into yours, and record that
commit and the hashes, so a local edit does not go unnoticed:

```text
scripts/lib/ci-tree.sh    from lib/ci-tree.sh
scripts/lib/ci-label.sh   from lib/ci-label.sh
```

Then start `scripts/ci` like this, keeping its work below the `if`:

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

CI_REPO="${CI_REPO:-owner/repository}"
if [[ -n "${CI_GH:-}" ]]; then
  CI_TREE_KEEP=(/target/ node_modules/)   # ignored paths kept between runs: caches only
  CI_TREE_SEED=()                         # further ignored directories copied on first use
  . scripts/lib/ci-tree.sh
  ci_tree_run                             # never returns
fi

# The suite. It runs again from here, in the tree, with CI_GH unset.
```

Run it with `CI_GH=gh scripts/ci`. The commit must be on GitHub already. Without
`CI_GH`, `scripts/ci` is just the suite, in place.

Give everything the suite starts the run's label, so a run that dies can be
cleaned up:

```bash
. scripts/lib/ci-label.sh
podman run "${CI_LABEL[@]}" --rm --log-driver=none ...
podman network create "${CI_LABEL[@]}" ...
podman volume create "${CI_LABEL[@]}" ...
```

| Setting | What it does | Default |
|---|---|---|
| `CI_GH` | GitHub client; a command, or a path relative to the repository | none: no certification |
| `CI_REPO` | `owner/name` the status goes to | set by `scripts/ci` |
| `CI_SHA` | commit to test | `HEAD` |
| `CI_TREE` | the tree | `~/.cache/ci-local/<name>` |
| `CI_TREE_STOP_SECONDS` | how long the suite gets between TERM and KILL | 30 |

### When a run does not finish

Each run keeps a record in `<tree>.run` until its cleanup is verified. If the
launcher dies, the next run retries the cleanup and carries on when the old
process group is gone and everything labelled with the old run's id is removed.

The tree stays quarantined, and runs exit 2 without doing anything, when that
cannot be established:

- the old suite is still running;
- labelled resources could not be removed;
- the record cannot be read, or another version of this library wrote it;
- the run tested a commit whose `scripts/lib/ci-label.sh` is missing or uses
  another label, and did not finish normally, so its containers cannot be found.

To clear it, look for leftovers with `podman ps -a --filter label=ci-tree.run`
(and the label of any older version you used), remove what is left, and delete
`<tree>.run`.

Keep the launcher at least as new as the commit you test: an older copy of the
library, started with `CI_SHA` set to a newer commit, looks for the older label
and finds nothing.

## This repository

- `bin/build-image NAME` builds an image under its current tag.
  `bin/image-tags` lists the current tags. `bin/check-image-tags` runs on
  every pull request.
- `tests/audit.sh IMAGE` checks the audit image against fixtures with known
  results.
- `tests/check-image-tags.sh` runs `bin/check-image-tags` on a copy of the tree,
  with the workflow's audit tag current, one behind, two behind and unpinned.
- `tests/security-workflow.sh` runs the reusable workflow's `bun-ignore-file`
  reader, taken from the workflow itself, against good and bad lists.
- `lib/check-one-shot-logs.sh` runs on this repository, and
  `tests/check-one-shot-logs.sh` runs it on throwaway repositories.
- `tests/ci-tree.sh` checks the CI tree library with real git, locks and signals
  and a fake Podman. `tests/ci-tree-podman.sh` checks what only real Podman can
  show, and pulls a small image to do it.
- Workflows: **CI** checks pull requests and builds the images they change.
  **Images** publishes new tags from `main`. **Image scan** runs Trivy daily
  over the published images and keeps an "Image scan findings" issue.
  Dependabot proposes base-image updates monthly, after a 7-day cooldown.

## Licences

This repository is under the Apache License 2.0 (`LICENSE`). The images
contain third-party software under its own licences:

- Rust: MIT or Apache-2.0
- Agave and platform-tools: Apache-2.0
- Anchor: Apache-2.0
- Trident: MIT
- Node.js: MIT
- Bun: MIT
- cargo-deny: MIT or Apache-2.0
- Trivy: Apache-2.0
- Chromium: BSD-3-Clause and others
- Debian and Alpine packages: their own licences
