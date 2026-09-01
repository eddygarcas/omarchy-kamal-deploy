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

source "$(dirname "${BASH_SOURCE[0]}")/cache-dir.sh"
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

run_kamal() {
  echo "\$ kamal $*"
  kamal "$@"
}

source "$(dirname "${BASH_SOURCE[0]}")/dispatch.sh"

# dispatch_action's stdout/stderr feed a Quickshell StdioCollector with no
# size limit of its own, inside the long-lived, shared omarchy-shell
# process — a misbehaving/compromised remote server (kamal talks to
# whatever host config/deploy.yml points at) echoing enough output could
# otherwise grow that persistent process's memory unbounded, or fill /tmp
# if buffered through a file with no cap while it runs. Cap each stream
# while it's still being produced: pipe stdout/stderr through `head -c`,
# which stops reading once it hits the limit and exits, closing its end
# of the pipe — the next write from a still-producing child (kamal) then
# hits a closed pipe and is killed by SIGPIPE, so a runaway target can't
# grow storage past the cap. Land the capped output in unpredictable
# (mktemp, mode 0600) temp files rather than piping straight to our own
# stdout/stderr, so a mid-write kill can't interleave partial lines from
# the two streams.
MAX_OUTPUT=65536
out_file="$(mktemp)" || die "Could not create a temp file for output capture."
err_file="$(mktemp)" || die "Could not create a temp file for output capture."
trap 'rm -f "$out_file" "$err_file"' EXIT

dispatch_action \
  > >(head -c "$MAX_OUTPUT" >"$out_file") \
  2> >(head -c "$MAX_OUTPUT" >"$err_file")
status=$?
wait

cat "$out_file"
cat "$err_file" >&2

exit "$status"
