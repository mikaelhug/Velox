#!/usr/bin/env bash
# Generate docs/stats.json from GitHub Releases download counts.
#
# Pure GitHub-native adoption stats: NO client-side ping, NO external service, NO
# per-machine tracking. GitHub already tallies a download_count on every release
# asset; every `velox update --apply` pulls the release .zip (Updater.swift) and
# every manual install grabs the .zip/.dmg, so those counters ARE the install +
# update numbers — this script just sums them into a small JSON the landing page
# renders. (Download count != unique machines: a machine that updates N times
# counts N. Counting unique computers would need a phone-home, which we don't do.)
#
# Run by .github/workflows/pages.yml (scheduled daily + on any docs/ change) so the
# deployed site always ships a fresh docs/stats.json. Also runnable locally after
# `gh auth login`. Writes nothing else and never commits — the file is generated
# into the Pages artifact at deploy time (see .gitignore).
set -euo pipefail
cd "$(dirname "$0")/.."

# Repo comes from Actions ($GITHUB_REPOSITORY) or, locally, from versions.env —
# the single source of truth for owner/name (CLAUDE.md §2).
repo="${GITHUB_REPOSITORY:-}"
if [ -z "$repo" ]; then
  set -a; . ./versions.env; set +a
  repo="$VELOX_GITHUB_REPO"
fi

out="docs/stats.json"

# All releases (paginated, newest first); drop drafts. Count ONLY the macOS app
# assets (.zip = in-app auto-update, .dmg = manual install) so the total reads as
# installs+updates — ignore .sig / checksum sidecars. `latest` is the newest
# non-prerelease, and its count is the "how many picked up the current build"
# number. gh + jq are preinstalled on GitHub-hosted runners.
gh api --paginate "repos/$repo/releases" \
  | jq -s --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
      (add // [])
      | map(select(.draft | not)) as $rels
      | def appcount: [.assets[] | select(.name | test("\\.(zip|dmg)$")) | .download_count] | add // 0;
        ($rels | map(appcount) | add // 0) as $total
      | ($rels | map(select(.prerelease | not)) | first) as $latest
      | {
          generated_at: $now,
          total_downloads: $total,
          release_count: ($rels | length),
          latest: (
            if $latest == null then null
            else { version: ($latest.tag_name | ltrimstr("v")), downloads: ($latest | appcount) }
            end
          )
        }
    ' > "$out.tmp"

mv "$out.tmp" "$out"
echo "Wrote $out:"
cat "$out"
