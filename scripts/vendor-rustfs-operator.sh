#!/usr/bin/env bash
# Vendor the RustFS Operator Helm chart with the homeworld patch.
#
# Usage:
#   scripts/vendor-rustfs-operator.sh [chart-version]
#   scripts/vendor-rustfs-operator.sh --check
#
# When [chart-version] is omitted, the version is read from the currently
# vendored Chart.yaml. Renovate relies on this: it bumps either `version:` in
# `apps/rustfs-operator/helm/local-charts/rustfs-operator/Chart.yaml` or the
# operator image tag in `apps/rustfs-operator/helm/values.yaml`, and invokes
# this script without arguments as a postUpgradeTasks command (see
# renovate.json), so the PR contains the complete re-vendored tree.
#
# --check re-fetches only the CRDs and fails when the vendored crds/ directory
# differs from the one at the pinned operator tag (run by CI).
#
# Upstream packaging issues worked around here (see docs/argocd.md):
# - Upstream's published charts lag the operator releases, and the image tag
#   is tracked independently of the chart version, so a chart's crds/ can
#   predate the status fields the pinned operator binary writes. The apiserver
#   prunes undeclared status fields (which wedges Tenant user provisioning),
#   so crds/ is always replaced with deploy/rustfs-operator/crds/ from the
#   operator's git tag matching `operator.image.tag` in values.yaml.
# - The published chart ships `tenants.rustfs.com` twice under crds/
#   (`crds/tenant.yaml` next to `crds/tenant-crd.yaml`). Helm tolerates the
#   duplicate, but Kustomize's Helm inflation rejects it ("may not add
#   resource with an already registered id"), which breaks
#   `kustomize build --enable-helm` and therefore the Argo CD sync path.
#   Replacing crds/ with the operator tag's copy drops it; a fail-closed
#   guard rejects any duplicate CRD name that remains.
#
# This script also runs inside the slim Renovate image, so it must not depend
# on yq or kubectl (not installable there via postUpgradeTasks.installTools):
# - The tag is read with awk, the CRDs are fetched as the tag's source tarball
#   with curl (or wget) and tar, and the duplicate guard uses grep.
# - The kustomize render validation runs only when kubectl is available;
#   the Renovate PR's own CI re-validates the render in any case.
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
dest="$repo_root/apps/rustfs-operator/helm/local-charts/rustfs-operator"
chart_yaml="$dest/Chart.yaml"
values_yaml="$repo_root/apps/rustfs-operator/helm/values.yaml"

check=false
version=""
if [[ "${1:-}" == "--check" ]]; then
  check=true
elif [[ $# -ge 1 ]]; then
  version="$1"
elif [[ -f "$chart_yaml" ]]; then
  version="$(sed -n 's/^version:[[:space:]]*//p' "$chart_yaml" | head -n1 | tr -d '[:space:]')"
  if [[ -z "$version" ]]; then
    echo "Could not read version from $chart_yaml. Usage: $0 <chart-version>" >&2
    exit 2
  fi
else
  echo "Usage: $0 <chart-version> (no vendored Chart.yaml found to read a default from)" >&2
  exit 2
fi

# The first `tag:` after the operator image repository line.
operator_tag="$(
  awk '
    /^[[:space:]]+repository:[[:space:]]*docker\.io\/rustfs\/operator[[:space:]]*$/ { found = 1; next }
    found && /^[[:space:]]+tag:/ { sub(/^[[:space:]]+tag:[[:space:]]*/, ""); sub(/[[:space:]]*(#.*)?$/, ""); print; exit }
  ' "$values_yaml"
)"
if [[ -z "$operator_tag" ]]; then
  echo "FAIL: could not read operator.image.tag from $values_yaml" >&2
  exit 1
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Fetch deploy/rustfs-operator/crds/ from the operator's git tag into $1.
fetch_operator_crds() {
  local out="$1"
  local url="https://codeload.github.com/rustfs/operator/tar.gz/refs/tags/${operator_tag}"
  local tarball="$tmp/operator-${operator_tag}.tar.gz"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL -o "$tarball" "$url"
  elif command -v wget >/dev/null 2>&1; then
    wget -q -O "$tarball" "$url"
  else
    echo "curl or wget is required" >&2
    exit 1
  fi
  mkdir -p "$tmp/operator-src"
  tar -xzf "$tarball" -C "$tmp/operator-src" --strip-components=1
  local crds="$tmp/operator-src/deploy/rustfs-operator/crds"
  if [[ ! -f "$crds/tenant-crd.yaml" ]]; then
    echo "FAIL: deploy/rustfs-operator/crds/tenant-crd.yaml missing at operator tag $operator_tag (upstream restructure?)" >&2
    exit 1
  fi
  rm -rf "$out"
  cp -r "$crds" "$out"
}

if [[ "$check" == true ]]; then
  fetch_operator_crds "$tmp/crds"
  if ! diff -r "$tmp/crds" "$dest/crds" >/dev/null; then
    echo "FAIL: $dest/crds differs from deploy/rustfs-operator/crds/ at operator tag $operator_tag." >&2
    echo "Re-vendor with scripts/vendor-rustfs-operator.sh." >&2
    diff -r "$tmp/crds" "$dest/crds" | head -n 40 >&2 || true
    exit 1
  fi
  echo "rustfs-operator CRDs match operator tag $operator_tag."
  exit 0
fi

command -v helm >/dev/null 2>&1 || { echo "helm is required" >&2; exit 1; }

helm pull rustfs-operator \
  --repo https://operator.rustfs.com \
  --version "$version" --untar --untardir "$tmp"

src="$tmp/rustfs-operator"

# Replace the chart's CRDs with the operator tag's copy (see header).
fetch_operator_crds "$src/crds"
echo "Vendored CRDs from operator tag $operator_tag"

# Fail-closed guard: no CRD may be registered twice across the chart.
dupes="$(grep -rhoE '^  name: [a-z0-9.-]+\.rustfs\.com$' "$src/crds" 2>/dev/null | sort | uniq -d || true)"
if [[ -n "$dupes" ]]; then
  echo "FAIL: duplicate CRD names remain: $dupes" >&2
  exit 1
fi

# Install patched chart
rm -rf "$dest"
mkdir -p "$(dirname "$dest")"
cp -r "$src" "$dest"

echo "Vendored rustfs-operator $version → $dest"
if command -v kubectl >/dev/null 2>&1; then
  echo "Validating render..."
  kubectl kustomize --enable-helm "$repo_root/apps/rustfs-operator/helm" >/dev/null
  echo "Render OK."
else
  echo "kubectl not available; skipping render validation (the PR CI validates the render)." >&2
fi
