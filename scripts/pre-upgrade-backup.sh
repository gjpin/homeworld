#!/usr/bin/env bash
# Pre-merge backup guard for upgrades of stateful components (the /upgrade
# skill, docs/upgrades.md §9). Merging is deploying: Argo CD syncs main within
# minutes, and application migrations run on start. Before an upgrade of a
# component that holds state, make sure a Velero backup of its namespaces
# completed within the last hour; otherwise take one and wait for it.
#
# The on-demand Backup copies the spec of the daily schedule (volume policy,
# snapshot data movement to B2, TTL) and narrows it to the given namespaces,
# so it restores exactly like a nightly one (docs/velero.md).
#
# usage: scripts/pre-upgrade-backup.sh <namespace>...
#
# Exit codes: 0 a fresh backup covers every namespace (existing or just
# taken), 1 the backup failed or timed out, 2 usage, 3 cluster or Velero
# unreachable.
#
# Environment: MAX_AGE_SECONDS (default 3600), WAIT_SECONDS (default 3600).

set -euo pipefail

max_age="${MAX_AGE_SECONDS:-3600}"
wait_seconds="${WAIT_SECONDS:-3600}"
schedule="velero-daily"

if [[ $# -eq 0 ]]; then
  echo "usage: $0 <namespace>..." >&2
  exit 2
fi
namespaces_json="$(printf '%s\n' "$@" | jq -R . | jq -sc 'unique')"

if ! template="$(kubectl -n velero get schedule "$schedule" -o json 2>/dev/null | jq -c '.spec.template')"; then
  echo "cannot read schedule velero/$schedule: cluster or Velero unreachable" >&2
  exit 3
fi
backups="$(kubectl -n velero get backups.velero.io -o json)"

# Namespaces without a Completed backup newer than max_age that covers them.
uncovered="$(jq -c --argjson want "$namespaces_json" --argjson max_age "$max_age" '
  def covers($ns): ((.spec.includedNamespaces // []) as $inc
    | ($inc == [] or ($inc | index("*")) != null or ($inc | index($ns)) != null))
    and (((.spec.excludedNamespaces // []) | index($ns)) == null);
  [.items[] | select(.status.phase == "Completed" and .status.completionTimestamp != null)
    | select((now - (.status.completionTimestamp | fromdateiso8601)) < $max_age)] as $fresh
  | [$want[] as $ns | select([$fresh[] | select(covers($ns))] | length == 0) | $ns]
' <<<"$backups")"

for ns in $(jq -r '.[]' <<<"$namespaces_json"); do
  latest="$(jq -r --arg ns "$ns" '
    def covers($ns): ((.spec.includedNamespaces // []) as $inc
      | ($inc == [] or ($inc | index("*")) != null or ($inc | index($ns)) != null))
      and (((.spec.excludedNamespaces // []) | index($ns)) == null);
    [.items[] | select(.status.phase == "Completed" and .status.completionTimestamp != null) | select(covers($ns))]
    | max_by(.status.completionTimestamp) // {} | "\(.metadata.name // "none") \(.status.completionTimestamp // "")"
  ' <<<"$backups")"
  echo "latest completed backup covering $ns: $latest"
done

if [[ "$uncovered" == "[]" ]]; then
  echo "every namespace has a completed backup younger than ${max_age}s"
  exit 0
fi

first="$(jq -r '.[0]' <<<"$uncovered")"
name="pre-upgrade-${first}-$(date -u +%Y%m%d%H%M%S)"
name="${name:0:63}"

# Cluster-scoped resources default to the ones related to the included
# namespaces (their PersistentVolumes), as in a namespace restore.
jq -n --arg name "$name" --argjson template "$template" --argjson ns "$uncovered" '{
  apiVersion: "velero.io/v1",
  kind: "Backup",
  metadata: {name: $name, namespace: "velero", labels: {"homeworld/pre-upgrade": "true"}},
  spec: ($template | del(.excludedNamespaces, .includeClusterResources) | .includedNamespaces = $ns)
}' | kubectl create -f -

echo "waiting up to ${wait_seconds}s for backup velero/$name ($(jq -r 'join(", ")' <<<"$uncovered"))"
deadline=$((SECONDS + wait_seconds))
phase=""
while [[ $SECONDS -lt $deadline ]]; do
  phase="$(kubectl -n velero get backups.velero.io "$name" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  case "$phase" in
    Completed)
      echo "backup velero/$name completed"
      exit 0
      ;;
    Failed | PartiallyFailed | FailedValidation)
      break
      ;;
  esac
  sleep 15
done

echo "backup velero/$name did not complete (phase: ${phase:-unknown})" >&2
kubectl -n velero get backups.velero.io "$name" -o json |
  jq '.status | {phase, errors, warnings, validationErrors, failureReason}' >&2 || true
exit 1
