#!/usr/bin/env bash
# Velox end-to-end functional harness.
#
# The gap this closes: `velox-selftest` covers pure functions only, and CI structurally
# cannot boot the VM (CLAUDE.md §9). Everything below was previously verified — when it was
# verified at all — by hand, one shell session at a time. This is the local pre-release gate;
# run it beside `docs/bench/run.sh` before cutting a release.
#
#   Tests/e2e/run.sh              # full suite against the running engine
#   Tests/e2e/run.sh -k pattern   # only sections whose name matches
#
# Assumes Velox is already running (the app or `velox start`). Every artefact it creates is
# named `velox-e2e-*` and removed on exit; it never touches pre-existing containers, images
# or volumes.
set -uo pipefail

SOCK="${VELOX_SOCK:-$HOME/.velox/docker.sock}"
DOCKER="${VELOX_DOCKER:-$HOME/.velox/bin/docker}"
export DOCKER_HOST="unix://$SOCK"
PREFIX=velox-e2e
FILTER="${2:-}"; [ "${1:-}" = "-k" ] || FILTER=""

pass=0; fail=0; skipped=0; current="(none)"
ok(){   printf '  \033[32mok\033[0m    %s\n' "$1"; pass=$((pass+1)); }
bad(){  printf '  \033[31mFAIL\033[0m  %s\n' "$1"; [ -n "${2:-}" ] && printf '        %s\n' "$2"; fail=$((fail+1)); }
skip(){ printf '  --    %s (%s)\n' "$1" "$2"; skipped=$((skipped+1)); }
section(){ current="$1"; printf '\n== %s ==\n' "$1"; }
want(){ [ -z "$FILTER" ] && return 0; case "$1" in *"$FILTER"*) return 0;; *) return 1;; esac; }

# assert <desc> <expected> <actual>
assert(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2], got [$3]"; fi; }
# assert_contains <desc> <needle> <haystack>
assert_contains(){ case "$3" in *"$2"*) ok "$1";; *) bad "$1" "[$2] not in [$3]";; esac; }

cleanup(){
  $DOCKER rm -f $($DOCKER ps -aq --filter "name=^${PREFIX}" 2>/dev/null) >/dev/null 2>&1
  $DOCKER volume rm -f $($DOCKER volume ls -q --filter "name=^${PREFIX}" 2>/dev/null) >/dev/null 2>&1
  $DOCKER network rm $($DOCKER network ls -q --filter "name=^${PREFIX}" 2>/dev/null) >/dev/null 2>&1
  $DOCKER image rm -f "${PREFIX}-img" >/dev/null 2>&1
  rm -rf "${TMP:-/nonexistent}"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
printf 'Velox e2e — socket %s\n' "$SOCK"
[ -S "$SOCK" ] || { echo "error: $SOCK is not a socket — is the engine running?" >&2; exit 2; }
$DOCKER info >/dev/null 2>&1 || { echo "error: docker API not answering on $SOCK" >&2; exit 2; }
TMP="$(mktemp -d)"
BASE=alpine:3.23
$DOCKER pull -q "$BASE" >/dev/null 2>&1

# ---------------------------------------------------------------------------
if want "engine"; then section "engine + API"
  assert "docker API answers"            "ok" "$($DOCKER info >/dev/null 2>&1 && echo ok)"
  srv="$($DOCKER version --format '{{.Server.Version}}' 2>/dev/null)"
  [ -n "$srv" ] && ok "server version reported ($srv)" || bad "server version reported"
  # The CLI must reach the engine through the `velox` context, not just DOCKER_HOST (§1).
  if $DOCKER context inspect velox >/dev/null 2>&1; then
    assert "velox docker context works" "ok" "$(DOCKER_HOST= $DOCKER --context velox info >/dev/null 2>&1 && echo ok)"
  else skip "velox docker context" "context not created"; fi
fi

if want "run"; then section "container lifecycle"
  out="$($DOCKER run --rm --name ${PREFIX}-hello "$BASE" echo hello-velox 2>&1)"
  assert_contains "run + capture stdout" "hello-velox" "$out"
  $DOCKER run -d --name ${PREFIX}-sleep "$BASE" sleep 300 >/dev/null 2>&1
  assert "detached container is running" "running" "$($DOCKER inspect -f '{{.State.Status}}' ${PREFIX}-sleep 2>/dev/null)"
  assert_contains "exec into it" "exec-ok" "$($DOCKER exec ${PREFIX}-sleep echo exec-ok 2>&1)"
  $DOCKER stop -t 2 ${PREFIX}-sleep >/dev/null 2>&1
  assert "stop transitions to exited" "exited" "$($DOCKER inspect -f '{{.State.Status}}' ${PREFIX}-sleep 2>/dev/null)"
  $DOCKER rm -f ${PREFIX}-sleep >/dev/null 2>&1
fi

if want "logs"; then section "log streaming + hijacked streams"
  $DOCKER run -d --name ${PREFIX}-logger "$BASE" sh -c 'i=0; while :; do echo line-$i; i=$((i+1)); sleep 1; done' >/dev/null 2>&1
  sleep 3
  assert_contains "docker logs returns output" "line-0" "$($DOCKER logs ${PREFIX}-logger 2>&1 | head -3)"
  # follow is a HIJACKED stream through the socket proxy — the path that used to hang on quit
  timeout_follow(){ $DOCKER logs -f ${PREFIX}-logger >"$TMP/follow.out" 2>&1 & echo $!; }
  fpid="$(timeout_follow)"; sleep 3; kill "$fpid" 2>/dev/null; wait "$fpid" 2>/dev/null
  n="$(wc -l < "$TMP/follow.out" | tr -d ' ')"
  [ "$n" -ge 2 ] && ok "logs -f streamed $n lines (hijacked stream)" || bad "logs -f streamed only $n lines"
  # interactive exec is the other hijack shape
  assert_contains "exec -i round-trips stdin" "stdin-ok" "$(echo stdin-ok | $DOCKER exec -i ${PREFIX}-logger cat 2>&1)"
  $DOCKER rm -f ${PREFIX}-logger >/dev/null 2>&1
fi

if want "build"; then section "docker build (BuildKit through the proxy)"
  cat > "$TMP/Dockerfile" <<EOF
FROM $BASE
RUN echo built-by-velox > /marker
EOF
  if $DOCKER build -q -t ${PREFIX}-img "$TMP" >"$TMP/build.log" 2>&1; then
    ok "image builds"
    assert_contains "built layer content is correct" "built-by-velox" "$($DOCKER run --rm ${PREFIX}-img cat /marker 2>&1)"
  else
    bad "image builds" "$(tail -3 "$TMP/build.log")"
  fi
fi

if want "volume"; then section "volumes"
  $DOCKER volume create ${PREFIX}-vol >/dev/null 2>&1
  $DOCKER run --rm -v ${PREFIX}-vol:/data "$BASE" sh -c 'echo persisted > /data/f' >/dev/null 2>&1
  assert_contains "named volume persists across containers" "persisted" \
    "$($DOCKER run --rm -v ${PREFIX}-vol:/data "$BASE" cat /data/f 2>&1)"
fi

if want "virtiofs"; then section "VirtioFS bind mount (-v host path)"
  # Must live inside a configured share. `mktemp -d` lands in /var/folders, which is NOT
  # shared, so probing there only ever proved that unshared paths don't mount.
  SHARE_DIR="$HOME/.velox-e2e-share"
  mkdir -p "$SHARE_DIR"; echo host-file-content > "$SHARE_DIR/hostfile"
  out="$($DOCKER run --rm -v "$SHARE_DIR:/mnt" "$BASE" cat /mnt/hostfile 2>/dev/null)"
  if [ "$out" = "host-file-content" ]; then
    ok "host file is readable in the container"
    $DOCKER run --rm -v "$SHARE_DIR:/mnt" "$BASE" sh -c 'echo from-container > /mnt/written' >/dev/null 2>&1
    assert "container writes are visible on the host" "from-container" "$(cat "$SHARE_DIR/written" 2>/dev/null)"
  else
    bad "host file is readable in the container" "got [$out] — is $SHARE_DIR inside a configured share?"
  fi
  rm -rf "$SHARE_DIR"
fi

if want "port"; then section "published ports (TCP v4/v6/localhost)"
  $DOCKER run -d --name ${PREFIX}-web -p 18080:80 "$BASE" \
    sh -c 'while :; do printf "HTTP/1.1 200 OK\r\nContent-Length: 8\r\n\r\nvelox-ok" | nc -l -p 80 -s 0.0.0.0; done' >/dev/null 2>&1
  sleep 3
  assert "IPv4 127.0.0.1:18080"  "velox-ok" "$(curl -s --max-time 5 http://127.0.0.1:18080/ 2>/dev/null)"
  assert "IPv6 [::1]:18080"      "velox-ok" "$(curl -s --max-time 5 'http://[::1]:18080/' 2>/dev/null)"
  # the actual bug class: macOS resolves localhost to ::1 first
  assert "localhost:18080 (v6-first resolve)" "velox-ok" "$(curl -s --max-time 5 http://localhost:18080/ 2>/dev/null)"
  $DOCKER rm -f ${PREFIX}-web >/dev/null 2>&1
fi

if want "udp"; then section "published ports (UDP)"
  # A SEPARATE published port + container per family. `nc -u -l … -e /bin/cat` serves exactly
  # one client and then exits for the shell loop to restart it, so probing v4 and v6 against
  # the same listener made the second probe land in the restart gap — which looked exactly
  # like "v6 is broken" and is not.
  udp_echo(){ # <name> <hostport>
    $DOCKER run -d --name "$1" -p "$2:9/udp" "$BASE" \
      sh -c 'while :; do nc -u -l -p 9 -s 0.0.0.0 -e /bin/cat; done' >/dev/null 2>&1
  }
  udp_echo ${PREFIX}-udp4 18081
  udp_echo ${PREFIX}-udp6 18082
  sleep 3
  assert "UDP over IPv4" "udp-ping" \
    "$(printf 'udp-ping' | nc -4 -u -w 3 127.0.0.1 18081 2>/dev/null | head -c 8)"
  # macOS resolves `localhost` to ::1 first, so this is the case users actually hit.
  assert "UDP over IPv6" "udp-ping" \
    "$(printf 'udp-ping' | nc -6 -u -w 3 ::1 18082 2>/dev/null | head -c 8)"
  $DOCKER rm -f ${PREFIX}-udp4 ${PREFIX}-udp6 >/dev/null 2>&1
fi

if want "named"; then section "named access (<name>.velox.local)"
  $DOCKER run -d --name ${PREFIX}-named "$BASE" sleep 300 >/dev/null 2>&1
  sleep 3
  ip="$($DOCKER inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' ${PREFIX}-named 2>/dev/null)"
  resolved="$(dscacheutil -q host -a name ${PREFIX}-named.velox.local 2>/dev/null | awk '/ip_address/{print $2; exit}')"
  if [ -n "$resolved" ]; then assert "DNS resolves to the container IP" "$ip" "$resolved"
  else bad "DNS resolves to the container IP" "no answer for ${PREFIX}-named.velox.local"; fi
  if [ -n "$ip" ]; then
    $DOCKER run --rm "$BASE" sh -c "ping -c1 -W2 $ip >/dev/null 2>&1" && ok "container IP is pingable from another container" \
      || skip "container IP reachability" "ICMP blocked"
  fi
  $DOCKER rm -f ${PREFIX}-named >/dev/null 2>&1
fi

if want "network"; then section "user-defined networks + DNS between containers"
  $DOCKER network create ${PREFIX}-net >/dev/null 2>&1
  $DOCKER run -d --name ${PREFIX}-peer --network ${PREFIX}-net "$BASE" sleep 300 >/dev/null 2>&1
  sleep 2
  # Assert the resolved ADDRESS, not a substring of nslookup's layout: its trailing blank
  # "Non-authoritative answer:" block meant `tail -3` sometimes clipped past the Name line,
  # so this reported a failure while resolution was working perfectly.
  peer_ip="$($DOCKER inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' ${PREFIX}-peer 2>/dev/null)"
  resolved_ip="$($DOCKER run --rm --network ${PREFIX}-net "$BASE" \
    nslookup ${PREFIX}-peer 2>/dev/null | awk '/^Address: /{a=$2} END{print a}')"
  assert "container resolves a peer by name on a user-defined network" "$peer_ip" "$resolved_ip"
  assert_contains "peer is reachable by name" "1 packets received" \
    "$($DOCKER run --rm --network ${PREFIX}-net "$BASE" ping -c1 -W2 ${PREFIX}-peer 2>&1 | tail -2)"
  $DOCKER rm -f ${PREFIX}-peer >/dev/null 2>&1
fi

if want "egress"; then section "container egress (vmnet NAT + guest DNS)"
  assert_contains "DNS resolves an external name" "Address" \
    "$($DOCKER run --rm "$BASE" nslookup github.com 2>&1 | tail -4)"
  fwd="$(sysctl -n net.inet.ip.forwarding 2>/dev/null)"
  assert "host IP forwarding is on (vmnet datapath)" "1" "$fwd"
fi

if want "rosetta"; then section "Rosetta x86 emulation"
  # Pull first: pull progress goes to stderr, and folding it into the captured output made a
  # working Rosetta look like a failure.
  $DOCKER pull -q --platform linux/amd64 "$BASE" >/dev/null 2>&1
  arch="$($DOCKER run --rm --platform linux/amd64 "$BASE" uname -m 2>/dev/null | tr -d '\r\n')"
  if [ -n "$arch" ]; then assert "amd64 image runs under Rosetta" "x86_64" "$arch"
  else skip "Rosetta x86" "amd64 container did not run"; fi
fi

if want "compose"; then section "compose + buildx plugins"
  if $DOCKER compose version >/dev/null 2>&1; then
    ok "docker compose plugin present ($($DOCKER compose version --short 2>/dev/null))"
    mkdir -p "$TMP/proj"
    cat > "$TMP/proj/compose.yaml" <<EOF
services:
  app:
    image: $BASE
    command: sleep 60
EOF
    if (cd "$TMP/proj" && $DOCKER compose -p ${PREFIX}-compose up -d >/dev/null 2>&1); then
      assert "compose up starts a service" "running" \
        "$($DOCKER inspect -f '{{.State.Status}}' ${PREFIX}-compose-app-1 2>/dev/null)"
      (cd "$TMP/proj" && $DOCKER compose -p ${PREFIX}-compose down >/dev/null 2>&1)
    else bad "compose up starts a service"; fi
  else skip "docker compose" "plugin not installed"; fi
  $DOCKER buildx version >/dev/null 2>&1 && ok "docker buildx plugin present ($($DOCKER buildx version 2>/dev/null | awk '{print $2}'))" \
    || skip "docker buildx" "plugin not installed"
fi

if want "conduit"; then section "conduit guard (container must not reach the pool)"
  out="$($DOCKER run --rm "$BASE" sh -c 'nc -z -w 3 192.168.64.1 2379 && echo REACHABLE || echo blocked' 2>&1 | tail -1)"
  assert "container cannot reach GATEWAY:2379" "blocked" "$out"
  out2="$($DOCKER run --rm "$BASE" sh -c 'nc -z -w 3 192.168.64.1 53 && echo ok || echo no' 2>&1 | tail -1)"
  assert "other gateway ports still reachable (no collateral damage)" "ok" "$out2"
fi

if want "clock"; then section "guest clock (host-authoritative, no RTC)"
  gt="$($DOCKER run --rm "$BASE" date +%s 2>/dev/null | tr -d '\r')"
  ht="$(date +%s)"
  if [ -n "$gt" ]; then
    d=$(( gt > ht ? gt - ht : ht - gt ))
    [ "$d" -le 5 ] && ok "guest clock within ${d}s of the host" || bad "guest clock drift ${d}s"
  else bad "guest clock readable"; fi
fi

if want "clockdrift"; then section "guest clock drift correction (the sleep/wake path)"
  # `ClockSync` pushes host time on NSWorkspace.didWake AND on a 60 s backstop timer. Sleep
  # can't be forced safely from a test, but the *correction* is the same code path either
  # way: skew the guest clock, then wait for the next push and confirm it is pulled back.
  # vinit only re-sets on large drift, so skew by an hour.
  $DOCKER run --rm --privileged "$BASE" date -s "$(date -u -v+1H '+%Y-%m-%d %H:%M:%S')" >/dev/null 2>&1
  skewed="$($DOCKER run --rm "$BASE" date +%s 2>/dev/null | tr -d '\r')"
  host="$(date +%s)"
  drift=$(( skewed > host ? skewed - host : host - skewed ))
  if [ "$drift" -lt 600 ]; then
    skip "clock drift correction" "could not skew the guest clock (drift only ${drift}s)"
  else
    ok "guest clock skewed by ${drift}s"
    printf '        waiting up to 90s for the next ClockSync push...\n'
    corrected=0
    for _ in $(seq 1 18); do
      sleep 5
      g="$($DOCKER run --rm "$BASE" date +%s 2>/dev/null | tr -d '\r')"; h="$(date +%s)"
      d=$(( g > h ? g - h : h - g ))
      if [ "$d" -le 5 ]; then corrected=1; break; fi
    done
    [ "$corrected" = 1 ] && ok "host re-synced the guest clock (drift back within 5s)" \
                         || bad "host re-synced the guest clock" "still drifting after 90s"
  fi
fi

if want "nested"; then section "nested virtualization capability"
  # The toggle itself needs a config change + VM restart, so this only reports the host
  # capability the Settings switch is gated on.
  if [ -x "$HOME/.velox/bin/velox" ]; then
    ok "host reports: $(sysctl -n machdep.cpu.brand_string 2>/dev/null) (VZ nested virt is M3+)"
  else skip "nested virtualization" "velox CLI not on PATH"; fi
  case "$($DOCKER run --rm "$BASE" sh -c 'test -e /dev/kvm && echo yes || echo no' 2>/dev/null)" in
    yes) ok "/dev/kvm present in the guest (nested virt enabled)" ;;
    *)   skip "/dev/kvm in the guest" "nestedVirtualization is off in config (default)" ;;
  esac
fi

if want "resource"; then section "resource accounting"
  $DOCKER run -d --name ${PREFIX}-stats "$BASE" sleep 120 >/dev/null 2>&1
  sleep 2
  assert_contains "docker stats reports the container" "${PREFIX}-stats" \
    "$($DOCKER stats --no-stream --format '{{.Name}}' 2>/dev/null | head -20)"
  assert_contains "system df reports volume sizes" "VOLUME NAME" "$($DOCKER system df -v 2>&1)"
  $DOCKER rm -f ${PREFIX}-stats >/dev/null 2>&1
fi

if want "updater"; then section "updater (check only — never applies)"
  if [ -x "$HOME/.velox/bin/velox" ]; then
    out="$("$HOME/.velox/bin/velox" update 2>&1 | head -3)"
    case "$out" in
      *up\ to\ date*|*newer*|*available*) ok "velox update reports a result" ;;
      *) bad "velox update reports a result" "$out" ;;
    esac
  else skip "velox update" "CLI not on PATH"; fi
fi

printf '\n----------------------------------------\n'
printf 'passed %d   failed %d   skipped %d\n' "$pass" "$fail" "$skipped"
[ "$fail" -eq 0 ] || exit 1
