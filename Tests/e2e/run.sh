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
RESOLVER_FILE=/etc/resolver/velox.local
FILTER="${2:-}"; [ "${1:-}" = "-k" ] || FILTER=""

pass=0; fail=0; skipped=0
ok(){   printf '  \033[32mok\033[0m    %s\n' "$1"; pass=$((pass+1)); }
bad(){  printf '  \033[31mFAIL\033[0m  %s\n' "$1"; [ -n "${2:-}" ] && printf '        %s\n' "$2"; fail=$((fail+1)); }
skip(){ printf '  --    %s (%s)\n' "$1" "$2"; skipped=$((skipped+1)); }
section(){ printf '\n== %s ==\n' "$1"; }
want(){ [ -z "$FILTER" ] && return 0; case "$1" in *"$FILTER"*) return 0;; *) return 1;; esac; }

# assert <desc> <expected> <actual>
assert(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2], got [$3]"; fi; }
# assert_contains <desc> <needle> <haystack>
assert_contains(){ case "$3" in *"$2"*) ok "$1";; *) bad "$1" "[$2] not in [$3]";; esac; }

cleanup(){
  # shellcheck disable=SC2046  # deliberate: each id must become its own argument
  $DOCKER rm -f $($DOCKER ps -aq --filter "name=^${PREFIX}" 2>/dev/null) >/dev/null 2>&1
  # shellcheck disable=SC2046
  $DOCKER volume rm -f $($DOCKER volume ls -q --filter "name=^${PREFIX}" 2>/dev/null) >/dev/null 2>&1
  # shellcheck disable=SC2046
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
    # shellcheck disable=SC1007  # deliberate: clear DOCKER_HOST for this one command so the
    # context (not the env var) is what is being exercised.
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

if want "privileged"; then section "privileged published port (<1024, via velox-porthelper)"
  # The regression this exists for: the helper's wildcard bind briefly dropped SO_REUSEADDR,
  # so re-publishing a privileged port within TIME_WAIT of a client connection failed with
  # EADDRINUSE and the client silently fell back to a LOOPBACK bind — `-p 80:80` came back
  # host-only, which is not Docker's default and is invisible unless you look at the listener.
  serve_priv(){ # <name>
    $DOCKER run -d --name "$1" -p 1023:80 "$BASE" \
      sh -c 'while :; do printf "HTTP/1.1 200 OK\r\nContent-Length: 8\r\n\r\nvelox-ok" | nc -l -p 80 -s 0.0.0.0; done' >/dev/null 2>&1
  }
  if ! /usr/bin/pgrep -qf dev.velox.porthelper 2>/dev/null && [ ! -S /var/run/dev.velox.porthelper.sock ]; then
    skip "privileged published port" "porthelper not installed on this Mac"
  else
    serve_priv ${PREFIX}-priv
    sleep 3
    assert "privileged port serves (:1023)" "velox-ok" \
      "$(curl -s --max-time 5 http://127.0.0.1:1023/ 2>/dev/null)"
    bind_addr="$(lsof -nP -iTCP:1023 -sTCP:LISTEN 2>/dev/null | awk 'NR==2{print $9}')"
    case "$bind_addr" in
      \*:1023) ok "bound on ALL interfaces ($bind_addr) — Docker's default publish" ;;
      "") skip "privileged bind address" "lsof reported no listener" ;;
      *) bad "bound on ALL interfaces" "listener is on [$bind_addr] — degraded to host-only" ;;
    esac
    # Recreate INSIDE the TIME_WAIT window left by the curl above. Without SO_REUSEADDR the
    # rebind fails here and the fallback silently makes it loopback-only.
    $DOCKER rm -f ${PREFIX}-priv >/dev/null 2>&1
    serve_priv ${PREFIX}-priv2
    sleep 4
    assert "re-publishes inside TIME_WAIT" "velox-ok" \
      "$(curl -s --max-time 5 http://127.0.0.1:1023/ 2>/dev/null)"
    bind_addr2="$(lsof -nP -iTCP:1023 -sTCP:LISTEN 2>/dev/null | awk 'NR==2{print $9}')"
    case "$bind_addr2" in
      \*:1023) ok "still bound on ALL interfaces after the rebind" ;;
      "") skip "privileged rebind address" "lsof reported no listener" ;;
      *) bad "still bound on ALL interfaces after the rebind" \
             "listener fell back to [$bind_addr2] — the SO_REUSEADDR regression is back" ;;
    esac
    $DOCKER rm -f ${PREFIX}-priv2 >/dev/null 2>&1
  fi
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

if want "negcache"; then section "a name queried BEFORE its container exists recovers (negative cache)"
  # The failure this guards: query `<name>.velox.local` while the container is down (an engine
  # restart, `compose down`, a recreate) and macOS caches the NXDOMAIN. Without an SOA in the
  # authority section mDNSResponder picks its own negative TTL, which is long and sticky, so the
  # name stayed dead long after the container came back — while the responder answered it
  # correctly the whole time. RFC 2308: the negative TTL is the SOA MINIMUM, and it is 1 s.
  $DOCKER rm -f ${PREFIX}-neg >/dev/null 2>&1
  for _ in 1 2 3; do dscacheutil -q host -a name ${PREFIX}-neg.velox.local >/dev/null 2>&1; done
  early="$(dscacheutil -q host -a name ${PREFIX}-neg.velox.local 2>/dev/null | awk '/ip_address/{print $2; exit}')"
  [ -z "$early" ] && ok "the name is NXDOMAIN before the container exists" \
                  || bad "the name is NXDOMAIN before the container exists" "resolved to $early"
  # The responder itself must carry the SOA — check the wire, not just the behaviour.
  if command -v dig >/dev/null 2>&1; then
    soa="$(dig +time=3 +tries=1 @127.0.0.1 -p 49252 ${PREFIX}-neg.velox.local A 2>/dev/null \
           | awk '/AUTHORITY SECTION/{f=1;next} f&&/SOA/{print $NF; exit}')"
    assert "NXDOMAIN carries an SOA with MINIMUM=1" "1" "${soa:-missing}"
  else
    skip "NXDOMAIN carries an SOA" "dig not installed"
  fi
  $DOCKER run -d --name ${PREFIX}-neg "$BASE" sleep 300 >/dev/null 2>&1
  found=""
  for _ in $(seq 1 40); do
    found="$(dscacheutil -q host -a name ${PREFIX}-neg.velox.local 2>/dev/null | awk '/ip_address/{print $2; exit}')"
    [ -n "$found" ] && break; sleep 0.5
  done
  [ -n "$found" ] && ok "the same name resolves within 20s of the container starting ($found)" \
                  || bad "the same name resolves within 20s of the container starting" \
                         "still NXDOMAIN — the negative answer is being cached past its SOA MINIMUM"
  $DOCKER rm -f ${PREFIX}-neg >/dev/null 2>&1
fi

if want "restart"; then section "state SURVIVES an engine restart (regression guard)"
  # Why this section exists, in one sentence: the "named access" test above passed while
  # named access was broken for a real user.
  #
  # It resolved a BRAND-NEW name on an already-settled engine. The bug lived in the state
  # TRANSITION — the DNS responder briefly took an ephemeral port, so every restart rewrote
  # /etc/resolver, and any lookup that failed across that changeover was cached as NXDOMAIN
  # by mDNSResponder and never retried (measured: still failing 90 s later while `dig`
  # straight at the responder answered correctly). A fresh name can never be in that
  # negative cache, so a fresh-name test is structurally incapable of seeing it.
  #
  # The rules this encodes, worth keeping even if the DNS port never changes again:
  #   1. Re-query a name you ALREADY queried, after a restart — not a new one.
  #   2. Assert the INVARIANT the old code documented (the resolver file is static), not
  #      just the behaviour of whatever is currently implemented.
  restart_engine(){
    osascript -e 'tell application "Velox" to quit' >/dev/null 2>&1
    for _ in $(seq 1 300); do pgrep -f "Velox.app/Contents/MacOS/VeloxApp" >/dev/null || break; sleep 0.2; done
    open -a /Applications/Velox.app >/dev/null 2>&1
    for _ in $(seq 1 240); do $DOCKER info >/dev/null 2>&1 && return 0; sleep 1; done
    return 1
  }
  $DOCKER run -d --name ${PREFIX}-persist "$BASE" sleep 600 >/dev/null 2>&1
  sleep 3
  before_ip="$(dscacheutil -q host -a name ${PREFIX}-persist.velox.local 2>/dev/null | awk '/ip_address/{print $2; exit}')"
  [ -n "$before_ip" ] && ok "name resolves before restart ($before_ip)" \
                      || bad "name resolves before restart" "no answer — nothing to compare after"
  # The domain is a fixed constant (Paths.NamedAccess), NOT derived from the test prefix —
  # `${PREFIX%-e2e}velox.local` expanded to "veloxvelox.local" and only ever matched through
  # the fallback, which also meant `before` and `after` could be reading different files.
  resolver_before="$(cat "$RESOLVER_FILE" 2>/dev/null)"
  ctrs_before="$($DOCKER ps -aq | wc -l | tr -d ' ')"

  if restart_engine; then
    ok "engine restarted"
    # THE assertion. Same name, queried again, through the system resolver a browser uses.
    after_ip=""
    for _ in $(seq 1 20); do
      after_ip="$(dscacheutil -q host -a name ${PREFIX}-persist.velox.local 2>/dev/null | awk '/ip_address/{print $2; exit}')"
      [ -n "$after_ip" ] && break; sleep 2
    done
    [ -n "$after_ip" ] && ok "the SAME name still resolves after a restart ($after_ip)" \
                       || bad "the SAME name still resolves after a restart" \
                              "NXDOMAIN via the system resolver — mDNSResponder has cached a failure; \
                               check whether /etc/resolver changed (sudo killall -HUP mDNSResponder to clear)"
    resolver_after="$(cat "$RESOLVER_FILE" 2>/dev/null)"
    assert "/etc/resolver entry is unchanged across a restart" "$resolver_before" "$resolver_after"
    assert "containers survive the restart" "$ctrs_before" "$($DOCKER ps -aq | wc -l | tr -d ' ')"
    # A published port must come back too — the forwarders are rebuilt from scratch.
    $DOCKER rm -f ${PREFIX}-reweb >/dev/null 2>&1
    $DOCKER run -d --name ${PREFIX}-reweb -p 18086:80 "$BASE" \
      sh -c 'while :; do printf "HTTP/1.1 200 OK\r\nContent-Length: 8\r\n\r\nvelox-ok" | nc -l -p 80 -s 0.0.0.0; done' >/dev/null 2>&1
    sleep 3
    assert "a published port works after a restart" "velox-ok" \
      "$(curl -s --max-time 5 http://localhost:18086/ 2>/dev/null)"
    $DOCKER rm -f ${PREFIX}-reweb >/dev/null 2>&1
  else
    bad "engine restarted" "engine did not come back — everything below is unverified"
  fi
  $DOCKER rm -f ${PREFIX}-persist >/dev/null 2>&1
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
