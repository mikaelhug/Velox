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
configured identically (8 vCPU)** and **both on Apple's Virtualization.framework**. Velox
wins on footprint, RAM, startup, container launch, networking (now including published
ports), VirtioFS, and the in-VM disk — and it does all of it with a **fully durable** data
disk (no data loss on crash, power-off, or in-place update). The one path it still trails is
cold image pull, called out honestly below.

- **Host:** Apple M-series, 24 GB, macOS 26 · **2026-06-09**
- **Engines:** Velox 0.1.20 (dockerd 29.5.3) vs Docker Desktop (dockerd 29.4.3), both on
  Apple **Virtualization.framework**, 8 vCPU, idle baseline.
- **Durable by default:** the data disk is a **raw** image attached `synchronizationMode:
  .fsync` with guest barriers **on** — fully crash-safe, and *faster* than Docker Desktop's
  durable commit. Launch is tuned with an `HZ_1000` kernel + expedited RCU. See
  [`docs/benchmarks.md`](docs/benchmarks.md) for the disk and launch notes.
- **Method + runnable harness:** [`docs/benchmarks.md`](docs/benchmarks.md). One engine
  under load at a time, identical pinned images, medians where applicable. Absolute figures
  vary by host — the doc ships the scripts to measure your own.

### Scorecard

| Metric | Velox | Docker Desktop | Result |
| --- | --- | --- | --- |
| Install footprint | **226 MB** | 2,328 MB | 🟢 **10× smaller** |
| Idle RAM (host RSS, all processes) | **~0.9 GB** | ~3.3 GB | 🟢 **3.7× less** |
| Startup (restart → API-ready, warm) | **1.74 s** | 2.55 s | 🟢 **1.5× faster** |
| Container launch (`run --rm alpine true`) | **104 ms** | 160 ms | 🟢 **1.5× faster** |
| Sequential churn (per container, ×30) | **0.104 s** | 0.170 s | 🟢 **1.6× faster** |
| Parallel launch ×20 (total) | **0.97 s** | 1.11 s | 🟢 1.1× faster |
| Network — container → host (iperf3) | **88.8 Gbit/s** | 27.0 Gbit/s | 🟢 **3.3× faster** |
| Published port — host → container (1 stream) | **38.4 Gbit/s** | 13.0 Gbit/s | 🟢 **2.9× faster** |
| Published port — host → container (4 streams) | **59.2 Gbit/s** | 18.0 Gbit/s | 🟢 **3.3× faster** |
| VirtioFS bind-mount write (`dd` 1 GiB) | **2,951 MB/s** | 956 MB/s | 🟢 **3.1× faster** |
| VirtioFS bind-mount read | **3,861 MB/s** | 1,628 MB/s | 🟢 **2.4× faster** |
| Small-file extract (4,000 files → bind) | **0.21 s** | 3.43 s | 🟢 **16× faster** |
| Durable commit latency (`fio --fsync`, 4 K) | **0.31 ms** | 0.47 ms | 🟢 **1.5× faster** |
| Named-volume write (in-VM ext4) | **1,630 MB/s** | 1,500 MB/s | 🟢 1.1× faster |
| Container-overlay write | **1,695 MB/s** | 1,217 MB/s | 🟢 **1.4× faster** |
| Postgres `pgbench` TPS (8 clients, 30 s) | **13,318** | 11,690 | 🟢 **1.14× faster** |
| Postgres `pgbench` init (scale 50) | **2.18 s** | 2.88 s | 🟢 **1.3× faster** |
| Cold image pull (381 MB on disk) | 19.1 s | 17.3 s | 🔴 ~0.9× (trails) |

### Where Velox wins

- **Footprint & startup.** A self-contained **226 MB** app (vs a 2.3 GB install) and one
  lean Swift supervisor + VM — **~0.9 GB** resident at idle vs Docker Desktop's UI + backend
  daemons (~3.3 GB) — that also restarts to a ready Docker API in **~1.7 s**.
- **Container launch.** `docker run --rm alpine true` is **~104 ms vs 160 ms**. An `HZ_1000`
  kernel plus `rcupdate.rcu_expedited=1` collapse the RCU grace-period waits that dominate
  veth/netns *teardown* on every `--rm`.
- **Published ports.** Inbound `-p` throughput now rides the fast VZNAT path via a pre-warmed
  conduit pool (data over VZNAT, control over VSOCK), hitting **38–60 Gbit/s vs 13–18** — a
  complete turnaround from the old vsock-relay bottleneck.
- **VZNAT uplink.** The container→host path is Apple's in-kernel NAT driven by a far leaner
  host, hitting **~89 Gbit/s** vs ~27. Repro: `iperf3 -s -B 0.0.0.0` on the Mac, then in a
  container `iperf3 -c host.docker.internal`.
- **VirtioFS.** Bulk bind-mount writes run ~3× faster, and metadata-heavy small-file work
  (the `node_modules` / `git clone` case) ~16× faster.
- **In-VM disk — durable *and* fast.** Even with a fully durable `.fsync` data disk, Velox
  **beats Docker Desktop's durable commit** (0.31 ms vs 0.47 ms) and posts higher
  overlay/volume write bandwidth and a `pgbench` TPS win.

### Durable data disk (no compromise)

Unlike a "dev-speed" writeback cache, Velox's data disk is **fully durable**: a raw image
attached `synchronizationMode: .fsync` with guest-side barriers on, so every committed write
survives a guest crash, a host crash (ext4 journal recovery), and an in-place app update —
**no more losing containers/images/volumes on restart.** On a raw image that durable `fsync`
is just an `fdatasync` of the dirty page (~0.3 ms), so durability costs essentially nothing
here: Velox is *faster* than Docker Desktop's durable commit while never sacrificing the
data. `vinit` reclaims freed space with periodic `fstrim` (VZ hole-punches the raw backing
file), so the image doesn't grow forever.

### On par — cold image pull

Cold image pulls land within ~10% of Docker Desktop (19.1 s vs 17.3 s) — same Apple
primitives, same stock `dockerd`, same containerd image store. The download itself rides the
fast VZNAT path; the small residual is durable layer *extraction* (fsync-heavy), the one
place the data-safety guarantee shows a measurable cost.

Full methodology, fairness controls, caveats, and the runnable harness live in
[`docs/benchmarks.md`](docs/benchmarks.md).
