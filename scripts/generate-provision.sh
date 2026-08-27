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
mkdir -p "$expanded" || { echo "Could not create folder: $expanded" >&2; exit 1; }

ruby -r erb -r json -e '
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
  File.write(out, rendered)
  puts out
' "$expanded" "$OPTIONS_JSON" "$TEMPLATE"

status=$?
[[ $status -eq 0 ]] && chmod +x "$expanded/provision"
exit $status
