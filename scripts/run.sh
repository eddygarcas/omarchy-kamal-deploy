#!/usr/bin/env bash
# Runs one Kamal action against one discovered target, inside the terminal
# omarchy-launch-or-focus-tui opened for it. Looks the target up in the cache
# discover.sh just wrote, so the panel never has to smuggle a project path
# (which might contain spaces) through the launcher's word-splitting.
set -uo pipefail

CACHE_FILE="${XDG_RUNTIME_DIR:-/tmp}/eduard.kamal-deploy/targets.json"
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

bold "== ${PROJECT_NAME:-$(basename "$PROJECT_DIR")} . ${LABEL:-default} =="
dim "$PROJECT_DIR"
echo

run_kamal() {
  echo "\$ kamal $*"
  kamal "$@"
}

case "$ACTION" in
  provision)
    echo "\$ ruby provision \"$ENV\""
    ruby provision "$ENV"
    ;;
  setup)
    run_kamal setup -v "${DEST[@]}"
    ;;
  deploy)
    run_kamal lock release "${DEST[@]}"
    run_kamal deploy -v "${DEST[@]}"
    ;;
  restart)
    run_kamal app restart "${DEST[@]}"
    ;;
  logs)
    run_kamal app logs -f "${DEST[@]}"
    ;;
  console)
    run_kamal app exec -i 'bin/rails console' "${DEST[@]}"
    ;;
  shell)
    run_kamal app exec -i bash "${DEST[@]}"
    ;;
  rack_attack)
    run_kamal app exec --reuse 'bin/rails rack_attack:status' "${DEST[@]}"
    ;;
  details)
    run_kamal details "${DEST[@]}"
    ;;
  rollback)
    run_kamal rollback "${DEST[@]}"
    ;;
  audit)
    run_kamal audit "${DEST[@]}"
    ;;
  lock_status)
    run_kamal lock status "${DEST[@]}"
    ;;
  lock_release)
    run_kamal lock release "${DEST[@]}"
    ;;
  accessory_boot|accessory_reboot|accessory_stop|accessory_restart|accessory_remove|accessory_logs)
    if [[ -z "$EXTRA" ]]; then
      die "No accessory name given."
    fi
    sub="${ACTION#accessory_}"
    if [[ "$sub" == "reboot" ]]; then
      run_kamal lock release "${DEST[@]}"
      run_kamal accessory reboot "$EXTRA" "${DEST[@]}"
    elif [[ "$sub" == "logs" ]]; then
      run_kamal accessory logs "$EXTRA" -f "${DEST[@]}"
    else
      run_kamal accessory "$sub" "$EXTRA" "${DEST[@]}"
    fi
    ;;
  *)
    die "Unknown action: $ACTION"
    ;;
esac

status=$?
echo
if [[ $status -eq 0 ]]; then
  green "done"
else
  red "exited with status $status"
fi
pause_exit "$status"
