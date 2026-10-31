#!/usr/bin/env bash
# Seed argocd/homeworld-domain before the bootstrap Argo CD starts, as
# host/bootstrap.sh does in production: the repo-server's homeworld plugin
# sidecar mounts it and renders nothing without it (docs/argocd.md). The
# staged tree keeps the base-domain.invalid placeholder; the plugin swaps in
# BASE_DOMAIN, the same value seed-infisical.sh stores as /argocd/BASE_DOMAIN
# for the homeworld-domain ExternalSecret that adopts this Secret.
set -euo pipefail

DOMAIN="${BASE_DOMAIN:-homeworld.test}"

kubectl get ns argocd >/dev/null 2>&1 || kubectl create namespace argocd
kubectl -n argocd create secret generic homeworld-domain \
  --from-literal=BASE_DOMAIN="${DOMAIN}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
echo "[apply-argocd-domain] applied Secret/argocd/homeworld-domain (${DOMAIN})"
