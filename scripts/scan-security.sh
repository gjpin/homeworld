#!/usr/bin/env bash
set -euo pipefail

profile="${1:-}"
report_root="${2:-security-reports}"
repo_root="$(git rev-parse --show-toplevel)"
render_dir="$(mktemp -d)"
stripped_dir="$(mktemp -d)"
trap 'rm -rf "$render_dir" "$stripped_dir"' EXIT

"$repo_root/scripts/validate-security-exceptions.sh"
"$repo_root/scripts/render-helm-profiles.sh" "$profile" "$render_dir"

mkdir -p "$report_root/$profile"

# kube-linter silently ignores annotations that name an unknown check, and an
# annotation whose finding has disappeared is a stale exception. Both must
# fail the job so only the required exceptions stay in place.

unknown_checks="$(
  comm -23 \
    <(
      yq -o=json -I=0 '.' "$render_dir"/*.yaml |
        jq -r '(.metadata.annotations // {}) | keys[] |
          select(startswith("ignore-check.kube-linter.io/")) |
          sub("^ignore-check\\.kube-linter\\.io/"; "")' |
        sort -u
    ) \
    <(kube-linter checks list | sed -n 's/^Name: \(.*\)$/\1/p' | sort -u)
)"
if [[ -n "$unknown_checks" ]]; then
  echo "ignore annotations name unknown kube-linter checks: $unknown_checks" >&2
  exit 1
fi

for file in "$render_dir"/*.yaml; do
  yq eval '.metadata.annotations |= (to_entries | map(select(.key | test("^ignore-check\\.kube-linter\\.io/") | not)) | from_entries)' \
    "$file" >"$stripped_dir/$(basename "$file")"
done

stale_exceptions="$(
  comm -23 \
    <(
      yq -o=json -I=0 '.' "$render_dir"/*.yaml |
        jq -r '. as $d |
          ($d.metadata.annotations // {}) | keys[] |
          select(startswith("ignore-check.kube-linter.io/")) |
          [($d.kind // ""), ($d.metadata.name // ""), ($d.metadata.namespace // ""),
           sub("^ignore-check\\.kube-linter\\.io/"; "")] | @tsv' |
        sort -u
    ) \
    <(
      kube-linter lint "$stripped_dir" --format json 2>/dev/null |
        jq -r '.Reports[] |
          [.Object.K8sObject.GroupVersionKind.Kind, .Object.K8sObject.Name,
           .Object.K8sObject.Namespace, .Check] | @tsv' |
        sort -u
    )
)"
if [[ -n "$stale_exceptions" ]]; then
  echo "stale kube-linter exceptions without a live finding:" >&2
  printf '%s\n' "$stale_exceptions" >&2
  exit 1
fi

kube-linter lint "$render_dir" \
  --format json \
  >"$report_root/$profile/kube-linter.json"

kubescape scan framework AllControls "$render_dir" \
  --controls-version v2.0.31 \
  --exceptions="$repo_root/security/kubescape-exceptions.json" \
  --fail-on-degraded-config \
  --format json \
  --format-version v2 \
  --keep-local \
  --output "$report_root/$profile/kubescape.json"

jq -e '
  [.results[].controls[] | select(.status.status == "failed")] | length == 0
' "$report_root/$profile/kubescape.json" >/dev/null
