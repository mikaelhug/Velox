#!/usr/bin/env bash
#
# Velox vs Docker Desktop — benchmark harness.
#
# Selects each engine by its Docker *context* (no wrapper, no daemon swap) and
# runs the same suite against both, one engine under load at a time. Results are
# appended to results.csv; ./report.py prints the scorecard.
#
# Usage:
#   ./run.sh                      # footprint + full suite on both engines, then scorecard
#   ./run.sh suite <ctx> <label>  # run the active suite against one context only
#   ./run.sh footprint            # idle host-RSS footprint of both engines
#   ./run.sh startup              # restart-to-ready timing (this bounces both apps)
#
# Requirements: docker CLI with both contexts, python3, jq, iperf3, hyperfine.
#   brew install jq iperf3 hyperfine
#
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
CSV="$HERE/results.csv"

# ---- config: edit to match your two engines ----------------------------------
CTX_A="velox";          LBL_A="velox";  APP_A="Velox"
CTX_B="desktop-linux";  LBL_B="dd";     APP_B="Docker"
IMG_ALPINE="alpine:3.20"
IMG_IPERF="networkstatic/iperf3:latest"
IMG_PULL="python:3.12"      # cold-pull target (removed before each pull)
IMG_PG="postgres:16"
DD_MB=1024                  # dd write/read size, MiB
SF_COUNT=4000               # small-files count
# ------------------------------------------------------------------------------

now(){ python3 -c 'import time;print(time.time())'; }
rec(){ echo "$1,$2,$3,$4,$5,$6" >> "$CSV"; }            # eng,suite,test,metric,unit,value
mbps(){ python3 -c "print(round($DD_MB/($2-$1),1))"; } # MiB / elapsed
secs(){ python3 -c "print(round($2-$1,3))"; }
log(){ echo ">>> $*" >&2; }

sum_rss(){ local t=0 r; for p in "$@"; do r=$(ps -o rss= -p "$p" 2>/dev/null|tr -d ' '); [ -n "$r" ]&&t=$((t+r)); done; echo $((t/1024)); }

footprint(){
  log "idle footprint (host RSS, both engines, 0 containers)"
  local vvm vapp vport ddvm ddprocs ddnetd
  vvm=$(lsof -t "$HOME/.velox/data.img" 2>/dev/null|head -1)
  vapp=$(pgrep -f 'Velox.app/Contents/MacOS/VeloxApp'); vport=$(pgrep -f 'dev.velox.porthelper')
  ddvm=$(lsof -t "$HOME/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw" 2>/dev/null|head -1)
  ddprocs=$(pgrep -f 'Docker.app/Contents/MacOS|com.docker.backend|com.docker.virtualization|com.docker.build')
  ddnetd=$(pgrep -f 'com.docker.vmnetd')
  rec "$LBL_A" mem idle_footprint host_rss MB "$(sum_rss $vapp $vvm $vport)"
  rec "$LBL_B" mem idle_footprint host_rss MB "$(sum_rss $ddvm $ddprocs $ddnetd)"
  # installed footprint
  local va vk vr da
  va=$(du -sm /Applications/Velox.app 2>/dev/null|awk '{print $1}')
  vk=$(du -sm "$HOME/.velox/kernel" 2>/dev/null|awk '{print $1}')
  vr=$(du -sm "$HOME/.velox/root.img" 2>/dev/null|awk '{print $1}')
  da=$(du -sm /Applications/Docker.app 2>/dev/null|awk '{print $1}')
  rec "$LBL_A" disk installed_footprint size MB "$((va+vk+vr))"
  rec "$LBL_B" disk installed_footprint size MB "${da:-0}"
}

suite(){            # $1 context  $2 label
  local CTX="$1" ENG="$2"; local BD; BD="$(mktemp -d)"
  D(){ docker --context "$CTX" "$@"; }
  for i in "$IMG_ALPINE" "$IMG_IPERF"; do D pull -q "$i" >/dev/null 2>&1; done

  log "[$ENG] launch latency (hyperfine x12)"
  D run --rm "$IMG_ALPINE" true >/dev/null 2>&1
  hyperfine --warmup 2 --runs 12 --export-json "$BD/run.json" \
    "docker --context $CTX run --rm $IMG_ALPINE true" >/dev/null 2>&1
  rec "$ENG" launch run_true median_s s "$(jq -r '.results[0].median' "$BD/run.json")"

  log "[$ENG] sequential churn x30"
  local t0 t1; t0=$(now); for i in $(seq 1 30); do D run --rm "$IMG_ALPINE" true >/dev/null 2>&1; done; t1=$(now)
  rec "$ENG" launch churn30_per per_s s "$(python3 -c "print(round(($t1-$t0)/30,3))")"

  log "[$ENG] parallel launch x20"
  t0=$(now); for i in $(seq 1 20); do D run --rm "$IMG_ALPINE" true >/dev/null 2>&1 & done; wait; t1=$(now)
  rec "$ENG" launch parallel20_total total_s s "$(secs $t0 $t1)"

  log "[$ENG] iperf3 published port (host->container) 1 + 4 streams"
  D rm -f ipsrv >/dev/null 2>&1
  D run -d --name ipsrv -p 5301:5201 "$IMG_IPERF" -s >/dev/null 2>&1; sleep 2
  for P in 1 4; do
    local bps; bps=$(iperf3 -c 127.0.0.1 -p 5301 -t 8 -P $P -J 2>/dev/null|jq -r '.end.sum_received.bits_per_second // 0')
    rec "$ENG" net pubport_h2c_p$P gbits gbps "$(python3 -c "print(round(${bps:-0}/1e9,2))")"
  done
  D rm -f ipsrv >/dev/null 2>&1

  log "[$ENG] iperf3 container->host"
  pkill -f 'iperf3 -s -p 5302' 2>/dev/null; iperf3 -s -p 5302 -D >/dev/null 2>&1; sleep 1
  local bps; bps=$(D run --rm "$IMG_IPERF" -c host.docker.internal -p 5302 -t 8 -J 2>/dev/null|jq -r '.end.sum_received.bits_per_second // 0')
  rec "$ENG" net c2host gbits gbps "$(python3 -c "print(round(${bps:-0}/1e9,2))")"
  pkill -f 'iperf3 -s -p 5302' 2>/dev/null

  # fs writes: wall-clock around `dd; sync` (busybox dd lacks conv=fdatasync)
  log "[$ENG] fs bind-mount (VirtioFS) write+read ${DD_MB}MiB"
  rm -rf "$BD/mnt"; mkdir -p "$BD/mnt"
  t0=$(now); D run --rm -v "$BD/mnt":/m "$IMG_ALPINE" sh -c "dd if=/dev/zero of=/m/f bs=1M count=$DD_MB 2>/dev/null; sync"; t1=$(now)
  rec "$ENG" fs bind_write mbps MBps "$(mbps $t0 $t1)"
  t0=$(now); D run --rm -v "$BD/mnt":/m "$IMG_ALPINE" sh -c 'dd if=/m/f of=/dev/null bs=1M 2>/dev/null'; t1=$(now)
  rec "$ENG" fs bind_read mbps MBps "$(mbps $t0 $t1)"

  log "[$ENG] fs named-volume (in-VM ext4) write"
  D volume rm benchvol >/dev/null 2>&1; D volume create benchvol >/dev/null 2>&1
  t0=$(now); D run --rm -v benchvol:/m "$IMG_ALPINE" sh -c "dd if=/dev/zero of=/m/f bs=1M count=$DD_MB 2>/dev/null; sync"; t1=$(now)
  rec "$ENG" fs vol_write mbps MBps "$(mbps $t0 $t1)"; D volume rm benchvol >/dev/null 2>&1

  log "[$ENG] fs container-overlay write"
  t0=$(now); D run --rm "$IMG_ALPINE" sh -c "dd if=/dev/zero of=/f bs=1M count=$DD_MB 2>/dev/null; sync"; t1=$(now)
  rec "$ENG" fs overlay_write mbps MBps "$(mbps $t0 $t1)"

  log "[$ENG] fs small-files: extract $SF_COUNT files into bind-mount"
  local SF="$HERE/smallfiles.tar"
  if [ ! -f "$SF" ]; then
    local g; g="$(mktemp -d)"; ( cd "$g" && for i in $(seq 1 $SF_COUNT); do head -c 4096 /dev/zero > "f$i"; done )
    tar -cf "$SF" -C "$g" .; rm -rf "$g"
  fi
  cp "$SF" "$BD/mnt/sf.tar"
  t0=$(now); D run --rm -v "$BD/mnt":/m "$IMG_ALPINE" sh -c 'mkdir -p /m/o && tar -xf /m/sf.tar -C /m/o && sync' >/dev/null 2>&1; t1=$(now)
  rec "$ENG" fs smallfiles_bind extract_s s "$(secs $t0 $t1)"

  log "[$ENG] cold image pull $IMG_PULL"
  D rmi "$IMG_PULL" >/dev/null 2>&1
  t0=$(now); D pull -q "$IMG_PULL" >/dev/null 2>&1; t1=$(now)
  local sz; sz=$(D image inspect "$IMG_PULL" --format '{{.Size}}' 2>/dev/null)
  rec "$ENG" pull cold_image total_s s "$(secs $t0 $t1)"
  rec "$ENG" pull cold_image size_mb MB "$(python3 -c "print(round(${sz:-0}/1048576))")"

  log "[$ENG] real-world: Postgres pgbench"
  D pull -q "$IMG_PG" >/dev/null 2>&1; D rm -f pg >/dev/null 2>&1
  D run -d --name pg -e POSTGRES_HOST_AUTH_METHOD=trust "$IMG_PG" >/dev/null 2>&1
  for i in $(seq 1 60); do D exec pg pg_isready -U postgres >/dev/null 2>&1 && break; sleep 0.5; done
  t0=$(now); D exec pg pgbench -i -s 50 -U postgres postgres >/dev/null 2>&1; t1=$(now)
  rec "$ENG" realworld pgbench_init load_s s "$(secs $t0 $t1)"
  local tps; tps=$(D exec pg pgbench -U postgres -T 30 -c 8 -j 4 postgres 2>&1|grep 'tps ='|tail -1|awk '{print $3}')
  rec "$ENG" realworld pgbench_tps tps tps "${tps:-0}"
  D rm -f pg >/dev/null 2>&1
  rm -rf "$BD"
  log "[$ENG] suite done"
}

startup(){          # bounces both apps; measures launch -> API-ready (warm disk cache)
  _one(){ local CTX="$1" ENG="$2" APP="$3"
    ready(){ docker --context "$CTX" version --format '{{.Server.Version}}' >/dev/null 2>&1; }
    log "[$ENG] quit $APP"; osascript -e "quit app \"$APP\"" >/dev/null 2>&1
    for i in $(seq 1 60); do ready || break; sleep 0.5; done; sleep 3
    log "[$ENG] launch $APP, timing to API-ready"; local t0; t0=$(now); open -a "$APP"
    for i in $(seq 1 240); do ready && { rec "$ENG" lifecycle restart_to_ready time_s s "$(secs $t0 "$(now)")"; log "[$ENG] ready"; return; }; sleep 0.5; done
    log "[$ENG] DID NOT become ready in 120s"; }
  _one "$CTX_A" "$LBL_A" "$APP_A"; _one "$CTX_B" "$LBL_B" "$APP_B"
}

case "${1:-all}" in
  all)       echo "engine,suite,test,metric,unit,value" > "$CSV"
             footprint; suite "$CTX_A" "$LBL_A"; suite "$CTX_B" "$LBL_B"
             python3 "$HERE/report.py" ;;
  footprint) [ -f "$CSV" ] || echo "engine,suite,test,metric,unit,value" > "$CSV"; footprint ;;
  suite)     [ -f "$CSV" ] || echo "engine,suite,test,metric,unit,value" > "$CSV"; suite "$2" "$3" ;;
  startup)   [ -f "$CSV" ] || echo "engine,suite,test,metric,unit,value" > "$CSV"; startup ;;
  report)    python3 "$HERE/report.py" ;;
  *) echo "usage: $0 [all|footprint|suite <ctx> <label>|startup|report]" >&2; exit 2 ;;
esac
