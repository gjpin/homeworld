#!/usr/bin/env bash
set -euo pipefail

profile="${1:-}"
output_dir="${2:-}"

if [[ "$profile" != "homelab" ]]; then
  echo "usage: $0 <homelab> <output-directory>" >&2
  exit 2
fi

if [[ -z "$output_dir" ]]; then
  echo "an output directory is required" >&2
  exit 2
fi

repo_root="$(git rev-parse --show-toplevel)"
mkdir -p "$output_dir"

while IFS= read -r kustomization; do
  kust_dir="${kustomization%/kustomization.yaml}"
  rel="${kust_dir#"$repo_root/apps/"}"
  component="${rel%%/*}"
  sub="${rel#"$component/helm"}"
  sub="${sub#/}"
  if [[ -n "$sub" ]]; then
    app="$sub"
  else
    app="$component"
  fi
  kubectl kustomize --enable-helm "$kust_dir" >"$output_dir/${component}-${app}.yaml"
done < <(
  find "$repo_root/apps" \( -path "*/helm/kustomization.yaml" -o -path "*/helm/*/kustomization.yaml" \) \
    ! -path "*/rustfs-operator/*" -print | sort
)

# rustfs-operator 0.0.5 ships tenants.rustfs.com twice under crds/. Kustomize
# rejects duplicate resource IDs, while Helm handles this chart normally.
helm template rustfs-operator rustfs-operator \
  --repo https://operator.rustfs.com \
  --version 0.0.5 \
  --namespace rustfs-operator \
  --include-crds \
  --values "$repo_root/apps/rustfs-operator/helm/values.yaml" \
  >"$output_dir/rustfs-operator-rustfs-operator.yaml"

