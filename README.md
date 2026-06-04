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
velox start                 # boot the engine (serial console on this terminal)
./Scripts/install-vlcmd.sh  # put `vlcmd` on PATH (one time)
vlcmd run --rm hello-world  # talk to the Velox engine, just like docker
vlcmd ps -a
```

`vlcmd` is the Docker CLI pointed at Velox's socket, so Velox coexists with any
existing Docker install. `velox version` shows component versions; `velox
update` checks GitHub for a newer build.

## Guest image

Build the custom kernel (once — enables VirtioFS), then the LinuxKit guest:

```bash
./Scripts/build-kernel.sh   # one-time: builds velox/kernel:<ver>-virtiofs (long compile)
./Scripts/make-guest.sh     # builds guest, installs kernel+initrd to ~/.velox
./Scripts/run.sh start      # boots the guest; serial console on this terminal
```

Needs `linuxkit` + a container engine on PATH. `make-guest.sh` decompresses the
arm64 EFI-zboot kernel into the raw `Image` that `VZLinuxBootLoader` requires.
The custom kernel adds `CONFIG_VIRTIO_FS=y` (needed for `-v` mounts and Rosetta;
the stock LinuxKit kernel lacks it) — see `Scripts/build-kernel.sh`.

## Status

**MVP complete** — all five phases working and verified end-to-end.

- [x] **Phase 1** — bootstrap & code-signing
- [x] **Phase 2** — minimal Linux guest boot (LinuxKit → root console)
- [x] **Phase 3** — VSOCK proxy (`~/.velox/docker.sock` ↔ guest relay)
- [x] **Phase 4** — dockerd in guest. `vlcmd run` (pull via NAT, streamed output
  via half-closing relay), **persistent overlay2 data disk**, graceful stop
  (sync over a VSOCK control port), **VirtioFS `-v` host mounts**, and **Rosetta
  x86** (`--platform linux/amd64`). Uses a custom kernel with VirtioFS
  (`Scripts/build-kernel.sh`).
- [x] **Phase 5** — reverse port forwarding (`-p 8080:80` → `localhost:8080`):
  watch the Docker API for published ports, open dynamic `127.0.0.1` listeners,
  pipe over VSOCK to a guest reverse-relay (closes when the container stops).

End-to-end: `velox start` → `vlcmd run -d -p 8080:80 nginx` → `curl localhost:8080`.
