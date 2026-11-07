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
repo_url="https://github.com/gjpin/homeworld.git"
mkdir -p "$output_dir"
cd "$repo_root"

# The scan covers exactly what Argo CD deploys: every Application sourced from
# this repository, at any depth of the app-of-apps tree (the root
# Applications and the child Applications under apps/<component>/).
manifests() {
  find apps -type f \( -name '*.yaml' -o -name '*.yml' \) \
    -not -path '*/charts/*' -not -path '*/local-charts/*' -print0
}
sources="$(
  manifests | xargs -0 -n1 yq -o=json -I=0 'select(.kind == "Application")' |
    jq -r '.metadata.name as $n | (.spec.sources // [.spec.source])[] |
      [$n, (.repoURL // ""), (.path // ""), (.chart // "")] | @tsv'
)"

# Sources outside this repository cannot be rendered offline. They are
# allowed only for upstream CRD bundles, whose Applications are named *-crd
# or *-crds; a workload must come from this repository so the scan sees it.
unscanned="$(
  awk -F'\t' -v url="$repo_url" '
    ($2 != url || $4 != "") && $1 !~ /-crds?$/ { print $1 " (" $2 ", " ($4 != "" ? "chart " $4 : $3) ")" }
  ' <<<"$sources"
)"
if [[ -n "$unscanned" ]]; then
  echo "error: Applications deploy sources the scan cannot render:" >&2
  printf '  %s\n' "$unscanned" >&2
  exit 1
fi

paths="$(awk -F'\t' -v url="$repo_url" '$2 == url && $4 == "" { print $3 }' <<<"$sources" | sort -u)"
if [[ -z "$paths" ]]; then
  echo "error: no Application sources this repository" >&2
  exit 1
fi

# Every manifest under apps/ must reach the cluster through one of those
# paths: either it sits directly in an Application's directory, or below one
# that kustomize renders. Anything else is deployed by nobody, and the scan
# would never see it either.
undeployed=""
while IFS= read -r dir; do
  d="$dir"
  while [[ "$d" == apps/* ]] && ! grep -qxF "$d" <<<"$paths"; do
    d="${d%/*}"
  done
  if [[ "$d" == "$dir" ]] || { grep -qxF "$d" <<<"$paths" && [[ -f "$d/kustomization.yaml" ]]; }; then
    continue
  fi
  undeployed+="  $dir"$'\n'
done < <(
  find apps -type f \( -name '*.yaml' -o -name '*.yml' -o -name '*.json' \) \
    -not -path '*/charts/*' -not -path 'apps/app-of-apps.yaml' -exec dirname {} \; | sort -u
)
if [[ -n "$undeployed" ]]; then
  echo "error: no Application deploys the manifests in:" >&2
  printf '%s' "$undeployed" >&2
  exit 1
fi

# Each path renders the way the homeworld Config Management Plugin renders it
# (apps/argocd/helm/values.yaml): kustomize with Helm where the directory
# holds a kustomization.yaml, its plain manifest files otherwise. The
# base-domain.invalid placeholder stays in place.
while IFS= read -r path; do
  if [[ ! -d "$path" ]]; then
    echo "error: Application path $path does not exist" >&2
    exit 1
  fi
  out="$output_dir/$(tr / _ <<<"${path#apps/}").yaml"
  if [[ -f "$path/kustomization.yaml" ]]; then
    kubectl kustomize --enable-helm "$path" >"$out"
  else
    for f in "$path"/*.yaml "$path"/*.yml "$path"/*.json; do
      [[ -f "$f" ]] || continue
      printf -- '---\n'
      cat "$f"
      printf '\n'
    done >"$out"
  fi
done <<<"$paths"
