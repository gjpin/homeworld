#!/usr/bin/env bash
# Envoy Gateway Helm installs EnvoyProxy CRDs via a hook Job. On a reused
# kind cluster that Job can go missing while directory apps already reference
# EnvoyProxy/SecurityPolicy. Apply the vendored chart CRDs up front.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
CRDS="${ROOT}/apps/envoy-gateway/helm/charts/gateway-helm-v1.7.2/gateway-helm/crds"

kubectl apply --server-side --force-conflicts -f "${CRDS}/generated"
# Gateway API CRDs (HTTPRoute/Gateway/GRPCRoute) live beside the Envoy
# CRDs. Applying them here avoids the first Argo sync failing with
# "resource mapping not found" before the helm chart's CRD job runs.
# On --keep-cluster, Envoy Gateway already installed
# ValidatingAdmissionPolicy safe-upgrades.gateway.networking.k8s.io, which
# rejects re-applying the vendored CRD bundle. Skip when they exist.
if kubectl get crd httproutes.gateway.networking.k8s.io >/dev/null 2>&1; then
  echo "[apply-envoy-gateway-crds] Gateway API CRDs already present; skip re-apply"
else
  kubectl apply --server-side --force-conflicts -f "${CRDS}/gatewayapi-crds.yaml"
fi

echo "[apply-envoy-gateway-crds] Envoy Gateway and Gateway API CRDs applied"
kubectl get crd envoyproxies.gateway.envoyproxy.io securitypolicies.gateway.envoyproxy.io gateways.gateway.networking.k8s.io httproutes.gateway.networking.k8s.io
