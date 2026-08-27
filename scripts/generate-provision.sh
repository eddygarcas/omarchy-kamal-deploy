#!/usr/bin/env bash
# Renders templates/provision.erb with the Provision Wizard's collected
# options into <target_dir>/provision. Prints the written path on success.
set -uo pipefail

TARGET_DIR="${1:-}"
OPTIONS_JSON="${2:-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE="$SCRIPT_DIR/../templates/provision.erb"

if [[ -z "$TARGET_DIR" || -z "$OPTIONS_JSON" ]]; then
  echo "Usage: generate-provision.sh <target_dir> <options_json>" >&2
  exit 1
fi

command -v ruby >/dev/null 2>&1 || { echo "ruby not found on PATH" >&2; exit 1; }
[[ -f "$TEMPLATE" ]] || { echo "Missing template: $TEMPLATE" >&2; exit 1; }

expanded="${TARGET_DIR/#\~/$HOME}"

# Safety baseline: this writes a file, so the target must resolve inside
# $HOME — resolved via realpath (follows `..` segments) rather than a
# string prefix, so e.g. "~/../../etc" can't sneak past a naive check.
resolved="$(realpath -m -- "$expanded" 2>/dev/null)"
if [[ -z "$resolved" || ( "$resolved" != "$HOME" && "$resolved" != "$HOME"/* ) ]]; then
  echo "Refusing to write outside your home folder ($HOME): $expanded" >&2
  exit 1
fi
expanded="$resolved"

mkdir -p "$expanded" || { echo "Could not create folder: $expanded" >&2; exit 1; }

ruby -r erb -r json -r tempfile -e '
  target, json_text, template_path = ARGV
  begin
    opts = JSON.parse(json_text)
  rescue JSON::ParserError => e
    warn "Invalid options JSON: #{e.message}"
    exit 1
  end
  opts["generated_at"] ||= Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ")
  template = File.read(template_path)
  erb = ERB.new(template, trim_mode: "-")
  erb.filename = template_path
  begin
    rendered = erb.result_with_hash(opts.transform_keys(&:to_sym))
  rescue NameError => e
    warn "Template needs a value the wizard did not send: #{e.message}"
    exit 1
  end
  out = File.join(target, "provision")
  # Regenerating an existing provision script is expected (re-running the
  # wizard always overwrites) — but a plain File.write checks nothing
  # about what is currently at `out`, so a symlink placed there between
  # any earlier check and this write would be followed and clobber
  # whatever it points at instead. Write to a fresh, unpredictably-named
  # temp file in the same directory (Tempfile: mode 0600, created with
  # O_EXCL) and rename(2) it into place — rename replaces the directory
  # entry at `out` atomically, including a symlink, without ever
  # following it.
  tmp = Tempfile.new(".provision.tmp", target)
  begin
    tmp.write(rendered)
    tmp.close
    File.rename(tmp.path, out)
  ensure
    tmp.unlink if File.exist?(tmp.path)
  end
  puts out
' "$expanded" "$OPTIONS_JSON" "$TEMPLATE"

status=$?
[[ $status -eq 0 ]] && chmod +x "$expanded/provision"
exit $status
