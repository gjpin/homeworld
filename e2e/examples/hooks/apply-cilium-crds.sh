#!/usr/bin/env bash
# Cilium 1.17 helm chart does not ship CRDs (no crds/ dir, no templates
# gated on crds.install). Apply the policy CRDs from the matching Cilium
# tag so Argo Validate=true can admit CiliumNetworkPolicy objects.
set -euo pipefail

VERSION="${CILIUM_VERSION:-1.17.2}"
BASE="https://raw.githubusercontent.com/cilium/cilium/v${VERSION}/pkg/k8s/apis/cilium.io/client/crds/v2"

kubectl apply --server-side --force-conflicts \
  -f "${BASE}/ciliumnetworkpolicies.yaml" \
  -f "${BASE}/ciliumclusterwidenetworkpolicies.yaml"

echo "[apply-cilium-crds] CiliumNetworkPolicy CRDs from cilium v${VERSION}"
kubectl get crd ciliumnetworkpolicies.cilium.io ciliumclusterwidenetworkpolicies.cilium.io
