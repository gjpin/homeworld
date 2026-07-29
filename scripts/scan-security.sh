#!/usr/bin/env bash
set -euo pipefail

profile="${1:-}"
report_root="${2:-security-reports}"
repo_root="$(git rev-parse --show-toplevel)"
render_dir="$(mktemp -d)"
trap 'rm -rf "$render_dir"' EXIT

"$repo_root/scripts/validate-security-exceptions.sh"
"$repo_root/scripts/render-helm-profiles.sh" "$profile" "$render_dir"

mkdir -p "$report_root/$profile"

kube-score score "$render_dir"/*.yaml \
  --exit-one-on-warning \
  --output-format json \
  >"$report_root/$profile/kube-score.json"

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

