#!/usr/bin/env bash
# OpenChamber agent workspace entrypoint.
#
# Runs as the non-root `agent` user with a PVC-mounted HOME:
#   1. Seeds a fresh HOME from the image-staged skeleton (/opt/agent-seed) on
#      first boot.
#   2. Re-applies the managed no-approval agent configuration idempotently
#      so image updates refresh managed keys without clobbering
#      agent-created content.
#   3. Starts the OpenChamber web server in the foreground.
#
# `docker run <image> <command>` / `kubectl exec` style overrides still work:
# with arguments the entrypoint execs them instead of starting the server.
set -euo pipefail

home_dir="${HOME:-/home/agent}"
seed_dir=/opt/agent-seed
seed_marker="$home_dir/.workspace-seeded"

refuse_symlink() {
  if [ -L "$1" ]; then
    echo "refusing to follow a symlinked managed configuration: $1" >&2
    exit 1
  fi
}

set_toml_key() {
  file="$1"
  key="$2"
  value="$3"
  refuse_symlink "$file"
  touch "$file"
  if grep -Eq "^[[:space:]]*${key}[[:space:]]*=" "$file"; then
    sed -Ei "s/^[[:space:]]*${key}[[:space:]]*=.*/${key} = ${value}/" "$file"
  else
    printf '%s = %s\n' "$key" "$value" >>"$file"
  fi
}

set_toml_section_key() {
  file="$1"
  section="$2"
  key="$3"
  value="$4"
  refuse_symlink "$file"
  mkdir -p "$(dirname "$file")"
  touch "$file"
  tmp="$(mktemp)"
  awk -v section="$section" -v key="$key" -v value="$value" '
    BEGIN { in_section = 0; done = 0 }
    /^\[.*\]/ {
      if (in_section && !done) { print key " = " value; done = 1 }
      in_section = ($0 ~ "^\\[" section "\\][[:space:]]*(#.*)?$")
      print
      next
    }
    in_section && $0 ~ "^[[:space:]]*" key "[[:space:]]*=" { next }
    { print }
    END {
      if (!done) {
        if (!in_section) print "[" section "]"
        print key " = " value
      }
    }
  ' "$file" >"$tmp"
  cat "$tmp" >"$file"
  rm -f "$tmp"
}

merge_json() {
  file="$1"
  filter="$2"
  create="$3"
  refuse_symlink "$file"
  mkdir -p "$(dirname "$file")"
  if [ -f "$file" ] && [ -s "$file" ]; then
    tmp="$(mktemp)"
    jq "$filter" "$file" >"$tmp"
    cat "$tmp" >"$file"
    rm -f "$tmp"
  else
    printf '%s\n' "$create" | jq '.' >"$file"
  fi
}

if [ ! -f "$seed_marker" ]; then
  mkdir -p "$home_dir"
  cp -a "$seed_dir/." "$home_dir/" 2>/dev/null || true
  mkdir -p "$home_dir/projects"
  touch "$seed_marker"
fi

mkdir -p \
  "$home_dir/.local/bin" \
  "$home_dir/.config/opencode" \
  "$home_dir/.codex" \
  "$home_dir/.pi/agent" \
  "$home_dir/.grok" \
  "$home_dir/.gemini/antigravity-cli" \
  "$home_dir/.copilot"

# Codex: never ask for approval, full access.
set_toml_key "$home_dir/.codex/config.toml" approval_policy '"never"'
set_toml_key "$home_dir/.codex/config.toml" sandbox_mode '"danger-full-access"'

# OpenCode: allow all tool permissions; never self-update and never share
# conversations. Updates come exclusively from image rebuilds via approved PRs.
merge_json "$home_dir/.config/opencode/opencode.json" \
  '.permission = "allow" | .autoupdate = false | .share = "disabled"' \
  '{"$schema":"https://opencode.ai/config.json","permission":"allow","autoupdate":false,"share":"disabled"}'

# Pi: always trust projects.
merge_json "$home_dir/.pi/agent/settings.json" \
  '.defaultProjectTrust = "always"' \
  '{"defaultProjectTrust":"always"}'

# Grok: never self-update and never send telemetry. Updates come exclusively
# from image rebuilds via approved PRs. Auth is interactive
# (`grok login --device-auth`); the session persists on the PVC.
set_toml_section_key "$home_dir/.grok/config.toml" cli installer '"internal"'
set_toml_section_key "$home_dir/.grok/config.toml" cli auto_update 'false'
set_toml_section_key "$home_dir/.grok/config.toml" features telemetry 'false'
set_toml_section_key "$home_dir/.grok/config.toml" telemetry trace_upload 'false'

# Antigravity: never send telemetry and never prompt for tool approval,
# matching the workspace's no-approval convention for the other agents.
merge_json "$home_dir/.gemini/antigravity-cli/settings.json" \
  '.enableTelemetry = false | .showFeedbackSurvey = false | .toolPermission = "always-proceed"' \
  '{"enableTelemetry":false,"showFeedbackSurvey":false,"toolPermission":"always-proceed"}'

# Copilot: never self-update. Updates come exclusively from image rebuilds
# via approved PRs. Auth is interactive (`copilot login`); the token persists
# on the PVC.
merge_json "$home_dir/.copilot/settings.json" \
  '.autoUpdate = false' \
  '{"autoUpdate":false}'

if [ "$#" -eq 0 ]; then
  exec openchamber serve --foreground
fi

exec "$@"
