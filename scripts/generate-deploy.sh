#!/usr/bin/env bash
# Renders templates/deploy.erb — plus the static, byte-for-byte-verbatim
# tail of Kamal's own `kamal init` template (proxy/registry/builder/env/
# aliases/ssh/volumes/accessories guidance) for a brand-new base config —
# into config/deploy.yml or config/deploy.<env>.yml.
set -uo pipefail

TARGET_DIR="${1:-}"
ENV_NAME="${2:-}"
OPTIONS_JSON="${3:-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE="$SCRIPT_DIR/../templates/deploy.erb"
TAIL="$SCRIPT_DIR/../templates/deploy-tail.yml"

if [[ -z "$TARGET_DIR" || -z "$OPTIONS_JSON" ]]; then
  echo "Usage: generate-deploy.sh <target_dir> <env> <options_json>" >&2
  exit 1
fi

command -v ruby >/dev/null 2>&1 || { echo "ruby not found on PATH" >&2; exit 1; }
[[ -f "$TEMPLATE" ]] || { echo "Missing template: $TEMPLATE" >&2; exit 1; }

expanded="${TARGET_DIR/#\~/$HOME}"

# Safety baseline: this writes a file, so the target must resolve inside
# $HOME — resolved via realpath (follows `..` segments) rather than a
# string prefix, matching every other script in this plugin.
resolved="$(realpath -m -- "$expanded" 2>/dev/null)"
if [[ -z "$resolved" || ( "$resolved" != "$HOME" && "$resolved" != "$HOME"/* ) ]]; then
  echo "Refusing to write outside your home folder ($HOME): $expanded" >&2
  exit 1
fi
expanded="$resolved"

config_dir="$expanded/config"
include_header=true
if [[ -z "$ENV_NAME" ]]; then
  out_file="$config_dir/deploy.yml"
else
  out_file="$config_dir/deploy.$ENV_NAME.yml"
  include_header=false
fi

# Never let a minimal, servers-only render clobber a real base config — a
# named environment overriding an existing base is normal and expected
# (that's what deploy.<env>.yml is for), but "regenerate the base" only
# makes sense when there isn't a real one there yet.
if [[ -z "$ENV_NAME" && -f "$config_dir/deploy.yml" ]]; then
  echo "config/deploy.yml already exists — edit it directly, or generate a named environment (e.g. staging) instead." >&2
  exit 1
fi

mkdir -p "$config_dir" || { echo "Could not create folder: $config_dir" >&2; exit 1; }

ruby -r erb -r json -e '
  json_text, template_path, tail_path, include_header_flag, out_file = ARGV
  begin
    opts = JSON.parse(json_text)
  rescue JSON::ParserError => e
    warn "Invalid options JSON: #{e.message}"
    exit 1
  end
  opts["include_header"] = (include_header_flag == "true")
  template = File.read(template_path)
  erb = ERB.new(template, trim_mode: "-")
  erb.filename = template_path
  begin
    rendered = erb.result_with_hash(opts.transform_keys(&:to_sym))
  rescue NameError => e
    warn "Template needs a value the wizard did not send: #{e.message}"
    exit 1
  end
  if opts["include_header"] && File.exist?(tail_path)
    rendered = rendered.rstrip + "\n\n" + File.read(tail_path)
  end
  File.write(out_file, rendered)
  puts out_file
' "$OPTIONS_JSON" "$TEMPLATE" "$TAIL" "$include_header" "$out_file"
