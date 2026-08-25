#!/usr/bin/env bash
#
# Velox vs Docker Desktop — benchmark harness.
#
# Selects each engine by its Docker *context* (no wrapper, no daemon swap) and runs the
# same suite against both, ONE ENGINE RESIDENT AT A TIME. Results are appended to
# results.csv; ./report.py prints the scorecard.
#
# TWO CADENCES — pick the right one:
#
#   ./run.sh all        QUICK (~12 min).  One round per engine, no engine bouncing.
#                       This is the pre-release regression check (CLAUDE.md): run it
#                       before a human-cut release or a datapath/kernel/disk/engine
#                       change and compare against docs/benchmarks.md. Single-shot, so
#                       treat a delta smaller than the spreads in the report as noise.
#
#   ./run.sh campaign   FULL (~2.5 h).  The publishable head-to-head: order-balanced
#                       n=5 rounds, idle/CPU windows, RAM-under-load, disk reclaim and
#                       the functional matrix. Bounces both apps repeatedly and needs
#                       the Mac to itself. This is ANNUAL (or when a new Docker Desktop
#                       major lands / before a claim goes on the website) — NOT per
#                       commit and not per release. Output is a dated report next to
#                       this script; see REPORT-2026-08-25.md for the last one and
#                       "Running the annual comparison" in ../benchmarks.md for the
#                       preconditions that make it fair.
#
# Usage:
#   ./run.sh campaign             # the full order-balanced comparison (see RUN BOOK below)
#   ./run.sh preflight            # fairness gate: AC power, thermal, host idle, disk, deps
#   ./run.sh engine <velox|dd>    # quit the other engine, boot this one, settle
#   ./run.sh suite <ctx> <label>  # the timed suite against one context
#   ./run.sh idle <ctx> <label>   # idle CPU/RAM + resource-saver reclaim depth
#   ./run.sh loadram <ctx> <lbl>  # RAM under load, then return after teardown
#   ./run.sh reclaim <ctx> <lbl>  # disk growth vs reclaim after rmi/volume rm
#   ./run.sh matrix <ctx> <lbl>   # functional pass/fail probes (untimed, network allowed)
#   ./run.sh footprint            # installed on-disk footprint of both engines
#   ./run.sh startup              # restart-to-ready timing (bounces both apps)
#   ./run.sh report               # scorecard
#
# Requirements: docker CLI with both contexts, python3, jq, iperf3, hyperfine, nc, curl.
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
# ------------------------------------------------------------------------------
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
CSV="${BENCH_CSV:-$HERE/results.csv}"   # BENCH_CSV: write elsewhere while smoke-testing
CSV_HEADER="engine,suite,test,metric,unit,value,ts,run_id,round,velox_ver,dd_ver"

# ---- config: edit to match your two engines ----------------------------------
CTX_A="velox";          LBL_A="velox";  APP_A="Velox"
CTX_B="desktop-linux";  LBL_B="dd";     APP_B="Docker"
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

VELOX_VER=""; DD_VER=""
versions(){
  [ -n "$VELOX_VER" ] && return 0
  VELOX_VER=$(defaults read /Applications/Velox.app/Contents/Info.plist CFBundleShortVersionString 2>/dev/null || echo unknown)
  DD_VER=$(jq -r '.appVersion' /Applications/Docker.app/Contents/Resources/componentsVersion.json 2>/dev/null || echo unknown)
}

# eng,suite,test,metric,unit,value + provenance. Provenance exists because results.csv
# used to be an undated pile in which a June baseline and an August re-run were
# indistinguishable, and the published scorecard silently mixed them.
rec(){ versions; echo "$1,$2,$3,$4,$5,$6,$(now),$RUN_ID,$ROUND,$VELOX_VER,$DD_VER" >> "$CSV"; }
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
# `docker load` this way and the scorecard published it. `sleep_count` samples the number of
# wake events; a suite whose count moved is discarded rather than reported.
sleep_count(){ pmset -g log 2>/dev/null | grep -c "Wake from" 2>/dev/null || echo 0; }
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

# Full process set, INCLUDING each engine's persistent privileged LaunchDaemon
# (com.docker.vmnetd / dev.velox.porthelper). Those daemons are a real, permanent cost of
# running the engine, so they belong in every RSS number.
engine_pids(){                       # $1 label → pid list on stdout
  if [ "$1" = "$LBL_A" ]; then
    { engine_live_pids "$1"; pgrep -f 'dev.velox.porthelper'; } | sort -u | tr '\n' ' '
  else
    { engine_live_pids "$1"; pgrep -f 'com.docker.vmnetd'; } | sort -u | tr '\n' ' '
  fi
}
# Process set that actually goes away when the engine stops. The privileged helpers above
# are LaunchDaemons that outlive the app by design, so waiting for them to exit — as an
# earlier version of this function did — could never succeed and burned 60 s per switch
# while printing a false "still alive" warning.
engine_live_pids(){                  # $1 label → pid list on stdout
  if [ "$1" = "$LBL_A" ]; then
    { lsof -t "$HOME/.velox/data.img" 2>/dev/null|head -1
      pgrep -f 'Velox.app/Contents/MacOS/VeloxApp'; } | sort -u | tr '\n' ' '
  else
    { lsof -t "$HOME/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw" 2>/dev/null|head -1
      pgrep -f 'Docker.app/Contents/MacOS|com.docker.backend|com.docker.virtualization|com.docker.build'; } | sort -u | tr '\n' ' '
  fi
}
disk_image(){ [ "$1" = "$LBL_A" ] && echo "$HOME/.velox/data.img" \
              || echo "$HOME/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw"; }
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
  # Thermal throttling silently halves throughput; wait it out rather than publish it.
  for t in $(seq 1 60); do
    local lim; lim=$(pmset -g therm 2>/dev/null | awk -F' *: *' '/CPU_Speed_Limit/{print $2}')
    [ -z "$lim" ] && break
    [ "$lim" = "100" ] && break
    log "thermally throttled (CPU_Speed_Limit=$lim) — cooling, $t/60"; sleep 30
  done
  # Find the field labelled "idle" by name. Splitting on [ %]+ and taking NF-1 landed on the
  # literal word "idle" (the line has a trailing space), so int() made it 0 and the gate
  # reported "0% idle" on a perfectly quiet machine — a fairness check that never fired.
  local idle; idle=$(top -l 2 -n 0 -s 3 2>/dev/null | awk '/CPU usage/{for(j=1;j<=NF;j++) if($j=="idle"){gsub("%","",$(j-1)); v=$(j-1)}} END{print int(v)}')
  if [ -n "$idle" ] && [ "$idle" -lt 85 ] 2>/dev/null; then
    warn "host only ${idle}% idle — close background apps"; bad=1
  fi
  local freeg; freeg=$(df -g / | awk 'NR==2{print $4}')
  [ "${freeg:-0}" -lt 40 ] && { warn "only ${freeg}GB free on / (need 40)"; bad=1; }
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
  cp "$HOME/Library/Group Containers/group.com.docker/settings-store.json" "$RUNDIR/dd-settings-store.json" 2>/dev/null
  cp /Applications/Docker.app/Contents/Resources/componentsVersion.json "$RUNDIR/dd-components.json" 2>/dev/null
  cp "$HERE/../../versions.env" "$RUNDIR/velox-versions.env" 2>/dev/null
  docker compose version > "$RUNDIR/compose-binary.txt" 2>&1
  log "environment captured → $RUNDIR"
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
  if [ -n "$n" ] && [ -n "$mem" ]; then
    [ "$n" != "${EXPECT_CPU:-8}" ] && warn "[$2] vCPU $n != expected ${EXPECT_CPU:-8}"
    python3 -c "import sys; sys.exit(0 if 7000 <= float(sys.argv[1]) <= 8400 else 1)" "$mem" \
      || warn "[$2] RAM ${mem}MB outside the 7000–8400 parity window"
  fi
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
  if [ "$1" = "$LBL_A" ]; then osascript -e "quit app \"$APP_A\"" >/dev/null 2>&1
  else
    docker desktop stop >/dev/null 2>&1
    osascript -e 'quit app "Docker Desktop"' >/dev/null 2>&1
  fi
}
# Symmetric "start": launch the application and let it bring its engine up, which is what a
# user does and what the restart_to_ready metric is supposed to represent on both sides.
start_engine(){ if [ "$1" = "$LBL_A" ]; then open -a "$APP_A"; else open -a "$APP_B"; fi; }

engine(){                            # $1 velox|dd — leave exactly this engine resident
  local want="$1" ctx other_lbl other_ctx
  if [ "$want" = "$LBL_A" ]; then ctx="$CTX_A"; other_lbl="$LBL_B"; other_ctx="$CTX_B"
  else ctx="$CTX_B"; other_lbl="$LBL_A"; other_ctx="$CTX_A"; fi

  log "engine switch → $want (stopping $other_lbl)"
  stop_engine "$other_lbl"
  local i
  for i in $(seq 1 120); do api_up "$other_ctx" || break; sleep 1; done
  # The API can be down while the VM is still flushing; wait for the process tree too.
  for i in $(seq 1 60); do [ -z "$(engine_live_pids "$other_lbl" | tr -d ' ')" ] && break; sleep 1; done
  [ -n "$(engine_live_pids "$other_lbl" | tr -d ' ')" ] && warn "$other_lbl processes still alive after stop"

  if api_up "$ctx"; then log "[$want] already up"; else
    log "[$want] starting $want"; start_engine "$want"
    for i in $(seq 1 240); do api_up "$ctx" && break; sleep 0.5; done
    api_up "$ctx" || { fail "[$want] never became ready"; return 1; }
  fi
  # Settle: DHCP, image-store warmup, and — on Velox — the boot fstrim pass at t+60s,
  # which would otherwise land inside the first timed window.
  log "[$want] settling ${SETTLE_S:-60}s"; sleep "${SETTLE_S:-60}"
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
  local va vk vr vd da dr dg
  va=$(du -sm /Applications/Velox.app 2>/dev/null|awk '{print $1}')
  vk=$(du -sm "$HOME/.velox/kernel" 2>/dev/null|awk '{print $1}')
  vr=$(du -sm "$HOME/.velox/root.img" 2>/dev/null|awk '{print $1}')
  vd=$(du -sm "$HOME/.velox/data.img" 2>/dev/null|awk '{print $1}')
  da=$(du -sm /Applications/Docker.app 2>/dev/null|awk '{print $1}')
  dr=$(du -sm "$HOME/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw" 2>/dev/null|awk '{print $1}')
  dg=$(du -sm "$HOME/Library/Group Containers/group.com.docker" 2>/dev/null|awk '{print $1}')
  # Shipped bits only — the old harness compared Velox's app+kernel+rootfs against
  # Docker.app ALONE, which flattered Velox by excluding DD's VM data entirely.
  rec "$LBL_A" disk installed_footprint size MB "$(( ${va:-0} + ${vk:-0} + ${vr:-0} ))"
  rec "$LBL_B" disk installed_footprint size MB "${da:-0}"
  # And the honest total: everything the engine occupies on disk at rest.
  rec "$LBL_A" disk atrest_footprint size MB "$(( ${va:-0} + ${vk:-0} + ${vr:-0} + ${vd:-0} ))"
  rec "$LBL_B" disk atrest_footprint size MB "$(( ${da:-0} + ${dr:-0} + ${dg:-0} ))"
  log "velox: app=${va} kernel=${vk} rootfs=${vr} data=${vd} | dd: app=${da} raw=${dr} group=${dg}"
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

  log "[$ENG] real-world: Postgres pgbench"
  D pull -q "$IMG_PG" >/dev/null 2>&1; D rm -f pg >/dev/null 2>&1
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
  D rm -f pg >/dev/null 2>&1
  fi   # core

  has_set build   && suite_build   "$CTX" "$ENG" "$BD"
  has_set compose && suite_compose "$CTX" "$ENG"
  has_set rosetta && suite_rosetta "$CTX" "$ENG"

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
  local rsslist=""
  for i in $(seq 1 24); do sleep 10; rsslist="$rsslist $(sum_rss $pids)"; done
  w1=$(now); c1=$(sum_cputime $pids)
  rec "$ENG" idle cpu pct pct "$(python3 -c "print(round(($c1-$c0)/($w1-$w0)*100,2))")"
  rec "$ENG" idle rss_active host_rss MB "$(python3 -c "
v=sorted(float(x) for x in '''$rsslist'''.split())
print(round(v[len(v)//2]))")"
  # Resource Saver (both engines have one) fires at 5 min idle; sample past the timeout
  # plus margin to capture how deep each engine actually gives memory back.
  log "[$ENG] waiting out the 5-min resource-saver timeout"
  sleep 240
  w0=$(now); c0=$(sum_cputime $pids); sleep 60; w1=$(now); c1=$(sum_cputime $pids)
  rss=$(sum_rss $pids)
  rec "$ENG" idle rss_saver host_rss MB "$rss"
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
  D rm -f lpg >/dev/null 2>&1
  D run -d --name lpg -e POSTGRES_HOST_AUTH_METHOD=trust "$IMG_PG" >/dev/null 2>&1
  for i in $(seq 1 120); do D exec lpg pg_isready -U postgres >/dev/null 2>&1 && break; sleep 0.5; done
  sleep 60
  pids="$(engine_pids "$ENG")"
  rec "$ENG" mem loaded host_rss MB "$(sum_rss $pids)"
  log "[$ENG] loaded RSS $(sum_rss $pids)MB — tearing down, then 3 min for memory to return"
  for i in $(seq 1 20); do D rm -f "l$i" >/dev/null 2>&1; done
  D rm -f lpg >/dev/null 2>&1
  sleep 180
  pids="$(engine_pids "$ENG")"
  rec "$ENG" mem postload host_rss MB "$(sum_rss $pids)"
  log "[$ENG] post-teardown RSS $(sum_rss $pids)MB"
}

# ---- disk reclaim ------------------------------------------------------------
reclaim(){          # $1 ctx $2 label — measure growth, then whether it comes back
  local CTX="$1" ENG="$2" IMG a0 a1 a2
  ensure_csv
  D(){ docker --context "$CTX" "$@"; }
  IMG="$(disk_image "$ENG")"
  a0=$(du -m "$IMG" 2>/dev/null|awk '{print $1}')
  log "[$ENG] disk reclaim: baseline ${a0}MB allocated"
  D volume rm rvol >/dev/null 2>&1; D volume create rvol >/dev/null 2>&1
  D run --rm -v rvol:/m "$IMG_ALPINE" sh -c 'dd if=/dev/zero of=/m/f bs=1M count=4096 2>/dev/null; sync' >/dev/null 2>&1
  D load -i "$HERE/loadimage.tar" >/dev/null 2>&1
  sync; sleep 5
  a1=$(du -m "$IMG" 2>/dev/null|awk '{print $1}')
  log "[$ENG] after 4GiB volume + image load: ${a1}MB"
  D volume rm rvol >/dev/null 2>&1; D rmi "$IMG_LOAD" >/dev/null 2>&1
  # Restart is the reclaim trigger: Velox runs its fstrim pass 60 s after boot. Whether
  # Docker Desktop returns anything is exactly what this measures — do not assume it can't.
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
  a2=$(du -m "$IMG" 2>/dev/null|awk '{print $1}')
  rec "$ENG" disk reclaim grew_mb MB "$(( ${a1:-0} - ${a0:-0} ))"
  rec "$ENG" disk reclaim returned_mb MB "$(( ${a1:-0} - ${a2:-0} ))"
  rec "$ENG" disk reclaim retained_mb MB "$(( ${a2:-0} - ${a0:-0} ))"
  log "[$ENG] grew $(( ${a1:-0} - ${a0:-0} ))MB, returned $(( ${a1:-0} - ${a2:-0} ))MB, retained $(( ${a2:-0} - ${a0:-0} ))MB"
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

  # Per-container host-IP publish. Two separate cases, because they have different answers:
  #   loopback (-p 127.0.0.1:…) — Velox honours this explicitly (PublishBind.swift).
  #   a real LAN address        — DOCUMENTED Velox limitation: the guest dockerd cannot bind
  #                               a macOS address, so only the global publishHostIP knob works.
  # Recorded as a plain fail on Velox. A design rationale is not a pass.
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

  # Velox-only: <name>.velox.local reaches the container's real IP with no -p at all.
  if [ "$ENG" = "$LBL_A" ]; then
    D rm -f mxname >/dev/null 2>&1
    D run -d --name mxname "$IMG_LOAD" python -m http.server 8000 >/dev/null 2>&1
    sleep 3
    wait_http 'http://mxname.velox.local:8000/' 30 && p named_access pass || p named_access fail
    D rm -f mxname >/dev/null 2>&1
  fi

  rm -rf "$BD"
  log "[$ENG] matrix done → $RUNDIR/matrix-$ENG.txt"
}

startup(){          # bounces both apps; measures launch -> API-ready (warm disk cache)
  ensure_csv
  _one(){ local CTX="$1" ENG="$2"
    log "[$ENG] stopping"; stop_engine "$ENG"
    local i; for i in $(seq 1 120); do api_up "$CTX" || break; sleep 0.5; done
    for i in $(seq 1 60); do [ -z "$(engine_live_pids "$ENG" | tr -d ' ')" ] && break; sleep 1; done
    sleep 3
    log "[$ENG] starting, timing to API-ready"; local t0; t0=$(now); start_engine "$ENG"
    for i in $(seq 1 240); do api_up "$CTX" && { rec "$ENG" lifecycle restart_to_ready time_s s "$(secs "$t0" "$(now)" 0)"; log "[$ENG] ready"; return 0; }; sleep 0.5; done
    rec "$ENG" lifecycle restart_to_ready time_s s NA
    warn "[$ENG] DID NOT become ready in 120s"; }
  # Order alternates with the round so neither engine always gets the warm host.
  if [ $((ROUND % 2)) = 1 ]; then _one "$CTX_A" "$LBL_A"; _one "$CTX_B" "$LBL_B"
  else _one "$CTX_B" "$LBL_B"; _one "$CTX_A" "$LBL_A"; fi
}

# ---- campaign driver (resumable) ---------------------------------------------
STATE=""
done_step(){ [ -f "$STATE" ] && grep -qxF "$1" "$STATE"; }
mark_step(){ echo "$1" >> "$STATE"; }
step(){             # $1 key, rest: command — skip if already recorded
  local key="$1"; shift
  if done_step "$key"; then log "skip (done): $key"; return 0; fi
  log "=== $key"
  "$@"
  mark_step "$key"
}

campaign(){
  ensure_csv; STATE="$RUNDIR/campaign.state"; touch "$STATE"
  log "campaign run_id=$RUN_ID (resumable; state=$STATE)"
  step env:capture capture_env

  # Phase 1 — parity verification on each engine.
  step p1:velox:engine engine "$LBL_A"
  step p1:velox:pre    preflight "$CTX_A"
  step p1:velox:info   capture_info "$CTX_A" "$LBL_A"
  step p1:velox:foot   footprint
  step p1:dd:engine    engine "$LBL_B"
  step p1:dd:pre       preflight "$CTX_B"
  step p1:dd:info      capture_info "$CTX_B" "$LBL_B"

  # Phase 2 — idle + resource saver (needs the saver ENABLED at 5 min on both).
  step p2:velox:engine engine "$LBL_A"
  step p2:velox:idle   idle "$CTX_A" "$LBL_A"
  step p2:dd:engine    engine "$LBL_B"
  step p2:dd:idle      idle "$CTX_B" "$LBL_B"

  # Phase 3 — startup, n=5, alternating order (saver OFF from here on).
  local r
  for r in 1 2 3 4 5; do ROUND=$r; step "p3:startup:r$r" startup; done

  # Phase 4 — the timed suite, order-balanced. Heavy sets only in rounds 1–3.
  for r in 1 2 3 4 5; do
    ROUND=$r
    local sets="core"; [ "$r" -le 3 ] && sets="core,build,compose,rosetta"
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

  # Phase 5 — one-offs (low n, labeled as such in the report).
  step p5:velox:engine  engine "$LBL_A"
  step p5:velox:loadram loadram "$CTX_A" "$LBL_A"
  step p5:velox:reclaim reclaim "$CTX_A" "$LBL_A"
  step p5:dd:engine     engine "$LBL_B"
  step p5:dd:loadram    loadram "$CTX_B" "$LBL_B"
  step p5:dd:reclaim    reclaim "$CTX_B" "$LBL_B"

  # Phase 6 — functional matrix (untimed, network allowed).
  step p6:velox:engine engine "$LBL_A"
  step p6:velox:matrix matrix "$CTX_A" "$LBL_A"
  step p6:dd:engine    engine "$LBL_B"
  step p6:dd:matrix    matrix "$CTX_B" "$LBL_B"

  step p7:footprint footprint
  log "campaign complete — $CSV"
  python3 "$HERE/report.py"
}

# No default subcommand on purpose: the two cadences differ by 12 minutes vs 2.5 hours
# and the long one bounces both apps, so it must be asked for by name.
case "${1:-help}" in
  campaign)  campaign ;;
  preflight) preflight "${2:-}" ;;
  engine)    engine "${2:?usage: engine <velox|dd>}" ;;
  all)       echo "$CSV_HEADER" > "$CSV"
             footprint; suite "$CTX_A" "$LBL_A"; suite "$CTX_B" "$LBL_B"
             python3 "$HERE/report.py" ;;
  footprint) footprint ;;
  suite)     suite "${2:?ctx}" "${3:?label}" ;;
  idle)      idle "${2:?ctx}" "${3:?label}" ;;
  loadram)   loadram "${2:?ctx}" "${3:?label}" ;;
  reclaim)   reclaim "${2:?ctx}" "${3:?label}" ;;
  matrix)    matrix "${2:?ctx}" "${3:?label}" ;;
  startup)   startup ;;
  report)    python3 "$HERE/report.py" ;;
  help|-h|--help)
    sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//' >&2
    echo "usage: $0 [all|campaign|preflight|engine <e>|suite <ctx> <lbl>|idle|loadram|reclaim|matrix|footprint|startup|report]" >&2 ;;
  *) echo "usage: $0 [all|campaign|preflight|engine <e>|suite <ctx> <lbl>|idle|loadram|reclaim|matrix|footprint|startup|report]" >&2; exit 2 ;;
esac
