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

# Every release (including the vendored charts under helm/local-charts)
# renders through the same kustomize path, and so do the components that
# kustomize an upstream release directly (apps/<component>/<dir>/).
rendered=0
while IFS= read -r kustomization; do
  rendered=$((rendered + 1))
  kust_dir="${kustomization%/kustomization.yaml}"
  rel="${kust_dir#"$repo_root/apps/"}"
  component="${rel%%/*}"
  sub="${rel#"$component"}"
  sub="${sub#/helm}"
  sub="${sub#/}"
  if [[ -n "$sub" ]]; then
    app="$sub"
  else
    app="$component"
  fi
  kubectl kustomize --enable-helm "$kust_dir" >"$output_dir/${component}-${app}.yaml"
done < <(
  find "$repo_root/apps" -mindepth 3 -maxdepth 4 -name kustomization.yaml -not -path "*/charts/*" -print | sort
)

# Fail closed: zero kustomizations means nothing was rendered, and downstream
# scans over an empty directory would vacuously pass.
if [[ "$rendered" -eq 0 ]]; then
  echo "error: no kustomization files found under $repo_root/apps" >&2
  exit 1
fi

