# Velox

A lightweight, open-source Docker Desktop alternative for macOS. The host
supervisor is 100% Swift and drives Apple's `Virtualization.framework` to run a
minimal Linux guest hosting the stock `dockerd`. The Docker API socket is
bridged from the Mac to the guest over **VSOCK**; local directories are shared
via **VirtioFS**; outbound internet uses native **NAT**; and published container
ports are mapped back to `localhost`.

Targets **Apple Silicon (arm64)** first.

## Requirements

- macOS 15+ on Apple Silicon
- Swift 6 toolchain (Command Line Tools are sufficient — no full Xcode needed)
- (Guest build, later phases) `linuxkit` + a container runtime to drive the build

## Build & run

```bash
./Scripts/build.sh          # swift build -c release + ad-hoc codesign w/ entitlement
./Scripts/run.sh            # build, sign, and run
```

The build ad-hoc signs the binary with `com.apple.security.virtualization`
(see `Resources/Entitlements/velox.entitlements`). Verify it is embedded:

```bash
codesign -d --entitlements - "$(swift build -c release --show-bin-path)/Velox"
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
./Scripts/make-guest.sh     # builds initrd, installs kernel+initrd to ~/.velox
./Scripts/run.sh start      # boots the guest; serial console on this terminal
```

`build-kernel.sh` needs Docker (it compiles a bare arm64 kernel natively inside a
`linux/arm64` container on a named volume — never on APFS — and emits the raw
uncompressed `Image` that `VZLinuxBootLoader` requires). `make-guest.sh` needs
`linuxkit` + a container engine and assembles only the initrd. The kernel is
monolithic with `CONFIG_VIRTIO_FS`, `CONFIG_VIRTIO_VSOCKETS`, `BINFMT_MISC` and
all container prereqs built-in (needed for `-v` mounts and Rosetta) — config in
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
