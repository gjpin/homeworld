#!/usr/bin/env bash
# Vendor the DocumentDB Kubernetes Operator Helm chart with homeworld patches.
#
# Usage:
#   scripts/vendor-documentdb-operator.sh [chart-version]
#
# When [chart-version] is omitted, the version is read from the currently
# vendored Chart.yaml. Renovate relies on this: it bumps `version:` in
# `apps/documentdb-operator/helm/local-charts/documentdb-operator/Chart.yaml`
# and invokes this script without arguments as a postUpgradeTasks command
# (see renovate.json), so the PR contains the complete re-vendored tree.
#
# Upstream packaging issues worked around here (see docs/argocd.md):
# - Chart bundles cloudnative-pg as a hard subchart dependency (no condition
#   toggle) which would collide with homeworld's standalone CloudNativePG.
# - Sidecar-injector / wal-replica templates must live in the CloudNativePG
#   operator's namespace (`cloudnative-pg`) because CNPG-I only discovers
#   plugin Services in its own namespace. Upstream has used two forms for
#   this namespace: the literal `namespace: cnpg-system` (<= 1.1.0) and the
#   `{{ (index .Values "cloudnative-pg").namespaceOverride }}` expression
#   (>= 1.1.1). Both are rewritten to the `pluginNamespace` value so
#   values.yaml documents the choice.
#
# This script also runs inside the slim Renovate image, so it must not depend
# on yq or kubectl (not installable there via postUpgradeTasks.installTools):
# - YAML block removals use awk and are verified by fail-closed greps.
# - The kustomize render validation runs only when kubectl is available;
#   the Renovate PR's own CI re-validates the render in any case.
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
dest="$repo_root/apps/documentdb-operator/helm/local-charts/documentdb-operator"
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

# Remove a top-level YAML key and its block (indented lines, column-0 list
# items, and blank lines) until the next top-level key, without yq.
remove_top_level_block() {
  local key="$1" file="$2"
  awk -v key="^${key}:" '
    $0 ~ key { skip=1; next }
    skip && /^- / { next }
    skip && /^[^ \t#-]/ { skip=0 }
    skip && /^([ \t]*$|[ \t]+)/ { next }
    { print }
  ' "$file" > "${file}.tmp"
  mv "${file}.tmp" "$file"
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

helm pull "oci://ghcr.io/documentdb/documentdb-operator" \
  --version "$version" --untar --untardir "$tmp"

src="$tmp/documentdb-operator"

# Strip bundled CloudNativePG subchart and its lockfile.
rm -rf "$src/charts" "$src/Chart.lock"

# Remove the hard `dependencies:` block (Helm refuses to template a chart
# whose dependencies are not vendored under charts/).
remove_top_level_block dependencies "$src/Chart.yaml"
if grep -q '^dependencies:' "$src/Chart.yaml"; then
  echo "FAIL: dependencies block not removed from Chart.yaml" >&2
  exit 1
fi

# Remove dead subchart values (the subchart is gone; enabling it or setting
# its namespaceOverride would recreate cnpg-system references).
remove_top_level_block cloudnative-pg "$src/values.yaml"
if grep -q '^cloudnative-pg:' "$src/values.yaml"; then
  echo "FAIL: cloudnative-pg block not removed from values.yaml" >&2
  exit 1
fi

# Delete any template that creates a Namespace (upstream: 01_namespace.yaml,
# which created cnpg-system; the subchart strip above keeps it from rendering).
while IFS= read -r template; do
  [[ -n "$template" ]] || continue
  rm -f "$template"
  echo "Deleted Namespace template: $template"
done < <(grep -rl -- 'kind: Namespace' "$src/templates" 2>/dev/null || true)

# Scope sidecar-injector / wal-replica resources to the plugin namespace.
# Both upstream namespace forms are rewritten (see the header comment).
patched=0
while IFS= read -r template; do
  [[ -n "$template" ]] || continue
  sed -i.bak \
    -e 's/namespace: cnpg-system/namespace: {{ .Values.pluginNamespace | default "cloudnative-pg" }}/g' \
    -e 's/namespace: {{ (index .Values "cloudnative-pg")\.namespaceOverride }}/namespace: {{ .Values.pluginNamespace | default "cloudnative-pg" }}/g' \
    "$template"
  rm -f "$template.bak"
  patched=$((patched + 1))
done < <(grep -rl -e 'namespace: cnpg-system' -e 'namespaceOverride' "$src/templates" 2>/dev/null || true)
if [[ "$patched" -eq 0 ]]; then
  echo "FAIL: no template matched an upstream plugin-namespace form (upstream template change?)" >&2
  exit 1
fi
echo "Scoped ${patched} template file(s) to the plugin namespace."

# Fail-closed guards: a template rename or restructure upstream must fail the
# run loudly (surfaced as an artifact error on the Renovate PR) instead of
# silently shipping the injector into the wrong namespace.
if grep -rn -- 'namespace: cnpg-system' "$src/templates" 2>/dev/null; then
  echo "FAIL: unpatched 'namespace: cnpg-system' remains in templates (upstream template change?)" >&2
  exit 1
fi
if grep -rn -- 'namespaceOverride' "$src/templates" 2>/dev/null; then
  echo "FAIL: unpatched 'cloudnative-pg.namespaceOverride' remains in templates (upstream template change?)" >&2
  exit 1
fi
if grep -rn -- 'name: cnpg-system' "$src/templates" 2>/dev/null; then
  echo "FAIL: cnpg-system resource remains in templates (upstream template change?)" >&2
  exit 1
fi

# Install patched chart
rm -rf "$dest"
mkdir -p "$(dirname "$dest")"
cp -r "$src" "$dest"

echo "Vendored documentdb-operator $version → $dest"
if command -v kubectl >/dev/null 2>&1; then
  echo "Validating render..."
  kubectl kustomize --enable-helm "$repo_root/apps/documentdb-operator/helm" >/dev/null
  echo "Render OK."
else
  echo "kubectl not available; skipping render validation (the PR CI validates the render)." >&2
fi
