#!/usr/bin/env bash
# Fast-forwards this plugin's own install directory to the latest commit
# on GitHub. Only does anything if this install actually IS the git clone
# the README's install instructions produce — never touches files
# directly, never force-pushes/resets/rebases. Run as a background job
# from the panel's "Update available" button, same as any Kamal action —
# see run-background.sh for why that path has no colors/pause of its own.
set -uo pipefail

PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BRANCH="main"

die() {
  echo "$1" >&2
  exit 1
}

cd "$PLUGIN_DIR" || die "Could not enter $PLUGIN_DIR"

git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || die "This install isn't a git checkout — can't self-update. Re-clone from the repo, or download the latest release manually."

git remote get-url origin >/dev/null 2>&1 \
  || die "No 'origin' remote configured — can't tell where to update from."

if [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then
  die "Local changes present in $PLUGIN_DIR — resolve or stash them before updating (an automatic update won't overwrite them)."
fi

old_version="$(jq -r '.version // "unknown"' manifest.json 2>/dev/null)"

echo "\$ git fetch origin $BRANCH"
git fetch origin "$BRANCH" || die "Fetch failed — check your network connection."

echo "\$ git merge --ff-only origin/$BRANCH"
git merge --ff-only "origin/$BRANCH" \
  || die "Can't fast-forward — local history has diverged from origin/$BRANCH. Update manually (git log, git merge/rebase) to resolve."

new_version="$(jq -r '.version // "unknown"' manifest.json 2>/dev/null)"

if [[ "$old_version" == "$new_version" ]]; then
  echo "Already up to date (v$old_version)."
else
  echo "Updated v$old_version -> v$new_version."
fi
echo
echo "Restart the shell to load the new code: omarchy restart shell"
