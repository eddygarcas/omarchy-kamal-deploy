#!/usr/bin/env bash
# Runs one Kamal action against one discovered target, inside the terminal
# omarchy-launch-or-focus-tui opened for it. Looks the target up in the cache
# discover.sh just wrote, so the panel never has to smuggle a project path
# (which might contain spaces) through the launcher's word-splitting.
set -uo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/cache-dir.sh"
TARGET_ID="${1:-}"
ACTION="${2:-}"
EXTRA="${3:-}"

bold() { printf '\033[1m%s\033[0m\n' "$1"; }
green() { printf '\033[32m%s\033[0m\n' "$1"; }
red() { printf '\033[31m%s\033[0m\n' "$1"; }
dim() { printf '\033[2m%s\033[0m\n' "$1"; }

pause_exit() {
  echo
  read -n1 -rsp "Press any key to close..."
  echo
  exit "${1:-0}"
}

die() {
  red "$1"
  pause_exit 1
}

if [[ -z "$TARGET_ID" || -z "$ACTION" ]]; then
  red "Usage: run.sh <target_id> <action> [extra]"
  pause_exit 1
fi

cache_dir_is_safe || die "Cache directory unavailable or unsafe: $CACHE_DIR — rescan the Kamal Deploy panel."
cache_file_is_safe || die "No Kamal targets discovered yet — open the Kamal Deploy panel first."

IFS=$'\x01' read -r PROJECT_DIR PROJECT_NAME ENV LABEL <<<"$(read_cache_file | jq -r --arg id "$TARGET_ID" '
  [.[] | . as $p | .environments[] | select(.targetId == $id) | [$p.path, $p.name, .env, .label]] | first // empty | join("")
' 2>/dev/null)"

[[ -z "${PROJECT_DIR:-}" ]] && die "Unknown deploy target — rescan the Kamal Deploy panel and try again."
[[ -d "$PROJECT_DIR" ]] || die "Project folder no longer exists: $PROJECT_DIR"

cd "$PROJECT_DIR" || die "Could not enter $PROJECT_DIR"

source "$(dirname "${BASH_SOURCE[0]}")/ensure-kamal.sh"
ensure_kamal_installed || die "kamal is not on PATH in $PROJECT_DIR, and 'gem install kamal' didn't fix it (check your Ruby/bundler setup)."

DEST=()
[[ -n "$ENV" ]] && DEST=(-d "$ENV")

bold "== ${PROJECT_NAME:-$(basename "$PROJECT_DIR")} . ${LABEL:-default} =="
dim "$PROJECT_DIR"
echo

run_kamal() {
  echo "\$ kamal $*"
  kamal "$@"
}

source "$(dirname "${BASH_SOURCE[0]}")/dispatch.sh"
dispatch_action
status=$?
echo
if [[ $status -eq 0 ]]; then
  green "done"
else
  red "exited with status $status"
fi
pause_exit "$status"
