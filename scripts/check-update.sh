#!/usr/bin/env bash
# Compares the installed manifest.json version against the one on this
# plugin's own GitHub repo (main branch, derived from manifest.json's own
# "homepage" field — never hardcoded, so a fork just works). Always exits
# 0 and always prints a JSON object; any failure (offline, GitHub down,
# homepage isn't a github.com URL, jq/curl missing) just reports
# updateAvailable:false rather than surfacing an error in the panel — an
# update check should never be able to break the checklist view.
set -uo pipefail

PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST="$PLUGIN_DIR/manifest.json"

no_update() {
  jq -n --arg current "${1:-}" '{updateAvailable: false, currentVersion: $current, latestVersion: null}'
  exit 0
}

[[ -f "$MANIFEST" ]] || no_update ""
current_version="$(jq -r '.version // empty' "$MANIFEST" 2>/dev/null)"
[[ -n "$current_version" ]] || no_update ""

homepage="$(jq -r '.homepage // empty' "$MANIFEST" 2>/dev/null)"
# https://github.com/<owner>/<repo> -> raw.githubusercontent.com/<owner>/<repo>/main/manifest.json
repo_path="$(printf '%s' "$homepage" | sed -nE 's#^https?://github\.com/([^/]+/[^/]+?)(\.git)?/?$#\1#p')"
[[ -n "$repo_path" ]] || no_update "$current_version"

raw_url="https://raw.githubusercontent.com/${repo_path}/main/manifest.json"
remote_manifest="$(curl -fsSL --max-time 8 "$raw_url" 2>/dev/null)" || no_update "$current_version"
[[ -n "$remote_manifest" ]] || no_update "$current_version"

latest_version="$(printf '%s' "$remote_manifest" | jq -r '.version // empty' 2>/dev/null)"
[[ -n "$latest_version" ]] || no_update "$current_version"

# Numeric per-segment comparison — "1.10.0" must sort after "1.9.0", which
# a plain string/lexical compare would get backwards.
is_newer() {
  local a="$1" b="$2" av bv i an bn
  IFS='.' read -r -a av <<<"$a"
  IFS='.' read -r -a bv <<<"$b"
  for i in 0 1 2; do
    an="${av[$i]:-0}"; bn="${bv[$i]:-0}"
    [[ "$an" =~ ^[0-9]+$ ]] || an=0
    [[ "$bn" =~ ^[0-9]+$ ]] || bn=0
    if (( an > bn )); then return 0; fi
    if (( an < bn )); then return 1; fi
  done
  return 1
}

if is_newer "$latest_version" "$current_version"; then
  jq -n --arg current "$current_version" --arg latest "$latest_version" \
    '{updateAvailable: true, currentVersion: $current, latestVersion: $latest}'
else
  jq -n --arg current "$current_version" --arg latest "$latest_version" \
    '{updateAvailable: false, currentVersion: $current, latestVersion: $latest}'
fi
