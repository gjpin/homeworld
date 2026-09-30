#!/usr/bin/env bash
# Copy the Authelia Gateway TLS CA into the forgejo namespace so gitea's
# configure-gitea init can verify OIDC discovery over the kind self-signed
# Gateway cert (Go honors SSL_CERT_FILE). The CA is provisioned at runtime by
# cert-manager, so it cannot be committed to the repo; re-copy on every deploy
# to survive rotation. Idempotent.
set -euo pipefail

SRC_NS="${SRC_NS:-authelia}"
SRC_SECRET="${SRC_SECRET:-authelia-tls-cert}"
DST_NS="${DST_NS:-forgejo}"
DST_SECRET="${DST_SECRET:-gateway-ca}"
WAIT_SECS="${WAIT_SECS:-900}"

log() { printf '[copy-gateway-ca] %s\n' "$*"; }

# The CA comes from a cert-manager Certificate created by the authelia
# application, which sits at the end of the root sync-wave chain (the
# argocd Redis cutover, the envoy Gateway, cert-manager, and then the
# authelia app itself must all reconcile first); 900s covers the chain
# on a cold kind node.
deadline=$((SECONDS + WAIT_SECS))
while (( SECONDS < deadline )); do
  if kubectl -n "${SRC_NS}" get secret "${SRC_SECRET}" >/dev/null 2>&1; then
    break
  fi
  sleep 3
done
if ! ca="$(kubectl -n "${SRC_NS}" get secret "${SRC_SECRET}" -o jsonpath='{.data.ca\.crt}' 2>/dev/null)" || [[ -z "${ca}" ]]; then
  log "timeout waiting for ${SRC_NS}/${SRC_SECRET} ca.crt"
  exit 1
fi

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
printf '%s' "${ca}" | base64 -d >"${tmp}/ca.crt"
kubectl -n "${DST_NS}" create secret generic "${DST_SECRET}" \
  --from-file=ca.crt="${tmp}/ca.crt" \
  --dry-run=client -o yaml \
  | kubectl apply -f - >/dev/null
log "copied ${SRC_NS}/${SRC_SECRET} ca.crt to ${DST_NS}/${DST_SECRET}"
