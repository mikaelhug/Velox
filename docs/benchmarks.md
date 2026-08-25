# Benchmarks — Velox vs Docker Desktop

A reproducible head-to-head of Velox against **Docker Desktop** on the same Mac, the same
way, with **both engines configured identically**. The harness lives in
[`docs/bench/`](bench/); this page is the method, the fairness rules, and the recorded
results.

> **North star:** be as lean, efficient, and fast as possible with the smallest footprint —
> beating Docker Desktop where possible, on par where not. These tests are how we keep that
> claim honest, including where Velox currently **trails**.

## TL;DR

| | Velox vs Docker Desktop 4.88.0 |
| --- | --- |
| 🟢 **Wins** | install 6× smaller, idle RAM 2.4× less, idle CPU 4.6× less, startup 1.6× faster, container launch 1.2×, published ports 2.4–3.4×, `docker cp` ~2.4×, container→container net 1.4×, 1.5× more disk handed back after a delete |
| ⚪ **Par** | VirtioFS bind read, named-volume write, overlay write, `docker load`, cold/incremental build, compose up, emulation tax, pgbench |
| 🔴 **Trails** | `compose down` on SIGTERM-ignoring services (3× slower), small-file extract over VirtioFS (25% slower), no per-container host-IP publishing |

Full numbers and raw values: **[REPORT-2026-08-25.md](bench/REPORT-2026-08-25.md)**. The data
disk is raw + durable `.fsync` ([Disk](#disk-raw-image--durable-fsync-2026-06-09)); published
ports ride a VZNAT conduit pool; launch is `HZ_1000` + expedited RCU
([Launch](#launch-expedited-rcu-2026-06-09)).

## Test environment (recorded run)

- **Host:** Apple M4 Pro (8 performance + 4 efficiency cores), 24 GB RAM, macOS 26.6.2
- **Velox:** 1.2.0 — guest kernel 7.2, dockerd 29.7.2
- **Docker Desktop:** 4.88.0 — dockerd 29.7.2, `Virtualization.framework` backend
- **Both engines:** **8 vCPU / ~8 GB** (verified in-guest), 0 containers, same containerd
  image store, same `docker` CLI and compose plugin, one engine resident at a time
- **Date:** 2026-08-25 (`./run.sh campaign`, run id `2026-08-24`)

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
| image | `load_local` | `docker load` of a fixed local tar — decompress + snapshotter write, no registry |
| realworld | `pgbench_init` | bulk DB load (sequential writes + checkpoint) |
| realworld | `pgbench_tps` | TPC-B-like txns — dominated by per-commit **fsync latency** |

## Results

Medians over five order-balanced rounds (three for build/compose); `±` is the inter-quartile
spread. Metrics whose spread was too wide to call are published without a verdict in the
[report](bench/REPORT-2026-08-25.md#appendix-a--unreliable-metrics) rather than summarised here.

```
Metric                                      Velox    Docker Desktop        Δ  Verdict
----------------------------------------------------------------------------------------
Installed footprint (shipped)              357 MB          2,193 MB    6.14x  WIN
Idle RAM (host RSS, whole engine)          734 MB          1,771 MB    2.41x  WIN
Idle RAM after resource saver              373 MB            847 MB    2.27x  WIN
Idle CPU (4 min, whole engine)              0.76 %           3.52 %    4.63x  WIN
RAM under load (21 containers)           1,949 MB          2,991 MB    1.53x  WIN
Startup: restart→API-ready                 1.23 s            1.99 s    1.62x  WIN
Container launch (run true)                0.11 s            0.13 s    1.21x  WIN
Sequential churn (per container)           0.11 s            0.14 s    1.21x  WIN
Parallel launch x20 (total)                0.86 s            1.01 s    1.17x  WIN
Net: container→container               130 Gbps        96.37 Gbps    1.35x  WIN
Net: published port (1 stream)       43.36 Gbps        12.68 Gbps    3.42x  WIN
Net: published port (4 streams)      59.77 Gbps        25.29 Gbps    2.36x  WIN
docker cp out / in (1 GiB)          540 / 373 MB/s   225 / 154 MB/s   ~2.4x  WIN
Disk returned after rm (~5 GB)           5,295 MB          3,594 MB    1.47x  WIN
FS: VirtioFS bind read (cached)        2,452 MB/s        2,180 MB/s    1.12x  par
FS: named-volume write (in-VM)         2,115 MB/s        1,840 MB/s    1.15x  par
Image extraction (docker load)             6.70 s            6.38 s    0.95x  par
Build: cold / incremental           1.60 / 1.52 s     1.77 / 1.56 s    ~1.1x  par
Compose up→healthy (3 services)            3.57 s            3.54 s    0.99x  par
Emulation tax (amd64÷native)               4.89 x            4.82 x    0.99x  par
pgbench init / TPS                  2.21 s / 13,796   2.38 s / 12,372  ~1.1x  par
FS: extract 4000 files (bind)              3.21 s            2.56 s    0.80x  TRAIL
Compose down -v                           10.36 s            3.49 s    0.34x  TRAIL
```

Both engines also passed every functional probe that was run — bind mounts,
`host.docker.internal`, TCP/UDP/IPv6 publishing, privileged ports, BuildKit with
attestations, `linux/amd64` + `linux/arm/v7` + `linux/386` emulation, `exec`, `stats`,
`logs -f`, `events`. Velox adds `<name>.velox.local`; Docker Desktop supports per-container
host-IP publishing, which Velox does not.

### Running the annual comparison

`./run.sh campaign` takes about 2.5 hours, bounces both applications repeatedly, and needs the
Mac to itself — so it is **an annual exercise**, not a per-commit or per-release one. Run it
when a Docker Desktop major lands, before putting a performance claim on the website, or once
a year to keep this page honest. The quick pre-release regression check is `./run.sh all`
(~12 minutes, single round); see the header of [`bench/run.sh`](bench/run.sh).

Preconditions the harness enforces, each of which was bought with a wrong number:

- **On AC power.** Preflight blocks and waits. The first attempt at this run degraded to
  battery, macOS began sleeping the machine between measurements, and wall-clock timings that
  span a sleep are fiction — `docker load` "took" 945 s instead of 7 s. A wake-event counter
  now discards any round that spans a sleep, and the campaign should be run under
  `caffeinate -dimsu`.
- **Nothing else running**, thermals unthrottled, ≥40 GB free, no containers on the engine
  under test.
- **Both engines at matched CPU/RAM**, verified in-guest and aborted on mismatch.
- **One engine resident at a time**, the other fully quit including its GUI.
- **Nothing network-dependent on a timed path** — every fixture is pre-pulled untimed. A cold
  `docker pull` metric was deliberately deleted: the same image measured 4.1 s and 20.0 s
  forty minutes apart, which is a CDN reading, not an engine property.
- **Order-balanced rounds and n≥5.** Single-shot numbers on this workload are worthless;
  container→host throughput alone ranges 51–94 Gbit/s across identical runs.

Results land in `results.csv` with a timestamp, run id, round and both version strings;
`./run.sh report` prints the scorecard with medians, spreads and verdicts. Per-run artifacts
(settings snapshots, `docker info`, matrix output) are written to `bench/runs/<run-id>/` and
are git-ignored, because they capture the hostname and whatever real containers happen to be
on the machine.

> **Footprint note (multi-arch emulation).** Baking the three static QEMU user-mode emulators
> (arm, i386, x86_64) into the guest grew `root.img` from **78.8 MB to 91.4 MB (+12.7 MB)**.
> That is included in the 357 MB above — still ~6× smaller than Docker Desktop, which ships
> the same emulators in a far larger VM image. The cost is disk only: the erofs root is
> demand-paged, so an emulator that is never used is never read into RAM.
> The rest of that change was **A/B'd guest-vs-guest** rather than re-run against the table
> above (that baseline was measured on a different machine state): the pre-change `root.img`
> and the new one, same host, same hour, zero containers. **No regression attributable to the
> change** — and a caution for whoever benchmarks next: *single-shot suite numbers on a busy
> workstation are not evidence*. On identical code the suite reported `c2host` at 36.7, 96.8
> and 88.4 Gbit/s across three runs, and the ext4 named-volume write it scored at 1,029 MB/s
> measured a **median of 2,044 MB/s over n=7** with a 102% spread. Repeat the metric, compare
> medians, and treat a delta smaller than the intra-run spread as noise. The vs-Docker-Desktop
> half could not be run (Docker Desktop was not installed on the measuring machine).

### Published ports: now a VZNAT conduit-pool win

Inbound `localhost:PORT → container` used to route over a single `VZVirtioSocketDevice`
(VSOCK), which serialized and capped at ~1–6 Gbit/s — the old big trail. It now rides a
**pre-warmed VZNAT conduit pool**: the guest keeps idle TCP conduits dialed to the host over
the fast VZNAT path, and the host hands each published connection an idle conduit (assignment
over VSOCK, *data* over VZNAT), so throughput jumps to **38–60 Gbit/s — 2.9–3.3× Docker
Desktop** (it falls back to the VSOCK relay if the pool is momentarily empty).

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

> **Baseline note.** The filesystem rows above were re-measured same-day against Docker
> Desktop 4.88.0 on 2026-08-25, which resolves the provisional status they carried while the
> DD column was a June 2026 recording. VirtioFS bind read and named-volume write came out par
> or better; small-file extract remains the one filesystem path that trails, now measured at
> 0.80× with a tight ±4% spread — a real result rather than a noisy one.

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

> **Two caveats on the table above.** Its **Docker Desktop column is the June 2026
> recording**, superseded by the [2026-08-25 report](bench/REPORT-2026-08-25.md) — which
> measured named-volume write at 2,115 MB/s vs 1,840 MB/s and pgbench at 13,796 vs 12,372 TPS
> on current builds of both. And the **fsync-latency and durable-commits rows are not
> reproducible from this repo**: they came from a hand-run `fio`, which no script here
> installs or invokes. Treat those two rows as a historical note on the ASIF→raw decision
> (where the guest-vs-guest comparison is what mattered), not as a current DD claim.

Raw still reclaims host space: `vinit`'s periodic `FITRIM` hole-punches the raw backing file,
so the image doesn't grow forever. Measured 2026-08-25 with a real engine restart to trigger
the trim pass: of ~5.5 GB freed, Velox handed **5,295 MB (96%) back to macOS**, against
Docker Desktop's 3,594 MB of 5,210 MB (69%). So raw beats ASIF on every axis that mattered
(commit latency, durability, *and* reclaim), which is why ASIF was dropped entirely.

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
- `pgbench` TPS is a single run; everything else is medians / fixed windows.
- **No metric here touches the network off-box.** Image extraction is measured with
  `docker load` from a fixed local tar, never a `docker pull`: a pull is dominated by
  bandwidth to the registry, which is not a property of either engine — the same 381 MB
  image measured 4.1 s and 20.0 s on this machine forty minutes apart. It had been reported
  as a "TRAIL vs Docker Desktop" row that was really a CDN reading. Don't add one back.

## Not yet covered (planned additions)

- x86 / Rosetta throughput under emulation (`--platform linux/amd64` compute)
- `docker cp` over the VSOCK data plane (in/out)
- Disk reclaim (sparse-image hole-punch after `rmi` + `fstrim`)
- A multi-service `compose` stack with end-to-end HTTP latency (`wrk`/`hey`)
- Incremental `docker build` (BuildKit cache) inner-loop timing
