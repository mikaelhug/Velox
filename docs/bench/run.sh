#!/usr/bin/env bash
#
# Velox vs a peer engine (Docker Desktop or OrbStack) — benchmark harness.
#
# Selects each engine by its Docker *context* (no wrapper, no daemon swap) and runs the
# same suite against both, ONE ENGINE RESIDENT AT A TIME. Velox is always engine A; the peer
# is chosen with BENCH_PEER=dd (default) or BENCH_PEER=orbstack. Results are appended to
# results.csv (dd) or results-orbstack.csv (orbstack); ./report.py prints the scorecard.
#
# TWO CADENCES — pick the right one:
#
#   ./run.sh all        QUICK (~12 min).  One round per engine, no engine bouncing.
#                       This is the pre-release regression check (CLAUDE.md): run it
#                       before a human-cut release or a datapath/kernel/disk/engine
#                       change and compare against docs/benchmarks.md. Single-shot, so
#                       treat a delta smaller than the spreads in the report as noise.
#                       Writes to runs/<id>/quick.csv, never to the published CSVs.
#
#   ./run.sh campaign   FULL (~4 h).  The publishable head-to-head: order-balanced
#                       n=6 rounds, idle/CPU windows, RAM-under-load, disk reclaim and
#                       the functional matrix. Bounces both apps repeatedly and needs
#                       the Mac to itself. This is ANNUAL (or when a new peer major
#                       lands / before a claim goes on the website) — NOT per
#                       commit and not per release. Output is a dated report next to
#                       this script (REPORT-<date>.md for DD, REPORT-<date>-orbstack.md);
#                       see "Running the annual comparison" in ../benchmarks.md for the
#                       preconditions that make it fair.
#
# Usage:
#   BENCH_PEER=orbstack ./run.sh campaign   # the full order-balanced comparison
#   ./run.sh preflight [ctx]      # fairness gate: AC power, quiet host, disk, deps
#   ./run.sh parity               # configured vCPU/RAM of both apps match (aborts if not)
#   ./run.sh engine <velox|peer>  # quit the other engine, boot this one, settle
#   ./run.sh suite <ctx> <label>  # the timed suite against one context
#   ./run.sh idle <ctx> <label>   # idle CPU/RAM + resource-saver reclaim depth
#   ./run.sh loadram <ctx> <lbl>  # RAM under load, then return after teardown
#   ./run.sh reclaim <ctx> <lbl>  # disk growth vs reclaim after rmi/volume rm
#   ./run.sh matrix <ctx> <lbl>   # functional pass/fail probes (untimed, network allowed)
#   ./run.sh footprint            # installed on-disk footprint of both engines
#   ./run.sh startup              # restart-to-ready timing (bounces both apps)
#   ./run.sh report               # scorecard
#
# Requirements: Velox.app (its bundled docker/compose/buildx drive BOTH engines), python3,
# jq, iperf3, hyperfine, nc, curl, Xcode (one 2-line Swift probe for the thermal gate).
#   brew install jq iperf3 hyperfine
#
# ---- METHOD NOTES (why this harness looks the way it does) --------------------
# Every rule below was bought with a wrong number. Do not remove one without reading
# the comment at its implementation site.
#   * ONE engine resident at a time — Docker Desktop's daemon proved unstable when
#     co-resident, and two 8 GiB VMs on a 24 GB host is memory pressure, not a benchmark.
#   * ORDER-BALANCED rounds — the old harness always measured Velox first, so every
#     host warm-up effect was a systematic gift to Velox.
#   * n>=5 with median+IQR — single-shot numbers on this workload are worthless:
#     container→host throughput measured 36.7 and 96.8 Gbit/s on identical code.
#   * NA, never 0 — a failed measurement used to be recorded as 0 by `jq // 0` and
#     published as a catastrophic loss for whichever engine hiccuped.
#   * NOTHING network-dependent on a timed path. The cold `docker pull` metric was
#     deleted for this reason (same 381 MB image: 4.1 s and 20.0 s, forty minutes apart).
#   * QUIET-HOST GATES, not long sleeps — after every engine stop/start and between heavy
#     test groups, wait until CPU is idle, memory pressure normal and the Mac thermally
#     nominal (host_quiet / engine_quiet). The old thermal check never fired on Apple Silicon.
#   * ONE client toolchain — Velox's bundled docker/compose/buildx from a private
#     DOCKER_CONFIG, so neither app's CLI or plugin re-linking can make the sides differ.
# ------------------------------------------------------------------------------
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

# ---- config: Velox is always engine A; BENCH_PEER picks engine B -------------
# BENCH_PEER=dd (default) or orbstack. Each peer gets its own CSV so one comparison can
# never overwrite or mix with the other's evidence.
BENCH_PEER="${BENCH_PEER:-dd}"
CTX_A="velox";          LBL_A="velox";  APP_A="Velox"
case "$BENCH_PEER" in
  dd)       CTX_B="desktop-linux"; LBL_B="dd";       APP_B="Docker";   CSV_DEFAULT="$HERE/results.csv" ;;
  orbstack) CTX_B="orbstack";      LBL_B="orbstack"; APP_B="OrbStack"; CSV_DEFAULT="$HERE/results-orbstack.csv" ;;
  *) echo "BENCH_PEER must be dd or orbstack (got: $BENCH_PEER)" >&2; exit 2 ;;
esac
CSV="${BENCH_CSV:-$CSV_DEFAULT}"         # BENCH_CSV: write elsewhere while smoke-testing
# results.csv predates BENCH_PEER and keeps its old `dd_ver` header; the column is the peer's.
CSV_HEADER="engine,suite,test,metric,unit,value,ts,run_id,round,velox_ver,peer_ver"
OSG="$HOME/Library/Group Containers/HUAQ24HBR6.dev.orbstack"   # OrbStack's data (data.img.raw, swap.img)
VELOX_BIN="/Applications/Velox.app/Contents/Resources/bin"
IMG_ALPINE="alpine:3.20"
IMG_IPERF="networkstatic/iperf3:latest"
IMG_LOAD="python:3.12"      # extraction fixture: saved to a tar once, then re-loaded
IMG_PG="postgres:16"
DD_MB=1024                  # dd write/read size, MiB
SF_COUNT=4000               # small-files count
CP_MB=1024                  # docker cp payload, MiB
CTX_MB=512                  # build-context payload, MiB
# ------------------------------------------------------------------------------

RUN_ID="${RUN_ID:-$(date +%Y%m%d-%H%M%S)}"
ROUND="${ROUND:-0}"
RUNDIR="$HERE/runs/$RUN_ID"
BENCH_SETS="${BENCH_SETS:-core}"     # comma list: core,build,compose,rosetta

now(){ python3 -c 'import time;print(time.time())'; }
log(){ echo ">>> $*" >&2; }
warn(){ echo "!!! $*" >&2; }
fail(){ echo "XXX $*" >&2; return 1; }

VELOX_VER=""; PEER_VER=""
versions(){
  [ -n "$VELOX_VER" ] && return 0
  VELOX_VER=$(defaults read /Applications/Velox.app/Contents/Info.plist CFBundleShortVersionString 2>/dev/null || echo unknown)
  case "$LBL_B" in
    dd)       PEER_VER=$(jq -r '.appVersion' /Applications/Docker.app/Contents/Resources/componentsVersion.json 2>/dev/null || echo unknown) ;;
    orbstack) PEER_VER=$(defaults read /Applications/OrbStack.app/Contents/Info.plist CFBundleShortVersionString 2>/dev/null || echo unknown) ;;
  esac
}

# eng,suite,test,metric,unit,value + provenance. Provenance exists because results.csv
# used to be an undated pile in which a June baseline and an August re-run were
# indistinguishable, and the published scorecard silently mixed them.
# ROUND_TAG marks rows written after a resume, so a resumed round can never share a key with a
# discarded attempt of the same round (report.py drops discarded attempts by engine+run+round).
rec(){ versions; echo "$1,$2,$3,$4,$5,$6,$(now),$RUN_ID,$ROUND${ROUND_TAG:-},$VELOX_VER,$PEER_VER" >> "$CSV"; }

# ONE client toolchain for both engines. Each app installs its own docker CLI and re-links
# ~/.docker/cli-plugins to its own compose/buildx (OrbStack did exactly that on install), so
# "same CLI, same compose" silently stopped being true. The harness therefore runs Velox's
# bundled docker + compose + buildx against both sockets from a private DOCKER_CONFIG that
# neither app touches.
setup_client(){
  [ -x "$VELOX_BIN/docker" ] || { echo "missing $VELOX_BIN/docker" >&2; exit 2; }
  export PATH="$VELOX_BIN:$PATH"
  export DOCKER_CONFIG="$HERE/runs/.docker-config"
  mkdir -p "$DOCKER_CONFIG/cli-plugins"
  [ -f "$DOCKER_CONFIG/config.json" ] || echo '{}' > "$DOCKER_CONFIG/config.json"
  ln -sf "$VELOX_BIN/docker-compose" "$VELOX_BIN/docker-buildx" "$DOCKER_CONFIG/cli-plugins/"
  local c s
  for c in "$CTX_A" "$CTX_B"; do
    case "$c" in
      velox)         s="$HOME/.velox/docker.sock" ;;
      orbstack)      s="$HOME/.orbstack/run/docker.sock" ;;
      desktop-linux) s="$HOME/.docker/run/docker.sock" ;;
    esac
    docker context inspect "$c" >/dev/null 2>&1 || docker context create "$c" --docker "host=unix://$s" >/dev/null
  done
}
ensure_csv(){ mkdir -p "$RUNDIR"; [ -f "$CSV" ] || echo "$CSV_HEADER" > "$CSV"; }

# rate: MiB / elapsed → MB/s, or NA when the timed command failed.
rate(){ python3 -c "
import sys
mb,t0,t1,ok=float(sys.argv[1]),float(sys.argv[2]),float(sys.argv[3]),sys.argv[4]
print('NA' if ok!='0' or t1<=t0 else round(mb/(t1-t0),1))" "$1" "$2" "$3" "$4"; }
secs(){ python3 -c "
import sys
t0,t1,ok=float(sys.argv[1]),float(sys.argv[2]),sys.argv[3]
print('NA' if ok!='0' or t1<t0 else round(t1-t0,3))" "$1" "$2" "$3"; }

# Sleep detector. Every timed metric is wall-clock, so a system sleep inside a measurement
# silently inflates it by the sleep duration — the 2026-08-24 run recorded a 945 s
# `docker load` this way and the scorecard published it. `sleep_count` returns the timestamp
# of the most recent Sleep/Wake/DarkWake event; a suite during which it moved is discarded.
# It used to COUNT "Wake from" lines, but `pmset -g log` is a rolling window: when old entries
# age out the count drops with no sleep at all, and the 2026-10-09 run discarded two complete,
# valid Velox suites that way (the log's last real wake was the previous day).
sleep_count(){ pmset -g log 2>/dev/null | awk '$4=="Sleep"||$4=="Wake"||$4=="DarkWake"{t=$1" "$2} END{print t}'; }
assert_awake(){                      # $1 baseline count, $2 label — nonzero if we slept
  local n; n=$(sleep_count)
  if [ "${n:-0}" != "${1:-0}" ]; then warn "[$2] SYSTEM SLEPT during this measurement — results discarded"; return 1; fi
  return 0
}

sum_rss(){ local t=0 r; for p in "$@"; do r=$(ps -o rss= -p "$p" 2>/dev/null|tr -d ' '); [ -n "$r" ]&&t=$((t+r)); done; echo $((t/1024)); }
# Cumulative CPU seconds across a process set. `ps -o %cpu` is a lifetime average, which
# reports a busy boot forever and would make an idle engine look permanently hot; sampling
# cputime twice and dividing by the wall gap is the only honest unprivileged %CPU.
sum_cputime(){ local out=0 c; for p in "$@"; do c=$(ps -o cputime= -p "$p" 2>/dev/null|tr -d ' '); [ -n "$c" ] && out=$(python3 -c "
import sys
p=sys.argv[1].split(':'); s=float(p[-1])
if len(p)>1: s+=int(p[-2])*60
if len(p)>2: s+=int(p[-3])*3600
print(round(float(sys.argv[2])+s,2))" "$c" "$out"); done; echo "$out"; }

# Tiny compiled probes (Swift, built once into runs/): see thermal_state and sum_footprint.
probe_bin(){                         # $1 name  $2 swift source → path of the built binary
  local b="$HERE/runs/.$1"
  if [ ! -x "$b" ]; then
    mkdir -p "$HERE/runs"; printf '%s\n' "$2" > "$b.swift"
    xcrun swiftc -O "$b.swift" -o "$b" >/dev/null 2>&1 || { rm -f "$b"; return 1; }
  fi
  echo "$b"
}
# phys_footprint, from the kernel's own ledger (proc_pid_rusage → ri_phys_footprint): exactly
# what Activity Monitor's Memory column and top's MEM show, and what macOS charges against
# memory pressure. RSS alone over- or under-states a VM process depending on how its VMM maps
# guest RAM, so both are recorded.
# NOT footprint(1): it sums memory *regions* and does not see OrbStack's guest RAM at all —
# it reported 106 MB for the OrbStack Helper while the kernel ledger, top and RSS all said
# ~1,307 MB. Publishing that would have flattered OrbStack more than tenfold.
# Root-owned helpers can't be read unprivileged; those fall back to their RSS.
MEMPROBE_SRC='import Darwin
for a in CommandLine.arguments.dropFirst() {
    guard let pid = Int32(a) else { continue }
    var info = rusage_info_v4()
    let r = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
    }
    print(r == 0 ? String(info.ri_phys_footprint / 1048576) : "NA")
}'
sum_footprint(){ local t=0 p f mp; mp=$(probe_bin memprobe "$MEMPROBE_SRC") || { echo NA; return; }
  for p in "$@"; do
    f=$("$mp" "$p" 2>/dev/null)
    case "$f" in ''|NA) f=$(ps -o rss= -p "$p" 2>/dev/null|tr -d ' '); f=$(( ${f:-0} / 1024 )) ;; esac
    t=$((t + f)); done; echo "$t"; }
# System-wide anonymous + wired + compressor memory, MB. Not attributed to any process, so it
# catches memory neither process list sees (e.g. kernel-side hypervisor allocations). Used
# only as a delta against the no-engine baseline taken at every engine switch — a cross-check.
sysmem_mb(){ vm_stat | awk -F: '/page size of/{gsub(/[^0-9]/,"",$0); ps=$0}
  /^Anonymous pages/||/^Pages wired down/||/^Pages occupied by compressor/{gsub(/[ .]/,"",$2); s+=$2}
  END{printf "%d", s*ps/1048576}'; }
sysmem_base(){ cat "$RUNDIR/sysmem-baseline" 2>/dev/null || echo NA; }
sysmem_delta(){ local b; b=$(sysmem_base); [ "$b" = NA ] && echo NA || echo $(( $(sysmem_mb) - b )); }

# Full process set, INCLUDING each engine's persistent privileged LaunchDaemon
# (com.docker.vmnetd / dev.velox.porthelper / dev.orbstack.OrbStack.privhelper). Those daemons
# are a real cost of running the engine, so they belong in every RSS number.
engine_pids(){                       # $1 label → pid list on stdout
  local helper
  case "$1" in
    velox)    helper='dev.velox.porthelper' ;;
    dd)       helper='com.docker.vmnetd' ;;
    orbstack) helper='dev.orbstack.OrbStack.privhelper' ;;
  esac
  { engine_live_pids "$1"; pgrep -f "$helper"; } | sort -u | tr '\n' ' '
}
# Process set that actually goes away when the engine stops. The privileged helpers above
# are LaunchDaemons that outlive the app by design, so waiting for them to exit — as an
# earlier version of this function did — could never succeed and burned 60 s per switch
# while printing a false "still alive" warning.
# OrbStack runs its own VMM inside "OrbStack Helper" (no Virtualization.framework XPC
# process, verified with ps + lsof), so its whole tree lives under the app bundle.
engine_live_pids(){                  # $1 label → pid list on stdout
  case "$1" in
    velox)
      { lsof -t "$HOME/.velox/data.img" 2>/dev/null|head -1
        pgrep -f 'Velox.app/Contents/MacOS/VeloxApp'; } | sort -u | tr '\n' ' ' ;;
    dd)
      { lsof -t "$HOME/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw" 2>/dev/null|head -1
        pgrep -f 'Docker.app/Contents/MacOS|com.docker.backend|com.docker.virtualization|com.docker.build'; } | sort -u | tr '\n' ' ' ;;
    orbstack)
      pgrep -f 'OrbStack.app/Contents/' | sort -u | tr '\n' ' ' ;;
  esac
}
disk_image(){
  case "$1" in
    velox)    echo "$HOME/.velox/data.img" ;;
    dd)       echo "$HOME/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw" ;;
    orbstack) echo "$OSG/data/data.img.raw" ;;
  esac
}
# Allocated MB of a path, or NA. A failed `du` used to become 0 via ${x:-0} — and OrbStack's
# Group Container is TCC-protected, so its disk would have been published as 0 MB.
dum(){ local v; v=$(du -sm "$1" 2>/dev/null | awk '{print $1}'); echo "${v:-NA}"; }
addmb(){ python3 -c "
import sys
a=sys.argv[1:]; print('NA' if 'NA' in a or not a else sum(int(x) for x in a))" "$@"; }
submb(){ python3 -c "
import sys
a,b=sys.argv[1],sys.argv[2]; print('NA' if 'NA' in (a,b) else int(a)-int(b))" "$1" "$2"; }

# ---- quiet-host gates (conditions, not long sleeps) ---------------------------
# `pmset -g therm` reports nothing at all on Apple Silicon, so the old CPU_Speed_Limit loop
# exited on its first pass and never gated anything. ProcessInfo.thermalState is the real
# signal (0 nominal, 1 fair, 2 serious, 3 critical).
thermal_state(){ local b
  b=$(probe_bin thermal 'import Foundation
print(ProcessInfo.processInfo.thermalState.rawValue)') || { echo NA; return; }
  "$b" 2>/dev/null || echo NA; }
# Find the field labelled "idle" by name. Splitting on [ %]+ and taking NF-1 landed on the
# literal word "idle" (the line has a trailing space), so int() made it 0 and the gate
# reported "0% idle" on a perfectly quiet machine — a fairness check that never fired.
host_idle(){ top -l 2 -n 0 -s 3 2>/dev/null | awk '/CPU usage/{for(j=1;j<=NF;j++) if($j=="idle"){gsub("%","",$(j-1)); v=$(j-1)}} END{print int(v)}'; }
# Wait until the host is back to baseline: CPU idle, no memory pressure, thermally nominal.
# The floor is a minimum, not the cost — once the conditions hold it returns. It never waits
# forever on an unattended run: after QUIET_MAX_S it records a quality flag (so the report can
# see which measurement started on a busy host) and carries on.
host_quiet(){                        # $1 floor seconds  $2 what we are waiting for
  local floor="${1:-10}" why="${2:-}" t0 idle th pr
  sync; sleep "$floor"; t0=$(date +%s)
  while :; do
    idle=$(host_idle); th=$(thermal_state); pr=$(sysctl -n kern.memorystatus_vm_pressure_level 2>/dev/null)
    if [ "${idle:-0}" -ge "${QUIET_IDLE:-90}" ] && { [ "$th" = 0 ] || [ "$th" = NA ]; } && [ "${pr:-1}" = 1 ]; then
      return 0; fi
    if [ $(( $(date +%s) - t0 )) -ge "${QUIET_MAX_S:-1200}" ]; then
      warn "host never went quiet ($why): idle=${idle}% thermal=$th pressure=$pr — flagged, continuing"
      rec host quality not_quiet flag n 1; return 0; fi
    log "waiting for a quiet host ($why): idle=${idle}% thermal=$th pressure=$pr"
    sleep 5
  done
}
# After boot, wait until the engine's own process tree stops working (DHCP, image-store warmup,
# Velox's boot fstrim at t+60 s, whatever the peer does after boot) instead of guessing a sleep.
engine_quiet(){                      # $1 label
  local i pids w0 w1 c0 c1 pct
  for i in $(seq 1 60); do
    pids="$(engine_pids "$1")"; w0=$(now); c0=$(sum_cputime $pids); sleep 10; w1=$(now); c1=$(sum_cputime $pids)
    pct=$(python3 -c "print(int(($c1-$c0)/($w1-$w0)*100))")
    [ "$pct" -lt "${ENGINE_QUIET_PCT:-5}" ] && { log "[$1] engine quiet (${pct}% CPU)"; return 0; }
    log "[$1] engine still busy (${pct}% CPU over 10 s) — waiting"
  done
  warn "[$1] engine never went quiet after boot"; rec "$1" quality engine_not_quiet flag n 1
}
has_set(){ case ",$BENCH_SETS," in *",$1,"*) return 0;; esac; return 1; }

# ---- fairness gate -----------------------------------------------------------
preflight(){                         # $1 optional context to assert is container-free
  local bad=0 t
  for t in jq iperf3 hyperfine python3 nc curl docker; do
    command -v "$t" >/dev/null || { warn "missing dependency: $t"; bad=1; }
  done
  # Battery is a BLOCKING condition, not a warning. The 2026-08-24 run degraded to battery
  # mid-campaign and macOS then slept the machine repeatedly; wall-clock timings that span a
  # sleep are meaningless (`docker load` "took" 945 s instead of 7 s). Wait for AC rather
  # than record fiction.
  for t in $(seq 1 120); do
    pmset -g batt 2>/dev/null | grep -q "AC Power" && break
    log "on battery — plug in to continue ($t/120)"; sleep 30
  done
  pmset -g batt 2>/dev/null | grep -q "AC Power" || { warn "still on battery after 60 min"; bad=1; }
  # Thermal throttling silently halves throughput, and a busy host steals from whichever
  # engine is measured: WAIT for both to clear (host_quiet) rather than fail once and carry on.
  host_quiet 0 "preflight"
  local idle; idle=$(host_idle)
  local freeg; freeg=$(df -g / | awk 'NR==2{print $4}')
  # The heaviest step (reclaim: 4 GiB volume + image load) needs well under 15 GB.
  [ "${freeg:-0}" -lt "${MIN_FREE_GB:-25}" ] && { warn "only ${freeg}GB free on / (need ${MIN_FREE_GB:-25})"; bad=1; }
  tmutil status 2>/dev/null | grep -q "Running = 1" && warn "Time Machine backup running"
  if [ $# -ge 1 ] && [ -n "$1" ]; then
    local running; running=$(docker --context "$1" ps -q 2>/dev/null | wc -l | tr -d ' ')
    [ "${running:-0}" != "0" ] && { warn "$running container(s) already running on $1"; bad=1; }
  fi
  [ "$bad" = "0" ] && log "preflight OK (${idle:-?}% idle, ${freeg}GB free, AC, cool)"
  return "$bad"
}

capture_env(){                       # one snapshot per campaign, for the report appendix
  mkdir -p "$RUNDIR"
  { sw_vers; echo; sysctl -n hw.model hw.ncpu hw.memsize; echo; uname -v; } > "$RUNDIR/host.txt" 2>&1
  cp "$HOME/.velox/config.json" "$RUNDIR/velox-config.json" 2>/dev/null
  cp "$HOME/.velox/workspaces.json" "$RUNDIR/velox-workspaces.json" 2>/dev/null
  case "$LBL_B" in
    dd)
      cp "$HOME/Library/Group Containers/group.com.docker/settings-store.json" "$RUNDIR/dd-settings-store.json" 2>/dev/null
      cp /Applications/Docker.app/Contents/Resources/componentsVersion.json "$RUNDIR/dd-components.json" 2>/dev/null ;;
    orbstack)
      cp "$HOME/.orbstack/vmconfig.json" "$RUNDIR/orbstack-vmconfig.json" 2>/dev/null
      cp "$HOME/.orbstack/config/docker.json" "$RUNDIR/orbstack-docker.json" 2>/dev/null
      "$HOME/.orbstack/bin/orb" config show > "$RUNDIR/orbstack-config.txt" 2>&1 ;;
  esac
  cp "$HERE/../../versions.env" "$RUNDIR/velox-versions.env" 2>/dev/null
  { echo "PATH docker: $(command -v docker)"; docker version --format 'client {{.Client.Version}}' 2>/dev/null
    docker compose version; docker buildx version; echo "DOCKER_CONFIG=$DOCKER_CONFIG"
    ls -l "$DOCKER_CONFIG/cli-plugins"; } > "$RUNDIR/compose-binary.txt" 2>&1
  log "environment captured → $RUNDIR"
}

# Host-side resource parity from each app's own settings file — the in-guest check below can
# only see what the guest got, not what the user configured. A mismatch ABORTS.
config_parity(){
  local cpu="${EXPECT_CPU:-8}" mib="${EXPECT_MEM_MIB:-8192}" vc vm bc bm bad=0
  vc=$(jq -r '.cpuCount' "$HOME/.velox/config.json" 2>/dev/null); vm=$(jq -r '.memoryGiB*1024' "$HOME/.velox/config.json" 2>/dev/null)
  case "$LBL_B" in
    dd)       bc=$(jq -r '.Cpus // empty' "$HOME/Library/Group Containers/group.com.docker/settings-store.json" 2>/dev/null)
              bm=$(jq -r '.MemoryMiB // empty' "$HOME/Library/Group Containers/group.com.docker/settings-store.json" 2>/dev/null) ;;
    orbstack) bc=$(jq -r '.cpu' "$HOME/.orbstack/vmconfig.json" 2>/dev/null); bm=$(jq -r '.memory_mib' "$HOME/.orbstack/vmconfig.json" 2>/dev/null) ;;
  esac
  log "configured: velox ${vc} vCPU/${vm} MiB, $LBL_B ${bc:-?} vCPU/${bm:-?} MiB (expected $cpu/$mib)"
  [ "$vc" = "$cpu" ] && [ "$vm" = "$mib" ] || { warn "velox configuration is not ${cpu} vCPU / ${mib} MiB"; bad=1; }
  [ "${bc:-$cpu}" = "$cpu" ] && [ "${bm:-$mib}" = "$mib" ] || { warn "$LBL_B configuration is not ${cpu} vCPU / ${mib} MiB"; bad=1; }
  return "$bad"
}

capture_info(){                      # $1 ctx $2 label — engine identity + resource parity
  docker --context "$1" info --format '{{json .}}' > "$RUNDIR/info-$2.json" 2>&1
  docker --context "$1" version --format '{{json .}}' > "$RUNDIR/version-$2.json" 2>&1
  local n mem
  n=$(docker --context "$1" run --rm "$IMG_ALPINE" nproc 2>/dev/null)
  mem=$(docker --context "$1" run --rm "$IMG_ALPINE" sh -c "free -m | awk '/Mem:/{print \$2}'" 2>/dev/null)
  echo "nproc=$n mem_mb=$mem" > "$RUNDIR/alloc-$2.txt"
  rec "$2" env vcpu count n "${n:-NA}"
  rec "$2" env memory total_mb MB "${mem:-NA}"
  log "[$2] allocation: ${n:-?} vCPU, ${mem:-?} MB RAM"
  # Resource parity is the whole basis of the comparison — refuse to measure a mismatch.
  # (This used to only warn, while benchmarks.md promised an abort.)
  [ -n "$n" ] && [ -n "$mem" ] || { warn "[$2] could not read in-guest allocation"; return 1; }
  [ "$n" = "${EXPECT_CPU:-8}" ] || { warn "[$2] vCPU $n != expected ${EXPECT_CPU:-8} — refusing to measure"; return 1; }
  python3 -c "import sys; sys.exit(0 if 7000 <= float(sys.argv[1]) <= 8400 else 1)" "$mem" \
    || { warn "[$2] RAM ${mem}MB outside the 7000–8400 parity window — refusing to measure"; return 1; }
}

# ---- engine switching --------------------------------------------------------
api_up(){ docker --context "$1" version --format '{{.Server.Version}}' >/dev/null 2>&1; }

# Docker Desktop ignores `osascript quit` for its backend — the GUI wrapper exits while
# com.docker.backend and the VM keep running, so the "other" engine was never actually
# gone. `docker desktop stop` is DD's own supported control path; use it.
# Symmetric definition of "stopped" on both sides: engine down AND the GUI gone. Quitting
# Velox tears down its whole app; `docker desktop stop` alone leaves ~284 MB of Electron UI
# resident, which is background load charged to whichever engine is measured next — so the
# UI is quit explicitly too. (Its bundle name is "Docker Desktop", not "Docker".)
stop_engine(){                       # $1 label
  case "$1" in
    velox) osascript -e "quit app \"$APP_A\"" >/dev/null 2>&1 ;;
    dd)    # `docker desktop` is DD's own CLI plugin — reach it through the user's real config,
           # not the harness's private one (which deliberately carries only compose/buildx).
           DOCKER_CONFIG="$HOME/.docker" docker desktop stop >/dev/null 2>&1
           osascript -e 'quit app "Docker Desktop"' >/dev/null 2>&1 ;;
    orbstack)
           # Same symmetric definition: engine down AND the GUI gone. `orb` would launch the
           # app to talk to it, so only call it when OrbStack is actually running.
           [ -n "$(engine_live_pids orbstack | tr -d ' ')" ] && "$HOME/.orbstack/bin/orb" stop >/dev/null 2>&1
           osascript -e 'quit app "OrbStack"' >/dev/null 2>&1 ;;
  esac
}
# Symmetric "start": launch the application and let it bring its engine up, which is what a
# user does and what the restart_to_ready metric is supposed to represent on both sides.
start_engine(){ if [ "$1" = "$LBL_A" ]; then open -a "$APP_A"; else open -a "$APP_B"; fi; }

engine(){                            # $1 velox|<peer> — leave exactly this engine resident
  local want="$1" ctx other_lbl other_ctx
  if [ "$want" = "$LBL_A" ]; then ctx="$CTX_A"; other_lbl="$LBL_B"; other_ctx="$CTX_B"
  else ctx="$CTX_B"; other_lbl="$LBL_A"; other_ctx="$CTX_A"; fi

  log "engine switch → $want (stopping $other_lbl)"
  stop_engine "$other_lbl"
  local i
  for i in $(seq 1 120); do api_up "$other_ctx" || break; sleep 1; done
  # The API can be down while the VM is still flushing; wait for the process tree too.
  for i in $(seq 1 60); do [ -z "$(engine_live_pids "$other_lbl" | tr -d ' ')" ] && break; sleep 1; done
  # Two VMs resident at once is not a measurement — fatal, not a warning.
  [ -n "$(engine_live_pids "$other_lbl" | tr -d ' ')" ] && { fail "$other_lbl processes still alive after stop"; return 1; }

  if api_up "$ctx"; then log "[$want] already up"; else
    # The other engine just released its VM: let the host return to baseline before booting
    # this one, then take the no-engine memory baseline for the sysmem cross-check.
    host_quiet "${COOLDOWN_S:-30}" "after stopping $other_lbl"
    sysmem_mb > "$RUNDIR/sysmem-baseline"
    log "[$want] starting $want"; start_engine "$want"
    for i in $(seq 1 240); do api_up "$ctx" && break; sleep 0.5; done
    api_up "$ctx" || { fail "[$want] never became ready"; return 1; }
  fi
  # Settle: DHCP, image-store warmup, and — on Velox — the boot fstrim pass at t+60s,
  # which would otherwise land inside the first timed window. Then wait for the engine's own
  # processes to actually go quiet rather than trusting the fixed sleep.
  log "[$want] settling ${SETTLE_S:-60}s"; sleep "${SETTLE_S:-60}"
  engine_quiet "$want"
}

# ---- readiness helpers (never a bare sleep) ----------------------------------
wait_port(){                         # $1 host $2 port $3 tries
  local i; for i in $(seq 1 "${3:-60}"); do nc -z -G 1 "$1" "$2" >/dev/null 2>&1 && return 0; sleep 0.25; done
  return 1
}
# An open host port does NOT mean the container is serving. Docker Desktop binds its proxy
# listener the instant the container is created, so a single request fired right after
# `wait_port` hits a listener with nothing behind it yet and fails — which made DD look
# incapable of publishing ports at all. Velox only exposes the port once traffic can reach
# the container, so it "passed" the same broken probe. Retry until the SERVICE answers.
wait_http(){                         # $1 url [$2 tries] — curl args after --
  local url="$1" tries="${2:-40}" i
  for i in $(seq 1 "$tries"); do curl -sf --max-time 3 "$url" >/dev/null 2>&1 && return 0; sleep 0.5; done
  return 1
}
wait_http6(){                        # $1 url [$2 tries] — IPv6-forced
  local url="$1" tries="${2:-40}" i
  for i in $(seq 1 "$tries"); do curl -6 -sf --max-time 3 "$url" >/dev/null 2>&1 && return 0; sleep 0.5; done
  return 1
}

footprint(){
  ensure_csv
  log "installed footprint (shipped bits + engine disk at rest)"
  local va vk vr vd
  va=$(dum /Applications/Velox.app); vk=$(dum "$HOME/.velox/kernel")
  vr=$(dum "$HOME/.velox/root.img"); vd=$(dum "$HOME/.velox/data.img")
  # Shipped bits only — the old harness compared Velox's app+kernel+rootfs against
  # Docker.app ALONE, which flattered Velox by excluding DD's VM data entirely.
  rec "$LBL_A" disk installed_footprint size MB "$(addmb "$va" "$vk" "$vr")"
  # And the honest total: everything the engine occupies on disk at rest.
  rec "$LBL_A" disk atrest_footprint size MB "$(addmb "$va" "$vk" "$vr" "$vd")"
  log "velox: app=${va} kernel=${vk} rootfs=${vr} data=${vd}"
  case "$LBL_B" in
    dd)
      local da dr dg
      da=$(dum /Applications/Docker.app)
      dr=$(dum "$HOME/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw")
      dg=$(dum "$HOME/Library/Group Containers/group.com.docker")
      rec dd disk installed_footprint size MB "$da"
      rec dd disk atrest_footprint size MB "$(addmb "$da" "$dr" "$dg")"
      log "dd: app=${da} raw=${dr} group=${dg}" ;;
    orbstack)
      # OrbStack's kernel + rootfs ship inside the app bundle; ~/.orbstack holds its CLI links,
      # logs and VM config. Its Group Container is TCC-protected against *listing*, so its two
      # disk images are sized by explicit path (the same files lsof shows its VMM holding).
      local oa oh od os
      oa=$(dum /Applications/OrbStack.app); oh=$(dum "$HOME/.orbstack")
      od=$(dum "$OSG/data/data.img.raw"); os=$(dum "$OSG/data/swap.img")
      rec orbstack disk installed_footprint size MB "$(addmb "$oa" "$oh")"
      rec orbstack disk atrest_footprint size MB "$(addmb "$oa" "$oh" "$od" "$os")"
      log "orbstack: app=${oa} home=${oh} data=${od} swap=${os}" ;;
  esac
}

# ---- the timed suite ---------------------------------------------------------
suite(){            # $1 context  $2 label
  # Scratch dir MUST live somewhere both engines actually share into the guest, or the
  # "VirtioFS" tests silently measure guest-local storage instead. macOS `mktemp -d`
  # returns /var/folders/… which Docker Desktop shares (via /private) but Velox does NOT
  # (Velox shares /Users + configured fileShares) — so a bind mount there gave Velox an
  # empty in-guest directory and inflated its fs numbers ~2× on bulk write and ~12× on
  # small files. $HOME is shared by both. Override with BENCH_TMP if needed.
  local CTX="$1" ENG="$2"; local BD; BD="${BENCH_TMP:-$HOME/.velox-bench}/run.$$"
  ensure_csv; rm -rf "$BD"; mkdir -p "$BD"
  D(){ docker --context "$CTX" "$@"; }
  # Between test groups: let writeback and heat from the previous group (iperf3 at tens of
  # Gbit/s, pgbench, builds) clear before the next one starts, on both engines alike.
  gate(){ host_quiet "${GATE_S:-10}" "$ENG before $1"; }

  # Assert the scratch dir really round-trips through the host filesystem. A guest-local
  # write here would invalidate every fs number below, so fail loudly rather than publish
  # a fabricated win.
  mkdir -p "$BD/mnt"
  D run --rm -v "$BD/mnt":/m "$IMG_ALPINE" sh -c 'echo shared > /m/.bindprobe' >/dev/null 2>&1
  if [ ! -f "$BD/mnt/.bindprobe" ]; then
    log "[$ENG] FATAL: $BD/mnt is not shared into the guest — fs results would be bogus."
    log "[$ENG]        Add it to the engine's file sharing, or set BENCH_TMP to a shared path."
    return 1
  fi
  rm -f "$BD/mnt/.bindprobe"

  # Let prior writeback drain before timing anything. Measuring seconds after a busy
  # container stopped charges that container's flush to this run: named-volume write
  # read ~1,170 MB/s starting immediately vs ~1,800 MB/s after a 30 s quiesce — a 35%
  # error, easily large enough to invent a "regression" that isn't there.
  log "[$ENG] quiescing ${QUIESCE_S:-30}s so prior writeback drains"
  sync; sleep "${QUIESCE_S:-30}"
  local i
  for i in "$IMG_ALPINE" "$IMG_IPERF"; do D pull -q "$i" >/dev/null 2>&1; done
  local WAKE0; WAKE0=$(sleep_count)

  local t0 t1 ok

  if has_set core; then
  log "[$ENG] launch latency (hyperfine x12)"
  D run --rm "$IMG_ALPINE" true >/dev/null 2>&1
  if hyperfine --warmup 2 --runs 12 --export-json "$BD/run.json" \
      "docker --context $CTX run --rm $IMG_ALPINE true" >/dev/null 2>&1; then
    rec "$ENG" launch run_true median_s s "$(jq -r '.results[0].median' "$BD/run.json")"
  else rec "$ENG" launch run_true median_s s NA; warn "[$ENG] hyperfine failed"; fi

  log "[$ENG] sequential churn x30"
  ok=0; t0=$(now); for i in $(seq 1 30); do D run --rm "$IMG_ALPINE" true >/dev/null 2>&1 || ok=1; done; t1=$(now)
  rec "$ENG" launch churn30_per per_s s "$(python3 -c "print('NA' if '$ok'!='0' else round(($t1-$t0)/30,3))")"

  log "[$ENG] parallel launch x20"
  t0=$(now); for i in $(seq 1 20); do D run --rm "$IMG_ALPINE" true >/dev/null 2>&1 & done; wait; t1=$(now)
  rec "$ENG" launch parallel20_total total_s s "$(secs "$t0" "$t1" 0)"

  gate net
  log "[$ENG] iperf3 published port (host->container) 1 + 4 streams"
  D rm -f ipsrv >/dev/null 2>&1
  D run -d --name ipsrv -p 5301:5201 "$IMG_IPERF" -s >/dev/null 2>&1
  if wait_port 127.0.0.1 5301 120; then
    iperf3 -c 127.0.0.1 -p 5301 -t 1 >/dev/null 2>&1     # untimed warmup, not a sleep
    local P bps
    for P in 1 4; do
      bps=$(iperf3 -c 127.0.0.1 -p 5301 -t 8 -P $P -J 2>/dev/null|jq -r '.end.sum_received.bits_per_second // empty')
      # `// 0` used to turn a failed run into a recorded 0 Gbit/s and a fake catastrophe.
      if [ -n "$bps" ]; then rec "$ENG" net pubport_h2c_p$P gbits gbps "$(python3 -c "print(round($bps/1e9,2))")"
      else rec "$ENG" net pubport_h2c_p$P gbits gbps NA; warn "[$ENG] pubport P$P failed"; fi
    done
  else rec "$ENG" net pubport_h2c_p1 gbits gbps NA; rec "$ENG" net pubport_h2c_p4 gbits gbps NA
       warn "[$ENG] published port never opened"; fi
  D rm -f ipsrv >/dev/null 2>&1

  log "[$ENG] iperf3 container->host"
  pkill -f 'iperf3 -s -p 5302' 2>/dev/null; iperf3 -s -p 5302 -D >/dev/null 2>&1
  if wait_port 127.0.0.1 5302 40; then
    bps=$(D run --rm "$IMG_IPERF" -c host.docker.internal -p 5302 -t 8 -J 2>/dev/null|jq -r '.end.sum_received.bits_per_second // empty')
    if [ -n "$bps" ]; then rec "$ENG" net c2host gbits gbps "$(python3 -c "print(round($bps/1e9,2))")"
    else rec "$ENG" net c2host gbits gbps NA; warn "[$ENG] c2host failed"; fi
  else rec "$ENG" net c2host gbits gbps NA; warn "[$ENG] host iperf3 never listened"; fi
  pkill -f 'iperf3 -s -p 5302' 2>/dev/null

  # Container→container on a user-defined network, addressed BY NAME: also the functional
  # proof that the engine's embedded DNS resolves service names.
  log "[$ENG] iperf3 container->container (user network, by name)"
  D rm -f ipc >/dev/null 2>&1; D network rm benchnet >/dev/null 2>&1
  D network create benchnet >/dev/null 2>&1
  D run -d --name ipc --network benchnet "$IMG_IPERF" -s >/dev/null 2>&1
  if D run --rm --network benchnet "$IMG_ALPINE" sh -c 'for i in $(seq 1 60); do nc -z ipc 5201 && exit 0; sleep 0.25; done; exit 1' >/dev/null 2>&1; then
    bps=$(D run --rm --network benchnet "$IMG_IPERF" -c ipc -t 8 -J 2>/dev/null|jq -r '.end.sum_received.bits_per_second // empty')
    if [ -n "$bps" ]; then rec "$ENG" net c2c gbits gbps "$(python3 -c "print(round($bps/1e9,2))")"
    else rec "$ENG" net c2c gbits gbps NA; warn "[$ENG] c2c failed"; fi
  else rec "$ENG" net c2c gbits gbps NA; warn "[$ENG] c2c DNS/readiness failed"; fi
  D rm -f ipc >/dev/null 2>&1; D network rm benchnet >/dev/null 2>&1

  # docker cp moves bytes over the engine's API transport (VSOCK proxy on Velox), which
  # no other metric here exercises in bulk.
  gate cp
  log "[$ENG] docker cp ${CP_MB}MiB out + in"
  D rm -f cpbox >/dev/null 2>&1
  D run -d --name cpbox "$IMG_ALPINE" sleep 600 >/dev/null 2>&1
  if D exec cpbox sh -c "dd if=/dev/zero of=/data bs=1M count=$CP_MB 2>/dev/null"; then
    ok=0; t0=$(now); D cp cpbox:/data "$BD/cpout" >/dev/null 2>&1 || ok=1; t1=$(now)
    rec "$ENG" io cp_out mbps MBps "$(rate "$CP_MB" "$t0" "$t1" "$ok")"
    ok=0; t0=$(now); D cp "$BD/cpout" cpbox:/data2 >/dev/null 2>&1 || ok=1; t1=$(now)
    rec "$ENG" io cp_in mbps MBps "$(rate "$CP_MB" "$t0" "$t1" "$ok")"
  else rec "$ENG" io cp_out mbps MBps NA; rec "$ENG" io cp_in mbps MBps NA; warn "[$ENG] cp setup failed"; fi
  D rm -f cpbox >/dev/null 2>&1; rm -f "$BD/cpout"

  # fs writes: wall-clock around `dd; sync` (busybox dd lacks conv=fdatasync)
  gate fs
  log "[$ENG] fs bind-mount (VirtioFS) write+read ${DD_MB}MiB"
  rm -rf "${BD:?}/mnt"; mkdir -p "$BD/mnt"   # :? — an empty BD would make this `rm -rf /mnt`
  ok=0; t0=$(now); D run --rm -v "$BD/mnt":/m "$IMG_ALPINE" sh -c "dd if=/dev/zero of=/m/f bs=1M count=$DD_MB 2>/dev/null; sync" || ok=1; t1=$(now)
  rec "$ENG" fs bind_write mbps MBps "$(rate "$DD_MB" "$t0" "$t1" "$ok")"
  ok=0; t0=$(now); D run --rm -v "$BD/mnt":/m "$IMG_ALPINE" sh -c 'dd if=/m/f of=/dev/null bs=1M 2>/dev/null' || ok=1; t1=$(now)
  rec "$ENG" fs bind_read mbps MBps "$(rate "$DD_MB" "$t0" "$t1" "$ok")"

  log "[$ENG] fs named-volume (in-VM ext4) write"
  D volume rm benchvol >/dev/null 2>&1; D volume create benchvol >/dev/null 2>&1
  ok=0; t0=$(now); D run --rm -v benchvol:/m "$IMG_ALPINE" sh -c "dd if=/dev/zero of=/m/f bs=1M count=$DD_MB 2>/dev/null; sync" || ok=1; t1=$(now)
  rec "$ENG" fs vol_write mbps MBps "$(rate "$DD_MB" "$t0" "$t1" "$ok")"; D volume rm benchvol >/dev/null 2>&1

  log "[$ENG] fs container-overlay write"
  ok=0; t0=$(now); D run --rm "$IMG_ALPINE" sh -c "dd if=/dev/zero of=/f bs=1M count=$DD_MB 2>/dev/null; sync" || ok=1; t1=$(now)
  rec "$ENG" fs overlay_write mbps MBps "$(rate "$DD_MB" "$t0" "$t1" "$ok")"

  log "[$ENG] fs small-files: extract $SF_COUNT files into bind-mount"
  local SF="$HERE/smallfiles.tar"
  if [ ! -f "$SF" ]; then
    local g; g="$(mktemp -d)"; ( cd "$g" && for i in $(seq 1 $SF_COUNT); do head -c 4096 /dev/zero > "f$i"; done )
    tar -cf "$SF" -C "$g" .; rm -rf "$g"
  fi
  cp "$SF" "$BD/mnt/sf.tar"
  ok=0; t0=$(now); D run --rm -v "$BD/mnt":/m "$IMG_ALPINE" sh -c 'mkdir -p /m/o && tar -xf /m/sf.tar -C /m/o && sync' >/dev/null 2>&1 || ok=1; t1=$(now)
  rec "$ENG" fs smallfiles_bind extract_s s "$(secs "$t0" "$t1" "$ok")"

  # Image extraction. `docker load` from a tar built once and reused by both engines: identical
  # input bytes, no registry, no bandwidth — decompress + write through the snapshotter, which
  # is where Velox's fsync-durable data disk costs something real.
  #
  # This REPLACED a cold `docker pull` timing. Do not add one back. A pull is dominated by
  # bandwidth to the registry, which is not a property of either engine: the same 381 MB image
  # measured 4.1 s and 20.0 s on this machine forty minutes apart. It produced a "TRAIL vs
  # Docker Desktop" row in the scorecard that was really a CDN reading.
  gate image
  log "[$ENG] image extraction (docker load)"
  local TAR="$HERE/loadimage.tar"
  if [ ! -f "$TAR" ]; then
    log "  building $TAR once (pulling $IMG_LOAD to save it)"
    D pull -q "$IMG_LOAD" >/dev/null 2>&1
    D save -o "$TAR" "$IMG_LOAD" >/dev/null 2>&1
  fi
  D rmi "$IMG_LOAD" >/dev/null 2>&1
  # One untimed load+remove first. `rmi` drops the reference but the just-saved layers can still
  # be in the content store, and `load` then dedupes against them and reports ~0.09 s instead of
  # ~7 s — a 75x artefact on whichever run happened to build the tar. This makes every run start
  # from the same state.
  D load -i "$TAR" >/dev/null 2>&1; D rmi "$IMG_LOAD" >/dev/null 2>&1
  ok=0; t0=$(now); D load -i "$TAR" >/dev/null 2>&1 || ok=1; t1=$(now)
  local sz; sz=$(D image inspect "$IMG_LOAD" --format '{{.Size}}' 2>/dev/null)
  rec "$ENG" image load_local total_s s "$(secs "$t0" "$t1" "$ok")"
  rec "$ENG" image load_local size_mb MB "$([ -n "$sz" ] && python3 -c "print(round($sz/1048576))" || echo NA)"

  gate pgbench
  log "[$ENG] real-world: Postgres pgbench"
  D pull -q "$IMG_PG" >/dev/null 2>&1; D rm -fv pg >/dev/null 2>&1
  D run -d --name pg -e POSTGRES_HOST_AUTH_METHOD=trust "$IMG_PG" >/dev/null 2>&1
  local pgready=1
  for i in $(seq 1 120); do D exec pg pg_isready -U postgres >/dev/null 2>&1 && { pgready=0; break; }; sleep 0.5; done
  if [ "$pgready" = "0" ]; then
    ok=0; t0=$(now); D exec pg pgbench -i -s 50 -U postgres postgres >/dev/null 2>&1 || ok=1; t1=$(now)
    rec "$ENG" realworld pgbench_init load_s s "$(secs "$t0" "$t1" "$ok")"
    local tps; tps=$(D exec pg pgbench -U postgres -T 30 -c 8 -j 4 postgres 2>&1|grep 'tps ='|tail -1|awk '{print $3}')
    rec "$ENG" realworld pgbench_tps tps tps "${tps:-NA}"
  else
    # Previously this fell through and recorded 0.074 s / 0 TPS — a broken run published
    # as a result. It is still in results.csv as a warning.
    rec "$ENG" realworld pgbench_init load_s s NA; rec "$ENG" realworld pgbench_tps tps tps NA
    warn "[$ENG] postgres never became ready"
  fi
  D rm -fv pg >/dev/null 2>&1
  fi   # core

  has_set build   && { gate build;   suite_build   "$CTX" "$ENG" "$BD"; }
  has_set compose && { gate compose; suite_compose "$CTX" "$ENG"; }
  has_set rosetta && { gate emul;    suite_rosetta "$CTX" "$ENG"; }

  rm -rf "$BD"
  # A sleep anywhere inside the suite invalidates every wall-clock number in it. Mark the
  # round so report.py's caller can drop it, rather than letting a 100x artefact reach the
  # scorecard as a "result".
  if ! assert_awake "$WAKE0" "$ENG"; then
    rec "$ENG" quality slept flag n 1
    log "[$ENG] suite done (INVALID — system slept)"
    return 1
  fi
  rec "$ENG" quality slept flag n 0
  log "[$ENG] suite done"
}

# ---- build set ---------------------------------------------------------------
suite_build(){      # $1 ctx $2 label $3 scratch
  local CTX="$1" ENG="$2" BD="$3" t0 t1 ok i
  D(){ docker --context "$CTX" "$@"; }
  log "[$ENG] build: preparing local base + context (untimed)"
  # Retag locally so `FROM bench-base:local` can never reach a registry: a build metric
  # must not be a bandwidth metric.
  D tag "$IMG_ALPINE" bench-base:local >/dev/null 2>&1 || { warn "[$ENG] tag failed"; return 1; }
  mkdir -p "$BD/build/src"
  cp "$HERE/fixtures/build/Dockerfile" "$BD/build/Dockerfile" 2>/dev/null || { warn "[$ENG] build fixture missing"; return 1; }
  for i in $(seq 1 200); do head -c 65536 /dev/urandom > "$BD/build/src/f$i"; done
  D builder prune -af >/dev/null 2>&1

  log "[$ENG] build cold (--no-cache)"
  ok=0; t0=$(now); D build --no-cache -q -t bench-build "$BD/build" >/dev/null 2>&1 || ok=1; t1=$(now)
  rec "$ENG" build cold total_s s "$(secs "$t0" "$t1" "$ok")"
  [ "$ok" != "0" ] && warn "[$ENG] cold build failed"

  log "[$ENG] build cached (no-op rebuild)"
  ok=0; t0=$(now); D build -q -t bench-build "$BD/build" >/dev/null 2>&1 || ok=1; t1=$(now)
  rec "$ENG" build cached_noop total_s s "$(secs "$t0" "$t1" "$ok")"

  log "[$ENG] build incremental (one source file changed)"
  head -c 65536 /dev/urandom > "$BD/build/src/f1"
  ok=0; t0=$(now); D build -q -t bench-build "$BD/build" >/dev/null 2>&1 || ok=1; t1=$(now)
  rec "$ENG" build incremental total_s s "$(secs "$t0" "$t1" "$ok")"

  # A big COPY context is streamed to the daemon over the API socket — Velox's VSOCK
  # proxy vs Docker Desktop's socket path, which no other metric measures in bulk.
  log "[$ENG] build ${CTX_MB}MiB context transfer"
  mkdir -p "$BD/ctx"; printf 'FROM bench-base:local\nCOPY blob /blob\n' > "$BD/ctx/Dockerfile"
  dd if=/dev/zero of="$BD/ctx/blob" bs=1m count="$CTX_MB" 2>/dev/null
  ok=0; t0=$(now); D build -q -t bench-ctx "$BD/ctx" >/dev/null 2>&1 || ok=1; t1=$(now)
  rec "$ENG" build context_xfer mbps MBps "$(rate "$CTX_MB" "$t0" "$t1" "$ok")"

  D rmi bench-build bench-ctx bench-base:local >/dev/null 2>&1
  D builder prune -af >/dev/null 2>&1
}

# ---- compose set -------------------------------------------------------------
suite_compose(){    # $1 ctx $2 label
  local CTX="$1" ENG="$2" F="$HERE/fixtures/compose/compose.yaml" t0 t1 ok
  [ -f "$F" ] || { warn "[$ENG] compose fixture missing"; return 1; }
  D(){ docker --context "$CTX" "$@"; }
  log "[$ENG] compose: pre-pulling images (untimed)"
  D compose -f "$F" -p benchcompose pull -q >/dev/null 2>&1
  D compose -f "$F" -p benchcompose down -v >/dev/null 2>&1

  log "[$ENG] compose up -d --wait (3 services, healthchecked)"
  ok=0; t0=$(now); D compose -f "$F" -p benchcompose up -d --wait >/dev/null 2>&1 || ok=1; t1=$(now)
  rec "$ENG" compose up_ready total_s s "$(secs "$t0" "$t1" "$ok")"
  [ "$ok" != "0" ] && warn "[$ENG] compose up failed"

  log "[$ENG] compose down -v"
  ok=0; t0=$(now); D compose -f "$F" -p benchcompose down -v >/dev/null 2>&1 || ok=1; t1=$(now)
  rec "$ENG" compose down total_s s "$(secs "$t0" "$t1" "$ok")"
}

# ---- rosetta / emulation set -------------------------------------------------
suite_rosetta(){    # $1 ctx $2 label
  local CTX="$1" ENG="$2" a n
  D(){ docker --context "$CTX" "$@"; }
  local PY='import hashlib,time
d=b"x"*4096
t=time.time()
for _ in range(300000): hashlib.sha256(d).digest()
print(round(time.time()-t,3))'
  log "[$ENG] amd64 emulation vs native arm64 (pure CPU, pre-pulled)"
  D pull -q --platform linux/amd64 "$IMG_LOAD" >/dev/null 2>&1
  D pull -q "$IMG_LOAD" >/dev/null 2>&1
  a=$(D run --rm --platform linux/amd64 "$IMG_LOAD" python -c "$PY" 2>/dev/null | tail -1)
  n=$(D run --rm "$IMG_LOAD" python -c "$PY" 2>/dev/null | tail -1)
  rec "$ENG" emul amd64_sha total_s s "${a:-NA}"
  rec "$ENG" emul native_sha total_s s "${n:-NA}"
  if [ -n "$a" ] && [ -n "$n" ]; then
    rec "$ENG" emul amd64_tax ratio x "$(python3 -c "print(round($a/$n,2))")"
    log "[$ENG] amd64 ${a}s vs native ${n}s"
  else warn "[$ENG] emulation measurement failed"; fi
}

# ---- idle / resource-saver ---------------------------------------------------
idle(){             # $1 ctx $2 label — engine must already be running, saver ON at 5 min
  local CTX="$1" ENG="$2" pids c0 c1 w0 w1 i rss
  ensure_csv
  pids="$(engine_pids "$ENG")"
  [ -z "$(echo "$pids"|tr -d ' ')" ] && { warn "[$ENG] no engine processes found"; return 1; }
  log "[$ENG] idle window: 4 min active-idle sampling (pids: $pids)"
  docker --context "$CTX" ps -q >/dev/null 2>&1     # last activity, then hands off
  w0=$(now); c0=$(sum_cputime $pids)
  local rsslist="" fplist=""
  for i in $(seq 1 24); do sleep 10; rsslist="$rsslist $(sum_rss $pids)"; fplist="$fplist $(sum_footprint $pids)"; done
  w1=$(now); c1=$(sum_cputime $pids)
  rec "$ENG" idle cpu pct pct "$(python3 -c "print(round(($c1-$c0)/($w1-$w0)*100,2))")"
  local MED='import sys; v=sorted(float(x) for x in sys.argv[1].split()); print(round(v[len(v)//2]))'
  rec "$ENG" idle rss_active host_rss MB "$(python3 -c "$MED" "$rsslist")"
  rec "$ENG" idle fp_active host_fp MB "$(python3 -c "$MED" "$fplist")"
  rec "$ENG" idle sysmem_active delta_mb MB "$(sysmem_delta)"
  # Velox's Resource Saver (and DD's) fires at 5 min idle; OrbStack has no timer and returns
  # memory continuously. Sample past the timeout plus margin either way: this row is "idle
  # RAM after 5+ minutes with nothing running", whatever mechanism each engine uses.
  log "[$ENG] waiting out the 5-min resource-saver timeout"
  sleep 240
  w0=$(now); c0=$(sum_cputime $pids); sleep 60; w1=$(now); c1=$(sum_cputime $pids)
  rss=$(sum_rss $pids)
  rec "$ENG" idle rss_saver host_rss MB "$rss"
  rec "$ENG" idle fp_saver host_fp MB "$(sum_footprint $pids)"
  rec "$ENG" idle sysmem_saver delta_mb MB "$(sysmem_delta)"
  rec "$ENG" idle cpu_saver pct pct "$(python3 -c "print(round(($c1-$c0)/($w1-$w0)*100,2))")"
  log "[$ENG] saver RSS ${rss}MB"
}

# ---- RAM under load ----------------------------------------------------------
loadram(){          # $1 ctx $2 label
  local CTX="$1" ENG="$2" i pids
  ensure_csv
  D(){ docker --context "$CTX" "$@"; }
  log "[$ENG] RAM under load: 20 idle containers + postgres"
  for i in $(seq 1 20); do D run -d --name "l$i" "$IMG_ALPINE" sleep 3600 >/dev/null 2>&1; done
  D rm -fv lpg >/dev/null 2>&1
  D run -d --name lpg -e POSTGRES_HOST_AUTH_METHOD=trust "$IMG_PG" >/dev/null 2>&1
  for i in $(seq 1 120); do D exec lpg pg_isready -U postgres >/dev/null 2>&1 && break; sleep 0.5; done
  sleep 60
  pids="$(engine_pids "$ENG")"
  rec "$ENG" mem loaded host_rss MB "$(sum_rss $pids)"
  rec "$ENG" mem loaded_fp host_fp MB "$(sum_footprint $pids)"
  rec "$ENG" mem loaded_sysmem delta_mb MB "$(sysmem_delta)"
  log "[$ENG] loaded RSS $(sum_rss $pids)MB — tearing down, then 3 min for memory to return"
  for i in $(seq 1 20); do D rm -f "l$i" >/dev/null 2>&1; done
  D rm -fv lpg >/dev/null 2>&1
  sleep 180
  pids="$(engine_pids "$ENG")"
  rec "$ENG" mem postload host_rss MB "$(sum_rss $pids)"
  rec "$ENG" mem postload_fp host_fp MB "$(sum_footprint $pids)"
  rec "$ENG" mem postload_sysmem delta_mb MB "$(sysmem_delta)"
  log "[$ENG] post-teardown RSS $(sum_rss $pids)MB"
}

# ---- disk reclaim ------------------------------------------------------------
reclaim(){          # $1 ctx $2 label — measure growth, then whether it comes back
  local CTX="$1" ENG="$2" IMG a0 a1 a2
  ensure_csv
  D(){ docker --context "$CTX" "$@"; }
  IMG="$(disk_image "$ENG")"
  a0=$(dum "$IMG")
  log "[$ENG] disk reclaim: baseline ${a0}MB allocated"
  D volume rm rvol >/dev/null 2>&1; D volume create rvol >/dev/null 2>&1
  D run --rm -v rvol:/m "$IMG_ALPINE" sh -c 'dd if=/dev/zero of=/m/f bs=1M count=4096 2>/dev/null; sync' >/dev/null 2>&1
  D load -i "$HERE/loadimage.tar" >/dev/null 2>&1
  sync; sleep 5
  a1=$(dum "$IMG")
  log "[$ENG] after 4GiB volume + image load: ${a1}MB"
  D volume rm rvol >/dev/null 2>&1; D rmi "$IMG_LOAD" >/dev/null 2>&1
  # Restart is the reclaim trigger: Velox runs its fstrim pass 60 s after boot. Whether the
  # peer returns anything is exactly what this measures — do not assume it can't.
  #
  # This MUST be a real stop+start. Calling engine() here was a silent no-op ("already up"),
  # so no boot happened, no trim pass ran, and Velox scored a fabricated "0 MB reclaimed"
  # against a Docker Desktop that trims on its own schedule.
  log "[$ENG] restarting to trigger the trim pass"
  stop_engine "$ENG"
  local i; for i in $(seq 1 120); do api_up "$CTX" || break; sleep 1; done
  for i in $(seq 1 60); do [ -z "$(engine_live_pids "$ENG" | tr -d ' ')" ] && break; sleep 1; done
  start_engine "$ENG"
  for i in $(seq 1 240); do api_up "$CTX" && break; sleep 0.5; done
  sleep 150                       # Velox trims at boot+60 s; leave margin on both engines
  a2=$(dum "$IMG")
  rec "$ENG" disk reclaim grew_mb MB "$(submb "$a1" "$a0")"
  rec "$ENG" disk reclaim returned_mb MB "$(submb "$a1" "$a2")"
  rec "$ENG" disk reclaim retained_mb MB "$(submb "$a2" "$a0")"
  log "[$ENG] grew $(submb "$a1" "$a0")MB, returned $(submb "$a1" "$a2")MB, retained $(submb "$a2" "$a0")MB"
}

# ---- functional matrix (untimed; network allowed) ----------------------------
matrix(){           # $1 ctx $2 label
  local CTX="$1" ENG="$2" BD; BD="${BENCH_TMP:-$HOME/.velox-bench}/mx.$$"
  ensure_csv; mkdir -p "$BD/mnt"
  D(){ docker --context "$CTX" "$@"; }
  p(){ rec "$ENG" matrix "$1" state state "$2"; printf '%-24s %s\n' "$1" "$2" | tee -a "$RUNDIR/matrix-$ENG.txt"; }

  log "[$ENG] functional matrix probes"
  D run --rm -v "$BD/mnt":/m "$IMG_ALPINE" sh -c 'echo ok > /m/probe' >/dev/null 2>&1
  [ -f "$BD/mnt/probe" ] && p bind_mount pass || p bind_mount fail

  pkill -f 'iperf3 -s -p 5302' 2>/dev/null; iperf3 -s -p 5302 -D >/dev/null 2>&1; sleep 1
  D run --rm "$IMG_ALPINE" sh -c 'nc -z -w 3 host.docker.internal 5302' >/dev/null 2>&1 \
    && p host_docker_internal pass || p host_docker_internal fail
  pkill -f 'iperf3 -s -p 5302' 2>/dev/null

  # iperf3 -u still negotiates over a TCP control connection on the same port, so the
  # container must publish BOTH protocols or this probe fails for a reason that has
  # nothing to do with UDP forwarding.
  D rm -f mxudp >/dev/null 2>&1
  D run -d --name mxudp -p 5399:5201/udp -p 5399:5201/tcp "$IMG_IPERF" -s >/dev/null 2>&1
  wait_port 127.0.0.1 5399 60 >/dev/null 2>&1
  iperf3 -u -c 127.0.0.1 -p 5399 -t 2 -b 10M >/dev/null 2>&1 && p udp_publish pass || p udp_publish fail
  D rm -f mxudp >/dev/null 2>&1

  D rm -f mxweb >/dev/null 2>&1
  D run -d --name mxweb -p 18001:8000 "$IMG_LOAD" python -m http.server 8000 >/dev/null 2>&1
  wait_http 'http://127.0.0.1:18001/' 40 && p ipv4_publish pass || p ipv4_publish fail
  wait_http6 'http://[::1]:18001/' 20 && p ipv6_publish pass || p ipv6_publish fail
  D rm -f mxweb >/dev/null 2>&1

  # Privileged port (<1024). On Velox this exercises the root porthelper; if the user
  # declined the one-time admin grant it legitimately fails — record, don't excuse.
  D rm -f mxpriv >/dev/null 2>&1
  D run -d --name mxpriv -p 80:8000 "$IMG_LOAD" python -m http.server 8000 >/dev/null 2>&1
  wait_http 'http://127.0.0.1:80/' 40 && p privileged_port pass || p privileged_port fail
  D rm -f mxpriv >/dev/null 2>&1

  # Per-container host-IP publish. Two separate cases, because they once had different answers:
  #   loopback (-p 127.0.0.1:…) — Velox honours this explicitly (PublishBind.swift).
  #   a real LAN address        — failed on Velox until 2026-10 (the guest dockerd couldn't bind
  #                               a macOS address); now ip_nonlocal_bind + exact host binding.
  D rm -f mxbind >/dev/null 2>&1
  D run -d --name mxbind -p 127.0.0.1:18002:8000 "$IMG_LOAD" python -m http.server 8000 >/dev/null 2>&1
  wait_http 'http://127.0.0.1:18002/' 40 && p publish_loopback_pin pass || p publish_loopback_pin fail
  D rm -f mxbind >/dev/null 2>&1

  local lanip; lanip=$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null)
  if [ -n "$lanip" ]; then
    D rm -f mxlan >/dev/null 2>&1
    D run -d --name mxlan -p "$lanip":18003:8000 "$IMG_LOAD" python -m http.server 8000 >/dev/null 2>&1
    wait_http "http://$lanip:18003/" 30 && p percontainer_hostip pass || p percontainer_hostip fail
    D rm -f mxlan >/dev/null 2>&1
  else p percontainer_hostip skip; fi

  local plat arch
  for plat in linux/amd64 linux/arm/v7 linux/386; do
    D pull -q --platform "$plat" "$IMG_ALPINE" >/dev/null 2>&1
    arch=$(D run --rm --platform "$plat" "$IMG_ALPINE" uname -m 2>/dev/null | tr -d '\r\n')
    [ -n "$arch" ] && p "platform_${plat//\//_}" "pass($arch)" || p "platform_${plat//\//_}" fail
  done

  mkdir -p "$BD/b"; printf 'FROM %s\nRUN echo built > /m\n' "$IMG_ALPINE" > "$BD/b/Dockerfile"
  D build -q -t mxbuild "$BD/b" >/dev/null 2>&1 && p buildkit_build pass || p buildkit_build fail
  D build -q --provenance=true -t mxprov "$BD/b" >/dev/null 2>&1 && p build_provenance pass || p build_provenance fail
  D rmi mxbuild mxprov >/dev/null 2>&1

  # Streaming probes. macOS ships no `timeout(1)`, and an unbounded `logs -f` would hang
  # the run — so background the stream, let it collect, then kill it and judge by what
  # actually arrived. A stream that produces the expected bytes is the only proof that
  # hijacked connections work through the engine's API transport.
  D rm -f mxev >/dev/null 2>&1
  D run -d --name mxev "$IMG_ALPINE" sh -c 'while :; do echo tick; sleep 1; done' >/dev/null 2>&1
  sleep 2
  D stats --no-stream mxev >/dev/null 2>&1 && p stats pass || p stats fail

  docker --context "$CTX" logs -f mxev > "$BD/logs.out" 2>/dev/null &
  local lp=$!; sleep 4; kill "$lp" 2>/dev/null; wait "$lp" 2>/dev/null
  grep -q tick "$BD/logs.out" && p logs_follow pass || p logs_follow fail

  docker --context "$CTX" events --format '{{.Action}}' > "$BD/events.out" 2>/dev/null &
  local ep=$!; sleep 2
  D run --rm "$IMG_ALPINE" true >/dev/null 2>&1          # generate a real event to observe
  sleep 2; kill "$ep" 2>/dev/null; wait "$ep" 2>/dev/null
  [ -s "$BD/events.out" ] && p events_stream pass || p events_stream fail

  D exec mxev echo hi >/dev/null 2>&1 && p exec pass || p exec fail
  D rm -f mxev >/dev/null 2>&1

  # Named access: <name>.<domain> reaches the container's real IP with no -p at all. Velox
  # (.velox.local) and OrbStack (.orb.local) both have it, so probe each one's own domain;
  # Docker Desktop has no equivalent.
  local dom=""; case "$ENG" in velox) dom=velox.local ;; orbstack) dom=orb.local ;; esac
  if [ -n "$dom" ]; then
    D rm -f mxname >/dev/null 2>&1
    D run -d --name mxname "$IMG_LOAD" python -m http.server 8000 >/dev/null 2>&1
    sleep 3
    wait_http "http://mxname.$dom:8000/" 30 && p named_access pass || p named_access fail
    D rm -f mxname >/dev/null 2>&1
  fi

  rm -rf "$BD"
  log "[$ENG] matrix done → $RUNDIR/matrix-$ENG.txt"
}

# The engine's Docker API unix socket, for the startup timer's direct /_ping. Taken from the
# docker context itself (so a renamed/relocated socket follows the context), falling back to
# each engine's well-known path.
engine_sock(){                       # $1 ctx $2 label
  local s
  s=$(docker context inspect "$1" --format '{{.Endpoints.docker.Host}}' 2>/dev/null | sed -n 's#^unix://##p')
  if [ -z "$s" ]; then
    case "$2" in
      velox)  s="$HOME/.velox/docker.sock" ;;
      orb*)   s="$HOME/.orbstack/run/docker.sock" ;;
      *)      s="$HOME/.docker/run/docker.sock" ;;
    esac
  fi
  echo "$s"
}
# One /_ping straight at the socket: true once the daemon answers "OK". --max-time is
# deliberately generous — Velox holds a request that arrives before dockerd is listening and
# answers it the instant dockerd serves, so a short timeout would cut exactly the request
# whose completion IS the ready moment (and re-quantize the measurement to the timeout).
api_ping(){ [ "$(curl -s --max-time 30 --unix-socket "$1" http://localhost/_ping 2>/dev/null)" = "OK" ]; }

startup(){          # bounces both apps; measures launch -> API-ready (warm disk cache)
  ensure_csv
  _one(){ local CTX="$1" ENG="$2" OTHER SOCK
    # Quit BOTH engines first. This used to stop only the engine being timed, so after the
    # first round the other one was always resident during every startup measurement — the
    # one-engine-at-a-time rule silently did not hold for this metric (2026-10-09 run).
    [ "$ENG" = "$LBL_A" ] && OTHER="$LBL_B" || OTHER="$LBL_A"
    SOCK=$(engine_sock "$CTX" "$ENG")
    log "[$ENG] stopping (and $OTHER)"; stop_engine "$OTHER"; stop_engine "$ENG"
    local i; for i in $(seq 1 120); do api_up "$CTX" || break; sleep 0.5; done
    for i in $(seq 1 60); do [ -z "$(engine_live_pids "$ENG")$(engine_live_pids "$OTHER")" ] && break; sleep 1; done
    [ -n "$(engine_live_pids "$OTHER" | tr -d ' ')" ] && { fail "$OTHER still alive before timing $ENG"; return 1; }
    host_quiet "${COOLDOWN_S:-30}" "before timing $ENG startup"
    # Readiness = the first "OK" from /_ping on the engine's socket, polled every ~25 ms.
    # This used to be `docker version` every 0.5 s: the 0.5 s quantization (plus a docker CLI
    # spawn per probe) was larger than the differences being measured — the startup gap to
    # OrbStack is ~0.33 s. Recorded as `restart_to_ready_ping` so it never mixes with the
    # 0.5 s-polled `restart_to_ready_solo` rows of the 2026-10-09 run.
    #
    # The probe must not perturb what it measures. Hammering the socket every 25 ms cost OrbStack
    # ~0.5 s (2026-10-10): its early connections fail slowly (~0.1–0.3 s each) and each one
    # pushes its first answer out — measured 1.26–1.35 s at 10–100 ms probe intervals vs
    # 0.75–0.79 s at 250–500 ms, same Mac, same hour. Velox holds an early connection open until
    # dockerd answers, so it reads the same either way (0.42–0.45 s). So: wait for the socket
    # FILE with stat (no connections at all), then one blocking request; only an outright
    # failure retries, 250 ms apart. Recorded as `restart_to_ready_sparse`.
    #
    # "The socket file exists" must mean the NEW engine's socket: an engine that leaves its
    # socket file behind on quit would otherwise pass the wait at once and fall through to the
    # 250 ms retry loop — the dense probing this avoids, applied to one engine only. So wait for
    # an inode different from the one there before the start (a fresh bind is a new inode).
    local before; before=$(stat -L -f %i "$SOCK" 2>/dev/null || echo none)
    log "[$ENG] starting, timing to API-ready (/_ping on $SOCK)"; local t0; t0=$(now); start_engine "$ENG"
    local deadline=$((SECONDS + 120))
    while [ "$SECONDS" -lt "$deadline" ]; do
      if [ -S "$SOCK" ]; then
        [ "$before" = none ] && break
        [ "$(stat -L -f %i "$SOCK" 2>/dev/null)" != "$before" ] && break
        sleep 0.01
      else
        sleep 0.005
      fi
    done
    while [ "$SECONDS" -lt "$deadline" ]; do
      api_ping "$SOCK" && { rec "$ENG" lifecycle restart_to_ready_sparse time_s s "$(secs "$t0" "$(now)" 0)"; log "[$ENG] ready"; return 0; }
      sleep 0.25
    done
    rec "$ENG" lifecycle restart_to_ready_sparse time_s s NA
    warn "[$ENG] DID NOT become ready in 120s"; }
  # Order alternates with the round so neither engine always gets the warm host. ROUND may
  # carry a non-numeric tag (step's retry appends "r"), so use its leading digits only.
  local rnum="${ROUND%%[!0-9]*}"
  if [ $(( ${rnum:-0} % 2 )) = 1 ]; then _one "$CTX_A" "$LBL_A"; _one "$CTX_B" "$LBL_B"
  else _one "$CTX_B" "$LBL_B"; _one "$CTX_A" "$LBL_A"; fi
}

# ---- campaign driver (resumable) ---------------------------------------------
STATE=""
done_step(){ [ -f "$STATE" ] && grep -qxF "$1" "$STATE"; }
mark_step(){ echo "$1" >> "$STATE"; }
# A step that fails is retried ONCE, then the campaign STOPS (resumable with the same RUN_ID).
# It used to ignore exit codes, so a failed preflight or a parity mismatch was marked done and
# the run measured on regardless. A retried step runs under ROUND="<n>r", so rows from a
# discarded attempt (e.g. a suite that spanned a system sleep) stay distinguishable in the CSV.
step(){             # $1 key, rest: command — skip if already recorded
  local key="$1"; shift
  if done_step "$key"; then log "skip (done): $key"; return 0; fi
  log "=== $key"
  if "$@"; then mark_step "$key"; return 0; fi
  warn "step $key failed — retrying once"
  local r0="$ROUND"; ROUND="${ROUND}r"
  if "$@"; then ROUND="$r0"; mark_step "$key"; return 0; fi
  ROUND="$r0"
  echo "XXX step $key failed twice — campaign stopped. Fix the cause, then resume with RUN_ID=$RUN_ID." >&2
  exit 1
}

campaign(){
  ensure_csv; STATE="$RUNDIR/campaign.state"; touch "$STATE"
  log "campaign run_id=$RUN_ID peer=$LBL_B (resumable; state=$STATE; csv=$CSV)"
  step env:capture capture_env
  step env:parity  config_parity

  # Phase 1 — parity verification on each engine.
  step p1:velox:engine    engine "$LBL_A"
  step p1:velox:pre       preflight "$CTX_A"
  step p1:velox:info      capture_info "$CTX_A" "$LBL_A"
  step p1:velox:foot      footprint
  step "p1:$LBL_B:engine" engine "$LBL_B"
  step "p1:$LBL_B:pre"    preflight "$CTX_B"
  step "p1:$LBL_B:info"   capture_info "$CTX_B" "$LBL_B"

  # Phase 2 — idle + resource saver (Velox first; Phase 5/6 run the peer first).
  step p2:velox:engine    engine "$LBL_A"
  step p2:velox:idle      idle "$CTX_A" "$LBL_A"
  step "p2:$LBL_B:engine" engine "$LBL_B"
  step "p2:$LBL_B:idle"   idle "$CTX_B" "$LBL_B"

  # Phase 3 — startup, n=6, alternating order: each engine goes first exactly 3 times
  # (n=5 gave Velox the first slot 3 times and the peer 2).
  local r
  for r in 1 2 3 4 5 6; do ROUND=$r; step "p3:startup:r$r" startup; done

  # Phase 4 — the timed suite, order-balanced, n=6. Heavy sets in rounds 1–4 (2 each way).
  for r in 1 2 3 4 5 6; do
    ROUND=$r
    local sets="core"; [ "$r" -le 4 ] && sets="core,build,compose,rosetta"
    local first second fctx sctx
    if [ $((r % 2)) = 1 ]; then first="$LBL_A"; fctx="$CTX_A"; second="$LBL_B"; sctx="$CTX_B"
    else first="$LBL_B"; fctx="$CTX_B"; second="$LBL_A"; sctx="$CTX_A"; fi
    step "p4:r$r:$first:engine" engine "$first"
    step "p4:r$r:$first:pre"    preflight "$fctx"
    BENCH_SETS="$sets" step "p4:r$r:$first:suite" suite "$fctx" "$first"
    step "p4:r$r:$second:engine" engine "$second"
    step "p4:r$r:$second:pre"    preflight "$sctx"
    BENCH_SETS="$sets" step "p4:r$r:$second:suite" suite "$sctx" "$second"
  done
  ROUND=0

  # Phase 5 — one-offs (low n, labeled as such in the report). Peer first.
  step "p5:$LBL_B:engine"  engine "$LBL_B"
  step "p5:$LBL_B:loadram" loadram "$CTX_B" "$LBL_B"
  step "p5:$LBL_B:reclaim" reclaim "$CTX_B" "$LBL_B"
  step p5:velox:engine     engine "$LBL_A"
  step p5:velox:loadram    loadram "$CTX_A" "$LBL_A"
  step p5:velox:reclaim    reclaim "$CTX_A" "$LBL_A"

  # Phase 6 — functional matrix (untimed, network allowed). Peer first.
  step "p6:$LBL_B:engine" engine "$LBL_B"
  step "p6:$LBL_B:matrix" matrix "$CTX_B" "$LBL_B"
  step p6:velox:engine    engine "$LBL_A"
  step p6:velox:matrix    matrix "$CTX_A" "$LBL_A"

  step p7:footprint footprint
  log "campaign complete — $CSV"
  python3 "$HERE/report.py" --csv "$CSV"
}

USAGE="usage: [BENCH_PEER=dd|orbstack] $0 [all|campaign|preflight|engine <e>|suite <ctx> <lbl>|idle|loadram|reclaim|matrix|footprint|startup|parity|report]"
case "${1:-help}" in report|help|-h|--help) ;; *) setup_client ;; esac
# No default subcommand on purpose: the two cadences differ by 12 minutes vs ~4 hours
# and the long one bounces both apps, so it must be asked for by name.
case "${1:-help}" in
  campaign)  campaign ;;
  preflight) preflight "${2:-}" ;;
  parity)    config_parity ;;
  engine)    engine "${2:?usage: engine <velox|$LBL_B>}" ;;
  # The quick check writes to its own scratch CSV: it used to truncate results.csv — the
  # committed evidence behind the published scorecard — on every run.
  all)       [ -z "${BENCH_CSV:-}" ] && CSV="$RUNDIR/quick.csv"
             mkdir -p "$RUNDIR"; echo "$CSV_HEADER" > "$CSV"
             footprint; suite "$CTX_A" "$LBL_A"; suite "$CTX_B" "$LBL_B"
             python3 "$HERE/report.py" --csv "$CSV" ;;
  footprint) footprint ;;
  suite)     suite "${2:?ctx}" "${3:?label}" ;;
  idle)      idle "${2:?ctx}" "${3:?label}" ;;
  loadram)   loadram "${2:?ctx}" "${3:?label}" ;;
  reclaim)   reclaim "${2:?ctx}" "${3:?label}" ;;
  matrix)    matrix "${2:?ctx}" "${3:?label}" ;;
  startup)   startup ;;
  report)    python3 "$HERE/report.py" --csv "$CSV" ;;
  help|-h|--help)
    sed -n '2,62p' "$0" | sed 's/^# \{0,1\}//' >&2
    echo "$USAGE" >&2 ;;
  *) echo "$USAGE" >&2; exit 2 ;;
esac
