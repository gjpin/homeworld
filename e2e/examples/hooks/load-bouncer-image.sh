#!/usr/bin/env bash
# envoy-proxy-bouncer publishes linux/amd64 only. Kind on Docker Desktop
# Apple Silicon can run it via qemu after the image is loaded into the node.
set -euo pipefail

IMG="${BOUNCER_IMAGE:-ghcr.io/kdwils/envoy-proxy-bouncer:v0.6.2}"
CLUSTER="${KIND_CLUSTER_NAME:-homeworld-e2e}"

log() { printf '[load-bouncer-image] %s\n' "$*"; }

log "pulling ${IMG} linux/amd64"
docker pull --platform linux/amd64 "${IMG}"
kind load docker-image --name "${CLUSTER}" "${IMG}"
log "loaded ${IMG} into kind cluster ${CLUSTER}"
