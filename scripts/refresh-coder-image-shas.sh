#!/usr/bin/env bash
# Refresh the sha256 hashes of the release binaries pinned in the Coder
# workspace image: mise and rustup-init, for amd64 and arm64.
#
# Renovate bumps `MISE_VERSION` or `RUSTUP_VERSION` in
# apps/coder/image/Dockerfile (regex managers) and then invokes this script as
# a postUpgradeTasks command (see renovate.json), so the PR carries both the
# new version and its matching `*_SHA256_AMD64`/`*_SHA256_ARM64`. Versions are
# read from the already-updated Dockerfile (same pattern as
# scripts/refresh-hass-oidc-auth-sha.sh); the hashes come from each release's
# published checksums.
#
# This script also runs inside the slim Renovate image, so it must not depend
# on tools beyond bash, grep/sed, and a downloader (curl or wget).

set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

dockerfile="apps/coder/image/Dockerfile"

fetch() {
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$1"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO- "$1"
  else
    echo "refresh-coder-image-shas: neither curl nor wget is available" >&2
    exit 1
  fi
}

pinned() {
  local version
  version="$(grep -oE "^ARG $1=[0-9][0-9.]*" "$dockerfile" | head -n1 | cut -d= -f2)"
  if [[ -z "${version}" ]]; then
    echo "refresh-coder-image-shas: no pinned $1 found in ${dockerfile}" >&2
    exit 1
  fi
  printf '%s\n' "${version}"
}

patch_sum() {
  local var=$1 sum=$2 what=$3
  if [[ ! "${sum}" =~ ^[0-9a-f]{64}$ ]]; then
    echo "refresh-coder-image-shas: no sha256 for ${what}" >&2
    exit 1
  fi
  sed -i.bak -E "s#^(ARG ${var}=)[0-9a-f]{64}\$#\\1${sum}#" "${dockerfile}"
  rm -f "${dockerfile}.bak"
  if ! grep -q "^ARG ${var}=${sum}\$" "${dockerfile}"; then
    echo "refresh-coder-image-shas: failed to patch ${var} in ${dockerfile}" >&2
    exit 1
  fi
  echo "refresh-coder-image-shas: ${var}=${sum} (${what})"
}

mise_version="$(pinned MISE_VERSION)"
mise_sums="$(fetch "https://github.com/jdx/mise/releases/download/v${mise_version}/SHASUMS256.txt")"
for pair in AMD64:x64 ARM64:arm64; do
  asset="mise-v${mise_version}-linux-${pair#*:}"
  sum="$(printf '%s\n' "${mise_sums}" | grep -E "[ *](\./)?${asset}\$" | cut -d' ' -f1)"
  patch_sum "MISE_SHA256_${pair%%:*}" "${sum}" "${asset}"
done

rustup_version="$(pinned RUSTUP_VERSION)"
for pair in AMD64:x86_64 ARM64:aarch64; do
  url="https://static.rust-lang.org/rustup/archive/${rustup_version}/${pair#*:}-unknown-linux-gnu/rustup-init"
  sum="$(fetch "${url}.sha256" | cut -d' ' -f1)"
  patch_sum "RUSTUP_SHA256_${pair%%:*}" "${sum}" "${url}"
done
