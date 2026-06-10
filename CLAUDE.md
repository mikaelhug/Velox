# Velox — Project Conventions

Velox is a lightweight, open-source Docker Desktop / OrbStack alternative for macOS.

## North Star — the main objective

Be **as lean, efficient, fast, and small-footprint as possible**, and on every
metric that matters — startup time, RAM, CPU, disk footprint, network throughput,
filesystem I/O — **beat Docker Desktop and OrbStack where it's possible, and be at
least on par otherwise.** Every decision in this repo serves that goal. The five
pillars that deliver it:

1. **Apple's kernel networking (VZNAT).** The container datapath is Apple's
   in-kernel NAT — the fastest networking path on `Virtualization.framework`
   (measured ~14 Gbit/s down / ~80 Gbit/s up, beating Docker Desktop). **No
   userspace netstack:** a host-side `PortForwarder` maps published ports to
   `localhost`, and dockerd `--host-gateway-ip` wires `host.docker.internal`.
   (Truly *beating* VZNAT on raw throughput would need a custom hypervisor —
   OrbStack's moat, out of scope; VZNAT keeps us on-par-or-better within VZ.)
   **Direct named access** (`<name>.velox.local` → the container's *real* IP, any
   protocol — OrbStack-style, no `-p`) is **pure DNS + routing, never a proxy or
   netstack**: a loopback DNS responder (`NameDNSResponder`, reached via
   `/etc/resolver/velox.local`) answers names from the event-driven container map
   (`NameRegistry`, filled by `DockerEventsWatcher`); a porthelper-installed host route
   (`NamedAccessRouter`) carries the Mac to the container subnet over VZNAT; and `vinit`
   adds one `nft` allow for the gateway IP in **both** dockerd-29 host→container drop
   chains (`filter-FORWARD` *and* `raw-PREROUTING`), re-asserted event-driven: the
   dockerd supervisor signals on respawn, and a guest-local docker `/events` network
   informer signals on endpoint changes (dockerd rewrites `raw-PREROUTING`'s
   per-container drops on every `docker run`, flushing the allow — measured).
   No entitlement, no ongoing root (one-time grant only — folded into the porthelper).
   Don't replace this with a reverse proxy or re-add `trusted_host_interfaces` (it doesn't
   apply to `docker0`).
2. **A 100% Swift host.** The whole supervisor — VM lifecycle, Docker-API VSOCK
   proxy, port forwarding, clock sync, the SwiftUI GUI — is pure Swift on
   `Virtualization.framework`. **No Go, no host-side Rust, no helper daemons** — with
   **one sanctioned exception**: `velox-porthelper`, a tiny root LaunchDaemon (still
   Swift, `Sources/velox-porthelper/`) that exists *only* for the two things macOS gives
   an unprivileged process no other way to do, both **control-plane**: (a) bind a loopback
   port `<1024` and pass the listening socket fd back over a unix socket, and (b) add/remove
   a host route to a container subnet (for direct **named-container access** — `<name>.velox.local`
   → the container's real IP). It never touches connection data, so **root stays out of the
   datapath**. It is installed on first use with a single admin prompt (no Developer ID ⇒ no
   `SMAppService`; a manual `osascript`-authorized LaunchDaemon install that *also* writes
   `/etc/resolver/velox.local`), and the host degrades gracefully (skip privileged ports / no
   named access) if the user declines. Keep it minimal: this is the *only* privileged component,
   nothing else may grow a daemon, and any new helper command must stay control-plane (route/port
   setup, never connection bytes). See `Sources/VeloxCore/Proxy/PortHelper.swift`.
3. **Rust only for the tiny guest `vinit`.** One static-musl Rust binary is the
   guest's PID 1 and entire userland orchestration. Lean and fast by design.
4. **A custom kernel, as lean as possible.** Built from kernel.org source —
   `tinyconfig` + a curated fragment, only what the VM needs, nothing else. Where a
   guest component must be faster or smaller, add a focused high-performance Rust
   piece (like `vinit`) rather than pull in heavyweight userland.
5. **Native-first; if we must build our own, it's Rust.** Prefer a capability that
   `dockerd` (or the kernel) already provides natively over adding another userland
   package — and over rolling our own. Example: dockerd 29's **native nftables
   firewall backend** (`--firewall-backend=nftables`, drives `nft` in-kernel)
   replaces shelling out to the `iptables-nft` compat binary, so the
   `iptables`/`ip6tables` packages are **dropped** from the guest. Only when no
   native option exists and we genuinely must build one do we write it — and then in
   **Rust** (like `vinit`), never Go, never a heavyweight dependency. Fewer packages
   and fewer bespoke components = leaner, faster, smaller.

Concretely: the host supervisor is 100% Swift driving `Virtualization.framework`;
the guest is a minimal custom Linux image (from-source kernel + a compressed `erofs`
rootfs of static binaries — **no LinuxKit, no initramfs**, see §7) running stock
`dockerd`. See `README.md` for status.

The following conventions are **binding** — keep them true in all future work.

> **Releasing is opt-in, never automatic.** Do **not** ship a release on your own:
> no `VELOX_VERSION` bump in `versions.env`, no `release: vX.Y.Z` commit, and above all
> no `vX.Y.Z` tag or tag push — a `v*` tag push triggers the CI release that the updater
> serves to users. Implement and commit requested fixes as normal, but **cut a release
> only when the user explicitly asks for it** ("ship it", "release vX", "tag it"). When
> in doubt, leave it untagged and ask.
>
> **Pre-release gate:** the North Star is comparative, so before a release that touches
> the datapath, kernel, disk, or engine version, re-run the benchmark scorecard
> (`docs/bench/run.sh`) and check it against `docs/benchmarks.md` — a regression vs
> Docker Desktop is a release blocker, not a footnote. On a `DOCKER_VERSION` major bump,
> also walk the checklist comment above it in `versions.env` (named-access nft chains).

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
release shipped in the guest, and the build-stage toolchain images (Rust + Alpine
only — **no Go**, per pillar #2). Nothing else may hard-code a version.

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
  (`KERNEL_ORG_VERSION`/`KERNEL_ORG_SHA256`; the kernel.org `v6.x` dir is derived
  from the version). No LinuxKit.
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
- **Data disk = a RAW image + `.fsync`, guest barriers ON — NEVER `.none`, ASIF, or
  `barrier=0`.** `Storage.swift` creates `data.img` as a *raw* sparse file (pure-Swift
  `truncate`, no `diskutil`); `VMConfiguration` attaches it `cachingMode: .cached` +
  `synchronizationMode: .fsync`; `vinit` mounts `/var/lib/docker` ext4 with barriers on.
  This is non-negotiable. A sparse **ASIF** image attached `.none` (a past benchmark
  "writeback optimization") never durably commits its allocation map, so the guest reads
  zeros and **reformats on every restart — wiping all containers/images/volumes** (measured
  and reproduced). raw + `.fsync` is fully crash-durable (ext4 journal recovery) *and* beats
  Docker Desktop's durable commit (0.31 ms vs 0.47 ms); periodic `fstrim` hole-punches the
  raw file to reclaim host space. Do **not** trade this back to `.none`/ASIF/`barrier=0` for
  a TPS number — it loses data. (`isLegacyASIF` migrates any old ASIF `data.img` to raw.)
- **`vinit` (`guest/vinit/`, Rust → static musl) IS PID 1**: it does every boot step
  via direct syscalls (`libc`) — mounts, cgroup2, clock from `velox.epoch`, **native
  DHCP via ioctl** (no udhcpc/dhcpcd), data-disk format/mount + swap, VirtioFS,
  Rosetta binfmt — then forks+supervises `dockerd` (on a unix socket, with
  `--host-gateway-ip` for host.docker.internal), runs the vsock agent (ports 2375
  docker / 2374 control+sync / 2376 reverse-port-forward / 2377 clock), and reaps
  zombies. All custom guest code is Rust (pillar #3) — keep it lean.
- The engine ships as Docker's **official static binaries** (`DOCKER_VERSION` in
  `versions.env`). A tiny musl userland (`nftables`, `e2fsprogs`, `ca-certificates`
  — the only tools dockerd shells out to) comes from Alpine packages, so there is a
  small `/lib`. dockerd runs its **native nftables firewall backend** (pillar #5), so
  it drives the `nft` binary directly and the legacy `iptables`/`ip6tables` (iptables-nft)
  packages are **not** shipped. The kernel still carries full nft/xt support (fragment)
  for container workloads that run their own `iptables`. Eliminating the musl `/lib`
  entirely (fully-static nft + mke2fs from source → a pure scratch tree) is a noted
  follow-up toward the leaner footprint.
- **Do NOT reintroduce:** `linuxkit`, the `docker:*-dind` image, `linuxkit/*` package
  images, an initramfs, or any OCI-image-as-guest-component. There is no
  `guest/velox.yml`. (Buildkit gotcha: a `RUN` immediately after `COPY …/sbin/init`
  gets exec'd as that binary — keep binary COPYs last and `init=` at `/sbin/vinit`.)

## 8. Event-driven, never polling

Where a push/notification exists, **use it — never poll for state.** Polling is
slower (you wait out the interval) and, here, actively harmful: each poll opens a
fresh API connection, and under the VSOCK contention of a `docker run` those
connections stall and serialize on the VM queue.

- The published-port watcher (`DockerEventsWatcher`) and Resource Saver
  (`ResourceSaver`) ride the Docker **`/events` stream** via the in-process
  `DockerClient` (one persistent VSOCK connection over `HTTPCodec`, straight to
  dockerd — *not* the unix-socket proxy), reconciling the instant a container
  changes. Result: a published port is reachable in ~0.4s vs 2–28s when polled.
- The **informer rule:** the event is only the *trigger*; a full reconcile (the
  `containers()` list) is the source of truth, re-run on every (re)connect — so a
  missed event or a daemon restart self-heals. Never trust event deltas alone.
- Clock sync pushes on `NSWorkspace.didWake`. The **only** timers that remain are
  genuine *delays / corrections with no event source* — DHCP lease renewal, periodic
  `fstrim`, the Resource-Saver idle countdown, clock drift re-push — never a status
  poll. (Even the guest's named-access `nft` re-assert is event-driven — the dockerd
  supervisor signals it on respawn and a local `/events` network informer on endpoint
  changes — and container uptime in the GUI renders from per-transition lifecycle
  anchors via a visible-only minute-tick TimelineView, not a re-list.) If you find yourself
  adding a repeating timer to *check* something, find the event instead.
- Do NOT hand-roll raw-socket HTTP against the docker socket for streaming; use
  `DockerClient` (it handles persistent streams + cancellation correctly). A
  raw-socket `/events` reader through the proxy churns connections and breaks it.

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
