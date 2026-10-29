#!/usr/bin/env bash
# Refresh the sha256 of the pinned AudioMuse-AI Navidrome plugin.
#
# Renovate bumps the v<tag> download URL in apps/navidrome/1_deployment.yaml
# (AudioMuse-AI-NV-plugin regex manager) and then invokes this script as a
# postUpgradeTasks command (see renovate.json), so the PR carries both the
# new version and its matching sha256. Same pattern as
# scripts/refresh-hass-oidc-auth-sha.sh, and the same tool constraints: it
# runs inside the slim Renovate image (bash, grep/sed, curl or wget).

set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

manifest="apps/navidrome/1_deployment.yaml"

version="$(
  grep -oE 'AudioMuse-AI-NV-plugin/releases/download/v[0-9][0-9.]*/audiomuseai\.ndp' "$manifest" |
    head -n1 | sed -E 's#.*/download/v([0-9.]+)/.*#\1#'
)"
if [[ -z "${version}" ]]; then
  echo "refresh-navidrome-audiomuse-plugin-sha: no pinned plugin version found in ${manifest}" >&2
  exit 1
fi

url="https://github.com/NeptuneHub/AudioMuse-AI-NV-plugin/releases/download/v${version}/audiomuseai.ndp"
file="$(mktemp)"
trap 'rm -f "${file}"' EXIT

echo "refresh-navidrome-audiomuse-plugin-sha: downloading AudioMuse-AI-NV-plugin v${version}"
if command -v curl >/dev/null 2>&1; then
  curl -fsSL -o "${file}" "${url}"
elif command -v wget >/dev/null 2>&1; then
  wget -qO "${file}" "${url}"
else
  echo "refresh-navidrome-audiomuse-plugin-sha: neither curl nor wget is available" >&2
  exit 1
fi

if command -v sha256sum >/dev/null 2>&1; then
  sum="$(sha256sum "${file}" | cut -d' ' -f1)"
else
  sum="$(shasum -a 256 "${file}" | cut -d' ' -f1)"
fi

sed -i.bak -E "s#(echo ')[0-9a-f]{64}(  /tmp/audiomuseai\\.ndp')#\\1${sum}\\2#" "${manifest}"
rm -f "${manifest}.bak"

if ! grep -q "${sum}  /tmp/audiomuseai.ndp" "${manifest}"; then
  echo "refresh-navidrome-audiomuse-plugin-sha: failed to patch the sha256 line in ${manifest}" >&2
  exit 1
fi

echo "refresh-navidrome-audiomuse-plugin-sha: ${manifest} pins AudioMuse-AI-NV-plugin v${version} sha256 ${sum}"
