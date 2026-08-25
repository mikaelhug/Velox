<div align="center">

# Velox

**A fast, lean, open-source way to run Docker on Apple-silicon Macs.**

100% Swift host · stock Docker Engine · custom kernel.org kernel · no Electron, no Go, no background daemons

[![Latest release](https://img.shields.io/github/v/release/mikaelhug/Velox)](https://github.com/mikaelhug/Velox/releases)
![Platform](https://img.shields.io/badge/platform-macOS%2015%2B%20%C2%B7%20Apple%20Silicon-blue)
![Swift](https://img.shields.io/badge/host-100%25%20Swift-orange)
[![License](https://img.shields.io/badge/license-LGPL--2.1+-blue)](LICENSE)

[Website](https://mikaelhug.github.io/Velox/) ·
[Benchmarks](docs/benchmarks.md) ·
[Releases](https://github.com/mikaelhug/Velox/releases) ·
[Discord](https://discord.gg/kNysBA9VU5)

<img src="docs/images/dashboard.png" width="820" alt="Velox dashboard — engine status, resource cards, disk breakdown, live usage" />

</div>

Velox runs a real Docker Engine in a minimal Linux VM on Apple's
`Virtualization.framework` — and gets out of the way: a self-contained app that
installs in 357 MB, restarts to a ready Docker API in about 1.2 seconds, and
settles to well under half a gigabyte once its resource saver kicks in. Numbers
below, with the methodology, the raw values and a runnable harness in
[docs/bench/REPORT-2026-08-25.md](docs/bench/REPORT-2026-08-25.md).

## Highlights

- **The stock `docker` CLI.** No wrapper command — Velox registers a Docker
  context named `velox`, so Testcontainers and every Docker SDK just work,
  alongside any other Docker install. **`compose` and `buildx` are bundled**: the
  app ships and links the two CLI plugins into `~/.docker/cli-plugins`, so
  `docker compose` / `docker buildx` work on a clean Mac with no Docker Desktop —
  and it never overwrites a compose/buildx you already have.
- **Reach containers by name** at `<name>.velox.local` — details below.
- **A native Mac app.** Compose-grouped containers, images, volumes and
  networks with live CPU/MEM, streaming logs, a ⌘K command palette, a menu-bar
  quick panel, crash notifications, and one-click Reclaim Space.
- **Nested virtualization** (M3+, opt-in): `/dev/kvm` inside containers — run
  QEMU, Firecracker or Android emulators *inside* Docker.
- **Multi-arch out of the box.** `linux/amd64` runs on **Rosetta**, `linux/arm`
  (v5/v6/v7) and `linux/386` on built-in QEMU — registered in the guest at boot, so
  there is no privileged `multiarch/qemu-user-static` step to re-run after every restart.
- **VirtioFS** bind mounts and the **containerd image store** (multi-platform
  images, attestations, Wasm).
- **Event-driven, never polling.** Published ports come up the instant a
  container starts; a Resource Saver balloons an idle engine down to a
  **sub-100 MB** host footprint; the guest clock survives Mac sleep.
- **Self-updating** — `velox update` or the in-app Update button.

<div align="center">
<img src="docs/images/containers.png" width="820" alt="Containers dashboard — compose project grouping, per-container velox.local domains, live CPU/MEM" />
</div>

## Install

Requires **macOS 15+ on Apple Silicon**. Guest kernel, rootfs, engine and the
`docker` client are all bundled.

```bash
curl -fsSL https://raw.githubusercontent.com/mikaelhug/Velox/main/install.sh | bash
```

Or manually: download the `.zip` from [Releases](https://github.com/mikaelhug/Velox/releases),
drag **Velox** to Applications, and clear Gatekeeper's download quarantine
(Velox is signed but not notarized):

```bash
xattr -dr com.apple.quarantine /Applications/Velox.app && open /Applications/Velox.app
```

First launch boots the engine, puts `docker` + `velox` on your `PATH`
(rootless symlinks), and registers the context:

```bash
docker context use velox
docker run --rm hello-world
```

The app boots the engine automatically on launch and keeps it running while
open; `velox start` runs the same engine headless (no GUI needed).

## Reach containers by name

Every container is reachable from the Mac at **`<name>.velox.local`** — its
*real* IP, any protocol, no `-p` required. Pure DNS + routing, no proxy in the
data path:

```bash
docker run -d --name web nginx
curl http://web.velox.local          # no published port needed

docker run -d --name db -e POSTGRES_HOST_AUTH_METHOD=trust postgres
psql -h db.velox.local -U postgres   # any protocol, not just HTTP
```

Compose services resolve as `<service>.<project>.velox.local`. This needs a
one-time admin grant on first launch (a tiny root helper installs a route and
an `/etc/resolver` entry — control-plane only, it never touches connection
data); decline it and everything else still works.

## Published ports

`-p` follows Docker's own default: a published port binds **all interfaces**,
so it is reachable from other machines on your network — the same as Docker
Desktop, OrbStack and colima. Ports below 1024 work too (`-p 80:80`, `-p 22:22`).

```bash
docker run -d -p 8080:80 nginx              # reachable at <your-mac-ip>:8080
docker run -d -p 127.0.0.1:5432:5432 postgres   # host-only, stays private
```

An explicit **`127.0.0.1:`** in the `-p` spec always wins — a service you
deliberately pinned to loopback is never widened. To make host-only the
*default* for every port, set `publishHostIP` in `~/.velox/config.json`:

```json
{ "publishHostIP": "127.0.0.1" }
```

The value may also be a specific host address; an unparseable one falls back to
host-only rather than exposing anything. Changing it restarts the engine.

Two limits worth knowing: a **non-loopback host IP inside the `-p` spec**
(`-p 192.168.1.50:8080:80`) is unsupported — the guest daemon can't bind a
macOS address, so use `publishHostIP` instead; and a specific `publishHostIP`
can't be applied to ports below 1024, which fall back to host-only with a
warning.

## Performance

Measured against Docker Desktop 4.88.0 on the same Mac, on the same day, the same
way — and the comparison is a close one to make fairly, because **both engines run
the identical Docker Engine 29.7.2**, the same containerd image store, the same
`docker` CLI and the same compose plugin, at a verified 8 vCPU / ~8 GB each, with
only one engine resident at a time. What differs is the host around the engine.

Medians over five order-balanced rounds (three for build/compose). Full
methodology, every raw value, and the cases where Docker Desktop wins are in
[docs/bench/REPORT-2026-08-25.md](docs/bench/REPORT-2026-08-25.md).

| Metric | Velox | Docker Desktop | vs Docker Desktop |
| --- | --- | --- | --- |
| Install footprint | 357 MB | 2,193 MB | 6× smaller |
| Idle RAM (host RSS, whole engine) | 734 MB | 1,771 MB | 2.4× less |
| Idle RAM after the resource saver | 373 MB | 847 MB | 2.3× less |
| Idle CPU (4 min, whole engine) | 0.76 % | 3.52 % | 4.6× less |
| RAM with 21 containers running | 1,949 MB | 2,991 MB | 1.5× less |
| Startup (restart → API-ready, warm) | 1.23 s | 1.99 s | 1.6× faster |
| Container launch (`run --rm alpine true`) | 0.11 s | 0.13 s | 1.2× faster |
| Published port — host → container (4 streams) | 59.8 Gbit/s | 25.3 Gbit/s | 2.4× faster |
| `docker cp` out / in (1 GiB) | 540 / 373 MB/s | 225 / 154 MB/s | ~2.4× faster |
| Disk handed back after deleting ~5 GB | 5,295 MB | 3,594 MB | 1.5× more returned |
| Named-volume write (`dd` 1 GiB) | 2,115 MB/s | 1,840 MB/s | on par |
| Image extraction (`docker load`) | 6.70 s | 6.38 s | on par |
| Incremental `docker build` | 1.52 s | 1.56 s | on par |
| Postgres `pgbench` TPS (8 clients, 30 s) | 13,796 | 12,372 | on par |
| Small-file extract (4,000 files → bind) | 3.21 s | 2.56 s | **25% slower** |
| `compose down` (SIGTERM-ignoring services) | 10.4 s | 3.5 s | **3× slower** |

Two honest trails. `compose down` is the one users feel: for a container that
ignores `SIGTERM` — most containers running a bare command as PID 1 — Velox waits
Docker's documented 10-second grace period before `SIGKILL`, while Docker Desktop
escalates at about 3 s. Given an explicit `docker stop -t`, the two are
indistinguishable. Small-file extraction over VirtioFS is the other, and it is the
only filesystem metric Velox loses; bulk reads, named-volume and overlay writes are
par or better.

Functionally the two engines came out level on every probe that was run — bind
mounts, `host.docker.internal`, TCP/UDP/IPv6 publishing, privileged ports, BuildKit
with attestations, and `linux/amd64`, `linux/arm/v7` and `linux/386` emulation
(where the emulation tax is the same on both, 4.9× vs 4.8× over native). Velox adds
`<name>.velox.local`; Docker Desktop supports per-container host-IP publishing,
which Velox does not. Docker Desktop also ships Kubernetes, Scout, Extensions and
its AI tooling — none of which Velox has, and which account for much of the size
difference above.

The data disk is durable by default: a raw image attached with
`synchronizationMode: .fsync` and guest barriers on, so every committed write
survives a crash, a power-off and in-place updates. Periodic `fstrim` returns freed
space to macOS — measured above at 96% of a 5 GB delete handed back.

## How it's built

- **One Swift process** hosts everything: VM lifecycle, the Docker-API VSOCK
  proxy, port forwarding, DNS and the SwiftUI app. The only privileged piece
  is a tiny optional root helper for `<1024` ports and the named-access route.
- **Apple's in-kernel networking (VZNAT)** is the container datapath — no
  userspace network stack anywhere.
- **The kernel is built from kernel.org source**: `tinyconfig` plus a curated
  fragment, monolithic, tuned for fast container launch (`HZ_1000`, expedited
  RCU).
- **A tiny Rust `vinit` is PID 1**: one static musl binary does every boot
  step via direct syscalls — mounts, cgroups, clock, native DHCP, data disk,
  Rosetta — then supervises stock `dockerd` on a read-only, demand-paged
  **erofs** root. No LinuxKit, no initramfs, no dind.
- **Native-first**: prefer what dockerd and the kernel already provide (e.g.
  dockerd 29's nftables backend — the legacy iptables packages are simply not
  shipped); anything genuinely custom is focused Rust.

Every version is pinned in one file (`versions.env`); CI builds a release on
every `v*` tag.

## VPNs

Velox coexists with VPNs — including full-tunnel WireGuard — with one known
interaction: some VPN clients (notably the OpenVPN-based **AWS VPN Client**)
silently switch off macOS's kernel packet forwarding when they connect, which
kills NAT egress for **every** VM on the Mac (vmnet-based Docker engines, UTM,
Internet Sharing…), not just Velox. The symptom is DNS resolving but every
container connection timing out. Velox detects the flip the moment it happens
(event-driven, no polling) and restores forwarding through its privileged
helper, so container networking keeps working with the VPN connected. If the
helper grant was declined, the engine log names the cause and the one-line
manual fix (`sudo sysctl -w net.inet.ip.forwarding=1`).

## vs Apple's `container`

Apple's [`container`](https://github.com/apple/container) validates the same
architecture (kernel.org kernel, tiny init, Swift on Virtualization.framework)
but speaks no Docker API — compose and Docker tooling don't work — and its
VM-per-container model can't share named volumes and pays a VM boot per
container. Velox is a *Docker engine*: one shared VM, the real API, and it
runs on macOS 15, not just 26.

## Build from source

Needs Docker (guest builds run in `linux/arm64` containers) and a Swift 6
toolchain (Command Line Tools are enough).

```bash
./Scripts/build-kernel.sh   # one-time: compile the kernel from source (long)
./Scripts/make-guest.sh     # build the erofs rootfs; install to ~/.velox
./Scripts/build.sh          # swift build -c release + ad-hoc codesign
./Scripts/build-app.sh      # package a self-contained Velox.app
./Scripts/run.sh start      # or: boot headless with a serial console
```

The signing entitlement is `com.apple.security.virtualization` only. Kernel
config lives in `guest/kernel/velox.fragment`; the guest filesystem in
`guest/rootfs/Dockerfile`.

## License

Velox is licensed under the GNU Lesser General Public License, version 2.1 or
later (`SPDX-License-Identifier: LGPL-2.1-or-later`). See [`LICENSE`](LICENSE)
for the full text.
