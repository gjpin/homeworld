#!/usr/bin/env bash
# Load envoy-proxy-bouncer image into the kind node.
#
# Not wired into the suite's hook list: the kind registry mirror pulls the
# image from ghcr.io directly during deploy. Run it manually only when the
# pull fails in an airgapped/slow environment:
#   BOUNCER_IMAGE=ghcr.io/kdwils/envoy-proxy-bouncer:<tag> KIND_CLUSTER_NAME=homeworld-e2e \
#     ./e2e/examples/hooks/load-bouncer-image.sh
# The pinned default tag stays aligned with apps/crowdsec-envoy-bouncer
# (Renovate's e2e load-hook image manager keeps them in sync).
set -euo pipefail

IMG="${BOUNCER_IMAGE:-ghcr.io/kdwils/envoy-proxy-bouncer:v0.8.1}"
CLUSTER="${KIND_CLUSTER_NAME:-homeworld-e2e}"

log() { printf '[load-bouncer-image] %s\n' "$*"; }

log "pulling ${IMG}"
docker pull "${IMG}"
kind load docker-image --name "${CLUSTER}" "${IMG}"
