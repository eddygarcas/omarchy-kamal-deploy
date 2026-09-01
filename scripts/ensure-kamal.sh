# Makes sure the `kamal` gem is on PATH before any action tries to run it.
# Sourced by run.sh and run-background.sh, right where each used to just
# `command -v kamal || die`. If it's missing, installs it with
# `gem install kamal` first — quietly: the install's own output isn't
# useful to the user, only whether the actual action that follows
# succeeds, so it's discarded here rather than mixed into that action's
# own captured output.

# True once `kamal` resolves on PATH, installing the gem first if needed.
ensure_kamal_installed() {
  command -v kamal >/dev/null 2>&1 && return 0
  gem install kamal >/dev/null 2>&1
  command -v kamal >/dev/null 2>&1
}
