# Closing the OrbStack gap — what worked, what can't (2026-10-09)

Follow-up to [REPORT-2026-10-09-orbstack.md](REPORT-2026-10-09-orbstack.md). Branch
`perf/orbstack-gap`. Same Mac: M4 Pro, macOS 27.0.1, 8 vCPU / 8 GiB.

**These are A/B measurements, not a campaign.** Each row is a focused before/after on this Mac
(n = 3–6). The published scorecard does not change until a full `run.sh campaign` re-measures
it (CLAUDE.md).

## How OrbStack wins

OrbStack 2.x no longer runs on Virtualization.framework. It ships its own Rust VMM (a libkrun
fork) on Hypervisor.framework, with **hypercall fast paths** that skip virtqueues entirely for
file sharing, block I/O, the console and free-page reporting. Its developer calls free-page
reporting OrbStack's biggest resource gain. Its data disk is btrfs mounted `discard=sync`.

## Results

| Gap (2026-10-09 report) | Before | After (branch) | OrbStack | How |
|---|---|---|---|---|
| Startup, GUI launch → API ready (10 ms `/_ping` poll) | 0.95–0.98 s | **0.47 s** | 1.24–1.27 s | `Task.immediate` boots the VM during app init; dockerd starts before DHCP with the cached gateway |
| Idle CPU, VM process (quiet 90 s windows) | 0.37–0.40 % | **0.18–0.19 %** | 0.27 % | `vm.compaction_proactiveness=0`, 15-min ClockSync backstop, fewer guest wakers |
| `docker cp` out, 1 GiB | 643–649 MB/s | **609–1,001 MB/s** (median ~780) | 691 MB/s | Docker API over the VZNAT conduit pool |
| `docker cp` in, 1 GiB | ~480 MB/s | ~500 MB/s | 542 MB/s | capped by the docker CLI's 8 KiB AF_UNIX send buffer; same ceiling as OrbStack |
| Disk returned after a 2 GiB delete | next boot / hourly | **2.6 GB within 45 s** | continuous | debounced FITRIM on Docker delete/destroy/prune events |
| Small-file extract (busybox, 8,000 entries) | ~2.4 s | ~2.4 s | 0.88 s | no viable fix inside VZ (see below) |
| RAM returned after teardown | none | none | continuous | macOS 27 VZ balloon releases nothing (see below) |

Unchanged:
- Container launch: 98 ms median, before and after.
- `docker load`: 5.8 s, before and after.
- Functional checks pass after every change: `host.docker.internal`, egress, published ports and `*.velox.local`.

**OrbStack's startup number moved.** In the campaign it was 0.88 s. Here it is 1.24–1.27 s,
measured with `/_ping`, `docker version` and `/containers/json`, which all agree within 30 ms.
Both engines now carry the campaign's image set. The campaign will settle which figure stands;
until then neither is published.

## The macOS 27 custom-device experiments

`VZCustomVirtioDevice` (new in the macOS 27 SDK) was tried through env-gated probes in
`Sources/VeloxCore/VM/Experimental/CustomVirtioProbes.swift`. Stock Linux binds custom
device IDs 26 (virtio-fs) and 5 (virtio-balloon).

### Velox-owned virtio-fs server: works, but cannot reach OrbStack

| Per request | No polling | Adaptive busy-poll |
|---|---|---|
| Our handler (incl. macOS file syscalls) | ~11 µs | ~10 µs |
| `returnToQueue` | — | ~3 µs |
| Turnaround (reply → guest → next request) | ~33–40 µs | ~17 µs |

| Workload | Custom device | Apple VirtioFS | OrbStack | Guest-local |
|---|---|---|---|---|
| open+close | 58 µs | 75 µs | — | — |
| create+write 4 KiB+close+unlink | 189 µs | 218 µs | — | — |
| Untar, GNU tar | 1.9–2.0 s | 2.2–2.5 s | — | — |
| Untar, busybox (8,000 entries) | 2.25 s | ~2.4 s | 0.88 s | 0.33 s |

With polling, the custom server matches or slightly beats Apple's in-process server. It cannot
reach OrbStack:
- About 20 µs per round trip is VZ's own interrupt path back into the guest. `idle=poll` in
  the guest changed nothing.
- The Linux FUSE client needs about 8 synchronous requests per extracted file. `O_CREAT|O_EXCL`
  always re-LOOKUPs a negative dentry.

So 8 × ~27 µs is the floor, against OrbStack's hypercall path. That doesn't justify
productizing a FUSE server (security surface, correctness) for roughly 10–15 %.

Notes for anyone revisiting:
- FUSE errno values must be translated macOS→Linux. ENOSYS is 78 on macOS and 38 on Linux;
  sending 78 made the guest re-issue GETXATTR on every write.
- The optional ObjC delegate methods need pinned `@objc(...)` selectors, or they are silently
  never called.

### Free-page-reporting balloon: not possible

- `madvise` (REUSABLE, FREE or DONTNEED) on `VZGuestMemoryMapping.mutableBytes` returns 0, but
  the VZ process's RSS and footprint don't move. Guest RAM is owned by the VZ XPC service, and
  the device delegate runs in our process.
- Linux's page reporting hands pages over as device-writable buffers, whose addresses the API
  does not expose.

### Apple's own balloon releases nothing on macOS 27

Velox's resource saver (unchanged since 1.2.0) inflated the balloon to 7 GiB: 1,835,008 pages
per `/proc/vmstat`. The VM process stayed at 3.7 GB RSS, with 3.5 GB of guest RAM dirty and
0 reclaimable. A simulated memory-pressure notification released nothing either. On macOS 26.6
the same saver took idle RAM from 734 to 373 MB.

**This is the "resource saver regression"**: an environmental change in macOS 27's
Virtualization.framework, not Velox code. It should be reported to Apple with this
reproduction. Until it is fixed, no VZ engine can return guest memory without a restart.

## Still open
- **Small-file VirtioFS:** out of reach inside VZ, as measured above.
- **Memory return:** blocked on Apple. The saver now costs a little CPU each idle cycle (the
  inflate) for no host benefit on macOS 27. Decide whether to gate it by OS version.
- **A full campaign** to replace the A/B numbers above with publishable ones.
