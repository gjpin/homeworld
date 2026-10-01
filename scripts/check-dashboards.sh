#!/usr/bin/env bash
# Fail when Grafana dashboard wiring drifts: dashboard JSON files, the
# kustomize configMapGenerator, GrafanaDashboard CRs, GrafanaFolder CRs,
# and the provisioned datasource uids must all stay in sync.
#
# Covered drift classes:
#   1. duplicate dashboard uids across apps/grafana/dashboards/
#   2. datasource uids that no GrafanaDatasource CR in apps/grafana
#      provisions (template variables like $ds are exempt)
#   3. GrafanaDashboard CRs whose configMapRef has no configMapGenerator
#      entry, and generator entries no CR references
#   4. dashboard JSON files no generator declares, and generator file
#      paths that do not exist
#   5. GrafanaDashboard folderRefs without a GrafanaFolder CR, and folder
#      CRs no dashboard references

set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

failures=0

grafana_dir="apps/grafana"

# Datasource uids provisioned by apps/grafana/0_*_datasource.yaml, plus the
# Grafana-internal uids imported dashboards legitimately reference.
allowed_uids=(
  victoriametrics
  prometheus
  loki
  victorialogs
  victoriatraces-jaeger
  victoriatraces-tempo
  grafana
  '-- Grafana --'
  '-- Mixed --'
  '-- Dashboard --'
)

# --- 1. Dashboard uid uniqueness -------------------------------------------

dupe_uids="$(
  find "$grafana_dir/dashboards" -type f -name '*.json' -print0 |
    xargs -0 jq -r '.uid' | sort | uniq -d
)"
if [[ -n "$dupe_uids" ]]; then
  while IFS= read -r uid; do
    echo "check-dashboards: duplicate dashboard uid: $uid" >&2
    failures=$((failures + 1))
  done <<<"$dupe_uids"
fi

# --- 2. Datasource uid allowlist -------------------------------------------

bad_uids="$(
  find "$grafana_dir/dashboards" -type f -name '*.json' -print0 |
    xargs -0 jq -r '
      [.. | objects | .datasource? // empty | objects | .uid? // empty] | .[]
    ' | sort -u
)"
while IFS= read -r uid; do
  case "$uid" in
    '$'*)
      # Datasource template variable reference (e.g. $ds, ${DS_PROMETHEUS}).
      continue
      ;;
  esac
  known=0
  for allowed in "${allowed_uids[@]}"; do
    if [[ "$uid" == "$allowed" ]]; then
      known=1
      break
    fi
  done
  if [[ "$known" -ne 1 ]]; then
    echo "check-dashboards: dashboard references unknown datasource uid: $uid" >&2
    failures=$((failures + 1))
  fi
done <<<"$bad_uids"

# --- 3./4. GrafanaDashboard CRs <-> configMapGenerator <-> JSON files ------

# yq eval-all separates documents with --- lines; drop them from all
# multi-document extractions so comm(1) sees bare values.
strip_sep() { grep -v '^---$' || true; }

dash_cm_refs="$(
  yq ea 'select(.kind == "GrafanaDashboard") | .spec.configMapRef.name' \
    "$grafana_dir"/1_dashboards_*.yaml | strip_sep | sort
)"
cm_names="$(
  yq '.configMapGenerator[].name' "$grafana_dir/kustomization.yaml" | sort
)"

missing_cm="$(comm -23 <(printf '%s\n' "$dash_cm_refs") <(printf '%s\n' "$cm_names"))"
orphan_cm="$(comm -13 <(printf '%s\n' "$dash_cm_refs") <(printf '%s\n' "$cm_names"))"
for cm in $missing_cm; do
  echo "check-dashboards: GrafanaDashboard references configMap without a configMapGenerator entry: $cm" >&2
  failures=$((failures + 1))
done
for cm in $orphan_cm; do
  echo "check-dashboards: configMapGenerator entry no GrafanaDashboard references: $cm" >&2
  failures=$((failures + 1))
done

declared_paths="$(
  yq '.configMapGenerator[].files[]' "$grafana_dir/kustomization.yaml" |
    cut -d= -f2 | sort
)"
actual_paths="$(
  (cd "$grafana_dir" && find dashboards -type f -name '*.json') | sort
)"
undeclared="$(comm -23 <(printf '%s\n' "$actual_paths") <(printf '%s\n' "$declared_paths"))"
missing_file="$(comm -13 <(printf '%s\n' "$actual_paths") <(printf '%s\n' "$declared_paths"))"
for p in $undeclared; do
  echo "check-dashboards: dashboard JSON not declared in kustomization.yaml: $grafana_dir/$p" >&2
  failures=$((failures + 1))
done
for p in $missing_file; do
  echo "check-dashboards: kustomization.yaml declares missing dashboard JSON: $grafana_dir/$p" >&2
  failures=$((failures + 1))
done

# --- 5. GrafanaDashboard folderRef <-> GrafanaFolder ----------------------

dash_folder_refs="$(
  yq ea 'select(.kind == "GrafanaDashboard") | .spec.folderRef' \
    "$grafana_dir"/1_dashboards_*.yaml | strip_sep | sort -u
)"
folder_names="$(
  yq ea 'select(.kind == "GrafanaFolder") | .metadata.name' "$grafana_dir"/0_folders.yaml |
    strip_sep | sort -u
)"

missing_folder="$(comm -23 <(printf '%s\n' "$dash_folder_refs") <(printf '%s\n' "$folder_names"))"
orphan_folder="$(comm -13 <(printf '%s\n' "$dash_folder_refs") <(printf '%s\n' "$folder_names"))"
for folder in $missing_folder; do
  echo "check-dashboards: GrafanaDashboard folderRef without a GrafanaFolder CR: $folder" >&2
  failures=$((failures + 1))
done
for folder in $orphan_folder; do
  echo "check-dashboards: GrafanaFolder CR no GrafanaDashboard references: $folder" >&2
  failures=$((failures + 1))
done

if [[ "$failures" -ne 0 ]]; then
  echo "check-dashboards: $failures wiring drift(s) found under $grafana_dir" >&2
  exit 1
fi

echo "check-dashboards: dashboards, configMaps, and folders agree"
