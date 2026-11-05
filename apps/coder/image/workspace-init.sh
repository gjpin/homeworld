#!/usr/bin/env bash
# Prepares the Coder workspace home volume; the template's startup script runs
# it as coder on every start (apps/coder/template/main.tf). Idempotent: it
# rewrites only the managed keys and preserves everything the user or the
# agents add. The TOML and JSON helpers come from
# host/agents-vm/agents-config.sh.
set -euo pipefail

home_dir=${HOME:-/home/coder}

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

# The home volume hides the image's /home/coder: copy the skeleton dotfiles
# once.
if [ ! -f "$home_dir/.init_done" ]; then
  cp -rT /etc/skel "$home_dir"
  touch "$home_dir/.init_done"
fi
mkdir -p "$home_dir/.local/bin"

# Interactive shells also load each project's mise [env] and tasks.
if ! grep -qF 'mise activate bash' "$home_dir/.bashrc"; then
  # shellcheck disable=SC2016 # expanded by bash at login, not here
  echo 'eval "$(mise activate bash)"' >>"$home_dir/.bashrc"
fi

# Playwright agent skills, seeded once into HOME. --global skips the
# workspace setup, whose browser check never exits against the image's
# read-only browser directory.
if [ ! -f "$home_dir/.claude/skills/playwright-cli/SKILL.md" ]; then
  playwright-cli install --skills --global </dev/null
fi
if [ ! -f "$home_dir/.agents/skills/playwright-cli/SKILL.md" ]; then
  playwright-cli install --skills=agents --global </dev/null
fi

# Codex: never check for updates and never send analytics or feedback.
set_toml_key "$home_dir/.codex/config.toml" check_for_update_on_startup 'false'
set_toml_section_key "$home_dir/.codex/config.toml" analytics enabled 'false'
set_toml_section_key "$home_dir/.codex/config.toml" feedback enabled 'false'

# OpenCode: never self-update and never share conversations.
# shellcheck disable=SC2016 # "$schema" is a literal JSON key
merge_json "$home_dir/.config/opencode/opencode.json" \
  '.autoupdate = false | .share = "disabled"' \
  '{"$schema":"https://opencode.ai/config.json","autoupdate":false,"share":"disabled"}'

# Pi: never send install telemetry (the version check is disabled by
# PI_SKIP_VERSION_CHECK).
merge_json "$home_dir/.pi/agent/settings.json" \
  '.enableInstallTelemetry = false' \
  '{"enableInstallTelemetry":false}'

# Antigravity: no feedback survey. Its telemetry choice is saved with the
# account (/config), not in this file (docs/coder.md); the deprecated key is
# dropped.
merge_json "$home_dir/.gemini/antigravity-cli/settings.json" \
  'del(.enableTelemetry) | .showFeedbackSurvey = false' \
  '{"showFeedbackSurvey":false}'

# Copilot: never self-update.
merge_json "$home_dir/.copilot/settings.json" \
  '.autoUpdate = false' \
  '{"autoUpdate":false}'

# Tools from the user's global mise config (~/.config/mise/config.toml); the
# image's own tools are already installed system-wide.
cd "$home_dir"
mise install --yes || echo "mise install failed; run it again from a terminal" >&2
