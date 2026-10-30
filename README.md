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
`bin/check-image-tags` prints the line to add. A rebuild with no other change
(to take Debian's or Alpine's fixes) is a new revision too: change a comment
in the Containerfile and add the tag.

## Checking a repository

`lockfile-audit` runs cargo-deny advisories wherever a `Cargo.lock` is and
`bun audit` wherever a `bun.lock` is:

```bash
podman run --rm -v "$PWD:/work" -w /work -v cargo-home:/cargo -e CARGO_HOME=/cargo \
  ghcr.io/roosseetch/ci-one-tools/audit:1.0.0 \
  lockfile-audit --deny-config deny.toml . frontend
```

Accepted advisories go in your own cargo-deny configuration (`[advisories]
ignore`, each with a reason) and in `--bun-ignore GHSA-…`.

`scan-images` scans images straight from their registries and prints a
Markdown table of HIGH and CRITICAL findings that have a fixed version. Only
a fixable CRITICAL finding, or an image it could not scan, makes it exit
non-zero:

```bash
printf '%s\n' docker.io/library/postgres:18.6 | podman run --rm -i \
  ghcr.io/roosseetch/ci-one-tools/audit:1.0.0 scan-images
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
      images: |
        docker.io/library/postgres:18.6
      images-command: ./scripts/list-images   # optional: more images, one per line
      checks: ./scripts/check-something       # optional: fails the run like a lockfile finding
```

Lockfile findings and failed checks fail the run. Image findings only show
up in the report and the issue, because upstream images gain findings
without any change of yours.

## This repository

- `bin/build-image NAME` builds an image under its current tag.
  `bin/image-tags` lists the current tags. `bin/check-image-tags` runs on
  every pull request.
- `tests/audit.sh IMAGE` checks the audit image against fixtures with known
  results.
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
