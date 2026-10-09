# Velox 1.7.0 vs OrbStack 2.2.3 — full head-to-head

**Run** `2026-10-09-orbstack` · measured 2026-10-09 · Apple M4 Pro (12-core), 24 GB, macOS 27.0.1
**Harness** `BENCH_PEER=orbstack docs/bench/run.sh campaign` → `docs/bench/results-orbstack.csv` → `docs/bench/report.py --csv results-orbstack.csv`

## Verdict

**OrbStack is a far tougher opponent than Docker Desktop, and Velox does not beat it across
the board.** Velox clearly wins container work: launch (2×), builds (1.4–1.9×),
container↔container and container→host networking (1.4–1.6×), overlay writes, Postgres (2.5×
TPS) and amd64 emulation. OrbStack clearly wins the *host-integration* paths:
- startup (0.88 s vs 1.21 s);
- small-file VirtioFS (2.3× faster);
- `docker cp` (1.3–1.4×);
- idle CPU (half of Velox's);
- RAM under load and especially after teardown (OrbStack returns memory, Velox does not);
- disk space between trims.

Idle RAM is a tie. Published-port throughput has no verdict: Velox is bimodal there, explained
below.

Counted over the 41 scorecard rows:
- **Velox wins 16.**
- **11 are par.**
- **OrbStack wins 10.** Six of those are the n=1 idle/RAM one-offs. They are still losses.
- 3 are unreliable.

There is also one functional gap: OrbStack honours `-p <host-ip>:…`; Velox does not.

Measured the way the August Docker Desktop run was, with stricter gates (below). Rules were
fixed in `docs/benchmarks.md` before the first number existed; nothing was dropped or re-run
selectively.

---

## Scorecard

`[±x% n=y]` is the inter-quartile spread over y runs.
- `WIN`/`TRAIL` require ≥1.15× or ≤0.87× **and** non-overlapping IQRs.
- `UNRELIABLE` means one side's spread exceeds 25%.
- n=1 rows are the one-off phases (idle, RAM under load, reclaim) and carry no spread.
- Δ > 1 means Velox is better.

| Metric | Velox | OrbStack | Δ | Verdict |
|---|---|---|---|---|
| Installed footprint (shipped) | 344 MB | 696 MB | 2.02× | **WIN** |
| On-disk at rest, end of run (same images) | 3,345 MB | 3,090 MB | 0.92× | par (n=1) |
| Idle RAM, pre-saver (RSS / phys_footprint) | 729 / 493 MB | 759 / 543 MB | 1.04× / 1.10× | par |
| Idle RAM, after 5+ min idle (RSS / phys_footprint) | 747 / 505 MB | 738 / 522 MB | 0.99× / 1.03× | par |
| Idle CPU (4 min, whole engine) | 0.53 % | 0.27 % | 0.51× | **TRAIL** (n=1) |
| Idle CPU, after 5+ min idle | 0.61 % | 0.20 % | 0.33× | **TRAIL** (n=1) |
| RAM under load, 21 containers (RSS / phys_footprint) | 1,603 / 1,152 MB | 1,251 / 948 MB | 0.78× / 0.82× | **TRAIL** (n=1) |
| RAM 3 min after teardown (RSS / phys_footprint) | 1,616 / 1,058 MB | 939 / 638 MB | 0.58× / 0.60× | **TRAIL** (n=1) |
| Startup: restart → API-ready (both engines quit) | 1.21 s [±3%] | 0.88 s [±2%] | 0.73× | **TRAIL** |
| Container launch (`run --rm alpine true`) | 0.10 s [±7%] | 0.20 s [±4%] | 1.97× | **WIN** |
| Sequential churn (per container) | 0.11 s [±5%] | 0.21 s [±3%] | 2.00× | **WIN** |
| Parallel launch ×20 (total) | 0.89 s [±2%] | 1.68 s [±4%] | 1.89× | **WIN** |
| Network: container → host | 94.7 Gbps [±4%] | 60.3 Gbps [±1%] | 1.57× | **WIN** |
| Network: container → container | 127 Gbps [±19%] | 91.6 Gbps [±0%] | 1.39× | **WIN** |
| Published port, 1 stream | 42.4 Gbps [±25%] | 48.2 Gbps [±4%] | 0.88× | par |
| Published port, 4 streams | 57.3 Gbps [±52%] | 27.7 Gbps [±2%] | 2.07× | UNRELIABLE |
| VirtioFS bind write (1 GiB) | 1,625 MB/s [±12%] | 1,549 MB/s [±4%] | 1.05× | par |
| VirtioFS bind read (cached) | 2,589 MB/s [±7%] | 2,049 MB/s [±3%] | 1.26× | **WIN** |
| Small-file extract, 4,000 files → bind | 2.74 s [±3%] | 1.17 s [±1%] | 0.43× | **TRAIL** |
| Named-volume write (1 GiB) | 2,164 MB/s [±27%] | 1,204 MB/s [±12%] | 1.80× | UNRELIABLE |
| Container-overlay write (1 GiB) | 2,021 MB/s [±14%] | 1,077 MB/s [±18%] | 1.88× | **WIN** |
| `docker cp` out (1 GiB) | 535 MB/s [±3%] | 691 MB/s [±2%] | 0.77× | **TRAIL** |
| `docker cp` in (1 GiB) | 373 MB/s [±2%] | 542 MB/s [±7%] | 0.69× | **TRAIL** |
| Image extraction (`docker load`) | 6.37 s [±5%] | 5.83 s [±5%] | 0.92× | par |
| Build: cold (`--no-cache`) | 1.50 s [±1%] | 2.24 s [±3%] | 1.49× | **WIN** |
| Build: cached no-op | 0.22 s [±2%] | 0.41 s [±2%] | 1.86× | **WIN** |
| Build: incremental (1 file) | 1.41 s [±1%] | 2.02 s [±2%] | 1.43× | **WIN** |
| Build: 512 MiB context transfer | 161 MB/s [±2%] | 113 MB/s [±3%] | 1.42× | **WIN** |
| Compose up → healthy (3 svc) | 3.68 s [±2%] | 4.10 s [±8%] | 1.11× | par |
| Compose down `-v` | 10.39 s [±0%] | 10.56 s [±0%] | 1.02× | par |
| amd64 emulated SHA-256 loop | 2.01 s [±1%] | 2.41 s [±0%] | 1.20× | **WIN** |
| arm64 native SHA-256 loop | 0.42 s | 0.42 s | 1.00× | par |
| Emulation tax (amd64 ÷ native) | 4.74× | 5.67× | 1.20× | **WIN** |
| Disk returned after deleting ~5 GB (restart) | 6,612 MB | 6,051 MB | 1.09× | par (n=1) |
| pgbench init (scale 50) | 2.19 s [±16%] | 3.25 s [±1%] | 1.48× | **WIN** |
| pgbench TPS (8 clients, 30 s) | 14,763 [±9%] | 5,804 [±15%] | 2.54× | **WIN** |

The memory rows pass the pre-registered two-accounting check: RSS and the kernel's
`phys_footprint` agree in direction on every one, so the memory verdicts stand. The whole-system
`vm_stat` cross-check agrees under load (Velox +1,337 MB vs OrbStack +1,040 MB over a no-engine
baseline).

How the summary count was made:
- The "same images" at-rest row is taken from the end-of-run footprint. The start-of-run row is
  an artefact (see below), so the published CSV shows both and `report.py` prints them pooled as
  UNRELIABLE.
- "Disk retained after rm" is negative on both sides (−2,252 / −1,552 MB) and gets no ratio.
- The superseded startup row is not counted.

---

## Where OrbStack wins, and why

**Startup, 0.88 s vs 1.21 s.**
- This is the corrected measurement, with *both* engines quit before every timing (see
  [harness defects](#four-harness-defects-found-by-this-run)).
- OrbStack's vmgr hands off to an already-prepared VM state faster than Velox gets from
  `open -a` to a dockerd answering over vsock.
- Velox also showed two outliers in 12 starts (0.85 s and 2.29 s); OrbStack's spread is ±2%.
- Velox's 1.2 s beat Docker Desktop's 2.0 s. It does not beat OrbStack.

**Small-file VirtioFS, 2.3× slower.** The same weakness the August report found against Docker
Desktop (0.80×), much larger here. OrbStack's file sharing is clearly tuned for metadata-heavy
work: untar, `npm install`, git checkouts. This is the trail users will feel most on bind-mounted
source trees.

**`docker cp`, 1.3–1.4× slower.** The bulk API transport (Velox's VSOCK proxy) is the bottleneck.
It beat Docker Desktop 2.4×, and loses to OrbStack.

**Idle CPU, about 2× and 3× higher.** In absolute terms the numbers are tiny (0.53% / 0.61% of
one core vs 0.27% / 0.20%), but the North Star is explicit, and OrbStack is lower.

**RAM under load and after teardown.**
- With 21 containers, Velox holds 1.6 GB RSS against OrbStack's 1.25 GB.
- Three minutes after they are all removed, OrbStack is back down to 939 MB. Velox has not
  returned anything (1,616 MB).
- OrbStack returns guest memory to macOS continuously. Velox's balloon only acts through the
  resource saver.

**The resource saver did not reduce memory in this run.** Velox's idle RSS after the 5-minute
window was 747 MB against 729 MB before it. The August run measured 734 → 373 MB. See
[Act on this](#act-on-this).

**Disk space between trims.** Velox gives deleted blocks back to macOS only at boot (fstrim at
t+60 s) and on its periodic trim. OrbStack does it continuously. At the moment the run stopped
for disk space (see below), the two data images held:
- Velox: 19.8 GB allocated for 6.5 GB of data.
- OrbStack: 5.5 GB.

After a Velox restart, its image was back to 7.1 GB. Both engines hand back everything once
trimmed (the reclaim row is par), but between trims Velox can hold many GB of a user's disk.

---

## Published port: no verdict, and why it matters

Velox's 4-stream host → container throughput is **bimodal**:
- Velox: 18.9, 19.9, 20.2, 56.8, 57.2, 57.5, 59.8, 60.0 Gbit/s (including the two discarded
  round-4 attempts).
- OrbStack: 27.3–28.2, every time.

Three explanations were ruled out:
- **Run order:** the slow runs fell on both sides of the order balance.
- **OrbStack leftovers:** it reproduced with OrbStack fully quit.
- **Boot state:** four back-to-back probes on *one* Velox boot gave 20, 42, 59 and 25 Gbit/s.

So when Velox's conduit path is fast it is about twice OrbStack, and when it isn't it is
about 0.7× OrbStack. A user cannot predict which they get. Single-stream is steadier
(42 vs 48, par).

---

## Where Velox wins

- **Container lifecycle is twice as fast:** launch, churn, parallel ×20.
- **Builds are 1.4–1.9× faster**, including context transfer over the API socket.
- **Postgres:** 2.5× the TPS and 1.5× faster init. OrbStack's data disk is btrfs; Velox's is ext4
  on a raw image with barriers on. Both run durable defaults; this is not a fsync-off
  artefact on either side.
- **Guest networking:** container → host is 1.57× and container ↔ container 1.39×.
- **Writes:** overlay writes are 1.88×. Named-volume writes beat OrbStack in all six rounds
  (lowest Velox 1,342 vs highest OrbStack 1,312 MB/s), but Velox's own spread exceeds 25%, so
  by the pre-registered rule there is no verdict.
- **Emulation:** amd64 emulation is 1.2× faster (both use Rosetta).
- **Install size:** half of OrbStack's (344 vs 696 MB).

---

## Functional matrix

Both engines pass every probe except one:

| Probe | Velox | OrbStack |
|---|---|---|
| Per-container host-IP publish (`-p <LAN-IP>:…`) | **fail** | pass |

Both passed:
- bind mounts and `host.docker.internal`;
- UDP, IPv4 and IPv6 publishing;
- privileged port 80 and loopback pin;
- the `linux/amd64`, `linux/arm/v7` and `linux/386` platforms;
- BuildKit and provenance;
- `stats`, `logs -f`, `events` and `exec`;
- named access (`.velox.local` / `.orb.local`).

The one fail is the documented Velox limitation (CLAUDE.md pillar 1); OrbStack supports it.

---

## Fairness: what was equal, what was not

**Forced equal:**
- 8 vCPU / 8 GiB, verified host-side from both apps' settings files *and* in-guest:
  Velox 8 / 8,017 MB, OrbStack 8 / 8,005 MB.
- The same client binaries, by path, from a private `DOCKER_CONFIG`: Velox's bundled
  `docker` 29.8.2, compose v5.6.0 and buildx v0.37.2. OrbStack's installer had re-linked
  `~/.docker/cli-plugins` to its own compose/buildx.
- Both on the containerd image store (overlayfs snapshotter).
- Both privileged helpers installed (porthelper / OrbStack privhelper) and counted in RAM.
- Empty data disks at the start: both pruned of images and build cache.
- One engine resident at a time, except in the original startup phase (see defects).

**Each product at its shipped defaults otherwise.** Velox's 5-min resource saver stayed on;
OrbStack's dynamic memory and zram stayed on.

**Differences disclosed, not corrected:**

| | Velox 1.7.0 | OrbStack 2.2.3 |
|---|---|---|
| Docker Engine | 29.8.2 | 29.4.0 |
| Guest kernel | 7.2.9 (kernel.org, tinyconfig) | 7.0.14-orbstack |
| Hypervisor | Apple `Virtualization.framework` | OrbStack's own VMM (no VZ process; guest RAM lives in `OrbStack Helper`) |
| Data filesystem | ext4 on raw image, barriers on | btrfs |
| Swap | 1 GiB file | 8 GiB zram + 1 GiB file |
| Network datapath | Apple VZNAT + conduit pool | OrbStack's own |
| License state | open source | Pro trial |

**Gates.**
- After every engine stop and start, and between heavy test groups, the harness waited for:
  - ≥90% host CPU idle;
  - memory-pressure level normal;
  - `ProcessInfo.thermalState == nominal`;
  - the freshly booted engine's own processes to fall below 5% CPU.
- No gate ever timed out: 0 `not_quiet` and 0 `engine_not_quiet` flags in the CSV.
- Order balance: each engine went first in exactly 3 of the 6 rounds.

---

## Four harness defects found by this run

Each was found by disbelieving a result. All four are fixed in `run.sh` / `report.py`.

1. **Memory accounting.** `footprint(1)` does not see OrbStack's guest RAM: it reported 106 MB
   for `OrbStack Helper` while the kernel ledger, `top` and RSS all read about 1,307 MB.
   Publishing it would have flattered OrbStack more than tenfold. The harness now reads the
   kernel's `ri_phys_footprint` (Activity Monitor's figure) directly.
2. **Startup ran with the other engine resident.** `startup` quit only the engine being timed,
   so from round 1 onwards the other engine was always up. The campaign rows are kept as
   `restart_to_ready` ("other engine resident"): Velox 1.22 s [±22%], OrbStack 0.91 s. The
   phase was re-run with both quit, as `restart_to_ready_solo`: 1.21 s vs 0.88 s, the headline.
   **The August Docker Desktop report has the same defect.** Its 1.23 s vs 1.99 s startup row
   was measured with the other engine resident on both sides.
3. **False sleep detection.** The sleep detector counted "Wake from" lines in `pmset -g log`,
   which is a rolling window. As old entries aged out the count changed with no sleep at all,
   and two complete Velox round-4 suites were discarded (the last real wake on this Mac was the
   previous day). The detector now compares the timestamp of the latest sleep/wake event. The
   discarded rows stay in the CSV, flagged and excluded. They are not reinstated after the
   fact, and Velox's round 4 was re-measured after a restart (round `4b`).
4. **A 1.9 GB volume leak per pgbench run.** `docker rm -f pg` left Postgres's anonymous volume
   behind on both engines. Found in the smoke test, before the campaign. Now `rm -fv`.

The `step` runner also now stops instead of marking a failed step done, and the parity check
aborts instead of warning, as `benchmarks.md` always claimed.

## Deviations from the run book

- **No reboot before the run, and the Claude app stayed open.** It drove the run with minimal
  polling. The quiet-host gate never had to wait on it.
- **Velox 1.7.0 rather than 1.7.1.** The only 1.7.1 change is a menu-bar layout fix.
- **The run was resumed twice.**
  1. Round 3 stopped at OrbStack's preflight with 18 GB free against a 25 GB floor. The cause
     was Velox's untrimmed blocks (above). The floor was lowered to 15 GB; the heaviest step
     needs about 5 GB.
  2. Round 4's Velox suite was falsely flagged as slept (defect 3). Velox was restarted, so its
     boot trim ran, and the round was re-measured.
- **The start-of-run at-rest footprint is not comparable.** Velox's 3,616 MB includes blocks
  freed by the pre-run prune but not yet trimmed (Velox was already running when it was
  pruned). OrbStack's 706 MB is a genuinely empty, continuously trimmed disk. The end-of-run
  pair (3,345 vs 3,090 MB, same images on both) is the comparable one.
- **Default workspace was not empty.** Its images, including a user image, and its 4.5 GB build
  cache were pruned so both engines started equal.

---

## Act on this

1. **The resource saver is not saving: a regression since 1.2.0.** Idle RSS rose from 729 to
   747 MB across the saver window; in August the same phase fell from 734 to 373 MB.
   - Re-checked after the campaign: the Velox VM process's RSS stayed flat for 8–9 minutes past
     the 5-minute timeout. That held both on a fresh boot (592 → 600 MB) and after a container
     had run and exited (644 → 645 MB).
   - Not yet determined: whether the saver no longer arms, or the balloon no longer returns
     pages to macOS.
   - Fixing it is worth about 350 MB of idle RAM, which is the difference between "par with
     OrbStack" and "half of OrbStack".
2. **Return memory after load.** OrbStack drops back to about 940 MB within 3 minutes of
   removing 21 containers. Velox stays at 1.6 GB until the saver fires, and the saver has to
   work first (item 1).
3. **Small-file VirtioFS (0.43×).** The biggest real-world gap: source trees, `node_modules`.
4. **Published-port bimodality.** Twice OrbStack or 0.7× of it, at random. Find why the
   multi-stream conduit path sometimes runs at a third of its speed.
5. **`docker cp` (0.7–0.77×) and startup (0.73×).** These were wins against Docker Desktop and
   are trails against OrbStack.
6. **Trim between boots.** Run `fstrim` after large deletes (an image `rm`/prune event is the
   trigger, per CLAUDE.md §8) rather than holding many GB until the next boot or periodic pass.
7. **Idle CPU.** Half of what Velox uses is what OrbStack needs; find the residual wakeups.

## Appendix — environment

| | Velox | OrbStack |
|---|---|---|
| App | 1.7.0 | 2.2.3 (`dev.kdrag0n.MacVirt`) |
| Configured | `cpuCount 8`, `memoryGiB 8`, swap 1 GiB, saver 5 min | `cpu 8`, `memory_mib 8192`, rosetta on, admin on |
| In-guest | 8 vCPU / 8,017 MB | 8 vCPU / 8,005 MB |
| Engine | 29.8.2, overlayfs (containerd) | 29.4.0, overlayfs (containerd) |
| Host processes measured | VeloxApp + VZ VirtualMachine XPC + porthelper | OrbStack + OrbStack Helper (+ privhelper when running) |
| Data image | `~/.velox/data.img` (raw, sparse) | `…/HUAQ24HBR6.dev.orbstack/data/data.img.raw` + `swap.img` |

Raw data: `docs/bench/results-orbstack.csv` (run id `2026-10-09-orbstack`). Per-run
artifacts (settings snapshots, `docker info`, matrix, campaign log) are in
`docs/bench/runs/2026-10-09-orbstack/` (git-ignored).
