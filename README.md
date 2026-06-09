# Velox

A lightweight, open-source way to run Docker on macOS — built to be **as lean,
efficient, and fast as possible, with the smallest footprint.** The whole supervisor
is pure Swift on `Virtualization.framework`; the guest is a minimal custom Linux image
(a from-source kernel + a compressed `erofs` rootfs of static binaries) running stock
`dockerd`. You drive it with the **stock `docker` CLI** — Velox ships no wrapper
command. Apple Silicon (arm64) first.

## Design — four pillars

- **Apple's kernel networking (VZNAT)** — the fastest container datapath on
  `Virtualization.framework` (measured ~14 Gbit/s down / ~80 Gbit/s up). No userspace
  network stack.
- **A 100% Swift host** — VM lifecycle, the Docker-API proxy, port forwarding, and the
  SwiftUI app are all pure Swift. **No Go, no host-side Rust, no helper daemons.**
- **Rust only for the tiny guest `vinit`** — a single static binary is the guest's PID 1
  and entire userland orchestration.
- **A custom, minimal kernel** — built from kernel.org source, only what the VM needs
  (`tinyconfig` + a curated fragment), tuned for fast container launch.

The Docker API socket is bridged Mac↔guest over **VSOCK**; directories are shared via
**VirtioFS**; the container network is Apple's in-kernel **VZNAT** (outbound + NAT in
the kernel); published **TCP and UDP** ports map back to `localhost`; and
`host.docker.internal` reaches the Mac.

## Installation

Velox ships as a self-contained `Velox.app` — it bundles the guest kernel + rootfs, the
engine, **and** the `docker` client, so nothing else is required on a fresh Mac. Requires
**macOS 15+ on Apple Silicon**.

> Velox is code-signed but not notarized, so a downloaded copy trips macOS Gatekeeper
> ("Apple could not verify…"). Both methods below clear the download-quarantine flag so it
> opens normally.

### Quick install (recommended)

```bash
curl -fsSL https://raw.githubusercontent.com/mikaelhug/Velox/main/install.sh | bash
```

This downloads the latest release, installs `Velox.app` into `/Applications`, clears the
quarantine flag, and launches it.

### Manual install

1. Download `Velox-<version>-macos-arm64.zip` from the
   [Releases](https://github.com/mikaelhug/Velox/releases) page.
2. Double-click to unzip and drag **Velox** into Applications.
3. Clear the quarantine flag, then open it:
   ```bash
   xattr -dr com.apple.quarantine /Applications/Velox.app
   open /Applications/Velox.app
   ```
   (Or open it once via **System Settings → Privacy & Security → "Open Anyway"**.)

On first launch Velox starts the engine, installs `docker` + `velox` onto your `PATH`
(rootless — symlinks under `~/.velox/bin`), and registers a `velox` Docker context. Then,
in any terminal:

```bash
docker run --rm hello-world
docker ps -a
```

The app keeps the engine running while it is open (quit it to stop the VM); or run it
headless from the terminal with `velox start`.

## Usage

Velox registers a Docker **context** named `velox` (pointing at `~/.velox/docker.sock`)
and you use the stock `docker` CLI, so it coexists with any existing Docker install:

```bash
docker context use velox          # make velox the active context (persistent)
docker --context velox ps         # …or target it per-command
export DOCKER_HOST=unix://~/.velox/docker.sock   # …or via an env var
```

Prefer your own command? Alias it: `alias vdocker='docker --context velox'`.
`velox version` shows component versions.

## Updating

`velox update` (CLI), or the **Update** button in **Settings → General**, checks GitHub
Releases for a newer build and installs it in place (downloads the release, swaps the
app, relaunches). **Check for updates on startup** is on by default, and the menu bar
shows a notice when a new version is available.

## Build from source (developers)

Building the guest needs **Docker** (the kernel and erofs rootfs are compiled inside
`linux/arm64` containers — no LinuxKit, no Go, no cross-toolchain) and a **Swift 6**
toolchain (Command Line Tools are enough — no full Xcode).

```bash
./Scripts/build-kernel.sh   # one-time: compile Assets/velox-vmlinux from kernel.org source (long)
./Scripts/make-guest.sh     # build the erofs root.img; install kernel+root.img to ~/.velox
./Scripts/build.sh          # swift build -c release + ad-hoc codesign with the VZ entitlement
./Scripts/run.sh start      # boot the guest; serial console on this terminal
./Scripts/build-app.sh      # package a self-contained Velox.app (+ .dmg, .zip)
```

`build-kernel.sh` compiles a bare arm64 kernel natively inside a `linux/arm64` container
on a named volume (never on APFS), emitting the raw uncompressed `Image` that
`VZLinuxBootLoader` requires. `make-guest.sh` builds a single read-only **erofs** root
image (`root.img`) from `guest/rootfs/Dockerfile` — the static Rust `vinit`, Docker's
static server binaries, and a tiny musl userland — no LinuxKit, no initramfs. The kernel
boots it directly (`root=/dev/vda rootfstype=erofs`). Everything is version-pinned in
`versions.env` (the single source of truth); the kernel config lives in
`guest/kernel/velox.fragment`.

The signing entitlement is `com.apple.security.virtualization`
(`Resources/Entitlements/velox.entitlements`). Verify it is embedded:

```bash
codesign -d --entitlements - "$(swift build -c release --show-bin-path)/velox"
```

Releases are built by CI on every `v*` tag (`.github/workflows/release.yml`): the guest
is built on a native arm64 Linux runner, the app + package on macOS, and the `.dmg`/`.zip`
are attached to a GitHub Release.

## What works

A full, daily-driver Docker engine plus a native menu-bar app:

- **Engine** — `docker run/build/compose`, the **containerd image store** (multi-platform
  images, attestations, Wasm), a persistent data disk, **VirtioFS `-v` host mounts**, and
  **Rosetta x86** (`--platform linux/amd64`). Stock `dockerd`, native nftables firewall.
- **Networking** — Apple VZNAT, `host.docker.internal`, and reverse port forwarding for
  published **TCP and UDP** ports (`-p 8080:80`, `-p 53:53/udp`) → `localhost`.
- **Lifecycle** — host-authoritative clock (survives sleep), a Resource Saver that
  reclaims idle guest RAM, graceful stop that flushes the data disk, and event-driven
  reconciliation (no polling — ports come up the instant a container publishes them).
- **App** — containers, images, volumes, and networks dashboards with live CPU/memory
  sparklines and log streaming; an engine-console log view; resource settings
  (CPU/RAM/disk/swap/file-sharing); a self-contained, self-updating bundle.

End-to-end: open Velox → `docker run -d -p 8080:80 nginx` → `curl localhost:8080`.

## Performance

The north star is to be **as lean, efficient, and fast as possible, with the smallest
footprint** — beating Docker Desktop where possible, and on par where not. The table below
is a full head-to-head measured on the same Mac, the same way, with **both engines
configured identically (8 vCPU / 8 GB)**. Velox wins on footprint, startup, container
launch, the VZNAT uplink, VirtioFS, and the in-VM disk hot path; it's on par on cold pulls
and bulk DB load; and the one path it still **trails** is inbound published-port throughput,
called out honestly below.

- **Host:** Apple M4 Pro (8P+4E), 24 GB, macOS 26.5.1 · **2026-06-09**
- **Engines:** Velox 0.1.11 (dockerd 29.5.3) vs Docker Desktop (dockerd 29.4.3), both on
  `Virtualization.framework`, 8 vCPU / 8 GB, idle baseline.
- Velox runs a **dev-tuned profile**: a host writeback data disk (`.none` + `nobarrier`,
  with a boot `e2fsck`) and **expedited-RCU** launch tuning — see [the disk &
  launch notes](docs/benchmarks.md) for the speed/durability trade.
- **Method + runnable harness:** [`docs/benchmarks.md`](docs/benchmarks.md). One engine
  under load at a time, identical pinned images, medians where applicable. Absolute figures
  vary by host — the doc ships the scripts to measure your own.

### Scorecard

| Metric | Velox | Docker Desktop | Result |
| --- | --- | --- | --- |
| Install footprint | **226 MB** | 2,328 MB | 🟢 **10× smaller** |
| Idle RAM (host RSS, all processes) | **871 MB** | 2,296 MB | 🟢 **2.6× less** |
| Startup (restart → API-ready, warm) | **1.74 s** | 2.55 s | 🟢 **1.5× faster** |
| Container launch (`run --rm alpine true`) | **89 ms** | 158 ms | 🟢 **1.8× faster** |
| Sequential churn (per container, ×30) | **0.113 s** | 0.160 s | 🟢 **1.4× faster** |
| Parallel launch ×20 (total) | **0.82 s** | 1.19 s | 🟢 **1.4× faster** |
| Network — container → host (iperf3) | **93.3 Gbit/s** | 25.7 Gbit/s | 🟢 **3.6× faster** |
| VirtioFS bind-mount write (`dd` 1 GiB) | **1,979 MB/s** | 692 MB/s | 🟢 **2.9× faster** |
| VirtioFS bind-mount read | **2,879 MB/s** | 2,163 MB/s | 🟢 1.3× faster |
| Small-file extract (4,000 files → bind) | **0.31 s** | 3.14 s | 🟢 **10× faster** |
| In-VM durable commit (`fdatasync`) | **58 µs** | 131 µs | 🟢 **2.3× faster** |
| Named-volume write (in-VM ext4) | **2,393 MB/s** | 1,670 MB/s | 🟢 **1.4× faster** |
| Container-overlay write | **2,537 MB/s** | 1,590 MB/s | 🟢 **1.6× faster** |
| Postgres `pgbench` TPS (8 clients, 30 s) | **14,903** | 12,904 | 🟢 **1.15× faster** |
| Cold image pull (381 MB on disk) | 18.5 s | 16.9 s | ⚪ par |
| Postgres `pgbench` init (scale 50) | 2.48 s | 2.37 s | ⚪ par |
| Published port — host → container (1 stream) | 1.44 Gbit/s | 12.1 Gbit/s | 🔴 **trails ~8×** |
| Published port — host → container (4 streams) | 1.09 Gbit/s | 18.6 Gbit/s | 🔴 **trails ~17×** |

### Where Velox wins

- **Footprint & startup.** A self-contained **226 MB** app (vs a 2.3 GB install) and one
  lean Swift supervisor + VM — **871 MB** resident at idle vs Docker Desktop's UI + backend
  daemons (~2.3 GB) — that also restarts to a ready Docker API in **~1.7 s**.
- **Container launch.** `docker run --rm alpine true` is **~89 ms vs 158 ms**. Two tunings
  get there: the writeback data disk removes the per-commit fsync tax on overlay-snapshot
  setup, and `rcupdate.rcu_expedited=1` collapses the RCU grace-period waits that dominate
  veth/netns *teardown* on every `--rm` (~23% of launch on its own).
- **VZNAT uplink.** The container→host path is Apple's in-kernel NAT driven by a far leaner
  host, hitting **93 Gbit/s** vs ~26. Repro: `iperf3 -s -B 0.0.0.0` on the Mac, then in a
  container `iperf3 -c host.docker.internal`.
- **VirtioFS.** Bulk bind-mount writes run ~2.9× faster, and metadata-heavy small-file work
  (the `node_modules` / `git clone` case) ~10× faster.
- **In-VM disk.** The writeback data disk (`.none` + `nobarrier`) gives **~2.3× lower
  commit latency** and ~1.4–1.6× write bandwidth, so `pgbench` TPS beats DD too. A native
  macOS `fsync` costs ~3.9 ms here, so durable-per-commit (Velox's old default, and what
  the *guarantee* costs) caps throughput; the dev profile trades that for speed — see below.

### The dev-speed disk trade

Velox is a development engine — containers/images/volumes are recreatable, not a system of
record — so the data disk runs as a **host writeback cache** (no durable host `fsync` per
commit), exactly like Docker Desktop, plus `nobarrier` to drop the now-pointless guest FLUSH
round-trips. The only risk window is an unclean **host** shutdown (power loss / kernel
panic) losing the last unflushed writes; a guest crash or clean quit is safe, and `vinit`
preen-`fsck`s the disk on boot if it wasn't unmounted cleanly. This is a deliberate
speed-over-durability default; the full ladder and how to revert it are in
[`docs/benchmarks.md`](docs/benchmarks.md).

### On par

Cold image pulls and bulk DB load (`pgbench` init) land within ~10% of Docker Desktop —
same Apple primitives, same stock `dockerd`, same containerd image store.

### Where Velox trails (today)

- **Inbound published-port throughput.** A host→container connection to a published port
  (`-p`) routes through the host-side userspace `PortForwarder` over VSOCK, which **serializes
  and does not scale with parallel streams** (~1.1–1.4 Gbit/s vs 12–19). This is the *inbound*
  path only — the *outbound* VZNAT path is 3.6× faster than Docker Desktop. The in-scope fix
  (carry the data over the fast VZNAT path, control over VSOCK) is on the roadmap. Repro:
  `docker run -d -p 5301:5201 networkstatic/iperf3 -s` then `iperf3 -c 127.0.0.1 -p 5301`.

Full methodology, fairness controls, caveats, and the runnable harness live in
[`docs/benchmarks.md`](docs/benchmarks.md).
