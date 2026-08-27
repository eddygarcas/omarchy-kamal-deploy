#!/usr/bin/env bash
# Same target resolution and action dispatch as run.sh, but for actions
# that always run to completion on their own — no real terminal, no
# colors, no "press any key to close" pause. The panel runs this as a
# background Process, shows a spinner while it's alive, and renders
# whatever it printed once it exits. Actions that need real interactive
# input (Console/Bash shell, Rollback's version picker) or stream forever
# (Tail logs, an accessory's own -f logs) are refused here — those still
# only run through run.sh's real terminal.
set -uo pipefail

CACHE_FILE="${XDG_RUNTIME_DIR:-/tmp}/eduard.kamal-deploy/targets.json"
TARGET_ID="${1:-}"
ACTION="${2:-}"
EXTRA="${3:-}"

die() {
  echo "$1" >&2
  exit 1
}

case "$ACTION" in
  console|shell|logs|accessory_logs|rollback)
    die "This action needs a real terminal — it can't run in the background."
    ;;
esac

[[ -z "$TARGET_ID" || -z "$ACTION" ]] && die "Usage: run-background.sh <target_id> <action> [extra]"

[[ -f "$CACHE_FILE" ]] || die "No Kamal targets discovered yet — open the Kamal Deploy panel first."

IFS=$'\x01' read -r PROJECT_DIR PROJECT_NAME ENV LABEL <<<"$(jq -r --arg id "$TARGET_ID" '
  [.[] | . as $p | .environments[] | select(.targetId == $id) | [$p.path, $p.name, .env, .label]] | first // empty | join("")
' "$CACHE_FILE" 2>/dev/null)"

[[ -z "${PROJECT_DIR:-}" ]] && die "Unknown deploy target — rescan the Kamal Deploy panel and try again."
[[ -d "$PROJECT_DIR" ]] || die "Project folder no longer exists: $PROJECT_DIR"

cd "$PROJECT_DIR" || die "Could not enter $PROJECT_DIR"

command -v kamal >/dev/null 2>&1 || die "kamal is not on PATH in $PROJECT_DIR (check your Ruby/bundler setup)."

DEST=()
[[ -n "$ENV" ]] && DEST=(-d "$ENV")

run_kamal() {
  echo "\$ kamal $*"
  kamal "$@"
}

source "$(dirname "${BASH_SOURCE[0]}")/dispatch.sh"
dispatch_action
exit $?
