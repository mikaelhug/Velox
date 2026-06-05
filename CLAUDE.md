# Velox — Project Conventions

Velox is a lightweight, open-source Docker Desktop alternative for macOS. The
host supervisor is 100% Swift driving Apple's `Virtualization.framework`; the
guest is a minimal custom Linux image (from-source kernel + a hand-assembled
initramfs of static binaries — **no LinuxKit**, see §7) running stock `dockerd`.
The goal is to beat OrbStack on speed and footprint. See `README.md` for status.

The following conventions are **binding** — keep them true in all future work.

## 1. User-facing CLI is the stock `docker`, via a Docker **context**

Velox is "as original as possible": it ships **no wrapper command**. Users drive
it with the plain `docker` CLI, pointed at Velox's socket through a Docker
**context** named `velox` — exactly how Docker Desktop binds its own CLI (the
`desktop-linux` context). This coexists with any other Docker install with no
root and no `/var/run` conflict (like Colima).

- `velox start` creates/updates the `velox` context (`docker context create velox
  --docker host=unix://~/.velox/docker.sock`). Users then run:
  `docker context use velox` (persistent) or `docker --context velox ps` (one-off).
- Examples shown to users use plain `docker`: `docker ps -a`, `docker run …`.
  An env var works too: `export DOCKER_HOST=unix://~/.velox/docker.sock`.
- Want a distinct command? That's a user-side **alias**, not something Velox
  ships: `alias vdocker='docker --context velox'` in `~/.zshrc`.
- Velox never *auto*-hijacks the active `docker` context, but the user may opt in
  at launch: `velox start --bind none|docker`. `--bind docker` switches the active
  context to `velox` and restores the previous one on stop. Default is `none`
  (just create the context; don't change the active one). See `CLIBinding.swift`.
- Internal API/socket naming stays "docker" (it *is* the Docker API):
  `~/.velox/docker.sock`, `DockerSocketProxy`, etc.

## 2. All version numbers live in ONE place: `versions.env`

`versions.env` (repo root) is the single source of truth for **every** version:
Velox's own version, the guest kernel ("OS version"), the Docker Engine static
release shipped in the guest, and the build-stage toolchain images (Rust/Alpine/Go).
Nothing else may hard-code a version.

- Swift reads versions via `Sources/VeloxCore/Support/Versions.swift`, which is
  **generated** from `versions.env` by `Scripts/gen-versions.sh` (run by
  `Scripts/build.sh`). Never hand-edit `Versions.swift`.
- The guest image is **built**, not templated: `Scripts/make-guest.sh` sources
  `versions.env` and passes its values to `guest/rootfs/Dockerfile` as Docker
  build-args (`DOCKER_VERSION`, `RUST_BUILD_IMAGE`, `ALPINE_IMAGE`). There is no
  generated guest spec file (no `velox.yml`/`velox.yml.tmpl` — see §7).
- Updating Velox to newer components = editing `versions.env` only.

## 3. Built-in updater pointing at GitHub releases

Velox ships an updater so a future UI "Update" button (and the CLI today) can
pull a newer build. It is backed by `velox update`:

- `velox update` checks `https://api.github.com/repos/<VELOX_GITHUB_REPO>/releases/latest`
  (repo set in `versions.env`) and reports whether a newer version exists.
- `velox update --apply` downloads and installs the new release.
- Any UI added later must wire its "Update" button to this same code path
  (`Updater` in `Sources/VeloxCore/Support/Updater.swift`) — do not fork the logic.

## 4. Custom kernel built from kernel.org source (for VirtioFS / Rosetta)

Apple's Virtualization.framework shares files only via **VirtioFS** and boots a
raw, uncompressed `arch/arm64/boot/Image` (no EFI-zboot stub). So — like Docker
Desktop and OrbStack — Velox builds its **own** bare, fast arm64 kernel straight
from kernel.org source (`Scripts/build-kernel.sh`), under full config control:
`make tinyconfig` + a curated VM fragment (`guest/kernel/velox.fragment`) +
`olddefconfig`, with `CONFIG_VIRTIO_FS`, `CONFIG_VIRTIO_VSOCKETS`, `BINFMT_MISC`,
all cgroup/netfilter container prereqs, etc. built-in (monolithic, no modules).

- The build runs **Linux-to-Linux native** inside a `--platform linux/arm64`
  container, on a Docker **named volume** — never the host APFS (case-insensitive
  collisions + slow bind mounts). Only the final `Image` is copied back to
  `Assets/velox-vmlinux` (and `~/.velox/kernel`).
- The kernel version + SHA-256 are pinned in `versions.env`
  (`KERNEL_ORG_SERIES`/`KERNEL_ORG_VERSION`/`KERNEL_ORG_SHA256`). No LinuxKit.
- `Scripts/make-guest.sh` builds **only the erofs root userspace** (no LinuxKit,
  no initramfs); the kernel comes from `Assets/velox-vmlinux`. Both VirtioFS `-v`
  mounts and Rosetta x86 depend on this kernel — don't switch to a stock kernel
  expecting them to work.

## 5. dockerd uses the containerd image store ONLY

dockerd runs with `--feature=containerd-snapshotter=true` (set in vinit's dockerd
launch, `guest/vinit/src/main.rs`) — the containerd image store (overlayfs
snapshotter) is the **only** store, no
classic `overlay2` graph driver. This gives Docker-Desktop parity: native
multi-platform images, attestations/SBOM, and Wasm. Don't re-add `--storage-driver`.

## 6. Guest clock comes from the host (`velox.epoch`)

Apple VZ exposes no RTC, so the guest would boot at 1970 and break registry TLS.
`VMConfiguration.build()` stamps `velox.epoch=<unixtime>` on the kernel cmdline; the
init step (with `CAP_SYS_TIME`) sets the VM clock from it before anything else.
This is host-authoritative time injection (no NTP daemon) — keep it that way.

The same channel also corrects drift: there is no RTC to advance while the Mac
sleeps, so a resumed guest is behind by the sleep duration (enough to break TLS).
The host (`ClockSync`) re-pushes the current epoch to the guest's clock VSOCK port
(`VsockPort.clock`, 2377) at start, on `NSWorkspace.didWake`, and on a slow timer;
vinit re-sets the clock only on large drift. Still host-authoritative, still no NTP.

## 7. NO LinuxKit, NO dind image — the guest is a minimal custom rootfs

Velox is **not** a LinuxKit appliance. Beating OrbStack (and therefore beating
Docker Desktop by a mile) on RAM, boot time, and footprint is a primary goal, and
LinuxKit's "every component is a baked-in OCI image" model is the opposite of lean.
The binding architecture:

- **Host supervisor: 100% Swift** driving `Virtualization.framework`. Keep it that way.
- **Kernel:** built from kernel.org source (convention #4) — already not LinuxKit.
- **Guest root: a read-only, compressed, demand-paged `erofs` image** (`root.img`,
  built by `make-guest.sh` from `guest/rootfs/Dockerfile`). The kernel mounts it
  directly (`root=/dev/vda rootfstype=erofs ro init=/sbin/vinit`, **no initramfs**);
  the data disk is `/dev/vdb` (ext4, `/var/lib/docker`). Because the root is
  demand-paged from disk, the big Docker binaries are NOT all held in RAM.
- **`vinit` (`guest/vinit/`, Rust → static musl) IS PID 1**: it does every boot step
  via direct syscalls (`nix`/`libc`) — mounts, cgroup2, clock from `velox.epoch`,
  **native DHCP + netlink** (no udhcpc), data-disk format/mount, VirtioFS, Rosetta
  binfmt — then forks+supervises `dockerd` (on a unix socket), runs the vsock agent
  (ports 2375/2374/2376), and reaps zombies. All custom guest code is Rust.
- The engine ships as Docker's **official static binaries** (`DOCKER_VERSION` in
  `versions.env`). A tiny musl userland (`iptables`-nft, `e2fsprogs`, `ca-certs` —
  the only tools dockerd shells out to, plus busybox as a debug shell) comes from
  Alpine packages, so there is a small `/lib`. Eliminating it (fully-static nft +
  mke2fs from source → a pure scratch tree) is a noted follow-up.
- **Do NOT reintroduce:** `linuxkit`, the `docker:*-dind` image, `linuxkit/*` package
  images, an initramfs, or any OCI-image-as-guest-component. There is no
  `guest/velox.yml`. (Buildkit gotcha: a `RUN` immediately after `COPY …/sbin/init`
  gets exec'd as that binary — keep binary COPYs last and `init=` at `/sbin/vinit`.)

## Build / run quick reference

```bash
./Scripts/build.sh          # gen versions + swift build + ad-hoc codesign
./Scripts/make-guest.sh     # build kernel + erofs rootfs guest, install to ~/.velox
velox start                 # boot the engine (creates the `velox` docker context)
docker context use velox    # point the stock docker CLI at Velox
docker ps                   # talk to it
```

Only `com.apple.security.virtualization` is required for signing (NOT
`com.apple.security.hypervisor`, which is for raw Hypervisor.framework).
