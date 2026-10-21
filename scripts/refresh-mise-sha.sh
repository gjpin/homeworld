#!/usr/bin/env bash
# Refresh the sha256 of the pinned mise linux-x64 binary in the Coder
# workspace template.
#
# Renovate bumps `mise_version` in apps/coder/template/main.tf (mise regex
# manager) and then invokes this script as a postUpgradeTasks command (see
# renovate.json), so the PR carries both the new version and its matching
# `mise_sha256`. The version is read from the already-updated template (same
# pattern as scripts/refresh-hass-oidc-auth-sha.sh).
#
# This script also runs inside the slim Renovate image, so it must not depend
# on tools beyond bash, grep/sed, and a downloader (curl or wget). sha256sum is
# provided by coreutils; shasum is the macOS fallback for local runs.

set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

template="apps/coder/template/main.tf"

version="$(
  grep -oE 'mise_version[[:space:]]*=[[:space:]]*"[0-9][0-9.]*"' "$template" |
    head -n1 | sed -E 's#.*"([0-9.]+)"#\1#'
)"
if [[ -z "${version}" ]]; then
  echo "refresh-mise-sha: no pinned mise version found in ${template}" >&2
  exit 1
fi

url="https://github.com/jdx/mise/releases/download/v${version}/mise-v${version}-linux-x64"
bin="$(mktemp)"
trap 'rm -f "${bin}"' EXIT

echo "refresh-mise-sha: downloading mise v${version}"
if command -v curl >/dev/null 2>&1; then
  curl -fsSL -o "${bin}" "${url}"
elif command -v wget >/dev/null 2>&1; then
  wget -qO "${bin}" "${url}"
else
  echo "refresh-mise-sha: neither curl nor wget is available" >&2
  exit 1
fi

if command -v sha256sum >/dev/null 2>&1; then
  sum="$(sha256sum "${bin}" | cut -d' ' -f1)"
else
  sum="$(shasum -a 256 "${bin}" | cut -d' ' -f1)"
fi

sed -i.bak -E "s#(mise_sha256[[:space:]]*=[[:space:]]*\")[0-9a-f]{64}(\")#\\1${sum}\\2#" "${template}"
rm -f "${template}.bak"

if ! grep -q "mise_sha256 *= *\"${sum}\"" "${template}"; then
  echo "refresh-mise-sha: failed to patch mise_sha256 in ${template}" >&2
  exit 1
fi

echo "refresh-mise-sha: ${template} pins mise v${version} sha256 ${sum}"
