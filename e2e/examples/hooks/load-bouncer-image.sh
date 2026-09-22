#!/usr/bin/env bash
# Load envoy-proxy-bouncer image into the kind node.
set -euo pipefail

IMG="${BOUNCER_IMAGE:-ghcr.io/kdwils/envoy-proxy-bouncer:v0.8.1}"
CLUSTER="${KIND_CLUSTER_NAME:-homeworld-e2e}"

log() { printf '[load-bouncer-image] %s\n' "$*"; }

log "pulling ${IMG}"
docker pull "${IMG}"
kind load docker-image --name "${CLUSTER}" "${IMG}"
log "loaded ${IMG} into kind cluster ${CLUSTER}"
