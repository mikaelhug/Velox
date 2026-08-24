#!/usr/bin/env bash
# Velox upstream-maintenance scout: detect newer MINOR/MAJOR Linux-kernel,
# Docker-engine, and Docker CLI-plugin (compose + buildx) releases, rewrite the
# pins in versions.env, and print a machine-readable summary. Driven weekly by
# .github/workflows/version-watch.yml; also runnable locally (--dry-run) to preview.
#
# Policy (see CLAUDE.md §9 and the plan):
#   * Kernel  — track the NEWEST MAINLINE STABLE line (kernel.org latest_stable),
#               NOT a pinned LTS. Take ANY newer release, including in-line stable
#               patches (6.18.35 -> 6.18.36), and always the newest one upstream
#               offers — so a new line wins over a patch (6.18.35 -> 7.1.3).
#   * Docker  — same rule on the static-stable channel (29.5.3 -> 29.5.4 patch,
#               29.5.3 -> 29.6.1 minor, 29.x -> 30.0.0 major).
#   * Compose/Buildx — the host CLI plugins, same major.minor rule, discovered from
#               each project's GitHub releases/latest (docker/compose, docker/buildx).
#   * VELOX_VERSION — MINOR bump when a kernel/docker line moved (0.3.1 -> 0.4.0),
#               PATCH bump when the batch is only in-line patches (0.3.1 -> 0.3.2),
#               derived from the
#               value on the current branch so re-runs are idempotent.
#
# Patches ARE auto-pulled, so in-line kernel/Docker point releases — which carry
# CVE and bugfix content — reach users without a hand-bump. The cost is more
# releases; the weekly cap (Mon 07:00 UTC) keeps that bounded, and a batch that is
# only patches produces a patch-level Velox release. See CLAUDE.md §9.
#
# Requires: bash, curl, jq, shasum/sha256sum. No repo mutation beyond versions.env.
#
# Usage:
#   ./Scripts/check-upstream.sh            # rewrite versions.env in place if a bump is due
#   ./Scripts/check-upstream.sh --dry-run  # discover + compute SHAs, but touch nothing
set -euo pipefail
cd "$(dirname "$0")/.."

DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

command -v jq >/dev/null 2>&1 || { echo "error: jq is required (brew install jq)" >&2; exit 1; }
# shasum (macOS) or sha256sum (Linux) — normalise to a single function.
if command -v shasum >/dev/null 2>&1; then _sha(){ shasum -a 256 | cut -d' ' -f1; }
elif command -v sha256sum >/dev/null 2>&1; then _sha(){ sha256sum | cut -d' ' -f1; }
else echo "error: need shasum or sha256sum" >&2; exit 1; fi
# gpg verifies kernel.org's sha256sums.asc before any hash in it is trusted (see k_pinnable).
# Preflight it like jq: without this the kernel path failed with two bare import errors.
command -v gpg >/dev/null 2>&1 || { echo "error: gpg is required to verify kernel.org signatures (brew install gnupg)" >&2; exit 1; }

set -a; . ./versions.env; set +a

# GitHub API GET (authenticated when GITHUB_TOKEN is set, to dodge the 60/hr
# anonymous rate limit in CI). A function, not a `curl … ${arr[@]}`, so it stays
# safe under `set -u` on macOS's bash 3.2 (empty-array expansion would fault).
gh_curl(){ # <url>
  if [ -n "${GITHUB_TOKEN:-}" ]; then curl -fsSL -H "Authorization: Bearer ${GITHUB_TOKEN}" "$1"
  else curl -fsSL "$1"; fi
}

# --- version helpers -------------------------------------------------------
mm(){ printf '%s' "$1" | cut -d. -f1-2; }          # 6.18.35 -> 6.18
maj(){ printf '%s' "${1%%.*}"; }                    # 6.18.35 -> 6
# newer CUR CAND -> true iff CAND is strictly greater (semantic sort).
newer(){ [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" = "$2" ]; }
# In-line stable patches ARE taken. They were skipped originally to keep releases
# few and meaningful, but that also meant upstream bugfixes and CVEs sat unshipped
# until the next minor line — and a dockerd nftables endpoint-rollback bug (which
# corrupts a user-defined network's state and cascades across a whole stack) made
# the cost of waiting concrete. The candidate is always the newest version upstream
# offers, so if a newer minor/major exists it is chosen over a patch automatically:
# there is no "highest patch of the old line" path to fall into.
# blocked COMPONENT VERSION -> true iff that exact version is on the deny list.
#
# `rollback.yml` restores a previous tag's pins when a shipped upstream version turns out to
# be broken — but nothing recorded WHY, so the next weekly run saw the (now lower) pin, found
# the bad version "newer", re-validated it (compile-only, which is exactly what missed the
# problem the first time) and re-shipped it to the whole fleet. The documented recovery path
# had a one-week half-life. rollback.yml now appends to these lists.
blocked(){
  local list
  case "$1" in
    kernel)  list="${KERNEL_ORG_BLOCKED:-}" ;;
    docker)  list="${DOCKER_BLOCKED:-}" ;;
    compose) list="${DOCKER_COMPOSE_BLOCKED:-}" ;;
    buildx)  list="${DOCKER_BUILDX_BLOCKED:-}" ;;
    qemu)    list="${QEMU_USER_BLOCKED:-}" ;;
    *)       return 1 ;;
  esac
  case " $list " in *" $2 "*) return 0 ;; esac
  return 1
}

# classify COMPONENT CUR CAND -> "" (not newer, or blocked) | "patch" | "minor" | "major"
classify(){
  if blocked "$1" "$3"; then
    echo "==> $1 $3 is on the deny list (rolled back previously) — not adopting it" >&2
    printf ''; return
  fi
  shift   # drop the component; the rest of this function compares CUR/CAND as before
  newer "$1" "$2" || { printf ''; return; }
  [ "$(maj "$1")" != "$(maj "$2")" ] && { printf 'major'; return; }
  [ "$(mm "$1")" != "$(mm "$2")" ] && { printf 'minor'; return; }
  printf 'patch'
}
# X.Y.Z -> X.(Y+1).0
bump_minor(){ IFS=. read -r a b _ <<EOF
$1
EOF
printf '%s.%s.0' "$a" "$((b+1))"; }
# X.Y.Z -> X.Y.(Z+1)
bump_patch(){ IFS=. read -r a b c <<EOF
$1
EOF
printf '%s.%s.%s' "$a" "$b" "$((c+1))"; }

# --- portable in-place rewrite of one KEY= line ----------------------------
set_var(){ # KEY VALUE
  local tmp; tmp="$(mktemp)"
  awk -v k="$1" -v v="$2" '$0 ~ "^" k "=" { if (v ~ /[ \t]/) print k "=\"" v "\""; else print k "=" v; next } {print}' versions.env > "$tmp"
  mv "$tmp" versions.env
}

# ===========================================================================
# Discover: kernel (no tarball download — releases.json + signed sha256sums.asc)
# ===========================================================================
echo "==> current pins: kernel ${KERNEL_ORG_VERSION}, docker ${DOCKER_VERSION}, compose ${DOCKER_COMPOSE_VERSION}, buildx ${DOCKER_BUILDX_VERSION}, velox ${VELOX_VERSION}" >&2

# A version is only real to us once its tarball is SIGNED AND PUBLISHED: the
# sha256sums.asc for a major line lists every tarball actually in that directory,
# so it is the source of truth for "can we pin this?". kernel.org announces a
# release in releases.json before the sums propagate to the CDN, and treating that
# window as an error failed the weekly run for days at a time. An announced-but-
# unpublished version is simply "not out yet" — we take the newest one we CAN pin.
# The vendored kernel.org checksum-autosigner public key. Verification used to be claimed
# but never performed: the code parsed the CLEARTEXT body of the clearsigned file and never
# ran `gpg --verify`, so the `.asc` extension bought nothing and every pin this scout writes
# was authenticated by TLS-to-CDN alone. Vendored rather than fetched from a keyserver so
# the build has no keyserver dependency and no trust-on-first-use at run time.
# NB: the sums file is signed by `autosigner@kernel.org`, NOT by the Torvalds/Kroah-Hartman
# release keys that sign the tarballs themselves — measured, and worth knowing before anyone
# "corrects" the fingerprint below.
AUTOSIGNER_FPR=B8868C80BA62A1FFFAF5FDA9632D3A06589DA6B1
AUTOSIGNER_KEY="$(cd "$(dirname "$0")" && pwd)/keys/kernel.org-autosigner.asc"

k_pinnable(){ # <major> -> "<version> <sha>" of the newest published tarball, or ""
  local asc gnupg
  asc="$(mktemp)"; gnupg="$(mktemp -d)"; chmod 700 "$gnupg"
  # shellcheck disable=SC2064
  trap "rm -rf '$asc' '$gnupg'" RETURN
  curl -fsSL "https://cdn.kernel.org/pub/linux/kernel/v$1.x/sha256sums.asc" -o "$asc" 2>/dev/null || return 0
  if ! GNUPGHOME="$gnupg" gpg --batch --quiet --import "$AUTOSIGNER_KEY" 2>/dev/null; then
    echo "error: could not import $AUTOSIGNER_KEY" >&2; return 0
  fi
  # Fail CLOSED: an unverifiable sums file means we cannot authenticate any hash in it, so
  # this whole line is "not pinnable" and the scout falls back / skips the week. That is the
  # same safe direction as the existing announced-but-unpublished handling.
  if ! GNUPGHOME="$gnupg" gpg --batch --quiet --verify "$asc" 2>/dev/null; then
    echo "warning: sha256sums.asc for v$1.x did not verify against $AUTOSIGNER_FPR — refusing to pin from it" >&2
    return 0
  fi
  # Only now trust the contents. `--output` re-emits the verified cleartext.
  GNUPGHOME="$gnupg" gpg --batch --quiet --decrypt "$asc" 2>/dev/null \
    | awk '$2 ~ /^linux-[0-9]+\.[0-9]+(\.[0-9]+)?\.tar\.xz$/ {
             v = $2; sub(/^linux-/, "", v); sub(/\.tar\.xz$/, "", v); print v, $1 }' \
    | sort -V | tail -1
}

KERNEL_UNPINNABLE=0
# The kernel line degrades to "no kernel bump this week"; it must NOT abort the run. Every
# failure here (kernel.org unreachable, releases.json shape change, an autosigner key
# rotation making sha256sums.asc unverifiable) is kernel-specific, and exiting on it also
# blocked the Docker/compose/buildx bumps — which is where CVE fixes usually arrive. Keeping
# the current pin is always safe; skipping Docker security updates for a kernel.org outage
# is not.
K_ANNOUNCED="$(curl -fsSL https://www.kernel.org/releases.json 2>/dev/null | jq -r '.latest_stable.version' 2>/dev/null || true)"
[ "$K_ANNOUNCED" != "null" ] || K_ANNOUNCED=""
K_PICK=""
if [ -n "$K_ANNOUNCED" ]; then
  # Look in the announced line's directory; if that whole line is unpublished, fall
  # back to the line we are already on, which may still have a newer patch for us.
  K_PICK="$(k_pinnable "$(maj "$K_ANNOUNCED")")"
fi
[ -n "$K_PICK" ] || K_PICK="$(k_pinnable "$(maj "$KERNEL_ORG_VERSION")")"
if [ -n "$K_PICK" ]; then
  K_LATEST="${K_PICK%% *}"
  K_SHA_PUBLISHED="${K_PICK##* }"
  [ -z "$K_ANNOUNCED" ] || [ "$K_LATEST" = "$K_ANNOUNCED" ] || \
    echo "==> kernel ${K_ANNOUNCED} is announced but not signed/published yet — newest pinnable is ${K_LATEST}" >&2
  K_KIND="$(classify kernel "$KERNEL_ORG_VERSION" "$K_LATEST")"
else
  echo "::warning::no signed kernel tarball could be pinned (kernel.org unreachable, or sha256sums.asc did not verify against ${AUTOSIGNER_FPR}) — keeping kernel ${KERNEL_ORG_VERSION} and continuing with the Docker components" >&2
  K_LATEST="$KERNEL_ORG_VERSION"
  K_SHA_PUBLISHED="$KERNEL_ORG_SHA256"
  K_KIND=""
  # Surfaced as an output, not just a log line. Fail-soft is right — a kernel.org outage must
  # not block Docker CVE bumps — but a PERSISTENT failure (an autosigner key rotation) would
  # otherwise be a green run every week while the kernel pin quietly stops moving for months,
  # with CLAUDE.md §9 still claiming it is automated. The workflow annotates this.
  KERNEL_UNPINNABLE=1
fi

# ===========================================================================
# Discover: docker (parse the static-stable aarch64 index; SHAs need a download)
# ===========================================================================
D_INDEX="$(curl -fsSL https://download.docker.com/linux/static/stable/aarch64/)"
D_LATEST="$(printf '%s' "$D_INDEX" \
  | grep -oE 'docker-[0-9]+\.[0-9]+\.[0-9]+\.tgz' \
  | sed -E 's/^docker-(.*)\.tgz$/\1/' | sort -V | uniq | tail -1)"
[ -n "$D_LATEST" ] || { echo "error: could not parse a docker version from the static index" >&2; exit 1; }
D_KIND="$(classify docker "$DOCKER_VERSION" "$D_LATEST")"

# ===========================================================================
# Discover: compose + buildx (host CLI plugins) — each project's releases/latest
# (excludes pre-releases/drafts). SHAs need a binary download (done below).
# ===========================================================================
gh_latest(){ # <owner/repo> -> X.Y.Z (strips the leading v); dies on failure
  local tag ver
  tag="$(gh_curl "https://api.github.com/repos/$1/releases/latest" | jq -r '.tag_name')"
  [ -n "$tag" ] && [ "$tag" != "null" ] || { echo "error: could not read latest release for $1" >&2; exit 1; }
  ver="${tag#v}"
  # Git ref names allow $ ( ) ` ; & | and " — and this value is written verbatim into
  # versions.env, which a dozen scripts and workflows `source` as SHELL (and which
  # gen-versions.sh interpolates into a Swift string literal). An upstream tag like
  # `v1.0.0$(curl …|sh)` would execute on the release runner holding the signing key.
  case "$ver" in
    ''|*[!0-9.]*) echo "error: $1 released a non-numeric tag '$tag' — refusing to pin it" >&2; exit 1 ;;
  esac
  printf '%s' "$ver"
}
CP_LATEST="$(gh_latest docker/compose)"
CP_KIND="$(classify compose "$DOCKER_COMPOSE_VERSION" "$CP_LATEST")"
BX_LATEST="$(gh_latest docker/buildx)"
BX_KIND="$(classify buildx "$DOCKER_BUILDX_VERSION" "$BX_LATEST")"

# ===========================================================================
# Discover: qemu-user (the guest's multi-arch emulators) — Debian STABLE only
# ===========================================================================
# Not the shared pool listing: pool/main/q/qemu also holds testing/unstable uploads and
# binNMU rebuilds (`+b1`), and "newest in the pool" would silently adopt one of those. The
# per-suite download page is scoped to stable AND publishes Debian's own SHA-256, so one
# small page gives version + checksum with no 64 MB fetch to discover (we still download to
# confirm the bytes agree with it before pinning — two independent sources, like every other
# pin here). Debian versions are not semver: classify on the upstream part (10.0.11+ds-0+deb13u1
# -> 10.0.11), and treat a same-upstream Debian revision as a patch — that is what a security
# rebuild looks like, and skipping it is exactly the mistake the in-line-patch policy above
# was written to stop making.
q_up(){ printf '%s' "${1%%+*}"; }
Q_KIND=""; Q_LATEST=""; Q_SHA=""; Q_STAMP=""
Q_PAGE="$(curl -fsSL https://packages.debian.org/stable/arm64/qemu-user/download || true)"
Q_FILE="$(printf '%s' "$Q_PAGE" | grep -oE 'qemu-user_[^"<]+_arm64\.deb' | head -1 || true)"
if [ -z "$Q_FILE" ]; then
  echo "==> warning: could not read qemu-user from Debian stable — leaving its pin alone" >&2
else
  Q_LATEST="${Q_FILE#qemu-user_}"; Q_LATEST="${Q_LATEST%_arm64.deb}"
  # This value is written verbatim into versions.env, which a dozen scripts SOURCE as shell
  # (same reasoning as gh_latest above). Debian versions use only [0-9A-Za-z.+~:-].
  case "$Q_LATEST" in
    ''|*[!0-9A-Za-z.+~:-]*) echo "error: refusing to pin a qemu-user version with unexpected characters: '$Q_LATEST'" >&2; exit 1 ;;
  esac
  if [ "$Q_LATEST" = "$QEMU_USER_VERSION" ]; then
    : # already pinned
  elif blocked qemu "$Q_LATEST"; then
    echo "==> qemu-user $Q_LATEST is on the deny list (rolled back previously) — not adopting it" >&2
  else
    q_cur="$(q_up "$QEMU_USER_VERSION")"; q_new="$(q_up "$Q_LATEST")"
    if newer "$q_cur" "$q_new"; then
      if   [ "$(maj "$q_cur")" != "$(maj "$q_new")" ]; then Q_KIND="major"
      elif [ "$(mm  "$q_cur")" != "$(mm  "$q_new")" ]; then Q_KIND="minor"
      else Q_KIND="patch"; fi
    elif [ "$q_cur" = "$q_new" ]; then
      Q_KIND="patch"          # same upstream, new Debian revision — a stable/security rebuild
    else
      echo "==> qemu-user: stable serves an OLDER upstream ($q_new < $q_cur) — not adopting" >&2
    fi
  fi
fi

# ===========================================================================
# Compute new pins for whatever qualifies
# ===========================================================================
K_SHA="" D_GUEST_SHA="" D_MAC_SHA="" CP_SHA="" BX_SHA=""

if [ -n "$K_KIND" ]; then
  # Already read from the signed sums during discovery — a candidate cannot reach
  # here without one, so a blank pin is now impossible by construction.
  K_SHA="$K_SHA_PUBLISHED"
  [ -n "$K_SHA" ] || { echo "error: internal: kernel candidate ${K_LATEST} has no sha" >&2; exit 1; }
  echo "==> kernel ${KERNEL_ORG_VERSION} -> ${K_LATEST} (${K_KIND}); sha ${K_SHA}" >&2
fi

if [ -n "$D_KIND" ]; then
  D_GUEST_URL="https://download.docker.com/linux/static/stable/aarch64/docker-${D_LATEST}.tgz"
  D_MAC_URL="https://download.docker.com/mac/static/stable/aarch64/docker-${D_LATEST}.tgz"
  # The mac client sometimes lags the linux static publish — confirm it exists first.
  curl -fsIL -o /dev/null "$D_MAC_URL" || { echo "error: mac client docker-${D_LATEST}.tgz not published yet — refusing to bump docker this run" >&2; exit 1; }
  echo "==> docker ${DOCKER_VERSION} -> ${D_LATEST} (${D_KIND}); fetching tarballs to hash (~150MB)" >&2
  D_GUEST_SHA="$(curl -fsSL "$D_GUEST_URL" | _sha)"
  D_MAC_SHA="$(curl -fsSL "$D_MAC_URL" | _sha)"
  [ -n "$D_GUEST_SHA" ] && [ -n "$D_MAC_SHA" ] || { echo "error: failed to compute a docker SHA" >&2; exit 1; }
  echo "==> docker guest sha ${D_GUEST_SHA}; mac sha ${D_MAC_SHA}" >&2
fi

# The darwin plugin binaries are on the GitHub release CDN (public, no auth). Note
# the DIFFERENT asset names: compose = docker-compose-darwin-aarch64, buildx =
# buildx-v<ver>.darwin-arm64.
if [ -n "$CP_KIND" ]; then
  CP_URL="https://github.com/docker/compose/releases/download/v${CP_LATEST}/docker-compose-darwin-aarch64"
  curl -fsIL -o /dev/null "$CP_URL" || { echo "error: compose darwin binary for v${CP_LATEST} not published yet — refusing to bump compose this run" >&2; exit 1; }
  echo "==> compose ${DOCKER_COMPOSE_VERSION} -> ${CP_LATEST} (${CP_KIND}); fetching binary to hash (~30MB)" >&2
  CP_SHA="$(curl -fsSL "$CP_URL" | _sha)"
  [ -n "$CP_SHA" ] || { echo "error: failed to compute compose SHA" >&2; exit 1; }
  echo "==> compose sha ${CP_SHA}" >&2
fi

if [ -n "$BX_KIND" ]; then
  BX_URL="https://github.com/docker/buildx/releases/download/v${BX_LATEST}/buildx-v${BX_LATEST}.darwin-arm64"
  curl -fsIL -o /dev/null "$BX_URL" || { echo "error: buildx darwin binary for v${BX_LATEST} not published yet — refusing to bump buildx this run" >&2; exit 1; }
  echo "==> buildx ${DOCKER_BUILDX_VERSION} -> ${BX_LATEST} (${BX_KIND}); fetching binary to hash (~60MB)" >&2
  BX_SHA="$(curl -fsSL "$BX_URL" | _sha)"
  [ -n "$BX_SHA" ] || { echo "error: failed to compute buildx SHA" >&2; exit 1; }
  echo "==> buildx sha ${BX_SHA}" >&2
fi

if [ -n "$Q_KIND" ]; then
  Q_URL="https://deb.debian.org/debian/pool/main/q/qemu/qemu-user_${Q_LATEST}_arm64.deb"
  Q_PAGE_SHA="$(printf '%s' "$Q_PAGE" | sed -n 's|.*SHA256 checksum</th>.*<tt>\([0-9a-f]\{64\}\)</tt>.*|\1|p' | head -1)"
  [ -n "$Q_PAGE_SHA" ] || { echo "error: Debian's download page published no SHA-256 for qemu-user ${Q_LATEST} — refusing to bump qemu this run" >&2; exit 1; }
  echo "==> qemu-user ${QEMU_USER_VERSION} -> ${Q_LATEST} (${Q_KIND}); fetching deb to hash (~64MB)" >&2
  Q_SHA="$(curl -fsSL "$Q_URL" | _sha)"
  [ -n "$Q_SHA" ] || { echo "error: failed to compute the qemu-user SHA" >&2; exit 1; }
  # Two independent sources must agree: Debian's published checksum and the bytes the CDN
  # actually served. A mismatch means a mirror is serving something else — fail, never pin.
  [ "$Q_SHA" = "$Q_PAGE_SHA" ] || { echo "error: qemu-user ${Q_LATEST} SHA mismatch — page ${Q_PAGE_SHA}, download ${Q_SHA}" >&2; exit 1; }
  # The immutable snapshot fallback the guest build uses when the pool URL ages out. The
  # Debian epoch for qemu is 1; if that ever changes the lookup returns nothing and we refuse
  # to bump rather than pin a version whose fallback URL we cannot construct.
  Q_STAMP="$(curl -fsSL "https://snapshot.debian.org/mr/binary/qemu-user/1%3A${Q_LATEST}/binfiles?fileinfo=1" \
             | jq -r '.fileinfo | to_entries[] | .value[] | select(.name | endswith("_arm64.deb")) | .first_seen' | head -1)"
  case "${Q_STAMP:-}" in
    [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9]Z) : ;;
    *) echo "error: no snapshot.debian.org stamp for qemu-user ${Q_LATEST} — refusing to bump qemu this run" >&2; exit 1 ;;
  esac
  echo "==> qemu-user sha ${Q_SHA}; snapshot ${Q_STAMP}" >&2
fi

# ===========================================================================
# Emit outputs + (unless --dry-run) rewrite versions.env
# ===========================================================================
# Velox's own version mirrors the biggest upstream move in the batch: a new
# kernel/docker LINE is a minor bump, a batch of pure in-line patches is a patch
# bump. Keeps `velox version` honest about how much actually moved underneath.
NEW_VELOX=""
case " $K_KIND $D_KIND $CP_KIND $BX_KIND $Q_KIND " in
  *" major "*|*" minor "*) NEW_VELOX="$(bump_minor "$VELOX_VERSION")" ;;
  *" patch "*)             NEW_VELOX="$(bump_patch "$VELOX_VERSION")" ;;
esac

emit(){ # KEY=VALUE to stdout and, in CI, to $GITHUB_OUTPUT
  printf '%s\n' "$1"
  [ -n "${GITHUB_OUTPUT:-}" ] && printf '%s\n' "$1" >> "$GITHUB_OUTPUT"
  return 0
}

if [ -z "$NEW_VELOX" ]; then
  echo "==> up to date — no newer kernel, docker, compose, buildx or qemu-user release." >&2
  emit "changed=false"
  emit "kernel_unpinnable=${KERNEL_UNPINNABLE}"
  exit 0
fi

# Human-readable one-liners (also consumed by the workflow to build the PR body).
[ -n "$K_KIND" ]  && echo "CHANGED kernel ${KERNEL_ORG_VERSION} ${K_LATEST} ${K_KIND}"
[ -n "$D_KIND" ]  && echo "CHANGED docker ${DOCKER_VERSION} ${D_LATEST} ${D_KIND}"
[ -n "$CP_KIND" ] && echo "CHANGED compose ${DOCKER_COMPOSE_VERSION} ${CP_LATEST} ${CP_KIND}"
[ -n "$BX_KIND" ] && echo "CHANGED buildx ${DOCKER_BUILDX_VERSION} ${BX_LATEST} ${BX_KIND}"
[ -n "$Q_KIND" ]  && echo "CHANGED qemu-user ${QEMU_USER_VERSION} ${Q_LATEST} ${Q_KIND}"
echo "VELOX ${VELOX_VERSION} ${NEW_VELOX}"

# Compose a short title the commit/PR/tag reuse, comma-joining whatever changed.
TITLE_PARTS=""
add_part(){ [ -n "$1" ] && TITLE_PARTS="${TITLE_PARTS:+$TITLE_PARTS, }$1"; return 0; }
add_part "${K_KIND:+kernel ${KERNEL_ORG_VERSION}→${K_LATEST}}"
add_part "${D_KIND:+docker ${DOCKER_VERSION}→${D_LATEST}}"
add_part "${CP_KIND:+compose ${DOCKER_COMPOSE_VERSION}→${CP_LATEST}}"
add_part "${BX_KIND:+buildx ${DOCKER_BUILDX_VERSION}→${BX_LATEST}}"
add_part "${Q_KIND:+qemu ${QEMU_USER_VERSION}→${Q_LATEST}}"
TITLE="release: v${NEW_VELOX} — ${TITLE_PARTS}"

emit "changed=true"
emit "kernel_unpinnable=${KERNEL_UNPINNABLE}"
emit "prev_version=${VELOX_VERSION}"
emit "new_version=${NEW_VELOX}"
emit "kernel_from=${KERNEL_ORG_VERSION}"
emit "kernel_to=${K_KIND:+$K_LATEST}"
emit "kernel_kind=${K_KIND}"
emit "docker_from=${DOCKER_VERSION}"
emit "docker_to=${D_KIND:+$D_LATEST}"
emit "docker_kind=${D_KIND}"
emit "compose_from=${DOCKER_COMPOSE_VERSION}"
emit "compose_to=${CP_KIND:+$CP_LATEST}"
emit "compose_kind=${CP_KIND}"
emit "buildx_from=${DOCKER_BUILDX_VERSION}"
emit "buildx_to=${BX_KIND:+$BX_LATEST}"
emit "buildx_kind=${BX_KIND}"
emit "qemu_from=${QEMU_USER_VERSION}"
emit "qemu_to=${Q_KIND:+$Q_LATEST}"
emit "qemu_kind=${Q_KIND}"
emit "title=${TITLE}"

if [ "$DRY_RUN" = "1" ]; then
  echo "==> --dry-run: versions.env NOT modified." >&2
  exit 0
fi

if [ -n "$K_KIND" ]; then
  set_var KERNEL_ORG_VERSION "$K_LATEST"
  set_var KERNEL_ORG_SHA256  "$K_SHA"
fi
if [ -n "$D_KIND" ]; then
  set_var DOCKER_VERSION              "$D_LATEST"
  set_var DOCKER_STATIC_SHA256        "$D_GUEST_SHA"
  set_var DOCKER_CLI_MAC_ARM64_SHA256 "$D_MAC_SHA"
fi
if [ -n "$CP_KIND" ]; then
  set_var DOCKER_COMPOSE_VERSION          "$CP_LATEST"
  set_var DOCKER_COMPOSE_MAC_ARM64_SHA256 "$CP_SHA"
fi
if [ -n "$BX_KIND" ]; then
  set_var DOCKER_BUILDX_VERSION           "$BX_LATEST"
  set_var DOCKER_BUILDX_MAC_ARM64_SHA256  "$BX_SHA"
fi
if [ -n "$Q_KIND" ]; then
  set_var QEMU_USER_VERSION    "$Q_LATEST"
  set_var QEMU_USER_SNAPSHOT   "$Q_STAMP"
  set_var QEMU_USER_DEB_SHA256 "$Q_SHA"
fi
set_var VELOX_VERSION "$NEW_VELOX"
echo "==> versions.env updated (velox ${VELOX_VERSION} -> ${NEW_VELOX})." >&2
