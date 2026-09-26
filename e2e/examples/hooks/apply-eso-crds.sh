#!/usr/bin/env bash
# Apply External Secrets CRDs with server-side apply. The helm chart CRDs
# exceed the 256Ki last-applied-configuration annotation under client-side apply.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
# Chart version is pinned in apps/external-secrets/helm/kustomization.yaml;
# resolve the downloaded chart dir dynamically so version bumps don't stale this hook.
CHART="$(ls -d "${ROOT}"/apps/external-secrets/helm/charts/external-secrets-*/external-secrets 2>/dev/null | sort -V | tail -n 1)"
if [[ -z "${CHART}" || ! -d "${CHART}" ]]; then
  echo "[apply-eso-crds] chart not found under apps/external-secrets/helm/charts (run 'kubectl kustomize --enable-helm apps/external-secrets/helm' once to download)" >&2
  exit 1
fi

helm template eso-crds "${CHART}" \
  --set installCRDs=true \
  --set bitwarden-sdk-server.enabled=false \
  | python3 -c '
import re, sys
for part in re.split(r"(?m)^---\s*$", sys.stdin.read()):
    if re.search(r"(?m)^kind: CustomResourceDefinition\s*$", part):
        sys.stdout.write("---\n" + part.strip() + "\n")
' | kubectl apply --server-side --force-conflicts -f -

echo "[apply-eso-crds] ClusterSecretStore/ExternalSecret CRDs applied"
kubectl get crd clustersecretstores.external-secrets.io externalsecrets.external-secrets.io
