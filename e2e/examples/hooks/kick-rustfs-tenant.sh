#!/usr/bin/env bash
# Work around a rustfs-operator provisioning gap: when a transient request
# to the RustFS server fails during first boot ("failed to list RustFS
# canned policies: request failed" — the server is still initializing
# behind its PVC mount), the operator records ProvisioningReady=False as a
# status condition and returns the reconcile as successful, so
# controller-runtime never requeues it and the Tenant wedges until a
# watched object changes. An annotation touch is exactly that change.
#
# Idempotent: does nothing when the Tenant is already Ready.
set -euo pipefail

log() { printf '[kick-rustfs-tenant] %s\n' "$*"; }

TENANT_NS="${TENANT_NS:-rustfs}"
TENANT_NAME="${TENANT_NAME:-rustfs}"

ready() {
  kubectl -n "${TENANT_NS}" get tenant "${TENANT_NAME}" \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null | grep -q True
}

if ready; then
  log "tenant ${TENANT_NS}/${TENANT_NAME} already Ready"
  exit 0
fi

log "tenant not Ready; touching it to force the operator reconcile"
kubectl -n "${TENANT_NS}" annotate --overwrite tenant "${TENANT_NAME}" \
  "homeworld.e2e/reconcile-nudge=$(date +%s)" >/dev/null

deadline=$((SECONDS + 120))
while (( SECONDS < deadline )); do
  if ready; then
    log "tenant Ready after nudge"
    exit 0
  fi
  sleep 5
done

log "tenant still not Ready after nudge"
exit 1
