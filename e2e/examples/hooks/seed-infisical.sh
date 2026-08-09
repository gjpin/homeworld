#!/usr/bin/env bash
# Seed a local Infisical instance for homeworld E2E.
# Pins behavior to Infisical HTTP API; requires curl and jq.
# Optional: INFISICAL_CLI (default: infisical) if API bootstrap is awkward.
set -euo pipefail

INFISICAL_HOST_LOCAL="${INFISICAL_HOST_LOCAL:-http://127.0.0.1:8080}"
# URL pods use to reach Infisical on the Docker host (kind).
INFISICAL_HOST="${INFISICAL_HOST:-http://host.docker.internal:8080}"
INFISICAL_PROJECT_SLUG="${INFISICAL_PROJECT_SLUG:-homeworld}"
INFISICAL_ENVIRONMENT_SLUG="${INFISICAL_ENVIRONMENT_SLUG:-prod}"
ADMIN_EMAIL="${INFISICAL_ADMIN_EMAIL:-e2e-admin@example.com}"
ADMIN_PASSWORD="${INFISICAL_ADMIN_PASSWORD:-E2eAdminPassw0rd!}"
ORG_NAME="${INFISICAL_ORG_NAME:-homeworld-e2e}"
OUT_DIR="${INFISICAL_E2E_OUT:-/tmp/homeworld-e2e-infisical}"
CLI_VERSION_HINT="0.41.90"

mkdir -p "${OUT_DIR}"

log() { printf '[seed-infisical] %s\n' "$*"; }

wait_ready() {
  local deadline=$((SECONDS + 300))
  while (( SECONDS < deadline )); do
    if curl -sf "${INFISICAL_HOST_LOCAL}/api/status" >/dev/null 2>&1; then
      log "API ready at ${INFISICAL_HOST_LOCAL}"
      return 0
    fi
    sleep 2
  done
  log "timeout waiting for ${INFISICAL_HOST_LOCAL}/api/status"
  return 1
}

require_tools() {
  command -v curl >/dev/null || { log "curl required"; exit 1; }
  command -v jq >/dev/null || { log "jq required"; exit 1; }
  command -v openssl >/dev/null || { log "openssl required"; exit 1; }
  if ! command -v infisical >/dev/null 2>&1; then
    log "note: infisical CLI not found; using HTTP API only (pin CLI ${CLI_VERSION_HINT} if you prefer CLI bootstrap)"
  fi
}

# Best-effort signup / login. Infisical self-host first-run APIs evolve;
# this script records credentials for apply-eso-credentials.sh.
bootstrap_admin() {
  local signup_payload login_payload token
  signup_payload=$(jq -n \
    --arg email "${ADMIN_EMAIL}" \
    --arg password "${ADMIN_PASSWORD}" \
    --arg firstName "E2E" \
    --arg lastName "Admin" \
    --arg organizationName "${ORG_NAME}" \
    '{email:$email,password:$password,firstName:$firstName,lastName:$lastName,organizationName:$organizationName}')

  # Ignore failures if admin already exists.
  curl -sf -X POST "${INFISICAL_HOST_LOCAL}/api/v1/signup" \
    -H 'Content-Type: application/json' \
    -d "${signup_payload}" >"${OUT_DIR}/signup.json" 2>/dev/null || true

  login_payload=$(jq -n \
    --arg email "${ADMIN_EMAIL}" \
    --arg password "${ADMIN_PASSWORD}" \
    '{email:$email,password:$password}')

  if ! curl -sf -X POST "${INFISICAL_HOST_LOCAL}/api/v1/auth/login" \
    -H 'Content-Type: application/json' \
    -d "${login_payload}" >"${OUT_DIR}/login.json"; then
    # Try alternate login path used by newer Infisical builds.
    curl -sf -X POST "${INFISICAL_HOST_LOCAL}/api/v1/auth/login/email" \
      -H 'Content-Type: application/json' \
      -d "${login_payload}" >"${OUT_DIR}/login.json" || {
        log "login failed; write placeholder credentials and continue (manual seed may be required)"
        write_placeholders
        return 0
      }
  fi

  token=$(jq -r '.token // .accessToken // .identity.accessToken // empty' "${OUT_DIR}/login.json")
  if [[ -z "${token}" ]]; then
    log "could not parse login token; writing placeholders"
    write_placeholders
    return 0
  fi
  printf '%s' "${token}" >"${OUT_DIR}/token"

  ensure_project "${token}"
  ensure_identity "${token}"
  seed_secrets "${token}"
}

write_placeholders() {
  # Deterministic placeholders so apply-eso-credentials can still run in dry setups.
  printf 'e2e-client-id-placeholder' >"${OUT_DIR}/client_id"
  printf 'e2e-client-secret-placeholder' >"${OUT_DIR}/client_secret"
  printf '%s' "${INFISICAL_HOST}" >"${OUT_DIR}/host"
  printf '%s' "${INFISICAL_PROJECT_SLUG}" >"${OUT_DIR}/project_slug"
  printf '%s' "${INFISICAL_ENVIRONMENT_SLUG}" >"${OUT_DIR}/environment_slug"
}

ensure_project() {
  local token="$1"
  local projects project_id
  projects=$(curl -sf "${INFISICAL_HOST_LOCAL}/api/v1/workspace" \
    -H "Authorization: Bearer ${token}" || echo '{"workspaces":[]}')
  project_id=$(jq -r --arg slug "${INFISICAL_PROJECT_SLUG}" \
    '.workspaces[]? | select(.slug==$slug or .name==$slug) | .id' <<<"${projects}" | head -n1)

  if [[ -z "${project_id}" || "${project_id}" == "null" ]]; then
    curl -sf -X POST "${INFISICAL_HOST_LOCAL}/api/v1/workspace" \
      -H "Authorization: Bearer ${token}" \
      -H 'Content-Type: application/json' \
      -d "$(jq -n --arg name "${INFISICAL_PROJECT_SLUG}" --arg slug "${INFISICAL_PROJECT_SLUG}" '{workspaceName:$name,slug:$slug}')" \
      >"${OUT_DIR}/project.json" || true
    project_id=$(jq -r '.workspace.id // .id // empty' "${OUT_DIR}/project.json" 2>/dev/null || true)
  fi
  printf '%s' "${project_id:-}" >"${OUT_DIR}/project_id"
  printf '%s' "${INFISICAL_PROJECT_SLUG}" >"${OUT_DIR}/project_slug"
  printf '%s' "${INFISICAL_ENVIRONMENT_SLUG}" >"${OUT_DIR}/environment_slug"
  printf '%s' "${INFISICAL_HOST}" >"${OUT_DIR}/host"
  log "project slug=${INFISICAL_PROJECT_SLUG} id=${project_id:-unknown}"
}

ensure_identity() {
  local token="$1"
  # Universal Auth machine identity — best effort; APIs differ by version.
  local payload resp client_id client_secret
  payload=$(jq -n --arg name "homeworld-eso" '{name:$name,role:"admin"}')
  resp=$(curl -sf -X POST "${INFISICAL_HOST_LOCAL}/api/v1/identities" \
    -H "Authorization: Bearer ${token}" \
    -H 'Content-Type: application/json' \
    -d "${payload}" 2>/dev/null || echo '{}')
  echo "${resp}" >"${OUT_DIR}/identity.json"
  client_id=$(jq -r '.identity.id // .clientId // empty' <<<"${resp}")
  client_secret=$(jq -r '.identity.clientSecret // .clientSecret // empty' <<<"${resp}")

  if [[ -z "${client_id}" || -z "${client_secret}" ]]; then
    log "identity create did not return UA credentials; using placeholders (complete via Infisical UI/CLI ${CLI_VERSION_HINT})"
    write_placeholders
    return 0
  fi
  printf '%s' "${client_id}" >"${OUT_DIR}/client_id"
  printf '%s' "${client_secret}" >"${OUT_DIR}/client_secret"
}

seed_secrets() {
  local token="$1"
  local project_id authelia_jwk authelia_users
  project_id=$(cat "${OUT_DIR}/project_id" 2>/dev/null || true)
  if [[ -z "${project_id}" ]]; then
    log "skip secret seed (no project id)"
    return 0
  fi

  authelia_jwk=$(openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 2>/dev/null)
  authelia_users=$(printf '%s\n' \
    'users:' \
    '  e2e:' \
    '    disabled: false' \
    '    displayname: E2E User' \
    "    password: '\$argon2id\$v=19\$m=65536,t=3,p=2\$BpLnfgDsc2WD8F2q\$o/vzA4myCqZZ36bUGsDY//8mKUYNZZaR0t4MFFSs+iM'" \
    '    email: e2e@example.com' \
    '    groups:' \
    '      - opencloud-admin')

  # Placeholder values matching ExternalSecret remoteRef keys used by homeworld apps.
  local secrets=(
    "/grafana/GF_SECURITY_ADMIN_USER=admin"
    "/grafana/GF_SECURITY_ADMIN_PASSWORD=e2e-grafana"
    "/authelia/POSTGRES_USERNAME=authelia"
    "/authelia/POSTGRES_PASSWORD=e2e-authelia-db"
    "/authelia/DRAGONFLY_PASSWORD=e2e-authelia-dragonfly"
    "/authelia/RESET_PASSWORD_JWT_SECRET=rrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrr"
    "/authelia/SESSION_SECRET=ssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssss"
    "/authelia/STORAGE_ENCRYPTION_KEY=eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
    "/authelia/OIDC_HMAC_SECRET=hhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhh"
    "/authelia/OIDC_JWK_RS256=${authelia_jwk}"
    "/authelia/SMTP_PASSWORD=e2e-authelia-smtp"
    "/authelia/USERS_DATABASE=${authelia_users}"
    "/immich/POSTGRES_USERNAME=immich"
    "/immich/POSTGRES_PASSWORD=e2e-immich-db"
    "/immich/DRAGONFLY_PASSWORD=e2e-immich-redis"
    "/forgejo/POSTGRES_USERNAME=forgejo"
    "/forgejo/POSTGRES_PASSWORD=e2e-forgejo-db"
    "/openobserve/ZO_ROOT_USER_EMAIL=e2e@example.com"
    "/openobserve/ZO_ROOT_USER_PASSWORD=e2e-openobserve"
    "/openobserve/OTLP_AUTHORIZATION=Basic e2e"
    "/rustfs/RUSTFS_ACCESS_KEY=e2eaccesskey"
    "/rustfs/RUSTFS_SECRET_KEY=e2esecretkey"
    "/velero-ui/AUTH_SECRET_PASSPHRASE=e2e-velero-ui"
    "/velero-ui/BASIC_AUTH_USERNAME=e2e"
    "/velero-ui/BASIC_AUTH_PASSWORD=e2e-velero"
    "/velero/B2_APPLICATION_KEY_ID=e2e-b2-id"
    "/velero/B2_APPLICATION_KEY=e2e-b2-key"
    "/velero/KOPIA_REPOSITORY_PASSWORD=e2e-kopia"
    "/longhorn/CRYPTO_KEY_VALUE=e2e-longhorn-crypto"
  )

  local entry path key value
  for entry in "${secrets[@]}"; do
    path="${entry%%=*}"
    value="${entry#*=}"
    key="${path##*/}"
    # Best-effort create; ignore conflicts.
    curl -sf -X POST "${INFISICAL_HOST_LOCAL}/api/v3/secrets/raw/${key}" \
      -H "Authorization: Bearer ${token}" \
      -H 'Content-Type: application/json' \
      -d "$(jq -n \
        --arg workspaceId "${project_id}" \
        --arg environment "${INFISICAL_ENVIRONMENT_SLUG}" \
        --arg secretPath "${path%/*}" \
        --arg secretValue "${value}" \
        '{workspaceId:$workspaceId,environment:$environment,secretPath:$secretPath,type:"shared",secretValue:$secretValue}')" \
      >/dev/null 2>&1 || true
  done
  log "secret seed attempted for ${#secrets[@]} keys"
}

require_tools
wait_ready
bootstrap_admin
log "credentials written under ${OUT_DIR}"
