# Shared action dispatch — maps a Kamal Deploy action name to the actual
# kamal/ruby invocation. Sourced by both run.sh (opens a real terminal, for
# actions that need one) and run-background.sh (captures output for the
# panel's own spinner-then-result view). The caller must define `run_kamal`
# and `die`, and set ACTION/EXTRA/DEST/ENV/PROJECT_DIR, before calling
# dispatch_action.

dispatch_action() {
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
