#!/usr/bin/env bash
# Render the deployment tree: copy apps/, substitute the ${VARIABLE}
# allowlist, and produce a deployable git checkout (local dir or a push to
# the git remote Argo CD tracks).
#
# This script codifies the production envsubst pipeline that previously
# lived only in the e2e staging hook (e2e/examples/hooks/stage-local-repo.sh
# — same allowlist semantics): every ${VARIABLE} outside the allowlist is
# preserved verbatim. That protection is load-bearing:
#   * $argocd-oidc:clientSecret (apps/argocd/helm/values.yaml) is read by
#     Argo CD itself from a Secret and must survive rendering untouched;
#   * ${DB_PASSWORD} / ${REGISTRATION_TOKEN} (apps/crowdsec/helm/values.yaml)
#     are CrowdSec's own runtime expansions and must never be baked into
#     the ConfigMap in cleartext.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STAGING="${1:-}"
REMOTE="${2:-}"

log() { printf '[render-deploy] %s\n' "$*"; }

if [[ $# -lt 1 ]]; then
  cat <<'EOF'
Usage:
  scripts/render-deploy.sh <output-dir>              # render into a git repo checkout
  scripts/render-deploy.sh <output-dir> <git-remote> # render, commit, and push

Required environment variables (unquoted empty values fail):
  BASE_DOMAIN                    public DNS suffix for every route
  EXTERNAL_IP                    the Gateway listener's public address
  INFISICAL_HOST                 Infisical API base URL
  INFISICAL_HOSTNAME             Infisical hostname the CNP FQDN-allowlists
  INFISICAL_PROJECT_SLUG         Infisical project
  INFISICAL_ENVIRONMENT_SLUG     Infisical environment
  ACME_EMAIL                     ACME account email
  AUTHELIA_SMTP_HOST             Authelia SMTP relay host
  AUTHELIA_SMTP_USERNAME         Authelia SMTP username
  AUTHELIA_SMTP_SENDER           Authelia SMTP sender
  B2_BUCKET                      Velero Backblaze B2 bucket
  B2_REGION                      Velero Backblaze B2 region
EOF
  exit 1
fi

command -v rsync >/dev/null || { log "rsync required"; exit 1; }
command -v envsubst >/dev/null || { log "envsubst (gettext) required"; exit 1; }
command -v git >/dev/null || { log "git required"; exit 1; }

# The allowlist — keep in sync with e2e/examples/hooks/stage-local-repo.sh.
readonly VARS='${BASE_DOMAIN} ${EXTERNAL_IP} ${INFISICAL_HOST} ${INFISICAL_HOSTNAME} ${INFISICAL_PROJECT_SLUG} ${INFISICAL_ENVIRONMENT_SLUG} ${ACME_EMAIL} ${AUTHELIA_SMTP_HOST} ${AUTHELIA_SMTP_USERNAME} ${AUTHELIA_SMTP_SENDER} ${B2_BUCKET} ${B2_REGION}'

for var in BASE_DOMAIN EXTERNAL_IP INFISICAL_HOST INFISICAL_HOSTNAME \
           INFISICAL_PROJECT_SLUG INFISICAL_ENVIRONMENT_SLUG ACME_EMAIL \
           AUTHELIA_SMTP_HOST AUTHELIA_SMTP_USERNAME AUTHELIA_SMTP_SENDER \
           B2_BUCKET B2_REGION; do
  if [[ -z "${!var:-}" ]]; then
    log "required variable ${var} is unset or empty"
    exit 1
  fi
done

log "copying apps/ to ${STAGING}"
mkdir -p "${STAGING}"
rsync -a --delete \
  --exclude '.git/' \
  "${ROOT}/apps/" "${STAGING}/apps/"

log "substituting the ${VARIABLE} allowlist (everything else is preserved)"
while IFS= read -r -d '' f; do
  tmp="$(mktemp)"
  envsubst "${VARS}" <"${f}" >"${tmp}"
  mv "${tmp}" "${f}"
done < <(find "${STAGING}/apps" \( -name '*.yaml' -o -name '*.yml' -o -name '*.tmpl' \) -print0)

if [[ -n "${REMOTE}" ]]; then
  log "committing and pushing to ${REMOTE}"
  git -C "${STAGING}" init -q 2>/dev/null || true
  git -C "${STAGING}" add -A
  git -C "${STAGING}" commit -qm "Rendered deployment $(date -u +%Y-%m-%dT%H:%M:%SZ)" || true
  git -C "${STAGING}" push -qf "${REMOTE}" "HEAD:main"
  log "pushed ${REMOTE} HEAD:main"
else
  log "rendered tree ready at ${STAGING}/apps"
fi
