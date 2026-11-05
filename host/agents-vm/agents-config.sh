#!/usr/bin/env bash
# Managed coding-agent configuration for the agents VM, run as `agent` by the
# agents-config user service on every boot (installed by provision.sh).
# Idempotent: it rewrites only the managed keys and the managed instructions
# block, and preserves everything the agents or the user add.
set -euo pipefail

home_dir=${HOME:-/home/agent}
instructions=/usr/local/share/agents/AGENTS.md
begin='<!-- BEGIN homeworld agents-vm (managed; edits inside are overwritten) -->'
end='<!-- END homeworld agents-vm -->'

refuse_symlink() {
  if [ -L "$1" ]; then
    echo "refusing to follow a symlinked managed configuration: $1" >&2
    exit 1
  fi
}

# Sets a top-level key. A missing key is inserted before the first table
# header: appended after one (Codex writes [projects."..."] tables) it would
# silently belong to that table instead.
set_toml_key() {
  local file=$1 key=$2 value=$3 tmp
  refuse_symlink "$file"
  mkdir -p "$(dirname "$file")"
  touch "$file"
  tmp=$(mktemp)
  awk -v key="$key" -v value="$value" '
    BEGIN { top = 1; done = 0 }
    /^[[:space:]]*\[/ {
      if (top && !done) { print key " = " value; done = 1 }
      top = 0
      print
      next
    }
    top && $0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
      if (!done) { print key " = " value; done = 1 }
      next
    }
    { print }
    END { if (!done) print key " = " value }
  ' "$file" >"$tmp"
  cat "$tmp" >"$file"
  rm -f "$tmp"
}

set_toml_section_key() {
  local file=$1 section=$2 key=$3 value=$4 tmp
  refuse_symlink "$file"
  mkdir -p "$(dirname "$file")"
  touch "$file"
  tmp=$(mktemp)
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
  local file=$1 filter=$2 create=$3 tmp
  refuse_symlink "$file"
  mkdir -p "$(dirname "$file")"
  if [ -s "$file" ]; then
    tmp=$(mktemp)
    jq "$filter" "$file" >"$tmp"
    cat "$tmp" >"$file"
    rm -f "$tmp"
  else
    printf '%s\n' "$create" | jq '.' >"$file"
  fi
}

# Keeps the managed instructions between the markers; text outside them is
# preserved, and the block is appended when the file has none yet.
sync_instructions() {
  local file=$1 tmp
  refuse_symlink "$file"
  mkdir -p "$(dirname "$file")"
  touch "$file"
  tmp=$(mktemp)
  awk -v begin="$begin" -v end="$end" -v src="$instructions" '
    function block() {
      print begin
      while ((getline line < src) > 0) print line
      close(src)
      print end
    }
    $0 == begin { skipping = 1; if (!done) { block(); done = 1 } next }
    $0 == end { skipping = 0; next }
    !skipping { print }
    END { if (!done) { if (NR > 0) print ""; block() } }
  ' "$file" >"$tmp"
  cat "$tmp" >"$file"
  rm -f "$tmp"
}

mkdir -p "$home_dir/projects" "$home_dir/.local/bin"

# Playwright agent skills, seeded once into HOME. --global skips the
# workspace setup, whose browser check never exits against the read-only
# /opt/ms-playwright.
if [ ! -f "$home_dir/.claude/skills/playwright-cli/SKILL.md" ]; then
  playwright-cli install --skills --global </dev/null
fi
if [ ! -f "$home_dir/.agents/skills/playwright-cli/SKILL.md" ]; then
  playwright-cli install --skills=agents --global </dev/null
fi

# Codex: never ask for approval, full access; never check for updates and
# never send analytics or feedback.
set_toml_key "$home_dir/.codex/config.toml" approval_policy '"never"'
set_toml_key "$home_dir/.codex/config.toml" sandbox_mode '"danger-full-access"'
set_toml_key "$home_dir/.codex/config.toml" check_for_update_on_startup 'false'
set_toml_section_key "$home_dir/.codex/config.toml" analytics enabled 'false'
set_toml_section_key "$home_dir/.codex/config.toml" feedback enabled 'false'

# OpenCode: allow all tool permissions; never self-update and never share
# conversations. The deprecated V1 keys (permission, autoupdate) are dropped
# in favour of their native V2 replacements.
merge_json "$home_dir/.config/opencode/opencode.json" \
  'del(.permission, .autoupdate) | .permissions = [{"action":"*","resource":"*","effect":"allow"}] | .update = "disable" | .share = "disabled"' \
  '{"$schema":"https://opencode.ai/config.json","permissions":[{"action":"*","resource":"*","effect":"allow"}],"update":"disable","share":"disabled"}'

# Pi: always trust projects; never send install telemetry (the version check
# is disabled by PI_SKIP_VERSION_CHECK).
merge_json "$home_dir/.pi/agent/settings.json" \
  '.defaultProjectTrust = "always" | .enableInstallTelemetry = false' \
  '{"defaultProjectTrust":"always","enableInstallTelemetry":false}'

# Antigravity: no feedback survey and never prompt for tool approval. Its
# telemetry choice is saved with the account (/config), not in this file
# (docs/openchamber.md); the deprecated key is dropped.
merge_json "$home_dir/.gemini/antigravity-cli/settings.json" \
  'del(.enableTelemetry) | .showFeedbackSurvey = false | .toolPermission = "always-proceed"' \
  '{"showFeedbackSurvey":false,"toolPermission":"always-proceed"}'

# Copilot: never self-update.
merge_json "$home_dir/.copilot/settings.json" \
  '.autoUpdate = false' \
  '{"autoUpdate":false}'

for file in \
  "$home_dir/.claude/CLAUDE.md" \
  "$home_dir/.codex/AGENTS.md" \
  "$home_dir/.config/opencode/AGENTS.md" \
  "$home_dir/.pi/agent/AGENTS.md" \
  "$home_dir/.copilot/copilot-instructions.md" \
  "$home_dir/.gemini/antigravity-cli/rules/homeworld-agents-vm.md"; do
  sync_instructions "$file"
done
