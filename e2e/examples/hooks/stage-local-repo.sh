#!/usr/bin/env bash
# Copy apps/, swap production coordinates for kind, rewrite Application sources, serve git:// on :9418.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
STAGING="${HOMEWORLD_E2E_GIT:-/tmp/homeworld-e2e-git}"
OUT_DIR="${INFISICAL_E2E_OUT:-/tmp/homeworld-e2e-infisical}"
GENERATED="${ROOT}/e2e/examples/.generated"
GIT_PID="${HOMEWORLD_E2E_GIT_PID:-/tmp/homeworld-e2e-git-daemon.pid}"
GIT_SERVE="${HOMEWORLD_E2E_GIT_SERVE:-/tmp/homeworld-e2e-git-serve}"
INFISICAL_HOST="${INFISICAL_HOST:-http://host.docker.internal:8080}"
# Production coordinates committed in apps/ (README "Manual Setup").
readonly PROD_GATEWAY_VIP=192.168.8.50
readonly PROD_INFISICAL_HOST=https://eu.infisical.com
readonly PROD_INFISICAL_HOSTNAME=eu.infisical.com

log() { printf '[stage-local-repo] %s\n' "$*"; }

require_tools() {
  command -v rsync >/dev/null || { log "rsync required"; exit 1; }
  command -v git >/dev/null || { log "git required"; exit 1; }
  command -v python3 >/dev/null || { log "python3 required"; exit 1; }
  command -v kubectl >/dev/null || { log "kubectl required"; exit 1; }
  command -v openssl >/dev/null || { log "openssl required"; exit 1; }
}

b64() { printf '%s' "$1" | base64 | tr -d '\n'; }

load_infisical_creds() {
  local raw_id raw_secret
  raw_id="$(cat "${OUT_DIR}/client_id" 2>/dev/null || true)"
  raw_secret="$(cat "${OUT_DIR}/client_secret" 2>/dev/null || true)"
  if [[ -z "${raw_id}" || -z "${raw_secret}" ]]; then
    log "missing ${OUT_DIR}/client_id or client_secret (run seed-infisical.sh first)"
    exit 1
  fi
  # The credentials are applied directly to the cluster by
  # apply-eso-credentials.sh; they never enter the staged tree.
}

node_internal_ip() {
  kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}'
}

copy_tree() {
  rm -rf "${STAGING}"
  mkdir -p "${STAGING}"
  rsync -a --delete \
    --exclude '.git/' \
    "${ROOT}/apps/" "${STAGING}/apps/"
}

kind_coordinates() {
  local ip
  ip="${KIND_GATEWAY_IP:-}"
  if [[ -z "${ip}" ]]; then
    ip="$(node_internal_ip)"
  fi
  if [[ -z "${ip}" ]]; then
    log "could not read kind node InternalIP"
    exit 1
  fi
  KIND_GATEWAY_IP="${ip}"
  INFISICAL_HOSTNAME="${INFISICAL_HOSTNAME:-host.docker.internal}"
  log "Gateway VIP ${PROD_GATEWAY_VIP} -> ${KIND_GATEWAY_IP}; Infisical ${PROD_INFISICAL_HOST} -> ${INFISICAL_HOST}"
}

# The tracked tree carries production coordinates as literals (README
# "Manual Setup"); swap the ones kind cannot use. The homeworld.internal
# domain and the Infisical project/environment (homeworld/prod) stay as-is.
rewrite_coordinates() {
  local f
  while IFS= read -r -d '' f; do
    sed -i.bak \
      -e "s#${PROD_INFISICAL_HOST//./\\.}#${INFISICAL_HOST}#g" \
      -e "s#${PROD_INFISICAL_HOSTNAME//./\\.}#${INFISICAL_HOSTNAME}#g" \
      -e "s#${PROD_GATEWAY_VIP//./\\.}#${KIND_GATEWAY_IP}#g" \
      "${f}"
    rm -f "${f}.bak"
  done < <(find "${STAGING}/apps" \( -name '*.yaml' -o -name '*.yml' -o -name '*.tmpl' \) -print0)
}

apply_static_overlays() {
  python3 "${ROOT}/e2e/examples/hooks/rewrite-staging.py" "${STAGING}"
}

stop_git_daemon() {
  if [[ -f "${GIT_PID}" ]]; then
    kill "$(cat "${GIT_PID}")" >/dev/null 2>&1 || true
    rm -f "${GIT_PID}"
  fi
  # Leftover daemons from a previous run keep serving (and mutating) the
  # bare repo; rm -rf + clone --bare then races on objects/*.
  pkill -f "git daemon .*--base-path=${GIT_SERVE}" >/dev/null 2>&1 || true
  pkill -f "git-daemon .*--base-path=${GIT_SERVE}" >/dev/null 2>&1 || true
  sleep 0.5
}

commit_and_serve() {
  git -C "${STAGING}" init -q
  git -C "${STAGING}" config gc.auto 0
  git -C "${STAGING}" add apps
  git -C "${STAGING}" \
    -c user.email=e2e@example.com \
    -c user.name=e2e \
    commit -q -m "homeworld e2e staging"
  stop_git_daemon
  rm -rf "${GIT_SERVE}"
  mkdir -p "${GIT_SERVE}"
  # push --mirror into a fresh bare repo. git clone --bare --local copies
  # loose objects one-by-one and races with auto-gc / a dying git-daemon
  # unlinking objects/<xx>/ (ENOENT).
  local dest="${GIT_SERVE}/homeworld.git" n
  for n in 1 2 3; do
    rm -rf "${dest}"
    git init --bare -q "${dest}"
    if git -C "${STAGING}" push --mirror --quiet "${dest}"; then
      break
    fi
    if [[ "${n}" -eq 3 ]]; then
      log "git push --mirror failed after ${n} attempts"
      exit 128
    fi
    log "git push --mirror attempt ${n} failed; retrying"
    sleep 1
  done
  git daemon --reuseaddr --detach --pid-file="${GIT_PID}" \
    --export-all --base-path="${GIT_SERVE}" --listen=0.0.0.0 --port=9418
  log "git daemon pid=$(cat "${GIT_PID}") serving git://127.0.0.1:9418/homeworld.git"
  wait_git_reachable
}

# Argo CD's first comparison runs seconds after this hook. If the daemon is
# not yet reachable through the Docker VM (seen right after a Lima VM
# restart), wave -1's External Secrets app records a ComparisonError but
# still reports Healthy, the waves advance, and argocd-app switches the
# controllers to Dragonfly credentials that External Secrets never
# created, wedging the run. Wait until the kind node can open the port.
wait_git_reachable() {
  local node deadline=$((SECONDS + 60))
  node="$(kind get nodes --name "${KIND_CLUSTER_NAME:-homeworld-e2e}" 2>/dev/null | head -n 1)"
  [[ -n "${node}" ]] || return 0
  until docker exec "${node}" bash -c 'exec 3<>/dev/tcp/host.docker.internal/9418' >/dev/null 2>&1; do
    if (( SECONDS >= deadline )); then
      log "git daemon not reachable from ${node} after 60s"
      exit 1
    fi
    sleep 2
  done
  log "git daemon reachable from ${node}"
}

publish_generated() {
  mkdir -p "${GENERATED}"
  cp "${STAGING}/apps/app-of-apps.yaml" "${GENERATED}/app-of-apps.yaml"
  log "wrote ${GENERATED}/app-of-apps.yaml"
}

require_tools
load_infisical_creds
copy_tree
kind_coordinates
rewrite_coordinates
apply_static_overlays
commit_and_serve
publish_generated
log "staging ready at ${STAGING}"
