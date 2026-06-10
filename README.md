<div align="center">

# Velox

**A fast, lean, open-source way to run Docker on Apple-silicon Macs.**

100% Swift host · stock Docker Engine · custom kernel.org kernel · no Electron, no Go, no background daemons

[![Latest release](https://img.shields.io/github/v/release/mikaelhug/Velox)](https://github.com/mikaelhug/Velox/releases)
![Platform](https://img.shields.io/badge/platform-macOS%2015%2B%20%C2%B7%20Apple%20Silicon-blue)
![Swift](https://img.shields.io/badge/host-100%25%20Swift-orange)

<img src="docs/images/dashboard.png" width="820" alt="Velox dashboard — engine status, resource cards, disk breakdown, live usage" />

</div>

Velox runs a real Docker Engine in a minimal Linux VM on Apple's
`Virtualization.framework` — and gets out of the way. The whole app is a
self-contained **226 MB**, idles around **0.9 GB RAM**, restarts to a ready
Docker API in **~1.7 s**, launches a container in **~100 ms**, and pushes
container networking at near-memory speeds — while keeping the data disk
**fully crash-durable**. All measured, all reproducible:
[docs/benchmarks.md](docs/benchmarks.md).

## Highlights

- **The stock `docker` CLI.** Velox ships no wrapper command — it registers a
  Docker context named `velox`, so `docker`, `compose`, `buildx`, Testcontainers
  and every Docker SDK just work, and it coexists with any other Docker install.
- **Reach containers by name.** Every container is reachable from the Mac at
  **`<name>.velox.local`** — its *real* IP, any protocol, no `-p` required.
  Pure DNS + routing, no proxy in the path.
- **A native Mac app, not Electron.** Containers (compose-grouped), images,
  volumes and networks dashboards with live CPU/MEM, streaming logs, a ⌘K
  command palette, a menu-bar quick panel, crash notifications, and one-click
  Reclaim Space.
- **Nested virtualization** (M3+, opt-in): `/dev/kvm` inside containers — run
  QEMU, Firecracker or Android emulators *inside* Docker.
- **Rosetta x86** (`--platform linux/amd64`), **VirtioFS** bind mounts, the
  **containerd image store** (multi-platform images, attestations, Wasm).
- **Event-driven everything.** No polling anywhere: published ports come up the
  instant a container starts, the UI reconciles off the Docker events stream, a
  Resource Saver reclaims idle guest RAM, and the guest clock survives Mac sleep.
- **Self-updating.** `velox update` or the in-app Update button pulls the latest
  GitHub release and swaps itself in place.

<div align="center">
<img src="docs/images/containers.png" width="820" alt="Containers dashboard — compose project grouping, per-container velox.local domains, live CPU/MEM" />
</div>

## Install

Requires **macOS 15+ on Apple Silicon**. The app is self-contained — guest
kernel, rootfs, engine and the `docker` client are all bundled.

```bash
curl -fsSL https://raw.githubusercontent.com/mikaelhug/Velox/main/install.sh | bash
```

Or manually: download the `.zip` from [Releases](https://github.com/mikaelhug/Velox/releases),
drag **Velox** to Applications, then clear Gatekeeper's download quarantine
(Velox is signed but not notarized):

```bash
xattr -dr com.apple.quarantine /Applications/Velox.app && open /Applications/Velox.app
```

First launch boots the engine, puts `docker` + `velox` on your `PATH` (rootless
symlinks), and registers the `velox` Docker context:

```bash
docker context use velox
docker run --rm hello-world
```

The app keeps the engine running while open; `velox start` runs it headless.
Updates: `velox update`, or Settings → General → Update (startup check is on by
default).

## Reach containers by name

```bash
docker run -d --name web nginx
curl http://web.velox.local          # the container's real IP — no -p needed

docker run -d --name db -e POSTGRES_HOST_AUTH_METHOD=trust postgres
psql -h db.velox.local -U postgres   # any protocol, not just HTTP
```

Compose services resolve too (`<service>.<project>.velox.local`). Named access
needs a one-time admin grant on first launch (a tiny root helper installs a
route + `/etc/resolver` entry — control-plane only, never connection data);
decline it and everything else still works.

## Performance

Measured on an Apple M-series Mac (8 vCPU, idle baseline). The full
methodology, fairness controls and a runnable harness to reproduce every
number on your own machine live in [docs/benchmarks.md](docs/benchmarks.md).

| Metric | Measured |
| --- | --- |
| Install footprint (self-contained app) | **226 MB** |
| Idle RAM (host RSS, all processes) | **~0.9 GB** |
| Startup (restart → API-ready, warm) | **1.74 s** |
| Container launch (`run --rm alpine true`) | **104 ms** |
| Network — container → host (iperf3) | **88.8 Gbit/s** |
| Published port — host → container (4 streams) | **59.2 Gbit/s** |
| VirtioFS bind-mount write / read (`dd` 1 GiB) | **2,951 / 3,861 MB/s** |
| Small-file extract (4,000 files → bind mount) | **0.21 s** |
| Durable commit latency (`fio --fsync`, 4 K) | **0.31 ms** |
| Container-overlay write | **1,695 MB/s** |
| Postgres `pgbench` TPS (8 clients, 30 s) | **13,318** |

**Durable by default:** the data disk is a raw image attached with
`synchronizationMode: .fsync` and guest barriers on — every committed write
survives a crash, a power-off and in-place updates. On a raw image that durable
commit costs ~0.3 ms, so data safety is essentially free; periodic `fstrim`
returns freed space to macOS automatically.

## How it's built

- **100% Swift host.** VM lifecycle, the Docker-API VSOCK proxy, port
  forwarding, DNS, clock sync and the SwiftUI app are one Swift process. The
  only privileged piece is a tiny optional root helper for `<1024` ports and the
  named-access route — control-plane only.
- **Apple's kernel networking (VZNAT).** The container datapath is in-kernel
  NAT — no userspace network stack, no proxy in the data path.
- **A custom, minimal kernel** built from kernel.org source: `tinyconfig` plus a
  curated fragment, monolithic, tuned for fast container launch (`HZ_1000`,
  expedited RCU).
- **A tiny Rust `vinit` as PID 1.** One static musl binary does every boot step
  via direct syscalls — mounts, cgroups, clock, native DHCP, data disk, Rosetta —
  then supervises stock `dockerd`. Guest root is a read-only, demand-paged
  **erofs** image. No LinuxKit, no initramfs, no dind.
- **Native-first.** Prefer what dockerd/the kernel already provide (e.g.
  dockerd 29's native nftables backend — the legacy iptables packages are simply
  not shipped) over extra userland; anything custom is focused Rust.

Versions are pinned in one place (`versions.env`); releases are built by CI on
every `v*` tag.

## vs Apple's `container`

Apple's [`container`](https://github.com/apple/container) validates the same
architecture (kernel.org kernel, tiny init, Swift on Virtualization.framework) —
but it speaks no Docker API, so compose and Docker tooling don't work, and its
VM-per-container model can't share named volumes and pays a VM boot per
container. Velox is a *Docker engine*: one shared VM, the real API, everything
Docker-compatible just works — and it runs on macOS 15, not just 26.

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
