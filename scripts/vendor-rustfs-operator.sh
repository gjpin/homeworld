#!/usr/bin/env bash
# Vendor the RustFS Operator Helm chart with the homeworld patch.
#
# Usage:
#   scripts/vendor-rustfs-operator.sh [chart-version]
#
# When [chart-version] is omitted, the version is read from the currently
# vendored Chart.yaml. Renovate relies on this: it bumps `version:` in
# `apps/rustfs-operator/helm/local-charts/rustfs-operator/Chart.yaml`
# and invokes this script without arguments as a postUpgradeTasks command
# (see renovate.json), so the PR contains the complete re-vendored tree.
#
# Upstream packaging issue worked around here (see docs/argocd.md):
# - The vendored chart ships `tenants.rustfs.com` twice under crds/
#   (`crds/tenant.yaml` is byte-identical to `crds/tenant-crd.yaml`). Helm
#   tolerates the duplicate, but Kustomize's Helm inflation rejects it
#   ("may not add resource with an already registered id"), which breaks
#   `kustomize build --enable-helm` and therefore the Argo CD sync path.
#   The duplicate file is deleted; the canonical copy is retained.
#
# This script also runs inside the slim Renovate image, so it must not depend
# on yq or kubectl (not installable there via postUpgradeTasks.installTools):
# - The duplicate-CRD deletion uses cmp and is verified by a fail-closed grep.
# - The kustomize render validation runs only when kubectl is available;
#   the Renovate PR's own CI re-validates the render in any case.
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
dest="$repo_root/apps/rustfs-operator/helm/local-charts/rustfs-operator"
chart_yaml="$dest/Chart.yaml"

if [[ $# -ge 1 ]]; then
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

command -v helm >/dev/null 2>&1 || { echo "helm is required" >&2; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

helm pull rustfs-operator \
  --repo https://operator.rustfs.com \
  --version "$version" --untar --untardir "$tmp"

src="$tmp/rustfs-operator"

# Delete the duplicated Tenant CRD. Upstream ships tenants.rustfs.com in both
# crds/tenant.yaml and crds/tenant-crd.yaml; keep the canonical copy and drop
# the byte-identical duplicate so Kustomize Helm inflation does not register
# the same resource ID twice.
crd_main="$src/crds/tenant-crd.yaml"
crd_dup="$src/crds/tenant.yaml"
if [[ ! -f "$crd_main" ]]; then
  echo "FAIL: $crd_main missing (upstream chart restructure?)" >&2
  exit 1
fi
if [[ -f "$crd_dup" ]]; then
  if ! cmp -s "$crd_main" "$crd_dup"; then
    echo "FAIL: $crd_dup is no longer byte-identical to $crd_main; review the upstream delta and update this script." >&2
    exit 1
  fi
  rm -f "$crd_dup"
  echo "Deleted duplicate CRD: crds/tenant.yaml"
else
  echo "Upstream fixed the duplicate CRD; nothing to strip."
fi

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
