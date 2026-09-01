# Shared action dispatch — maps a Kamal Deploy action name to the actual
# kamal/ruby invocation. Sourced by both run.sh (opens a real terminal, for
# actions that need one) and run-background.sh (captures output for the
# panel's own spinner-then-result view). The caller must define `run_kamal`
# and `die`, and set ACTION/EXTRA/DEST/ENV/PROJECT_DIR, before calling
# dispatch_action.

# True if $1 is a kamal action that builds and/or pushes a Docker image
# from *this* machine (kamal's build step) rather than just talking to the
# remote host's own docker daemon over SSH like every other action does —
# the one place a stopped local Docker actually breaks a Kamal Deploy
# action. `provision` is a plain ruby/SSH script, not kamal, and doesn't
# touch local docker either, so it's deliberately not included here.
action_requires_docker() {
  case "$1" in
    setup|deploy) return 0 ;;
    *) return 1 ;;
  esac
}

# Local Docker must be reachable before a build/push action runs, or the
# real failure a few seconds into `kamal deploy` is a confusing docker/API
# error rather than "start Docker". Fires a best-effort desktop
# notification (silently skipped if notify-send isn't there, same as
# every other such call in this plugin) and calls the caller's own `die` —
# which either pauses a real terminal or just exits with status 1,
# depending on which of run.sh/run-background.sh sourced this file — so a
# background job comes back "failed" with a clear reason instead of
# whatever kamal itself would have printed.
require_docker_running() {
  docker info >/dev/null 2>&1 && return 0
  notify-send --app-name="Kamal Deploy" --icon=dialog-error --urgency=critical \
    "Kamal Deploy — Docker not running" \
    "Start Docker, then retry ${ACTION:-this action}." >/dev/null 2>&1 || true
  die "Docker isn't running — start it (e.g. 'sudo systemctl start docker') and try again."
}

dispatch_action() {
  action_requires_docker "$ACTION" && require_docker_running

  case "$ACTION" in
    provision)
      if [[ ! -f "$PROJECT_DIR/provision" ]]; then
        die "No provision script in $PROJECT_DIR — run the Provision Wizard for this project first."
      fi
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
      # Defense in depth: Panel.qml already gates every accessory button on
      # this same allowlist, but accessory_logs reaches this through a real
      # terminal launcher (omarchy-launch-or-focus-tui) that reassembles
      # its args unquoted and runs them through `eval` — validate again
      # here so this script is never the only thing standing between a
      # crafted accessory name and shell metacharacters reaching that eval.
      if [[ ! "$EXTRA" =~ ^[A-Za-z0-9_-]+$ ]]; then
        die "Invalid accessory name: $EXTRA"
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
}
