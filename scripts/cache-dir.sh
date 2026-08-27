# Resolves CACHE_DIR/CACHE_FILE for the discovered-targets cache, and
# validates that whichever directory gets used is actually safe to trust.
# Sourced by discover.sh (the only writer) and run.sh/run-background.sh
# (readers) so all three agree on both the path and the safety check.
#
# $XDG_RUNTIME_DIR is owner-only (mode 0700, systemd-managed) on any real
# desktop session, so the normal case is already safe. The /tmp fallback
# only matters when it's unset, and /tmp is world-writable — another local
# user could pre-create a directory (or plant a symlink) at that
# predictable path before we ever get to it, either to read what we write
# there or to feed run.sh/run-background.sh a poisoned targets.json
# (which they'd otherwise trust blindly, since it decides which project
# directory a clicked target's kamal/ruby command actually runs in).
if [[ -n "${XDG_RUNTIME_DIR:-}" ]]; then
  CACHE_DIR="$XDG_RUNTIME_DIR/eduard.kamal-deploy"
else
  CACHE_DIR="/tmp/eduard.kamal-deploy-$UID"
fi
CACHE_FILE="$CACHE_DIR/targets.json"

cache_dir_is_safe() {
  [[ -d "$CACHE_DIR" && ! -L "$CACHE_DIR" ]] || return 1
  local owner perm
  owner="$(stat -c '%u' "$CACHE_DIR" 2>/dev/null)" || return 1
  perm="$(stat -c '%a' "$CACHE_DIR" 2>/dev/null)" || return 1
  [[ "$owner" == "$UID" ]] || return 1
  [[ "$perm" == "700" ]] || return 1
  return 0
}
