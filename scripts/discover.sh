#!/usr/bin/env bash
# Scans one or more folders for Kamal deploy configs (config/deploy.yml and
# config/deploy.<env>.yml), groups them by project, and prints/caches a JSON
# array the panel renders as a task list. Also used by run.sh to resolve a
# clicked target back to a project path + destination flag.
set -uo pipefail

CACHE_DIR="${XDG_RUNTIME_DIR:-/tmp}/eduard.kamal-deploy"
CACHE_FILE="$CACHE_DIR/targets.json"
mkdir -p "$CACHE_DIR"

write_empty() {
  echo "[]" | tee "$CACHE_FILE"
  exit 0
}

# Safety baseline: every search folder must resolve inside $HOME. The panel
# already enforces this when a folder is added, but this scan runs off
# whatever is saved in shell.json, which could predate the check or have
# been hand-edited — so it's re-checked here too, resolving `..` segments
# via realpath rather than trusting a string prefix.
within_home() {
  local resolved
  resolved="$(realpath -m -- "$1" 2>/dev/null)" || return 1
  [[ "$resolved" == "$HOME" || "$resolved" == "$HOME"/* ]]
}

paths=()
for raw in "$@"; do
  [[ -z "$raw" ]] && continue
  expanded="${raw/#\~/$HOME}"
  [[ -d "$expanded" ]] || continue
  within_home "$expanded" || continue
  paths+=("$expanded")
done

[[ ${#paths[@]} -eq 0 ]] && write_empty

files_list="$(mktemp)"
trap 'rm -f "$files_list"' EXIT

for root in "${paths[@]}"; do
  find "$root" \
    -type d \( -name node_modules -o -name .git -o -name vendor -o -name tmp -o -name log -o -name .bundle \) -prune -o \
    -type f -regextype posix-extended -regex '.*/config/deploy(\.[A-Za-z0-9_.-]+)?\.yml' -print \
    2>/dev/null
done | sort -u > "$files_list"

[[ -s "$files_list" ]] || write_empty

project_id() { printf '%s' "$1" | md5sum | cut -c1-10; }
target_id() { printf '%s|%s' "$1" "$2" | md5sum | cut -c1-10; }

service_name() {
  local f="$1" line
  [[ -f "$f" ]] || return 1
  line="$(grep -m1 -E '^service:' "$f" 2>/dev/null)" || return 1
  line="${line#service:}"
  line="$(printf '%s' "$line" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//; s/^"(.*)"$/\1/; s/^'"'"'(.*)'"'"'$/\1/')"
  [[ -n "$line" ]] && printf '%s' "$line"
}

language_of() {
  local dir="$1"
  if [[ -f "$dir/Gemfile" ]]; then echo "ruby"; return; fi
  if [[ -f "$dir/go.mod" ]]; then echo "go"; return; fi
  if [[ -f "$dir/tsconfig.json" ]]; then echo "typescript"; return; fi
  if [[ -f "$dir/package.json" ]]; then echo "node"; return; fi
  echo "generic"
}

accessories_in() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  awk '
    /^accessories:[[:space:]]*$/ { inacc=1; next }
    inacc && /^[^[:space:]]/ { inacc=0 }
    inacc && /^  [A-Za-z0-9_.-]+:/ {
      line=$0
      sub(/^  /, "", line)
      sub(/:.*/, "", line)
      print line
    }
  ' "$f"
}

rows="$(mktemp)"
acc_rows="$(mktemp)"
trap 'rm -f "$files_list" "$rows" "$acc_rows"' EXIT

declare -A project_name_for
declare -A project_base_for

while IFS= read -r file; do
  config_dir="$(dirname "$file")"
  project_dir="$(dirname "$config_dir")"
  base="$(basename "$file")"

  if [[ "$base" == "deploy.yml" ]]; then
    env=""
    label="default"
    project_base_for["$project_dir"]="$file"
  else
    env="${base#deploy.}"
    env="${env%.yml}"
    label="$env"
  fi

  pid="$(project_id "$project_dir")"
  tid="$(target_id "$project_dir" "$env")"

  jq -n --arg pid "$pid" --arg dir "$project_dir" --arg tid "$tid" \
        --arg env "$env" --arg label "$label" --arg file "$file" \
    '{projectId:$pid, projectDir:$dir, targetId:$tid, env:$env, label:$label, file:$file}' >> "$rows"
done < "$files_list"

for project_dir in "${!project_base_for[@]}"; do
  base_file="${project_base_for[$project_dir]}"
  name="$(service_name "$base_file")"
  [[ -z "$name" ]] && name="$(basename "$project_dir")"
  pid="$(project_id "$project_dir")"
  project_name_for["$project_dir"]="$name"

  while IFS= read -r acc; do
    [[ -z "$acc" ]] && continue
    jq -n --arg pid "$pid" --arg acc "$acc" '{projectId:$pid, accessory:$acc}' >> "$acc_rows"
  done < <(accessories_in "$base_file" | sort -u)
done

# Projects whose only discovered file wasn't the base deploy.yml (unusual,
# but possible) still need a display name.
while IFS= read -r file; do
  config_dir="$(dirname "$file")"
  project_dir="$(dirname "$config_dir")"
  [[ -n "${project_name_for[$project_dir]:-}" ]] && continue
  project_name_for["$project_dir"]="$(basename "$project_dir")"
done < "$files_list"

names_json="$(mktemp)"
trap 'rm -f "$files_list" "$rows" "$acc_rows" "$names_json"' EXIT
for project_dir in "${!project_name_for[@]}"; do
  pid="$(project_id "$project_dir")"
  has_provision=false
  [[ -f "$project_dir/provision" ]] && has_provision=true
  language="$(language_of "$project_dir")"
  jq -n --arg pid "$pid" --arg name "${project_name_for[$project_dir]}" --argjson hasProvision "$has_provision" --arg language "$language" \
    '{projectId:$pid, name:$name, hasProvision:$hasProvision, language:$language}'
done > "$names_json"

result="$(jq -n \
  --slurpfile rows "$rows" \
  --slurpfile names "$names_json" \
  --slurpfile accs "$acc_rows" \
  '
  $rows
  | group_by(.projectDir)
  | map(
      .[0] as $first
      | {
          path: $first.projectDir,
          name: (
            ($names | map(select(.projectId == $first.projectId)) | .[0].name)
            // ($first.projectDir | split("/") | last)
          ),
          hasProvision: (
            ($names | map(select(.projectId == $first.projectId)) | .[0].hasProvision) // false
          ),
          language: (
            ($names | map(select(.projectId == $first.projectId)) | .[0].language) // "generic"
          ),
          accessories: [$accs[] | select(.projectId == $first.projectId) | .accessory],
          environments: (
            map({targetId, env, label, file})
            | sort_by(if .env == "" then "" else .label end)
          )
        }
    )
  | sort_by(.name)
  ' 2>/dev/null)"

if [[ -z "$result" || "$result" == "null" ]]; then
  write_empty
fi

echo "$result" | tee "$CACHE_FILE"
