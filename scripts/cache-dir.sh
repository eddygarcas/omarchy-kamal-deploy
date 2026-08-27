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
CACHE_FILE_MAX_BYTES=4194304   # 4 MiB — real content is a few KiB at most

# True only if $CACHE_DIR exists, isn't a symlink, and is owned by us —
# the one check that must never be "fixed", only refused: a different
# owner means someone else controls this path, full stop.
cache_dir_is_ours() {
  [[ -d "$CACHE_DIR" && ! -L "$CACHE_DIR" ]] || return 1
  local owner
  owner="$(stat -c '%u' "$CACHE_DIR" 2>/dev/null)" || return 1
  [[ "$owner" == "$UID" ]]
}

# Full safety check: ours AND locked to owner-only (0700). Loose
# permissions alone on a directory we already own — e.g. one created by
# an older version of this plugin, before this was enforced, with
# whatever the ambient umask produced — aren't a sign of tampering the
# way a wrong owner is, so they're safe to self-heal (see
# ensure_cache_dir_safe) rather than refuse outright.
cache_dir_is_safe() {
  cache_dir_is_ours || return 1
  local perm
  perm="$(stat -c '%a' "$CACHE_DIR" 2>/dev/null)" || return 1
  [[ "$perm" == "700" ]]
}

# Creates $CACHE_DIR if missing and tightens it to owner-only if we
# already own it (mkdir -p's own -m only applies on *creation*, so an
# existing directory from before this permission was enforced needs an
# explicit chmod too). Only discover.sh, the sole writer, should call
# this — readers just check cache_dir_is_safe.
ensure_cache_dir_safe() {
  mkdir -p "$CACHE_DIR" 2>/dev/null
  cache_dir_is_ours && chmod 700 "$CACHE_DIR" 2>/dev/null
  cache_dir_is_safe
}

# $CACHE_DIR being owner-only already means no other user could have
# planted anything at $CACHE_FILE's path in the first place — but this is
# cheap, so check explicitly anyway rather than lean entirely on that:
# bash has no direct equivalent of opening with O_NOFOLLOW, so this
# check-then-read is the closest approximation, done immediately before
# every read rather than once up front.
cache_file_is_safe() {
  [[ -f "$CACHE_FILE" && ! -L "$CACHE_FILE" ]]
}

# Writes $1 to $CACHE_FILE without ever opening that path directly for
# writing — the temp file is created fresh (mktemp, mode 0600, O_EXCL)
# in the same already-validated directory, then `mv` (rename(2)) swaps
# it into place atomically. rename() replaces whatever is at the
# destination — including a symlink — as a directory-entry swap; it
# never follows one. Requires cache_dir_is_safe to already hold.
write_cache_file() {
  local tmp
  tmp="$(mktemp "$CACHE_DIR/.targets.json.XXXXXX")" || return 1
  printf '%s' "$1" > "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$CACHE_FILE"
}

# Reads $CACHE_FILE bounded by CACHE_FILE_MAX_BYTES, having already
# confirmed it's a real file (not a symlink) via cache_file_is_safe.
read_cache_file() {
  head -c "$CACHE_FILE_MAX_BYTES" -- "$CACHE_FILE"
}
