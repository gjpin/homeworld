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
# Grafana-internal uids imported dashboards legitimately reference. Derived
# from the GrafanaDatasource CRs so a new datasource only has to land once.
mapfile -t allowed_uids < <(
  yq ea 'select(.kind == "GrafanaDatasource") | .spec.uid' \
    "$grafana_dir"/0_*datasource*.yaml 2>/dev/null | grep -v '^---$' | grep -v '^$' | sort -u
)
allowed_uids+=(
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

# String-form datasource references: variables bound to a datasource name
# (e.g. current.value on a datasource-type template variable) must also be
# a provisioned uid.
bad_string_uids="$(
  find "$grafana_dir/dashboards" -type f -name '*.json' -print0 |
    xargs -0 jq -r '
      [.templating.list[] | select(.type == "datasource") | .current.value? // empty] | .[]
    ' | sort -u
)"
while IFS= read -r uid; do
  case "$uid" in
    '$'*|'')
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
    echo "check-dashboards: datasource variable defaults to unknown uid: $uid" >&2
    failures=$((failures + 1))
  fi
done <<<"$bad_string_uids"

# --- 2b. Template-variable sanity ------------------------------------------

# Duplicate template variable names break variable resolution; empty
# top-level descriptions drop the provenance AGENTS.md requires.
bad_vars="$(find "$grafana_dir/dashboards" -type f -name '*.json' -print0 |
  xargs -0 jq -r '
    . as $d |
    ([.templating.list[].name] | group_by(.) | map(select(length > 1) | .[0]))[]?,
    (if (($d.description // "") | length) == 0 then "«missing-description»" else empty end)
  ' | sort -u
)"
for entry in $bad_vars; do
  if [[ "$entry" == "«missing-description»" ]]; then
    echo "check-dashboards: dashboard has no top-level provenance description: (see list above)" >&2
    failures=$((failures + 1))
  else
    echo "check-dashboards: duplicate template variable name: $entry" >&2
    failures=$((failures + 1))
  fi
done

# Per-file missing-description reporting (the aggregate report above gives
# no filename).
find "$grafana_dir/dashboards" -type f -name '*.json' -print0 |
  xargs -0 -n1 sh -c 'jq -e '"'"'(.description // "") | length > 0'"'"' "$1" >/dev/null 2>&1 || echo "check-dashboards: dashboard has no top-level provenance description: $1" >&2' _
if [[ -n "$(find "$grafana_dir/dashboards" -type f -name '*.json' -print0 |
  xargs -0 -n1 sh -c 'jq -e '"'"'(.description // "") | length > 0'"'"' "$1" >/dev/null 2>&1 || echo x' _)" ]]; then
  failures=$((failures + 1))
fi


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
