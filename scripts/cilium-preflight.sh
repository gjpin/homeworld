#!/usr/bin/env bash
# Cilium pre-flight check before merging a Cilium minor bump
# (docs/upgrades.md "Cilium Pre-Flight Check"): render the pre-flight
# DaemonSet and Deployment from the target chart, apply them, wait until the
# DaemonSet is ready on every node the cilium DaemonSet runs on (the new image
# is pre-pulled) and the cnp-validator Deployment is ready (every
# CiliumNetworkPolicy is valid for the target version), then delete them.
#
# Only the pre-flight flags are passed, never apps/cilium/helm/values.yaml:
# the full values also render Hubble and a freshly generated cilium-ca Secret
# that would overwrite the live ones.
#
# usage: scripts/cilium-preflight.sh <target-chart-version>
#
# Exit codes: 0 pass, 1 the check failed (cnp-validator logs printed),
# 2 usage, 3 cluster unreachable.

set -euo pipefail

target="${1:-}"
if [[ -z "$target" ]]; then
  echo "usage: $0 <target-chart-version>" >&2
  exit 2
fi
timeout="${PREFLIGHT_TIMEOUT:-15m}"

if ! kubectl -n cilium get daemonset cilium >/dev/null 2>&1; then
  echo "cannot read daemonset cilium/cilium: cluster unreachable" >&2
  exit 3
fi

manifest="$(mktemp "${TMPDIR:-/tmp}/cilium-preflight.XXXXXX")"
cleanup() {
  kubectl delete -f "$manifest" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  rm -f "$manifest"
}
trap cleanup EXIT

helm template cilium-preflight cilium --repo https://helm.cilium.io \
  --version "$target" --namespace cilium \
  --set preflight.enabled=true --set agent=false --set operator.enabled=false \
  --set k8sServiceHost=127.0.0.1 --set k8sServicePort=6444 \
  >"$manifest"
kubectl apply -f "$manifest"

status=0
kubectl -n cilium rollout status daemonset/cilium-pre-flight-check --timeout="$timeout" || status=1
kubectl -n cilium rollout status deployment/cilium-pre-flight-check --timeout="$timeout" || status=1

want="$(kubectl -n cilium get daemonset cilium -o jsonpath='{.status.numberReady}')"
have="$(kubectl -n cilium get daemonset cilium-pre-flight-check -o jsonpath='{.status.numberReady}')"
echo "pre-flight DaemonSet ready on ${have:-0} node(s); cilium ready on ${want:-0}"
[[ "${have:-0}" == "${want:-x}" ]] || status=1

if [[ "$status" -ne 0 ]]; then
  echo "pre-flight check failed; cnp-validator logs:" >&2
  kubectl -n cilium logs deployment/cilium-pre-flight-check -c cnp-validator --tail=100 >&2 || true
  exit 1
fi
echo "pre-flight check passed for cilium $target"
