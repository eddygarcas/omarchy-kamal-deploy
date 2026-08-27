#!/usr/bin/env bash
# Pre-flight checks for the Provision Wizard: does this folder look ready for
# a generated `provision` script? Outputs JSON, always exit 0 (the panel
# renders whatever comes back rather than treating a bad folder as a script
# failure).
set -uo pipefail

DIR="${1:-}"

if [[ -z "$DIR" ]]; then
  echo '{"dir":"","folderExists":false}'
  exit 0
fi

expanded="${DIR/#\~/$HOME}"

if [[ ! -d "$expanded" ]]; then
  jq -n --arg dir "$expanded" '{dir:$dir, folderExists:false}'
  exit 0
fi

config_found=false
config_file=""
for f in "$expanded"/config/deploy.yml "$expanded"/config/deploy.*.yml; do
  [[ -f "$f" ]] || continue
  config_found=true
  config_file="$f"
  break
done

gemfile="$expanded/Gemfile"
gemfile_found=false
has_kamal_gem=false
has_net_ssh_gem=false
if [[ -f "$gemfile" ]]; then
  gemfile_found=true
  grep -qE '^[[:space:]]*gem[[:space:]]+["'"'"']kamal["'"'"']' "$gemfile" && has_kamal_gem=true
  grep -qE '^[[:space:]]*gem[[:space:]]+["'"'"']net-ssh["'"'"']' "$gemfile" && has_net_ssh_gem=true
fi

ssh_identity_count=0
if command -v ssh-add >/dev/null 2>&1; then
  identities_output="$(ssh-add -l 2>/dev/null)"
  rc=$?
  if [[ $rc -eq 0 ]]; then
    ssh_identity_count="$(printf '%s\n' "$identities_output" | grep -c '.')"
  fi
fi

provision_exists=false
[[ -f "$expanded/provision" ]] && provision_exists=true

jq -n \
  --arg dir "$expanded" \
  --argjson configFound "$config_found" \
  --arg configFile "$config_file" \
  --argjson gemfileFound "$gemfile_found" \
  --argjson hasKamalGem "$has_kamal_gem" \
  --argjson hasNetSshGem "$has_net_ssh_gem" \
  --argjson sshIdentityCount "$ssh_identity_count" \
  --argjson provisionExists "$provision_exists" \
  '{
    dir: $dir,
    folderExists: true,
    configFound: $configFound,
    configFile: $configFile,
    gemfileFound: $gemfileFound,
    hasKamalGem: $hasKamalGem,
    hasNetSshGem: $hasNetSshGem,
    sshIdentityCount: $sshIdentityCount,
    provisionExists: $provisionExists
  }'
