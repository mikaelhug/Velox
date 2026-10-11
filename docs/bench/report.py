#!/usr/bin/env python3
"""Print a Velox scorecard against one or more peers (Docker Desktop, OrbStack) from a results CSV.

    report.py [--csv PATH] [--peer dd|orbstack] [--supersede RUN_ID] [--md]
        default CSV: results.csv (Docker Desktop). A BENCH_PEER=orbstack run writes
        results-orbstack.csv.
        Three-way campaign: results-3way.csv — one column per engine, a verdict against each
        peer. --peer narrows any CSV to the classic two-column Velox-vs-peer table.

Aggregates ALL rows per metric (median + IQR + n) rather than showing the last one.
The old last-write-wins behaviour published whichever single run happened to be written
last, on a workload whose measured intra-metric spread reached 102% — container→host
throughput alone ranged 36.7–96.8 Gbit/s across identical runs. A number that noisy is
not a result, and the UNRELIABLE verdict below says so out loud instead of picking a
flattering sample.
"""
import csv, os, statistics, sys, collections

CSV = os.path.join(os.path.dirname(__file__), "results.csv")
if "--csv" in sys.argv:
    CSV = sys.argv[sys.argv.index("--csv") + 1]
NAMES = {"dd": "Docker Desktop", "orbstack": "OrbStack"}

# (suite, test, metric): (label, higher_is_better, unit)
SPEC = [
    ("disk", "installed_footprint", "size",        ("Installed footprint (shipped)", False, "MB")),
    ("disk", "atrest_footprint", "size",           ("On-disk at rest (incl. VM data)", False, "MB")),
    ("idle", "rss_active", "host_rss",             ("Idle RAM, pre-saver", False, "MB")),
    ("idle", "fp_active", "host_fp",               ("Idle RAM, pre-saver (footprint)", False, "MB")),
    ("idle", "rss_saver", "host_rss",              ("Idle RAM, after resource saver", False, "MB")),
    ("idle", "fp_saver", "host_fp",                ("Idle RAM, after saver (footprint)", False, "MB")),
    # Idle is compared in each product's idle state: after the 5-minute resource-saver timeout
    # (a product without a saver is measured as it is — that is its trade-off). The first 4
    # minutes, with every VM still running, are kept as context, not the idle comparison.
    ("idle", "cpu_saver", "pct",                    ("Idle CPU (idle state, after saver)", False, "%")),
    ("idle", "cpu", "pct",                          ("Idle CPU, first 4 min (before saver)", False, "%")),
    ("mem", "loaded", "host_rss",                   ("RAM under load (21 containers)", False, "MB")),
    ("mem", "loaded_fp", "host_fp",                 ("RAM under load (footprint)", False, "MB")),
    ("mem", "postload", "host_rss",                 ("RAM after teardown (return)", False, "MB")),
    ("mem", "postload_fp", "host_fp",               ("RAM after teardown (footprint)", False, "MB")),
    # `restart_to_ready` was measured with the OTHER engine still resident (harness defect found
    # 2026-10-09); `restart_to_ready_solo` is the corrected measurement with both quit first.
    ("lifecycle", "restart_to_ready", "time_s",    ("Startup (other engine resident)", False, "s")),
    ("lifecycle", "restart_to_ready_solo", "time_s", ("Startup: restart→API-ready", False, "s")),
    ("lifecycle", "restart_to_ready_ping", "time_s", ("Startup (25 ms /_ping poll)", False, "s")),
    # The 25 ms poll perturbs OrbStack (each early, slow-failing connection delays it ~0.5 s);
    # `_sparse` waits for the socket file, then one blocking request (2026-10-10).
    ("lifecycle", "restart_to_ready_sparse", "time_s", ("Startup: restart→API-ready (sparse probe)", False, "s")),
    ("launch", "run_true", "median_s",             ("Container launch (run true)", False, "s")),
    ("launch", "churn30_per", "per_s",             ("Sequential churn (per container)", False, "s")),
    ("launch", "parallel20_total", "total_s",      ("Parallel launch x20 (total)", False, "s")),
    ("net", "c2host", "gbits",                      ("Network: container→host", True, "Gbps")),
    ("net", "c2c", "gbits",                         ("Network: container→container", True, "Gbps")),
    ("net", "pubport_h2c_p1", "gbits",             ("Net: published port (1 stream)", True, "Gbps")),
    ("net", "pubport_h2c_p4", "gbits",             ("Net: published port (4 streams)", True, "Gbps")),
    ("fs", "bind_write", "mbps",                    ("FS: VirtioFS bind write", True, "MB/s")),
    ("fs", "bind_read", "mbps",                     ("FS: VirtioFS bind read (cached)", True, "MB/s")),
    ("fs", "smallfiles_bind", "extract_s",          ("FS: extract 4000 files (bind)", False, "s")),
    ("fs", "vol_write", "mbps",                     ("FS: named-volume write (in-VM)", True, "MB/s")),
    ("fs", "overlay_write", "mbps",                 ("FS: container-overlay write", True, "MB/s")),
    ("io", "cp_out", "mbps",                        ("docker cp out (1 GiB)", True, "MB/s")),
    ("io", "cp_in", "mbps",                         ("docker cp in (1 GiB)", True, "MB/s")),
    ("image", "load_local", "total_s",              ("Image extraction (docker load)", False, "s")),
    ("build", "cold", "total_s",                    ("Build: cold (--no-cache)", False, "s")),
    ("build", "cached_noop", "total_s",             ("Build: cached no-op rebuild", False, "s")),
    ("build", "incremental", "total_s",             ("Build: incremental (1 file)", False, "s")),
    ("build", "context_xfer", "mbps",               ("Build: 512 MiB context transfer", True, "MB/s")),
    ("compose", "up_ready", "total_s",              ("Compose up→healthy (3 svc)", False, "s")),
    ("compose", "down", "total_s",                  ("Compose down -v", False, "s")),
    ("emul", "amd64_sha", "total_s",                ("amd64 emulated SHA-256 loop", False, "s")),
    ("emul", "native_sha", "total_s",               ("arm64 native SHA-256 loop", False, "s")),
    ("emul", "amd64_tax", "ratio",                  ("Emulation tax (amd64÷native)", False, "x")),
    ("disk", "reclaim", "returned_mb",              ("Disk returned after rm (of ~5 GB)", True, "MB")),
    ("disk", "reclaim", "retained_mb",              ("Disk retained after rm", False, "MB")),
    ("realworld", "pgbench_init", "load_s",         ("pgbench init (scale 50)", False, "s")),
    ("realworld", "pgbench_tps", "tps",             ("pgbench TPS (8 clients, 30s)", True, "TPS")),
]

# Cross-checks: printed with raw values, never given a verdict.
XCHECK = [
    ("idle", "sysmem_active", "delta_mb",   "System memory Δ vs no engine, idle (vm_stat)"),
    ("idle", "sysmem_saver", "delta_mb",    "System memory Δ vs no engine, after saver"),
    ("mem", "loaded_sysmem", "delta_mb",    "System memory Δ vs no engine, under load"),
    ("mem", "postload_sysmem", "delta_mb",  "System memory Δ vs no engine, after teardown"),
]
# Pairs whose verdicts must agree before a memory claim is made (RSS vs phys_footprint).
MEMPAIRS = [("Idle RAM, pre-saver", "Idle RAM, pre-saver (footprint)"),
            ("Idle RAM, after resource saver", "Idle RAM, after saver (footprint)"),
            ("RAM under load (21 containers)", "RAM under load (footprint)"),
            ("RAM after teardown (return)", "RAM after teardown (footprint)")]

vals = collections.defaultdict(lambda: collections.defaultdict(list))
nas = collections.defaultdict(lambda: collections.defaultdict(int))
matrix = collections.defaultdict(dict)
engines = set()

with open(CSV) as f:
    rows = list(csv.DictReader(f))
# --supersede RUN_ID: a same-day re-measurement kept in the same CSV under its own run id. For
# every (suite, test, metric, engine) that run contains, its rows REPLACE the other runs' rows
# rather than mixing with them — a fixed test or a changed default must not be averaged with the
# build/test it corrects. Superseded metrics are marked † so the table says which numbers came
# from the re-measurement. Without the flag those rows are ignored, so the campaign renders as run.
superseded = set()
SUP = sys.argv[sys.argv.index("--supersede") + 1] if "--supersede" in sys.argv else None
extra = [r for r in rows if r["run_id"] == SUP]
rows = [r for r in rows if not r["run_id"].endswith("-followup")]
if SUP:
    keys = {(r["suite"], r["test"], r["metric"], r["engine"]) for r in extra}
    superseded = {k[:3] for k in keys}
    rows = [r for r in rows if (r["suite"], r["test"], r["metric"], r["engine"]) not in keys] + extra
# A suite that spanned a system sleep is flagged quality/slept=1; every timed-suite row of that
# attempt (same engine, run, round) is dropped, not averaged in. Only the suite's own rows: the
# startup/idle/load phases share round numbers but are separate measurements.
SUITE_ROWS = {"launch", "net", "io", "fs", "image", "realworld", "build", "compose", "emul", "quality"}
slept = {(r["engine"], r["run_id"], r["round"]) for r in rows
         if r["suite"] == "quality" and r["test"] == "slept" and r["value"] == "1"}
peers = sorted({r["engine"] for r in rows} - {"velox", "host"})
if "--peer" in sys.argv:
    peers = [sys.argv[sys.argv.index("--peer") + 1]]
PEER = peers[0] if peers else "dd"
PNAME = NAMES.get(PEER, PEER)
for r in rows:
    if r["engine"] == "host":
        continue
    if (r["engine"], r["run_id"], r["round"]) in slept and r["suite"] in SUITE_ROWS:
        continue
    eng, key = r["engine"], (r["suite"], r["test"], r["metric"])
    if r["suite"] == "matrix":
        matrix[r["test"]][eng] = r["value"]
        engines.add(eng)
        continue
    try:
        vals[key][eng].append(float(r["value"]))
    except (ValueError, TypeError):
        nas[key][eng] += 1          # "NA" — a failed measurement, never a zero


def stats(xs):
    """median, IQR width, n. IQR over <4 points is the full range."""
    n = len(xs)
    med = statistics.median(xs)
    if n >= 4:
        q = statistics.quantiles(xs, n=4, method="inclusive")
        iqr = q[2] - q[0]
    else:
        iqr = (max(xs) - min(xs)) if n > 1 else 0.0
    return med, iqr, n


def fmt(x):
    return f"{x:,.0f}" if abs(x) >= 100 else f"{x:.2f}"


def cell(med, iqr, n, unit):
    rel = (iqr / med * 100) if med else 0
    return f"{fmt(med)} {unit} [±{rel:.0f}% n={n}]"


def zero_verdict(vm, dm, hb):
    """A lower-is-better metric where one side measured exactly zero (idle CPU once Velox's
    resource saver has stopped the VM) is the best possible result, not an undefined ratio.
    This used to print "no ratio" and so never credited the win. Negative values (a baseline
    artefact) and higher-is-better zeros still get no verdict."""
    if hb or vm < 0 or dm < 0 or (vm == 0) == (dm == 0):
        return None
    return ("WIN", float("inf")) if vm == 0 else ("TRAIL", 0.0)


def judge(v_xs, p_xs, hb):
    """(verdict, ratio) for Velox against one peer; ratio > 1 means Velox is better."""
    vm, vi, _ = stats(v_xs)
    dm, di, _ = stats(p_xs)
    zero = zero_verdict(vm, dm, hb)
    if zero:
        return zero
    if vm <= 0 or dm <= 0:
        return "no ratio (≤0)", None
    ratio = vm / dm if hb else dm / vm
    if vi / vm > 0.25 or di / dm > 0.25:
        return "UNRELIABLE", ratio
    if not (vm + vi / 2 < dm - di / 2 or dm + di / 2 < vm - vi / 2):
        return "par", ratio            # overlapping IQRs: not separated, whatever the medians say
    return ("WIN" if ratio >= 1.15 else "TRAIL" if ratio <= 0.87 else "par"), ratio


MD = "--md" in sys.argv      # Markdown table rows (for the dated REPORT), not fixed-width


def mdcell(med, iqr, n, unit):
    rel = (iqr / med * 100) if med else 0
    return f"{fmt(med)} {unit} <sub>±{rel:.0f}% n={n}</sub>"


if len(peers) > 1 and MD:
    cols = ["velox"] + peers
    print("| Metric | " + " | ".join(NAMES.get(e, e.capitalize()) for e in cols) + " | "
          + " | ".join("vs " + NAMES.get(p, p) for p in peers) + " |")
    print("|" + " --- |" * (1 + len(cols) + len(peers)))
    for s_, t, m, (lbl, hb, unit) in SPEC:
        d = vals.get((s_, t, m), {})
        if not any(d.get(e) for e in cols):
            continue
        row = [lbl + (" †" if (s_, t, m) in superseded else "")] + [mdcell(*stats(d[e]), unit) if d.get(e) else "—" for e in cols]
        for p in peers:
            if d.get("velox") and d.get(p):
                verdict, ratio = judge(d["velox"], d[p], hb)
                bold = verdict in ("WIN", "TRAIL")
                txt = ("∞× " if ratio == float("inf") else f"{ratio:.2f}× " if ratio else "") + verdict
                row.append(f"**{txt}**" if bold else txt)
            else:
                row.append("—")
        print("| " + " | ".join(row) + " |")
    sys.exit(0)

if len(peers) > 1:
    # Three-way: one column per engine, then Velox's verdict against each peer. Same rules as
    # the two-way table (noise gate, IQR overlap, 15% threshold) — just applied per pair.
    cols = ["velox"] + peers
    head = f"{'Metric':34}" + "".join(f"{NAMES.get(e, e.capitalize()):>26}" for e in cols)
    head += "".join(f"{'vs ' + NAMES.get(p, p):>24}" for p in peers)
    print(head)
    print("-" * len(head))
    pair_trails = collections.defaultdict(list)
    pair_unrel = collections.defaultdict(list)
    for s_, t, m, (lbl, hb, unit) in SPEC:
        d = vals.get((s_, t, m), {})
        if not any(d.get(e) for e in cols):
            print(f"{lbl:34}" + "".join(f"{'—':>26}" for _ in cols) + "  not measured")
            continue
        cells = "".join(f"{(cell(*stats(d[e]), unit) if d.get(e) else '—'):>26}" for e in cols)
        vs = ""
        for p in peers:
            if d.get("velox") and d.get(p):
                verdict, ratio = judge(d["velox"], d[p], hb)
                rtxt = "∞x " if ratio == float("inf") else (f"{ratio:.2f}x " if ratio else "")
                vs += f"{rtxt + verdict:>24}"
                if verdict == "TRAIL":
                    pair_trails[p].append(f"  {lbl}: {cell(*stats(d['velox']), unit)} vs "
                                          f"{cell(*stats(d[p]), unit)}  ({ratio:.2f}x)")
                if verdict == "UNRELIABLE":
                    pair_unrel[p].append(f"  {lbl}: velox {[round(x, 2) for x in sorted(d['velox'])]}"
                                         f"  {p} {[round(x, 2) for x in sorted(d[p])]}")
            else:
                vs += f"{'—':>24}"
        print(f"{lbl + (' †' if (s_, t, m) in superseded else ''):34}{cells}{vs}")
    if matrix:
        order = [e for e in cols if e in engines]
        print(f"\n{'Functional probe':34}" + "".join(f"{e:>14}" for e in order))
        print("-" * (34 + 14 * len(order)))
        for probe in sorted(matrix):
            print(f"{probe:34}" + "".join(f"{matrix[probe].get(e, '—'):>14}" for e in order))
    for p in peers:
        if pair_trails[p]:
            print(f"\nTRAILS (Velox behind {NAMES.get(p, p)}):\n" + "\n".join(pair_trails[p]))
        if pair_unrel[p]:
            print(f"\nUNRELIABLE vs {NAMES.get(p, p)} (spread too wide to call — raw values):\n"
                  + "\n".join(pair_unrel[p]))
    xc = [(lbl, vals.get((s_, t, m), {})) for s_, t, m, lbl in XCHECK]
    if any(d for _, d in xc):
        print("\nCROSS-CHECK (whole-system memory, not attributed to processes; no verdict):")
        for lbl, d in xc:
            if d:
                print(f"  {lbl}: " + "  ".join(f"{e} {d.get(e, [])}" for e in cols))
    if slept:
        print(f"\nDISCARDED (system slept during the suite): {sorted(slept)}")
    if superseded:
        print("\n† re-measured after the campaign (--supersede); replaces the campaign's rows")
    sys.exit(0)

print(f"{'Metric':34}{'Velox':>26}{PNAME:>26}{'Δ':>9}  Verdict")
print("-" * 104)

trails, unreliable, missing = [], [], []
verdicts = {}

for s, t, m, (lbl, hb, unit) in SPEC:
    d = vals.get((s, t, m), {})
    na = nas.get((s, t, m), {})
    v_xs, d_xs = d.get("velox", []), d.get(PEER, [])
    if not v_xs and not d_xs:
        print(f"{lbl:34}{'—':>26}{'—':>26}{'':>9}  not measured")
        missing.append(lbl)
        continue
    if not v_xs or not d_xs:
        only = "velox" if v_xs else PEER
        med, iqr, n = stats(v_xs or d_xs)
        left = cell(med, iqr, n, unit) if v_xs else "—"
        right = cell(med, iqr, n, unit) if d_xs else "—"
        print(f"{lbl:34}{left:>26}{right:>26}{'':>9}  {only} only")
        continue

    vm, vi, vn = stats(v_xs)
    dm, di, dn = stats(d_xs)
    zero = zero_verdict(vm, dm, hb)
    if zero:
        verdicts[lbl] = zero
        print(f"{lbl:34}{cell(vm, vi, vn, unit):>26}{cell(dm, di, dn, unit):>26}{'∞' if zero[0] == 'WIN' else '0':>8}x  {zero[0]}")
        continue
    if vm <= 0 or dm <= 0:
        # A ratio of non-positive values is meaningless (e.g. "retained" going negative because
        # the baseline itself held untrimmed blocks) — show the numbers, claim nothing.
        print(f"{lbl:34}{cell(vm, vi, vn, unit):>26}{cell(dm, di, dn, unit):>26}{'':>9}  no ratio (≤0)")
        continue
    ratio = (vm / dm if dm else 0) if hb else (dm / vm if vm else 0)   # >1 ⇒ Velox better

    # Noise gate first: a metric whose own spread swamps the delta gets no verdict at all.
    v_rel = vi / vm if vm else 0
    d_rel = di / dm if dm else 0
    if v_rel > 0.25 or d_rel > 0.25:
        verdict = "UNRELIABLE"
        unreliable.append((lbl, sorted(v_xs), sorted(d_xs)))
    else:
        # Overlapping IQRs mean the two distributions are not separated, whatever the
        # medians say — call that par rather than manufacture a win from noise.
        v_lo, v_hi = vm - vi / 2, vm + vi / 2
        d_lo, d_hi = dm - di / 2, dm + di / 2
        overlap = not (v_hi < d_lo or d_hi < v_lo)
        if overlap:
            verdict = "par"
        elif ratio >= 1.15:
            verdict = "WIN"
        elif ratio <= 0.87:
            verdict = "TRAIL"
            trails.append((lbl, cell(vm, vi, vn, unit), cell(dm, di, dn, unit), ratio))
        else:
            verdict = "par"

    verdicts[lbl] = (verdict, ratio)
    flag = ""
    if na.get("velox") or na.get(PEER):
        flag = f"  (!{na.get('velox', 0)}v/{na.get(PEER, 0)}p failed)"
    print(f"{lbl:34}{cell(vm, vi, vn, unit):>26}{cell(dm, di, dn, unit):>26}{ratio:>8.2f}x  {verdict}{flag}")

if matrix:
    order = [e for e in ("velox", PEER) if e in engines]
    print(f"\n{'Functional probe':34}" + "".join(f"{e:>14}" for e in order))
    print("-" * (34 + 14 * len(order)))
    for probe in sorted(matrix):
        print(f"{probe:34}" + "".join(f"{matrix[probe].get(e, '—'):>14}" for e in order))

if trails:
    print(f"\nTRAILS (Velox behind {PNAME}):")
    for lbl, v, d, r in trails:
        print(f"  {lbl}: {v} vs {d}  ({r:.2f}x)")

if unreliable:
    print("\nUNRELIABLE (spread too wide to call — raw values):")
    for lbl, v, d in unreliable:
        print(f"  {lbl}\n    velox: {[round(x, 2) for x in v]}\n    {PEER}: {[round(x, 2) for x in d]}")

xc = [(lbl, vals.get((s, t, m), {})) for s, t, m, lbl in XCHECK]
if any(d for _, d in xc):
    print("\nCROSS-CHECK (whole-system memory, not attributed to processes; no verdict):")
    for lbl, d in xc:
        if d:
            print(f"  {lbl}: velox {d.get('velox', [])}  {PEER} {d.get(PEER, [])}")

# A memory claim needs RSS and phys_footprint to point the same way.
split = []
for a, b in MEMPAIRS:
    if a in verdicts and b in verdicts:
        (va, ra), (vb, rb) = verdicts[a], verdicts[b]
        if va in ("WIN", "TRAIL", "par") and vb in ("WIN", "TRAIL", "par") and va != vb:
            split.append(f"  {a}: RSS says {va} ({ra:.2f}x), footprint says {vb} ({rb:.2f}x)")
if split:
    print("\nMEMORY — depends on accounting (no claim either way):")
    print("\n".join(split))

if slept:
    print(f"\nDISCARDED (system slept during the suite): {sorted(slept)}")

if missing:
    print(f"\nNOT MEASURED: {', '.join(missing)}")
