#!/usr/bin/env python3
"""Print a Velox-vs-DD scorecard from results.csv (engine,suite,test,metric,unit,value)."""
import csv, os
CSV = os.path.join(os.path.dirname(__file__), "results.csv")

# (suite, test, metric): (label, higher_is_better, unit)
SPEC = [
    ("disk", "installed_footprint", "size",        ("Installed footprint", False, "MB")),
    ("mem", "idle_footprint", "host_rss",          ("Idle RAM (host RSS, all procs)", False, "MB")),
    ("lifecycle", "restart_to_ready", "time_s",    ("Startup: restart→API-ready", False, "s")),
    ("launch", "run_true", "median_s",             ("Container launch (run true)", False, "s")),
    ("launch", "churn30_per", "per_s",             ("Sequential churn (per container)", False, "s")),
    ("launch", "parallel20_total", "total_s",      ("Parallel launch x20 (total)", False, "s")),
    ("net", "c2host", "gbits",                      ("Network: container→host", True, "Gbps")),
    ("net", "pubport_h2c_p1", "gbits",             ("Net: published port (1 stream)", True, "Gbps")),
    ("net", "pubport_h2c_p4", "gbits",             ("Net: published port (4 streams)", True, "Gbps")),
    ("fs", "bind_write", "mbps",                    ("FS: VirtioFS bind write", True, "MB/s")),
    ("fs", "bind_read", "mbps",                     ("FS: VirtioFS bind read", True, "MB/s")),
    ("fs", "smallfiles_bind", "extract_s",          ("FS: extract 4000 files (bind)", False, "s")),
    ("fs", "vol_write", "mbps",                     ("FS: named-volume write (in-VM)", True, "MB/s")),
    ("fs", "overlay_write", "mbps",                 ("FS: container-overlay write", True, "MB/s")),
    ("pull", "cold_image", "total_s",               ("Cold image pull", False, "s")),
    ("realworld", "pgbench_init", "load_s",         ("pgbench init (scale 50)", False, "s")),
    ("realworld", "pgbench_tps", "tps",             ("pgbench TPS (8 clients, 30s)", True, "TPS")),
]

rows = {}
with open(CSV) as f:
    for r in csv.DictReader(f):
        rows.setdefault((r["suite"], r["test"], r["metric"]), {})[r["engine"]] = r["value"]

def fmt(v):
    try:
        x = float(v); return f"{x:,.0f}" if x >= 100 else f"{x:.2f}"
    except ValueError:
        return v

print(f"{'Metric':34}{'Velox':>14}{'Docker Desktop':>16}{'Δ':>9}  Verdict")
print("-" * 88)
for s, t, m, (lbl, hb, unit) in SPEC:
    d = rows.get((s, t, m))
    if not d or "velox" not in d or "dd" not in d:
        continue
    v, dd = float(d["velox"]), float(d["dd"])
    ratio = (v / dd if dd else 0) if hb else (dd / v if v else 0)  # >1 ⇒ Velox better
    verdict = "WIN" if ratio >= 1.15 else ("TRAIL" if ratio <= 0.87 else "par")
    print(f"{lbl:34}{fmt(d['velox'])+' '+unit:>14}{fmt(d['dd'])+' '+unit:>16}{ratio:>8.2f}x  {verdict}")
