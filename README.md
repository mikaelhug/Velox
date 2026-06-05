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

## Install

Velox ships as a self-contained `Velox.app` — it bundles the guest kernel + rootfs, the
engine, **and** the `docker` client, so nothing else is required on a fresh Mac.

1. Download `Velox-<version>-macos-arm64.dmg` from the
   [Releases](https://github.com/mikaelhug/Velox/releases) page.
2. Drag **Velox** into Applications and open it.
3. On first launch Velox starts the engine, installs `docker` + `velox` onto your `PATH`
   (rootless — symlinks under `~/.velox/bin`), and registers a `velox` Docker context.

Then, in any terminal:

```bash
docker run --rm hello-world
docker ps -a
```

Requires **macOS 15+ on Apple Silicon**. The app keeps the engine running while it is
open (quit it to stop the VM); or run it headless from the terminal with `velox start`.

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

The north star is to be **as lean, efficient, and fast as possible with the smallest
footprint** — beating the leading VM-based Docker engines where possible, and at least on
par otherwise. Numbers below were measured on Apple Silicon, same Docker Engine version
(29.x) on both sides, 10 vCPU / 16 GB both, 2026-06. They vary by host; each table has a
one-line reproduction. The comparison column is the leading VM-based alternative for
macOS, measured the same way.¹

**Scorecard:** Velox **wins** on container launch, cold start, idle RAM, network
throughput, and `docker cp`; and is **on par** on disk reclaim, VirtioFS, x86 emulation,
and published-port reachability.

### Container launch — **win** (`docker run --rm alpine true`, warm)

| | Velox | Leading alternative |
| --- | --- | --- |
| full network | **~0.17 s** | ~0.19 s |
| `--network none` | **~0.12 s** | ~0.15 s |

Both engines do the same per-container veth/bridge work; Velox does the rest faster. The
win comes from a finer scheduler tick (`HZ=1000` + lazy preemption) — per-container
network setup is full of short kernel waits that round up to the tick — and a
**host-cached engine disk** (the VZ block device runs `cachingMode: .cached`), which
routes overlay-snapshot metadata I/O through the page cache. Repro:
`time docker run --rm alpine true` (warm image, average a few runs); compare `--network none`.

### Cold start — **win** (launch → `docker` ready, warm caches)

| Velox | Leading alternative |
| --- | --- |
| **~0.8–1.3 s** | ~5.6 s |

Repro: `time` from `velox start` until `docker version` succeeds.

### Idle RAM — **win** (host-side resident memory, no containers)

| Velox | Leading alternative |
| --- | --- |
| **~13 MiB** | ~630 MiB |

One lean VM-supervisor process vs a UI + backend daemons + helpers. (Guest RAM is
accounted separately by VZ for both.) Repro:
`ps -o rss= -p "$(pgrep -f release/velox)"`.

### Network throughput — **win** (iperf3, container ↔ Mac, Apple VZNAT both sides)

| direction | Velox | Leading alternative |
| --- | --- | --- |
| upload (container → host) | **~87 Gbit/s** | ~25 Gbit/s |
| download (host → container) | **~13.5 Gbit/s** | ~12.5 Gbit/s |

Same in-kernel datapath, but Velox's far leaner host gets closer to the ceiling. Repro:
`iperf3 -s -B 0.0.0.0` on the Mac, then in a container
`apk add iperf3 && iperf3 -c host.docker.internal` (add `-R` for download).

### `docker cp` throughput — **win** (1 GiB in/out of a container, over the VSOCK data plane)

| direction | Velox | Leading alternative |
| --- | --- | --- |
| cp in (host → container) | **~393 MiB/s** | ~149 MiB/s |
| cp out (container → host) | **~508 MiB/s** | ~226 MiB/s |

Velox's lean Rust VSOCK relay is ~2.5× faster. Repro:
`docker run -d --name c alpine sleep 300 && time docker cp <1GiB-file> c:/big && time docker cp c:/big /tmp/out`.

### Disk reclaim — **on par** (pull 1 GiB image → remove → trim)

Velox's data disk is a sparse ASIF image that starts at tens of MiB and returns freed
space to macOS (guest `fstrim` + ASIF hole-punch). Repro: `du -m ~/.velox/data.img`
before/after `docker pull python:3.12`, then `docker rmi python:3.12` + an `fstrim`.

### VirtioFS write — **on par** (`dd` 1 GiB, `conv=fsync`; same Apple VirtioFS)

~1.0–1.9 GB/s — bounded by Apple's VirtioFS, which both engines use. Repro:
`docker run --rm -v "$PWD":/mnt alpine dd if=/dev/zero of=/mnt/big bs=1M count=1024 conv=fsync`.

### x86 emulation — **on par** (Rosetta, amd64 workload)

~0.2 s for a small amd64 workload (container-start subtracted) — native Apple Rosetta
both sides. Repro:
`time docker run --platform linux/amd64 --rm python:3.12-slim python3 -c pass`.

### Published-port reachability — **on par** (`docker run -d -p` → `curl` 200)

~0.4–0.6 s — a published port becomes reachable almost immediately, because the watcher
is **event-driven** (it rides the Docker `/events` stream over the in-process VSOCK client
rather than polling). Repro: `docker run -d -p 18080:80 nginx`, then poll
`curl -s localhost:18080` until it answers.

---

¹ Comparisons are against the leading VM-based Docker engine for macOS, on the same Docker
Engine version and resource allocation, measured on the same Mac. Absolute figures vary by
hardware; the reproduction commands above let you measure your own.
