# Velox

A lightweight, open-source Docker Desktop / OrbStack alternative for macOS, built
to be **as lean, efficient, and fast as possible with the smallest footprint** —
beating Docker Desktop and OrbStack on performance where possible, and at least on
par otherwise.

The design, in four pillars:

- **Apple's kernel networking (VZNAT)** — the fastest container datapath on
  `Virtualization.framework` (measured ~14 Gbit/s down / ~80 Gbit/s up, beating
  Docker Desktop). No userspace network stack.
- **A 100% Swift host** — VM lifecycle, the Docker-API proxy, port forwarding, and
  the SwiftUI app are all pure Swift. **No Go, no host-side Rust.**
- **Rust only for the tiny guest `vinit`** — a single static binary is the guest's
  PID 1 and entire userland orchestration.
- **A custom, minimal kernel** — built from kernel.org source, only what the VM
  needs (`tinyconfig` + a curated fragment), with high-performance Rust added in the
  guest where it helps.

The Docker API socket is bridged Mac↔guest over **VSOCK**; directories are shared
via **VirtioFS**; the container network is Apple's in-kernel **VZNAT** (outbound +
NAT in the kernel); published ports map back to `localhost`; and
`host.docker.internal` reaches the Mac.

Targets **Apple Silicon (arm64)** first.

## Requirements

- macOS 15+ on Apple Silicon
- Swift 6 toolchain (Command Line Tools are sufficient — no full Xcode needed)
- Docker (any engine) to build the guest — the kernel and erofs rootfs are built
  inside `linux/arm64` containers. No `linuxkit`, no Go, no cross-toolchain.

## Build & run

```bash
./Scripts/build.sh          # swift build -c release + ad-hoc codesign w/ entitlement
./Scripts/run.sh            # build, sign, and run
```

The build ad-hoc signs the binary with `com.apple.security.virtualization`
(see `Resources/Entitlements/velox.entitlements`). Verify it is embedded:

```bash
codesign -d --entitlements - "$(swift build -c release --show-bin-path)/velox"
```

## Usage

```bash
velox start                      # boot the engine (serial console on this terminal)
docker context use velox         # point the stock docker CLI at Velox (one time)
docker run --rm hello-world      # talk to the Velox engine — plain docker
docker ps -a
```

Velox ships no wrapper command: it registers a Docker **context** named `velox`
(pointing at `~/.velox/docker.sock`) and you use the stock `docker` CLI — the
same mechanism Docker Desktop uses for its `desktop-linux` context. This
coexists with any existing Docker install. Prefer a one-off? `docker --context
velox ps`. Prefer your own command? Alias it: `alias vdocker='docker --context
velox'`. `velox version` shows component versions; `velox update` checks GitHub
for a newer build.

## Guest image

Build the custom kernel (once — from kernel.org source), then the guest userspace:

```bash
./Scripts/build-kernel.sh   # one-time: compiles Assets/velox-vmlinux from source (long)
./Scripts/make-guest.sh     # builds the erofs root.img, installs kernel+root.img to ~/.velox
./Scripts/run.sh start      # boots the guest; serial console on this terminal
```

`build-kernel.sh` needs Docker (it compiles a bare arm64 kernel natively inside a
`linux/arm64` container on a named volume — never on APFS — and emits the raw
uncompressed `Image` that `VZLinuxBootLoader` requires). `make-guest.sh` builds a
single read-only **erofs** root image (`root.img`) from `guest/rootfs/Dockerfile`
— the static Rust `vinit`, Docker's static server binaries, and a tiny musl
userland — no LinuxKit, no initramfs. The kernel boots it directly
(`root=/dev/vda rootfstype=erofs`). The kernel is monolithic with
`CONFIG_VIRTIO_FS`, `CONFIG_VIRTIO_VSOCKETS`, `BINFMT_MISC` and all container
prereqs built-in (needed for `-v` mounts and Rosetta) — config in
`guest/kernel/velox.fragment`, version pinned in `versions.env`.

## Status

**MVP complete** — all five phases working and verified end-to-end.

- [x] **Phase 1** — bootstrap & code-signing
- [x] **Phase 2** — minimal Linux guest boot (erofs root + Rust `vinit` PID1)
- [x] **Phase 3** — VSOCK proxy (`~/.velox/docker.sock` ↔ guest relay)
- [x] **Phase 4** — dockerd in guest. `docker run` (pull via NAT, streamed output
  via half-closing relay), **persistent data disk on the containerd image store**
  (multi-platform images, attestations, Wasm), graceful stop (sync over a VSOCK
  control port), **VirtioFS `-v` host mounts**, and **Rosetta x86**
  (`--platform linux/amd64`). Uses a custom kernel with VirtioFS
  (`Scripts/build-kernel.sh`).
- [x] **Phase 5** — reverse port forwarding (`-p 8080:80` → `localhost:8080`):
  watch the Docker API for published ports, open dynamic `127.0.0.1` listeners,
  pipe over VSOCK to a guest reverse-relay (closes when the container stops).

End-to-end: `velox start` → `docker run -d -p 8080:80 nginx` → `curl localhost:8080`.

## Performance & objective

The north star is to be **as lean, efficient, and fast as possible with the
smallest footprint** — and to **beat Docker Desktop and OrbStack where possible,
and be at least on par otherwise**. Concrete data point (iperf3, container ↔ Mac):

| metric (container ↔ host) | Velox | Docker Desktop |
| --- | --- | --- |
| network upload (guest→host) | **~80 Gbit/s** | ~25 Gbit/s |
| network download (host→guest) | **~14 Gbit/s** | ~12.85 Gbit/s |

Velox uses the same kernel datapath as Docker Desktop (Apple's VZNAT) but with a far
leaner host (no Electron, no proxy/telemetry layers), so it matches-or-beats on
throughput while using a fraction of the resources. Beating this further would need
a custom hypervisor (OrbStack's approach) — deliberately out of scope.
