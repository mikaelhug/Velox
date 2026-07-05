# Contributing to Velox

Thanks for helping! Velox has a few **binding conventions** (see
[CLAUDE.md](CLAUDE.md) — it is the project's architecture contract, not just AI
tooling config). The short version:

- Host is **100% Swift**; guest code is **Rust only**; **no Go anywhere**.
- **Event-driven, never polling** — if you're adding a repeating timer to
  *check* something, find the event instead.
- The lean North Star rules: no LinuxKit, no dind, no initramfs, no extra
  daemons, prefer native dockerd/kernel capabilities over new userland.

## Build & test

```bash
./Scripts/build.sh              # gen versions + swift build + ad-hoc codesign
swift run velox-selftest        # dependency-free unit tests (CI-gated)
./Scripts/build-kernel.sh       # kernel (only if KERNEL_ORG_* / fragment changed)
./Scripts/make-guest.sh         # guest rootfs (erofs) → ~/.velox
```

Guest PID 1 (`guest/vinit/`) is linted against its real target:

```bash
rustup target add aarch64-unknown-linux-musl
cargo clippy --target aarch64-unknown-linux-musl -- -D warnings   # in guest/vinit/
```

CI (`.github/workflows/ci.yml`) runs the swift build + selftest and the vinit
clippy/check on every push and PR — keep both green.

## What a PR needs

- `swift run velox-selftest` passes; new pure logic gets a selftest section.
- No new versions hard-coded anywhere — **every** version/hash lives in
  `versions.env` (single source of truth). `Versions.swift` is generated; never
  hand-edit it.
- Changes that touch the datapath, kernel, disk format, or engine version must
  be benchmarked against the scorecard (`docs/bench/run.sh` vs
  `docs/benchmarks.md`) — a regression vs Docker Desktop blocks release.

## Maintainer-only actions

- **Bumping `VELOX_VERSION` and pushing `v*` tags.** A `v*` tag push triggers
  the release CI that the self-updater serves to every user — releases are cut
  only by the maintainer, deliberately (see the release gate in CLAUDE.md).
- Bumping `DOCKER_VERSION` (walk the checklist comment in `versions.env`,
  including the two SHA-256 pins and the named-access nft chains).
- Rotating the release signing key (`VELOX_ED25519_PRIVATE_KEY` secret +
  `VELOX_RELEASE_PUBKEY` in `versions.env`).

## Security issues

See [SECURITY.md](SECURITY.md) — private disclosure via GitHub Security
Advisories, please.
