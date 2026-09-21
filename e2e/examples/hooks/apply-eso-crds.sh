#!/usr/bin/env bash
# Apply External Secrets CRDs with server-side apply. The helm chart CRDs
# exceed the 256Ki last-applied-configuration annotation under client-side apply.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
CHART="${ROOT}/apps/external-secrets/helm/external-secrets/base/charts/external-secrets-2.4.1/external-secrets"

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
