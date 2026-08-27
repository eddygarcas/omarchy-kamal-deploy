#!/usr/bin/env bash
# Directory-only path completion for the panel's folder fields — Tab in a
# terminal, basically. Outputs one absolute path per matching subdirectory,
# sorted, no trailing slash. Restricted to $HOME like every other path in
# this plugin: not just a write-safety rule here, but there's nothing useful
# to complete outside it either.
set -uo pipefail

PARTIAL="${1:-}"
expanded="${PARTIAL/#\~/$HOME}"

if [[ -z "$expanded" ]]; then
  base_dir="$HOME"
  prefix=""
elif [[ "$expanded" == */ ]]; then
  base_dir="${expanded%/}"
  prefix=""
else
  base_dir="$(dirname -- "$expanded")"
  prefix="$(basename -- "$expanded")"
fi

resolved_base="$(realpath -m -- "$base_dir" 2>/dev/null)"
if [[ -z "$resolved_base" || ( "$resolved_base" != "$HOME" && "$resolved_base" != "$HOME"/* ) ]]; then
  exit 0
fi

[[ -d "$resolved_base" ]] || exit 0

shopt -s nullglob
for entry in "$resolved_base"/"$prefix"*/; do
  [[ -d "$entry" ]] || continue
  echo "${entry%/}"
done | sort
