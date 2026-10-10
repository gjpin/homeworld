#!/usr/bin/env bash
# Refresh the sha256 of the pinned hass-oidc-auth release zip.
#
# Renovate bumps the v<tag> download URL in
# apps/homeassistant/1_homeassistant_deployment.yaml (hass-oidc-auth regex
# manager) and then invokes this script as a postUpgradeTasks command
# (see renovate.json), so the PR carries both the new version and its
# matching sha256 without a manual release-assets lookup. The version is
# read from the already-updated manifest (same pattern as
# scripts/vendor-documentdb-operator.sh).
#
# This script also runs inside the slim Renovate image, so it must not depend
# on tools beyond bash, grep/sed, and a downloader (curl or wget). sha256sum is
# provided by coreutils; shasum is the macOS fallback for local runs.

set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

manifest="apps/homeassistant/1_homeassistant_deployment.yaml"

version="$(
  grep -oE 'hass-oidc-auth/releases/download/v[0-9][0-9.]*/hass-oidc-auth\.zip' "$manifest" |
    head -n1 | sed -E 's#.*/download/v([0-9.]+)/.*#\1#'
)"
if [[ -z "${version}" ]]; then
  echo "refresh-hass-oidc-auth-sha: no pinned hass-oidc-auth version found in ${manifest}" >&2
  exit 1
fi

url="https://github.com/christiaangoossens/hass-oidc-auth/releases/download/v${version}/hass-oidc-auth.zip"
zip="$(mktemp)"
trap 'rm -f "${zip}"' EXIT

echo "refresh-hass-oidc-auth-sha: downloading hass-oidc-auth v${version}"
if command -v curl >/dev/null 2>&1; then
  curl -fsSL -o "${zip}" "${url}"
elif command -v wget >/dev/null 2>&1; then
  wget -qO "${zip}" "${url}"
else
  echo "refresh-hass-oidc-auth-sha: neither curl nor wget is available" >&2
  exit 1
fi

if command -v sha256sum >/dev/null 2>&1; then
  sum="$(sha256sum "${zip}" | cut -d' ' -f1)"
else
  sum="$(shasum -a 256 "${zip}" | cut -d' ' -f1)"
fi

sed -i.bak -E "s#(echo ')[0-9a-f]{64}(  /tmp/hass-oidc-auth\\.zip')#\\1${sum}\\2#" "${manifest}"
rm -f "${manifest}.bak"

if ! grep -q "${sum}  /tmp/hass-oidc-auth.zip" "${manifest}"; then
  echo "refresh-hass-oidc-auth-sha: failed to patch the sha256 line in ${manifest}" >&2
  exit 1
fi

echo "refresh-hass-oidc-auth-sha: ${manifest} pins hass-oidc-auth v${version} sha256 ${sum}"
