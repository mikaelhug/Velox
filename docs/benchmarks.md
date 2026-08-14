# Benchmarks — Velox vs Docker Desktop

A reproducible head-to-head of Velox against **Docker Desktop** on the same Mac, the same
way, with **both engines configured identically**. The harness lives in
[`docs/bench/`](bench/); this page is the method, the fairness rules, and the recorded
results.

> **North star:** be as lean, efficient, and fast as possible with the smallest footprint —
> beating Docker Desktop where possible, on par where not. These tests are how we keep that
> claim honest, including where Velox currently **trails**.

## TL;DR

| | Velox | Docker Desktop |
| --- | --- | --- |
| 🟢 **Wins** | install 10× smaller, idle RAM ~2.6× less, startup 1.5× faster, **container launch 1.2–1.3×**, container→host net ~2×, **published ports 3.0–3.7×**, VirtioFS write 1.5×, **durable commit 1.5× (0.31 ms vs 0.47 ms)**, named-volume write ~1.1× | |
| ⚪ **Par** | VirtioFS read, container-overlay write, pgbench TPS / init | |
| 🔴 **Trails** | small-file extract (~0.9×), cold image pull (durable layer extraction) | |

Full numbers in [Results](#results). The data disk is raw + durable `.fsync`
([Disk](#disk-raw-image--durable-fsync-2026-06-09)); published ports now ride a VZNAT conduit
pool; launch is `HZ_1000` + expedited RCU ([Launch](#launch-expedited-rcu-2026-06-09)).

## Test environment (recorded run)

- **Host:** Apple M4 Pro (8 performance + 4 efficiency cores), 24 GB RAM, macOS 26.5.1
- **Velox:** 0.1.11 — guest kernel 6.18.34, dockerd 29.5.3
- **Docker Desktop:** dockerd 29.4.3, `Virtualization.framework` backend
- **Both engines:** **8 vCPU / 8 GB**, idle baseline, 0 containers, same containerd image store
- **Date:** 2026-06-08

Set Docker Desktop's allocation in **Settings → Resources** and Velox's in **Settings →
Resources** so the two match before running.

## How to run

```bash
brew install jq iperf3 hyperfine          # one-time
cd docs/bench

./run.sh                  # footprint + full suite on both engines, then prints the scorecard
./run.sh report           # re-print the scorecard from results.csv
./run.sh startup          # restart-to-ready timing — NOTE: this quits & relaunches both apps
./run.sh suite velox velox            # run the active suite against one engine only
```

The engine under test is selected purely by its **Docker context** (`velox` /
`desktop-linux`) — no daemon swap, no `DOCKER_HOST` juggling. Edit the config block at the
top of `run.sh` if your contexts or app names differ. Results append to
`docs/bench/results.csv`; `report.py` renders the scorecard.

## Fairness controls

These are what make the numbers comparable rather than anecdotal:

1. **Same resource caps.** Both engines pinned to 8 vCPU / 8 GB (verify with
   `docker run --rm alpine sh -c 'nproc; free -m'` on each context).
2. **One engine under load at a time.** The suite drives a single context end-to-end; the
   other engine sits idle. (Both VMs are resident, but only one is doing work.)
3. **Identical, pinned images.** `alpine:3.20`, `networkstatic/iperf3`, `python:3.12`,
   `postgres:16` — pulled on both before timing.
4. **Warm vs cold is stated per test.** Launch latency is warm (median of 12 via
   `hyperfine`); image pull is forced cold (`rmi` first); startup is a warm-disk restart.
5. **Host-side accounting.** RAM is the summed **host RSS** of each engine's whole process
   set — for a VM engine the cost is the host processes, not `docker stats` inside the guest.
6. **Repeat & summarize.** Latency uses medians; throughput uses 8–30 s windows.

## What each test measures

| Suite | Test | What it exercises |
| --- | --- | --- |
| disk | `installed_footprint` | shipped bytes: app bundle + guest kernel + rootfs |
| mem | `idle_footprint` | summed host RSS of all engine processes at idle |
| lifecycle | `restart_to_ready` | `open -a` → first successful `docker version` (warm disk) |
| launch | `run_true` / `churn30` / `parallel20` | per-container API + create/start/teardown round-trip |
| net | `c2host` | container→host uplink (Velox = Apple VZNAT) |
| net | `pubport_h2c_p1` / `_p4` | host→container via a published port (the host-side forwarder) |
| fs | `bind_write` / `bind_read` | VirtioFS host bind-mount bandwidth |
| fs | `smallfiles_bind` | extract 4,000 small files into a bind mount (metadata-heavy; `node_modules`/`git`) |
| fs | `vol_write` / `overlay_write` | in-VM disk (named volume ext4 / container overlay) |
| pull | `cold_image` | registry download + layer extraction / snapshotter |
| realworld | `pgbench_init` | bulk DB load (sequential writes + checkpoint) |
| realworld | `pgbench_tps` | TPC-B-like txns — dominated by per-commit **fsync latency** |

## Results

```
Metric                                 Velox  Docker Desktop        Δ  Verdict
----------------------------------------------------------------------------------------
Installed footprint                   226 MB         2,328 MB   10.30x  WIN
Idle RAM (host RSS, all procs)        ~0.9 GB          ~3.3 GB    3.71x  WIN
Startup: restart→API-ready            1.74 s           2.55 s    1.47x  WIN
Container launch (run true)           0.104 s          0.160 s    1.54x  WIN
Sequential churn (per container)      0.104 s          0.170 s    1.63x  WIN
Parallel launch x20 (total)           0.97 s           1.11 s    1.14x  WIN
Network: container→host           88.77 Gbps       27.00 Gbps    3.29x  WIN
Net: published port (1 stream)    38.38 Gbps       13.00 Gbps    2.95x  WIN
Net: published port (4 streams)   59.17 Gbps       18.00 Gbps    3.29x  WIN
FS: VirtioFS bind write           1,030 MB/s         692 MB/s    1.49x  WIN
FS: VirtioFS bind read            2,135 MB/s       2,163 MB/s    0.99x  par
FS: extract 4000 files (bind)         3.40 s           3.14 s    0.92x  par
FS: named-volume write (in-VM)    1,630 MB/s       1,500 MB/s    1.09x  WIN
FS: container-overlay write       1,695 MB/s       1,217 MB/s    1.39x  WIN
Durable commit (fio fsync, 4K)     0.31 ms          0.47 ms      1.52x  WIN
Cold image pull (381 MB)             19.06 s          17.30 s    0.91x  TRAIL
pgbench init (scale 50)               2.18 s           2.88 s    1.32x  WIN
pgbench TPS (8 clients, 30s)         13,318           11,690     1.14x  WIN
```

The harness appends to `results.csv` (`./run.sh report` prints the scorecard). The figures
above are the latest clean **single-engine** measurements — each engine measured with the
other stopped, since Docker Desktop's daemon proved unstable when both VMs were co-resident.

### Published ports: now a VZNAT conduit-pool win

Inbound `localhost:PORT → container` used to route over a single `VZVirtioSocketDevice`
(VSOCK), which serialized and capped at ~1–6 Gbit/s — the old big trail. It now rides a
**pre-warmed VZNAT conduit pool**: the guest keeps idle TCP conduits dialed to the host over
the fast VZNAT path, and the host hands each published connection an idle conduit (assignment
over VSOCK, *data* over VZNAT), so throughput jumps to **38–60 Gbit/s — 2.9–3.3× Docker
Desktop** (it falls back to the VSOCK relay if the pool is momentarily empty). The one path
that still trails is **cold image pull** (~0.9×): the download rides VZNAT, but durable layer
*extraction* is fsync-heavy — the single place the data-safety guarantee costs measurably.

## Filesystem: two harness bugs, and a read-ahead fix (2026-08-14)

The VirtioFS figures published before this date were wrong — not because Velox changed,
but because the harness was measuring the wrong thing. Both bugs are fixed in `run.sh`;
both inflated or depressed results by more than any real difference between the engines.

1. **The scratch dir wasn't shared.** The suite bind-mounted `$(mktemp -d)`, which on macOS
   is `/var/folders/…`. Docker Desktop shares `/private`, so **DD's numbers were real** —
   but Velox shares only `/Users` (plus configured `fileShares`), so the mount silently
   resolved to an *empty in-guest directory* and the test measured guest-local storage.
   Proven by writing from the guest and checking the host: the file never appeared.
   Measured side by side, 1 GiB write — real VirtioFS ~968 MB/s vs guest-local ~1,909 MB/s
   (2×); 4,000-file extract — **2.8 s vs 0.23 s (12×)**. That is the entire source of the
   old "16× small-files" claim. `run.sh` now uses a path under `$HOME` and **aborts** if the
   scratch dir doesn't round-trip to the host.
2. **No quiesce before timing.** Starting a run seconds after a busy container stopped
   charges that container's writeback flush to the measurement: named-volume write read
   ~1,170 MB/s immediately after `docker stop` vs **~1,800 MB/s after a 30 s quiesce** — a
   35% error, and enough to manufacture a "regression" that does not exist. `run.sh` now
   syncs and waits `QUIESCE_S` (default 30 s) before the first timer.

With both fixed, the filesystem picture is par-or-better rather than the lopsided win
previously published — and a genuine deficit surfaced that the bogus numbers had masked:

**VirtioFS read-ahead.** The kernel gives a FUSE/virtiofs backing-dev a **128 KiB**
read-ahead window against **8 MiB** for the virtio-blk disks, leaving bulk reads
latency-bound on the host round-trip. Swept in a live guest (caches dropped, 3 runs each,
1 GiB sequential read):

| `read_ahead_kb` | Read | vs DD (2,163 MB/s) |
| --- | --: | --: |
| 128 (kernel default) | 1,683 MB/s | 0.78× |
| **512** | **2,135 MB/s** | **0.99×** |
| 1024 | 2,021 MB/s | 0.93× |
| 4096 | 1,806 MB/s | 0.83× |

512 KiB is the peak — below it the window can't cover the round-trip, above it the surplus
pages are wasted work. `vinit` now sets it on every VirtioFS mount
(`tune_virtiofs_readahead`), worth **+27%** and closing the gap.

> **Baseline caveat.** Docker Desktop is no longer installed on the reference Mac, so the
> DD column is the June 2026 recording — measured against Velox 0.1.11 (kernel 6.18.34,
> dockerd 29.5.3, 8 GB) rather than the current build. The large structural wins (footprint,
> RAM, startup, published ports) are far outside that uncertainty; the filesystem and
> cold-pull deltas are not, and cold pull additionally depends on network conditions on the
> day. Treat those rows as provisional until a same-day head-to-head is re-run.

## Disk: raw image + durable `.fsync` (2026-06-09)

The data disk is a **raw** sparse image attached `synchronizationMode: .fsync`, with `vinit`
mounting `/var/lib/docker` with barriers **on**. This is both fully durable — it survives a
clean stop, a guest crash, *and* a host crash (ext4 journal recovery) — **and faster than
Docker Desktop on durable commits.**

The earlier sparse **ASIF** disk was the problem, on two counts:

- **Slow.** ASIF is copy-on-write, so every durable `fsync` also had to commit its
  allocation-map metadata — ~15× the cost (4.6 ms vs 0.31 ms on raw).
- **Data loss.** A brief `synchronizationMode: .none` "writeback" experiment (chasing the
  pgbench number) was catastrophic on ASIF: the allocation map was never committed, so the
  guest read zeros on the next boot, saw ext4 "bad magic", and **reformatted — wiping every
  container/image/volume on *every* restart, graceful or not.** `.none` was reverted. Raw
  makes `.fsync` cheap enough that there is no reason to trade away durability.

Measured (4k random write, fsync each; pgbench scale 50, 8 clients, 30 s; Velox and DD both on
Apple Virtualization.framework, one engine at a time):

| Metric | ASIF + `.fsync` (was) | **raw + `.fsync` (now)** | Docker Desktop |
| --- | --: | --: | --: |
| fsync latency | 4.65 ms | **0.31 ms** | 0.47 ms |
| durable commits/s | 215 | **3,216** | 2,086 |
| pgbench TPS | 5,524 | **10,948** | 11,184 |
| named-volume bulk write | — | **1,012 MB/s** | 655 MB/s |

Raw still reclaims host space: `vinit`'s periodic `FITRIM` hole-punches the raw backing file
(verified — a deleted 4 GiB file is reclaimed after a trim pass), so the image doesn't grow
forever like DD's `Docker.raw`. So raw beats ASIF on every axis that mattered (commit latency,
durability, *and* reclaim), which is why ASIF was dropped entirely.

## Launch: expedited RCU (2026-06-09)

Kernel cmdline `rcupdate.rcu_expedited=1`. Every `docker run --rm` tears down a veth pair +
netns, each otherwise blocking on a normal multi-ms RCU grace period; expedited forces them via
IPIs in ~µs (~23% of launch on its own): container launch (`run --rm true`) 175 ms → **89 ms**
(DD 158 ms); parallel launch ×20 1.27 s → **0.82 s** (DD 1.19 s). Disable with
`VELOX_KCMDLINE_EXTRA="rcupdate.rcu_expedited=0"`.

## Caveats

- Both VMs were resident concurrently (only one under load at a time); a fully-quiesced
  single-engine run would be marginally cleaner.
- **Startup** is a *warm-disk* restart (kernel/rootfs in the host page cache), not a
  purged-cache first boot.
- `dd`-based fs writes are wall-clock around `dd; sync` (busybox `dd` rejects
  `conv=fdatasync`), so they include ~0.2–0.3 s of container-start overhead — identical
  method on both engines, so the comparison holds, but absolute MB/s is slightly
  conservative.
- Bind-mount **read** is influenced by the host page cache (treat *write* + *small-files*
  as the reliable VirtioFS signals).
- `pgbench` TPS and cold pull are single runs; everything else is medians / fixed windows.
- Cold pull is partly network-bound (both engines pull the same bytes from the same
  registry); the engine-specific part is layer extraction.

## Not yet covered (planned additions)

- x86 / Rosetta throughput under emulation (`--platform linux/amd64` compute)
- `docker cp` over the VSOCK data plane (in/out)
- Disk reclaim (sparse-image hole-punch after `rmi` + `fstrim`)
- A multi-service `compose` stack with end-to-end HTTP latency (`wrk`/`hey`)
- Incremental `docker build` (BuildKit cache) inner-loop timing
