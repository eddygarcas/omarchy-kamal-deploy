# Makes sure the `kamal` gem is on PATH before any action tries to run it.
# Sourced by run.sh and run-background.sh, right where each used to just
# `command -v kamal || die`. Deliberately does NOT install it: `gem install
# kamal` would fetch and run whatever's currently published to a mutable
# registry, with no version pin and no user-visible confirmation — the same
# supply-chain shape already rejected for this plugin's own self-update
# path. If it's missing, the caller's die() message tells the user to
# install it themselves.

# True once `kamal` resolves on PATH.
ensure_kamal_installed() {
  command -v kamal >/dev/null 2>&1
}
