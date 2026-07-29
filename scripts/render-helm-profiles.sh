#!/usr/bin/env bash
set -euo pipefail

profile="${1:-}"
output_dir="${2:-}"

if [[ "$profile" != "homelab" && "$profile" != "production" ]]; then
  echo "usage: $0 <homelab|production> <output-directory>" >&2
  exit 2
fi

if [[ -z "$output_dir" ]]; then
  echo "an output directory is required" >&2
  exit 2
fi

repo_root="$(git rev-parse --show-toplevel)"
mkdir -p "$output_dir"

while IFS= read -r overlay; do
  overlay_dir="${overlay%/kustomization.yaml}"
  app="$(basename "$(dirname "$(dirname "$overlay_dir")")")"
  component="$(basename "$(dirname "$(dirname "$(dirname "$(dirname "$overlay_dir")")")")")"
  kubectl kustomize --enable-helm "$overlay_dir" >"$output_dir/${component}-${app}.yaml"
done < <(
  find "$repo_root/apps" -path "*/helm/*/overlays/$profile/kustomization.yaml" \
    ! -path "*/rustfs-operator/*" -print | sort
)

# rustfs-operator 0.0.5 ships tenants.rustfs.com twice under crds/. Kustomize
# rejects duplicate resource IDs, while Helm handles this chart normally.
rustfs_values=(
  --values "$repo_root/apps/rustfs-operator/helm/rustfs-operator/base/values.yaml"
)
if [[ "$profile" == "production" ]]; then
  rustfs_values+=(
    --values "$repo_root/apps/rustfs-operator/helm/rustfs-operator/overlays/production/values.yaml"
  )
fi

helm template rustfs-operator rustfs-operator \
  --repo https://operator.rustfs.com \
  --version 0.0.5 \
  --namespace rustfs-operator \
  --include-crds \
  "${rustfs_values[@]}" \
  >"$output_dir/rustfs-operator-rustfs-operator.yaml"
