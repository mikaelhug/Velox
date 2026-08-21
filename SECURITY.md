# Security Policy

## Supported versions

Only the **latest release** receives security fixes. Velox is a fast-moving
project with a self-updater (`velox update --apply` / the in-app Update button) —
update first, then re-test before reporting.

## Reporting a vulnerability

Please report vulnerabilities **privately** via
[GitHub Security Advisories](https://github.com/mikaelhug/Velox/security/advisories/new)
— do not open a public issue for anything exploitable. You should get a first
response within a week.

## Trust model (what to look at)

Velox's security-relevant surface is deliberately small:

- **`velox-porthelper`** is the *only* privileged component: a tiny root
  LaunchDaemon (Swift, `Sources/velox-porthelper/`) that binds loopback ports
  <1024 and passes the fd back, adds/removes host routes to RFC-1918 container
  subnets, and restores `net.inet.ip.forwarding=1` (restore-only — it can never
  disable forwarding). Its control socket is created `0600` under `umask 077`
  and every request is peer-checked (`getpeereid`) against the installing user's
  uid. Verifying the client's *code signature* additionally requires a Developer
  ID; until Velox ships with one, same-uid processes can talk to the helper —
  that is the accepted boundary. It never touches connection payloads: root
  stays out of the datapath.
- **Releases are Ed25519-signed.** CI signs each release `.zip`
  (`Scripts/release-sign.swift`); the in-app updater verifies the signature
  against the public key baked into the build (`VELOX_RELEASE_PUBKEY` in
  `versions.env`) and refuses unsigned or invalid archives. `install.sh`
  verifies the release `SHA256SUMS` (fail-closed) **and** the installed bundle's own code
  signature, and leaves Gatekeeper quarantine in place when the build is notarized. It
  cannot check the Ed25519 `.sig`: macOS ships LibreSSL, which has no Ed25519 support, and
  there is no portable verifier in base macOS — only the in-app updater performs that check.
  The `SHA256SUMS` come from the same release as the `.zip`, so they catch corruption and a
  swapped asset, not a compromised release page; the code-signature check is the one that
  does not share that trust root.
- **Build inputs are pinned.** The kernel.org tarball and both Docker static
  tarballs (guest daemon + bundled mac client) are SHA-256-pinned in
  `versions.env` and verified at build time.
- Everything else runs unprivileged as the logged-in user; the engine itself is
  isolated inside a Virtualization.framework VM.
