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
| 🟢 **Wins** | install 10× smaller, idle RAM 2.6× less, startup 1.5× faster, **container launch 1.8×**, container→host net 3.6×, VirtioFS write 2.9× / small-files 10×, **durable commit 1.5× (0.31 ms vs 0.47 ms)** | |
| ⚪ **Par** | cold pull, bulk DB load (`pgbench` init), **pgbench TPS (0.98×)** | |
| 🔴 **Trails** | inbound published-port throughput (~8–17×) | |

Full numbers in [Results](#results). The scorecard's disk/pgbench rows are the **old ASIF
`.fsync`** baseline; see [Disk: raw image + durable `.fsync`](#disk-raw-image--durable-fsync-2026-06-09)
for the raw-disk re-measurement (durable commits now beat DD with full durability intact) and
[Launch: expedited RCU](#launch-expedited-rcu-2026-06-09) for the launch wins.

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
Idle RAM (host RSS, all procs)        871 MB         2,296 MB    2.64x  WIN
Startup: restart→API-ready            1.74 s           2.55 s    1.47x  WIN
Container launch (run true)           0.17 s           0.16 s    0.90x  par
Sequential churn (per container)      0.18 s           0.16 s    0.89x  par
Parallel launch x20 (total)           1.27 s           1.19 s    0.93x  par
Network: container→host           93.25 Gbps       25.74 Gbps    3.62x  WIN
Net: published port (1 stream)     1.44 Gbps       12.11 Gbps    0.12x  TRAIL
Net: published port (4 streams)    1.09 Gbps       18.60 Gbps    0.06x  TRAIL
FS: VirtioFS bind write           1,979 MB/s         692 MB/s    2.86x  WIN
FS: VirtioFS bind read            2,879 MB/s       2,163 MB/s    1.33x  WIN
FS: extract 4000 files (bind)         0.31 s           3.14 s   10.08x  WIN
FS: named-volume write (in-VM)    1,556 MB/s       1,670 MB/s    0.93x  par
FS: container-overlay write       1,732 MB/s       1,590 MB/s    1.09x  par
Cold image pull (381 MB)             18.48 s          16.91 s    0.92x  par
pgbench init (scale 50)               2.48 s           2.37 s    0.96x  par
pgbench TPS (8 clients, 30s)          5,698           12,904     0.44x  TRAIL
```

Regenerate any time with `./run.sh report` (reads `results.csv`).

### The remaining trail: published-port throughput

Inbound `localhost:PORT → container` goes through the host-side userspace `PortForwarder`
(`Sources/VeloxCore/Proxy/`) over a single `VZVirtioSocketDevice` (VSOCK), which serializes
and does not scale with parallel streams (1.44 → 1.09 Gbit/s as `-P` goes 1 → 4). The
asymmetry is the tell: the *outbound* VZNAT path is 3.6× **faster** than Docker Desktop, so
this is the inbound VSOCK relay, not the datapath. Apple caps the VSOCK credit window
host-side (untunable from macOS), so the in-scope fix is to carry published-port *data* over
the fast VZNAT path with *control* over VSOCK (VZNAT-reverse-dial) — designed, not yet built.

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
