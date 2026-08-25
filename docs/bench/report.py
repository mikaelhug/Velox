#!/usr/bin/env python3
"""Print a Velox-vs-DD scorecard from results.csv.

Aggregates ALL rows per metric (median + IQR + n) rather than showing the last one.
The old last-write-wins behaviour published whichever single run happened to be written
last, on a workload whose measured intra-metric spread reached 102% — container→host
throughput alone ranged 36.7–96.8 Gbit/s across identical runs. A number that noisy is
not a result, and the UNRELIABLE verdict below says so out loud instead of picking a
flattering sample.
"""
import csv, os, statistics, sys, collections

CSV = os.path.join(os.path.dirname(__file__), "results.csv")

# (suite, test, metric): (label, higher_is_better, unit)
SPEC = [
    ("disk", "installed_footprint", "size",        ("Installed footprint (shipped)", False, "MB")),
    ("disk", "atrest_footprint", "size",           ("On-disk at rest (incl. VM data)", False, "MB")),
    ("mem", "idle_footprint", "host_rss",          ("Idle RAM (host RSS, all procs)", False, "MB")),
    ("idle", "rss_active", "host_rss",             ("Idle RAM, pre-saver", False, "MB")),
    ("idle", "rss_saver", "host_rss",              ("Idle RAM, after resource saver", False, "MB")),
    ("idle", "cpu", "pct",                          ("Idle CPU (4 min, whole engine)", False, "%")),
    ("idle", "cpu_saver", "pct",                    ("Idle CPU, after resource saver", False, "%")),
    ("mem", "loaded", "host_rss",                   ("RAM under load (21 containers)", False, "MB")),
    ("mem", "postload", "host_rss",                 ("RAM after teardown (return)", False, "MB")),
    ("lifecycle", "restart_to_ready", "time_s",    ("Startup: restart→API-ready", False, "s")),
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

vals = collections.defaultdict(lambda: collections.defaultdict(list))
nas = collections.defaultdict(lambda: collections.defaultdict(int))
matrix = collections.defaultdict(dict)
engines = set()

with open(CSV) as f:
    for r in csv.DictReader(f):
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


print(f"{'Metric':34}{'Velox':>26}{'Docker Desktop':>26}{'Δ':>9}  Verdict")
print("-" * 104)

trails, unreliable, missing = [], [], []

for s, t, m, (lbl, hb, unit) in SPEC:
    d = vals.get((s, t, m), {})
    na = nas.get((s, t, m), {})
    v_xs, d_xs = d.get("velox", []), d.get("dd", [])
    if not v_xs and not d_xs:
        print(f"{lbl:34}{'—':>26}{'—':>26}{'':>9}  not measured")
        missing.append(lbl)
        continue
    if not v_xs or not d_xs:
        only = "velox" if v_xs else "dd"
        med, iqr, n = stats(v_xs or d_xs)
        left = cell(med, iqr, n, unit) if v_xs else "—"
        right = cell(med, iqr, n, unit) if d_xs else "—"
        print(f"{lbl:34}{left:>26}{right:>26}{'':>9}  {only} only")
        continue

    vm, vi, vn = stats(v_xs)
    dm, di, dn = stats(d_xs)
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

    flag = ""
    if na.get("velox") or na.get("dd"):
        flag = f"  (!{na.get('velox', 0)}v/{na.get('dd', 0)}d failed)"
    print(f"{lbl:34}{cell(vm, vi, vn, unit):>26}{cell(dm, di, dn, unit):>26}{ratio:>8.2f}x  {verdict}{flag}")

if matrix:
    order = [e for e in ("velox", "dd") if e in engines]
    print(f"\n{'Functional probe':34}" + "".join(f"{e:>14}" for e in order))
    print("-" * (34 + 14 * len(order)))
    for probe in sorted(matrix):
        print(f"{probe:34}" + "".join(f"{matrix[probe].get(e, '—'):>14}" for e in order))

if trails:
    print("\nTRAILS (Velox behind Docker Desktop):")
    for lbl, v, d, r in trails:
        print(f"  {lbl}: {v} vs {d}  ({r:.2f}x)")

if unreliable:
    print("\nUNRELIABLE (spread too wide to call — raw values):")
    for lbl, v, d in unreliable:
        print(f"  {lbl}\n    velox: {[round(x, 2) for x in v]}\n    dd:    {[round(x, 2) for x in d]}")

if missing:
    print(f"\nNOT MEASURED: {', '.join(missing)}")
