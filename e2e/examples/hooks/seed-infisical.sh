#!/usr/bin/env bash
# Seed a local Infisical instance for homeworld E2E.
# Pinned to the Infisical HTTP API (see the infisical/infisical tag pinned in e2e/examples/infisical/docker-compose.yml).
#
# Bootstrap's machine-identity JWT has no `exp`. After
# LEGACY_IDENTITY_ACCESS_TOKEN_EXPIRATION_ENFORCED_AT (2026-05-04) Infisical
# rejects those tokens, so this script authenticates as the admin *user*
# (POST /api/v3/auth/login + select-organization) and uses that JWT.
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
IDENTITY_NAME="${INFISICAL_IDENTITY_NAME:-homeworld-eso}"
USER_AGENT="${INFISICAL_USER_AGENT:-homeworld-e2e-seed}"

mkdir -p "${OUT_DIR}"

log() { printf '[seed-infisical] %s\n' "$*"; }

api() {
  # api METHOD PATH [json-body] [token] — writes body to ${OUT_DIR}/last.json, prints HTTP code.
  local method="$1" path="$2" body="${3:-}" token="${4:-}"
  local args=(-sS -o "${OUT_DIR}/last.json" -w '%{http_code}'
    -X "${method}" "${INFISICAL_HOST_LOCAL}${path}"
    -H 'Content-Type: application/json'
    -H "User-Agent: ${USER_AGENT}")
  if [[ -n "${token}" ]]; then
    args+=(-H "Authorization: Bearer ${token}")
  fi
  if [[ -n "${body}" ]]; then
    args+=(-d "${body}")
  fi
  curl "${args[@]}"
}

require_ok() {
  local code="$1" what="$2"
  if [[ "${code}" != "200" && "${code}" != "201" ]]; then
    log "FAILED ${what} (HTTP ${code})"
    cat "${OUT_DIR}/last.json" >&2 || true
    exit 1
  fi
}

ok_or_exists() {
  local code="$1"
  [[ "${code}" == "200" || "${code}" == "201" || "${code}" == "400" || "${code}" == "409" ]]
}

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
}

# First-run: POST /api/v1/admin/bootstrap. The returned identity token is
# unusable after the 2026-05-04 legacy-token cutoff; we only need the user.
bootstrap_instance() {
  local code
  code=$(api POST /api/v1/admin/bootstrap "$(jq -n \
    --arg email "${ADMIN_EMAIL}" \
    --arg password "${ADMIN_PASSWORD}" \
    --arg organization "${ORG_NAME}" \
    '{email:$email,password:$password,organization:$organization}')")
  cp "${OUT_DIR}/last.json" "${OUT_DIR}/bootstrap.json"
  if [[ "${code}" == "200" || "${code}" == "201" ]]; then
    jq -r '.organization.id // empty' "${OUT_DIR}/bootstrap.json" >"${OUT_DIR}/org_id"
    log "bootstrapped org=$(cat "${OUT_DIR}/org_id")"
    return 0
  fi
  log "bootstrap returned HTTP ${code}; assuming instance already initialized"
}

# User JWT (has exp). Requires User-Agent. Then bind it to the org.
login_user() {
  local code login_token org_id
  code=$(api POST /api/v3/auth/login "$(jq -n \
    --arg email "${ADMIN_EMAIL}" \
    --arg password "${ADMIN_PASSWORD}" \
    '{email:$email,password:$password}')")
  require_ok "${code}" "login ${ADMIN_EMAIL}"
  cp "${OUT_DIR}/last.json" "${OUT_DIR}/login.json"
  login_token=$(jq -r '.accessToken // empty' "${OUT_DIR}/login.json")
  if [[ -z "${login_token}" ]]; then
    log "login response missing accessToken"
    cat "${OUT_DIR}/login.json" >&2
    exit 1
  fi

  code=$(api GET /api/v1/organization "" "${login_token}")
  require_ok "${code}" "list organizations"
  cp "${OUT_DIR}/last.json" "${OUT_DIR}/organizations.json"
  org_id=$(jq -r --arg name "${ORG_NAME}" \
    '.organizations[] | select(.name==$name) | .id' "${OUT_DIR}/organizations.json" | head -1)
  if [[ -z "${org_id}" ]]; then
    org_id=$(jq -r '.organizations[0].id // empty' "${OUT_DIR}/organizations.json")
  fi
  if [[ -z "${org_id}" ]]; then
    log "no organization found after login"
    cat "${OUT_DIR}/organizations.json" >&2
    exit 1
  fi
  printf '%s' "${org_id}" >"${OUT_DIR}/org_id"

  code=$(api POST /api/v3/auth/select-organization "$(jq -n \
    --arg organizationId "${org_id}" \
    '{organizationId:$organizationId}')" "${login_token}")
  require_ok "${code}" "select-organization ${org_id}"
  cp "${OUT_DIR}/last.json" "${OUT_DIR}/select-org.json"
  jq -r '.token // empty' "${OUT_DIR}/select-org.json" >"${OUT_DIR}/token"
  if [[ ! -s "${OUT_DIR}/token" ]]; then
    log "select-organization response missing token"
    cat "${OUT_DIR}/select-org.json" >&2
    exit 1
  fi
  log "logged in org=${org_id}"
}

ensure_project() {
  local token org_id code project_id slug
  token=$(cat "${OUT_DIR}/token")
  org_id=$(cat "${OUT_DIR}/org_id")

  code=$(api GET "/api/v1/projects/slug/${INFISICAL_PROJECT_SLUG}" "" "${token}")
  if [[ "${code}" == "200" ]]; then
    cp "${OUT_DIR}/last.json" "${OUT_DIR}/project.json"
  else
    code=$(api POST /api/v1/projects "$(jq -n \
      --arg name "${INFISICAL_PROJECT_SLUG}" \
      --arg slug "${INFISICAL_PROJECT_SLUG}" \
      '{projectName:$name,slug:$slug,shouldCreateDefaultEnvs:true}')" "${token}")
    require_ok "${code}" "create project ${INFISICAL_PROJECT_SLUG}"
    cp "${OUT_DIR}/last.json" "${OUT_DIR}/project.json"
  fi

  project_id=$(jq -r '.project.id // .id // empty' "${OUT_DIR}/project.json")
  slug=$(jq -r '.project.slug // .slug // empty' "${OUT_DIR}/project.json")
  if [[ -z "${project_id}" ]]; then
    log "failed to resolve project id"
    cat "${OUT_DIR}/project.json" >&2
    exit 1
  fi
  if ! jq -e --arg env "${INFISICAL_ENVIRONMENT_SLUG}" \
    '(.project.environments // .environments // []) | map(.slug) | index($env) != null' \
    "${OUT_DIR}/project.json" >/dev/null; then
    log "project ${slug} has no environment slug=${INFISICAL_ENVIRONMENT_SLUG}"
    jq '.project.environments // .environments' "${OUT_DIR}/project.json" >&2 || true
    exit 1
  fi
  printf '%s' "${project_id}" >"${OUT_DIR}/project_id"
  printf '%s' "${INFISICAL_PROJECT_SLUG}" >"${OUT_DIR}/project_slug"
  printf '%s' "${INFISICAL_ENVIRONMENT_SLUG}" >"${OUT_DIR}/environment_slug"
  printf '%s' "${INFISICAL_HOST}" >"${OUT_DIR}/host"
  log "project slug=${INFISICAL_PROJECT_SLUG} id=${project_id}"
}

ensure_identity() {
  local token org_id project_id code identity_id client_id client_secret
  token=$(cat "${OUT_DIR}/token")
  org_id=$(cat "${OUT_DIR}/org_id")
  project_id=$(cat "${OUT_DIR}/project_id")

  code=$(api GET "/api/v1/identities?orgId=${org_id}" "" "${token}")
  require_ok "${code}" "list identities"
  cp "${OUT_DIR}/last.json" "${OUT_DIR}/identities.json"
  identity_id=$(jq -r --arg name "${IDENTITY_NAME}" \
    '.identities[] | select(.identity.name==$name) | .identity.id' \
    "${OUT_DIR}/identities.json" | head -1)

  if [[ -z "${identity_id}" ]]; then
    code=$(api POST /api/v1/identities "$(jq -n \
      --arg name "${IDENTITY_NAME}" \
      --arg organizationId "${org_id}" \
      '{name:$name,organizationId:$organizationId,role:"admin"}')" "${token}")
    require_ok "${code}" "create identity ${IDENTITY_NAME}"
    cp "${OUT_DIR}/last.json" "${OUT_DIR}/identity.json"
    identity_id=$(jq -r '.identity.id // empty' "${OUT_DIR}/identity.json")
  else
    log "reusing identity ${IDENTITY_NAME} id=${identity_id}"
    printf '%s\n' "{\"identity\":{\"id\":\"${identity_id}\",\"name\":\"${IDENTITY_NAME}\"}}" \
      >"${OUT_DIR}/identity.json"
  fi
  if [[ -z "${identity_id}" ]]; then
    log "failed to resolve identity id"
    exit 1
  fi
  printf '%s' "${identity_id}" >"${OUT_DIR}/identity_id"

  # Attach Universal Auth (open CIDRs so kind pods can login).
  code=$(api POST "/api/v1/auth/universal-auth/identities/${identity_id}" "$(jq -n \
    '{clientSecretTrustedIps:[{ipAddress:"0.0.0.0/0"},{ipAddress:"::/0"}],
      accessTokenTrustedIps:[{ipAddress:"0.0.0.0/0"},{ipAddress:"::/0"}],
      lockoutEnabled:false}')" "${token}")
  if ! ok_or_exists "${code}"; then
    require_ok "${code}" "attach universal-auth"
  fi
  if [[ "${code}" == "200" || "${code}" == "201" ]]; then
    cp "${OUT_DIR}/last.json" "${OUT_DIR}/universal-auth.json"
  else
    code=$(api GET "/api/v1/auth/universal-auth/identities/${identity_id}" "" "${token}")
    require_ok "${code}" "get universal-auth"
    cp "${OUT_DIR}/last.json" "${OUT_DIR}/universal-auth.json"
  fi
  client_id=$(jq -r '.identityUniversalAuth.clientId // empty' "${OUT_DIR}/universal-auth.json")
  if [[ -z "${client_id}" ]]; then
    client_id="${identity_id}"
  fi

  # --keep-deps reuses OUT_DIR across Infisical recreations. Disk secrets
  # from a previous bootstrap 401 against a new identity clientId.
  reuse=false
  if [[ -s "${OUT_DIR}/client_id" && -s "${OUT_DIR}/client_secret" ]]; then
    disk_id=$(cat "${OUT_DIR}/client_id")
    disk_secret=$(cat "${OUT_DIR}/client_secret")
    if [[ "${disk_id}" == "${client_id}" ]]; then
      code=$(curl -sS -o "${OUT_DIR}/ua-login.json" -w '%{http_code}' \
        -X POST "${INFISICAL_HOST_LOCAL}/api/v1/auth/universal-auth/login" \
        -H 'Content-Type: application/json' \
        -H "User-Agent: ${USER_AGENT}" \
        -d "$(jq -n --arg id "${disk_id}" --arg secret "${disk_secret}" \
          '{clientId:$id,clientSecret:$secret}')" || true)
      if [[ "${code}" == "200" ]]; then
        reuse=true
        log "reusing universal-auth credentials from ${OUT_DIR}"
      else
        log "stored universal-auth credentials rejected (HTTP ${code}); rotating"
      fi
    else
      log "stored clientId does not match identity ${identity_id}; rotating"
    fi
  fi
  if [[ "${reuse}" != true ]]; then
    code=$(api POST "/api/v1/auth/universal-auth/identities/${identity_id}/client-secrets" \
      '{}' "${token}")
    require_ok "${code}" "create universal-auth client secret"
    cp "${OUT_DIR}/last.json" "${OUT_DIR}/client-secret.json"
    client_secret=$(jq -r '.clientSecret // empty' "${OUT_DIR}/client-secret.json")
    if [[ -z "${client_secret}" ]]; then
      log "client-secret create did not return clientSecret"
      cat "${OUT_DIR}/client-secret.json" >&2
      exit 1
    fi
    printf '%s' "${client_id}" >"${OUT_DIR}/client_id"
    printf '%s' "${client_secret}" >"${OUT_DIR}/client_secret"
  fi

  code=$(api POST "/api/v1/projects/${project_id}/memberships/identities/${identity_id}" \
    "$(jq -n '{roles:[{role:"admin",isTemporary:false}]}')" "${token}")
  if ! ok_or_exists "${code}"; then
    require_ok "${code}" "add identity to project"
  fi
  cp "${OUT_DIR}/last.json" "${OUT_DIR}/identity-membership.json"
  log "universal-auth identity=${identity_id} clientId=$(cat "${OUT_DIR}/client_id")"
}

ensure_folder() {
  local token="$1" project_id="$2" name="$3" code
  token=$(cat "${OUT_DIR}/token")
  code=$(api POST /api/v2/folders "$(jq -n \
    --arg projectId "${project_id}" \
    --arg environment "${INFISICAL_ENVIRONMENT_SLUG}" \
    --arg name "${name}" \
    '{projectId:$projectId,environment:$environment,name:$name,path:"/"}')" "${token}")
  if ! ok_or_exists "${code}"; then
    require_ok "${code}" "create folder /${name}"
  fi
}

put_secret() {
  local token="$1" project_id="$2" path="$3" value="$4"
  local key body code
  key="${path##*/}"
  body=$(jq -n \
    --arg workspaceId "${project_id}" \
    --arg environment "${INFISICAL_ENVIRONMENT_SLUG}" \
    --arg secretPath "${path%/*}" \
    --arg secretValue "${value}" \
    '{workspaceId:$workspaceId,environment:$environment,secretPath:$secretPath,type:"shared",secretValue:$secretValue}')
  code=$(curl -sS -o "${OUT_DIR}/secret-${key}.json" -w '%{http_code}' \
    -X POST "${INFISICAL_HOST_LOCAL}/api/v3/secrets/raw/${key}" \
    -H "Authorization: Bearer ${token}" \
    -H "User-Agent: ${USER_AGENT}" \
    -H 'Content-Type: application/json' \
    -d "${body}" || true)
  if [[ "${code}" == "200" || "${code}" == "201" ]]; then
    return 0
  fi
  code=$(curl -sS -o "${OUT_DIR}/secret-${key}.json" -w '%{http_code}' \
    -X PATCH "${INFISICAL_HOST_LOCAL}/api/v3/secrets/raw/${key}" \
    -H "Authorization: Bearer ${token}" \
    -H "User-Agent: ${USER_AGENT}" \
    -H 'Content-Type: application/json' \
    -d "${body}" || true)
  if [[ "${code}" == "200" || "${code}" == "201" ]]; then
    return 0
  fi
  log "failed to upsert ${path} (HTTP ${code})"
  cat "${OUT_DIR}/secret-${key}.json" >&2 || true
  exit 1
}

seed_secrets() {
  local token project_id authelia_jwk authelia_users proof_key proof_pub folder affine_key
  token=$(cat "${OUT_DIR}/token")
  project_id=$(cat "${OUT_DIR}/project_id")

  for folder in grafana homepage authelia cloudflare immich forgejo rustfs rustfs-operator opencloud velero-ui velero argocd longhorn notesnook woodpecker vaultwarden qbittorrent homeassistant coder prowlarr sonarr radarr lidarr bazarr bindery seerr cleanuparr streamystats audiobookshelf navidrome jellyfin-auto-collections unpackerr audiomuse-ai affine; do
    ensure_folder "${token}" "${project_id}" "${folder}"
  done

  authelia_jwk=$(openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 2>/dev/null)
  proof_key=$(openssl genrsa 4096 2>/dev/null)
  proof_pub=$(printf '%s\n' "${proof_key}" | openssl rsa -pubout 2>/dev/null)
  authelia_users=$(printf '%s\n' \
    'users:' \
    '  e2e:' \
    '    disabled: false' \
    '    displayname: E2E User' \
    "    password: '\$argon2id\$v=19\$m=65536,t=3,p=2\$BpLnfgDsc2WD8F2q\$o/vzA4myCqZZ36bUGsDY//8mKUYNZZaR0t4MFFSs+iM'" \
    '    email: e2e@example.com' \
    '    groups:' \
    '      - opencloud-admin' \
    '      - grafana-admin' \
    '      - forgejo-admin' \
    '      - argocd-admin' \
    '      - immich-admin' \
    '      - consoleAdmin')

  put_secret "${token}" "${project_id}" "/argocd/DRAGONFLY_PASSWORD" "e2e-argocd-dragonfly"
  put_secret "${token}" "${project_id}" "/argocd/BASE_DOMAIN" "${BASE_DOMAIN:-homeworld.test}"
  put_secret "${token}" "${project_id}" "/grafana/GF_SECURITY_ADMIN_USER" "admin"
  put_secret "${token}" "${project_id}" "/grafana/GF_SECURITY_ADMIN_PASSWORD" "e2e-grafana"
  put_secret "${token}" "${project_id}" "/homepage/ARGOCD_TOKEN" "e2e-homepage-argocd"
  put_secret "${token}" "${project_id}" "/homepage/GRAFANA_TOKEN" "e2e-homepage-grafana"
  put_secret "${token}" "${project_id}" "/homepage/HASS_TOKEN" "e2e-homepage-hass"
  put_secret "${token}" "${project_id}" "/homepage/IMMICH_API_KEY" "e2e-homepage-immich"
  put_secret "${token}" "${project_id}" "/authelia/POSTGRES_USERNAME" "authelia"
  put_secret "${token}" "${project_id}" "/authelia/POSTGRES_PASSWORD" "e2e-authelia-db"
  put_secret "${token}" "${project_id}" "/authelia/DRAGONFLY_PASSWORD" "e2e-authelia-dragonfly"
  put_secret "${token}" "${project_id}" "/authelia/RESET_PASSWORD_JWT_SECRET" "rrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrr"
  put_secret "${token}" "${project_id}" "/authelia/SESSION_SECRET" "ssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssss"
  put_secret "${token}" "${project_id}" "/authelia/STORAGE_ENCRYPTION_KEY" "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
  put_secret "${token}" "${project_id}" "/authelia/OIDC_HMAC_SECRET" "hhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhh"
  put_secret "${token}" "${project_id}" "/authelia/OIDC_JWK_RS256" "${authelia_jwk}"
  put_secret "${token}" "${project_id}" "/authelia/OIDC_CLIENT_SECRET_GRAFANA" "e2e-oidc-grafana"
  put_secret "${token}" "${project_id}" "/authelia/OIDC_CLIENT_SECRET_FORGEJO" "e2e-oidc-forgejo"
  put_secret "${token}" "${project_id}" "/authelia/OIDC_CLIENT_SECRET_ARGOCD" "e2e-oidc-argocd"
  put_secret "${token}" "${project_id}" "/authelia/OIDC_CLIENT_SECRET_CODER" "e2e-oidc-coder"
  put_secret "${token}" "${project_id}" "/authelia/OIDC_CLIENT_SECRET_IMMICH" "e2e-oidc-immich"
  put_secret "${token}" "${project_id}" "/authelia/OIDC_CLIENT_SECRET_VELERO_UI" "e2e-oidc-velero-ui"
  put_secret "${token}" "${project_id}" "/authelia/OIDC_CLIENT_SECRET_RUSTFS" "e2e-oidc-rustfs"
  put_secret "${token}" "${project_id}" "/authelia/OIDC_CLIENT_SECRET_VAULTWARDEN" "e2e-oidc-vaultwarden"
  put_secret "${token}" "${project_id}" "/authelia/OIDC_CLIENT_SECRET_ACTUAL_BUDGET" "e2e-oidc-actual-budget"
  put_secret "${token}" "${project_id}" "/authelia/OIDC_CLIENT_SECRET_AFFINE" "e2e-oidc-affine"
  # Shared gateway-OIDC client: consumed by the authelia, envoy-gateway,
  # homepage, victoria-metrics, homeassistant, and longhorn ExternalSecrets
  # (the latter two apps are omitted on kind, but seeding the key keeps the
  # omit list independent of the secret set).
  put_secret "${token}" "${project_id}" "/authelia/OIDC_CLIENT_SECRET_ENVOY" "e2e-oidc-envoy"
  # The Home Assistant app is omitted on kind, but its ExternalSecret is
  # part of the tracked manifest set; seeding the key keeps the omit list
  # independent of the secret set.
  put_secret "${token}" "${project_id}" "/authelia/OIDC_CLIENT_SECRET_HOMEASSISTANT" "e2e-oidc-homeassistant"
  put_secret "${token}" "${project_id}" "/authelia/USERS_DATABASE" "${authelia_users}"
  # Read only by the ExternalSecrets of the cert-manager and external-dns
  # components; kind swaps the Let's Encrypt issuers for self-signed ones
  # and omits ExternalDNS, so nothing calls Cloudflare.
  put_secret "${token}" "${project_id}" "/cloudflare/API_TOKEN" "e2e-cloudflare-token"
  put_secret "${token}" "${project_id}" "/immich/POSTGRES_USERNAME" "immich"
  put_secret "${token}" "${project_id}" "/immich/POSTGRES_PASSWORD" "e2e-immich-db"
  put_secret "${token}" "${project_id}" "/immich/DRAGONFLY_PASSWORD" "e2e-immich-redis"
  put_secret "${token}" "${project_id}" "/forgejo/POSTGRES_USERNAME" "forgejo"
  put_secret "${token}" "${project_id}" "/forgejo/POSTGRES_PASSWORD" "e2e-forgejo-db"
  put_secret "${token}" "${project_id}" "/rustfs/RUSTFS_ACCESS_KEY" "e2eaccesskey"
  put_secret "${token}" "${project_id}" "/rustfs-operator/JWT_SECRET" "e2e-rustfs-operator-jwt-secret-0123456789"
  put_secret "${token}" "${project_id}" "/rustfs/RUSTFS_SECRET_KEY" "e2esecretkey"
  put_secret "${token}" "${project_id}" "/opencloud/IDM_ADMIN_PASSWORD" "e2e-opencloud-admin"
  # The RustFS operator rejects a Tenant whose provisioning users resolve to
  # the same access key (UserSecretInvalid), so every user needs its own pair.
  put_secret "${token}" "${project_id}" "/opencloud/RUSTFS_ACCESS_KEY" "e2eaccesskey-opencloud"
  put_secret "${token}" "${project_id}" "/opencloud/RUSTFS_SECRET_KEY" "e2esecretkey-opencloud"
  put_secret "${token}" "${project_id}" "/opencloud/COLLABORA_ADMIN_USER" "e2e-collabora"
  put_secret "${token}" "${project_id}" "/opencloud/COLLABORA_ADMIN_PASSWORD" "e2e-collabora-admin"
  put_secret "${token}" "${project_id}" "/opencloud/COLLABORA_PROOF_KEY" "${proof_key}"
  put_secret "${token}" "${project_id}" "/opencloud/COLLABORA_PROOF_KEY_PUB" "${proof_pub}"
  put_secret "${token}" "${project_id}" "/velero-ui/AUTH_SECRET_PASSPHRASE" "e2e-velero-ui"
  put_secret "${token}" "${project_id}" "/velero/B2_APPLICATION_KEY_ID" "e2e-b2-id"
  put_secret "${token}" "${project_id}" "/velero/B2_APPLICATION_KEY" "e2e-b2-key"
  put_secret "${token}" "${project_id}" "/velero/KOPIA_REPOSITORY_PASSWORD" "e2e-kopia"
  put_secret "${token}" "${project_id}" "/longhorn/CRYPTO_KEY_VALUE" "e2e-longhorn-crypto"
  put_secret "${token}" "${project_id}" "/notesnook/NOTESNOOK_API_SECRET" "e2e-notesnook-api-secret-0123456789abcdef0123456789abcdef"
  put_secret "${token}" "${project_id}" "/notesnook/DOCUMENTDB_USERNAME" "notesnook"
  put_secret "${token}" "${project_id}" "/notesnook/DOCUMENTDB_PASSWORD" "e2e-notesnook-db"
  put_secret "${token}" "${project_id}" "/notesnook/RUSTFS_ACCESS_KEY" "e2eaccesskey-notesnook"
  put_secret "${token}" "${project_id}" "/notesnook/RUSTFS_SECRET_KEY" "e2esecretkey-notesnook"
  # The SSE server's mail notifier: unreachable on kind by design (it fails
  # at send time, never at startup).
  put_secret "${token}" "${project_id}" "/notesnook/SMTP_USERNAME" "e2e"
  put_secret "${token}" "${project_id}" "/notesnook/SMTP_PASSWORD" "e2e-notesnook-smtp"
  put_secret "${token}" "${project_id}" "/notesnook/SMTP_HOST" "smtp.e2e.local"
  put_secret "${token}" "${project_id}" "/notesnook/SMTP_PORT" "465"
  put_secret "${token}" "${project_id}" "/woodpecker/POSTGRES_USERNAME" "woodpecker"
  put_secret "${token}" "${project_id}" "/woodpecker/POSTGRES_PASSWORD" "e2e-woodpecker-db"
  put_secret "${token}" "${project_id}" "/woodpecker/AGENT_SECRET" "e2e-woodpecker-agent-secret"
  put_secret "${token}" "${project_id}" "/woodpecker/FORGEJO_CLIENT" "e2e-woodpecker-forgejo-client"
  put_secret "${token}" "${project_id}" "/woodpecker/FORGEJO_SECRET" "e2e-woodpecker-forgejo-secret"
  put_secret "${token}" "${project_id}" "/woodpecker/PROMETHEUS_AUTH_TOKEN" "e2e-woodpecker-metrics"
  put_secret "${token}" "${project_id}" "/coder/POSTGRES_USERNAME" "coder"
  put_secret "${token}" "${project_id}" "/coder/POSTGRES_PASSWORD" "e2e-coder-db"
  # The qbittorrent app itself is omitted on kind (gluetun needs real VPN
  # credentials), but Homepage's service widgets read the WebUI pair, and
  # qBittorrent enforces a minimum username length of 3 without a colon and
  # a minimum password length of 6.
  put_secret "${token}" "${project_id}" "/qbittorrent/WEBUI_USERNAME" "e2e-qbittorrent"
  put_secret "${token}" "${project_id}" "/qbittorrent/WEBUI_PASSWORD" "e2e-qbittorrent-pass"
  put_secret "${token}" "${project_id}" "/qbittorrent/WEBUI_API_KEY" "e2e-qbittorrent-api-key"
  # Plain token instead of an Argon2 PHC string: Vaultwarden accepts it for
  # the admin panel (with a startup warning), keeping the seed dependency-free.
  put_secret "${token}" "${project_id}" "/vaultwarden/ADMIN_TOKEN" "e2e-vaultwarden-admin"
  put_secret "${token}" "${project_id}" "/vaultwarden/POSTGRES_USERNAME" "vaultwarden"
  put_secret "${token}" "${project_id}" "/vaultwarden/POSTGRES_PASSWORD" "e2e-vaultwarden-db"
  # AFFiNE signs and encrypts with a P-256 key in SEC1 PEM, the format its
  # self-host-predeploy.js would generate.
  affine_key=$(openssl ecparam -name prime256v1 -genkey -noout 2>/dev/null)
  put_secret "${token}" "${project_id}" "/affine/PRIVATE_KEY" "${affine_key}"
  put_secret "${token}" "${project_id}" "/affine/POSTGRES_USERNAME" "affine"
  put_secret "${token}" "${project_id}" "/affine/POSTGRES_PASSWORD" "e2e-affine-db"
  put_secret "${token}" "${project_id}" "/affine/DRAGONFLY_PASSWORD" "e2e-affine-dragonfly"
  put_secret "${token}" "${project_id}" "/affine/RUSTFS_ACCESS_KEY" "e2eaccesskey-affine"
  put_secret "${token}" "${project_id}" "/affine/RUSTFS_SECRET_KEY" "e2esecretkey-affine"
  put_secret "${token}" "${project_id}" "/affine/EXA_API_KEY" "e2e-affine-exa"
  put_secret "${token}" "${project_id}" "/affine/UNSPLASH_API_KEY" "e2e-affine-unsplash"
  # Media stack (docs/media-stack.md). The Servarr keys are 32 hex characters.
  put_secret "${token}" "${project_id}" "/authelia/OIDC_CLIENT_SECRET_AUDIOBOOKSHELF" "e2e-oidc-audiobookshelf"
  put_secret "${token}" "${project_id}" "/authelia/OIDC_CLIENT_SECRET_BINDERY" "e2e-oidc-bindery"
  put_secret "${token}" "${project_id}" "/authelia/OIDC_CLIENT_SECRET_CLEANUPARR" "e2e-oidc-cleanuparr"
  for app in prowlarr sonarr radarr lidarr bazarr; do
    put_secret "${token}" "${project_id}" "/${app}/API_KEY" "$(openssl rand -hex 16)"
  done
  for app in prowlarr sonarr radarr lidarr bazarr seerr cleanuparr streamystats; do
    put_secret "${token}" "${project_id}" "/${app}/POSTGRES_USERNAME" "${app}"
    put_secret "${token}" "${project_id}" "/${app}/POSTGRES_PASSWORD" "e2e-${app}-db"
  done
  put_secret "${token}" "${project_id}" "/bindery/API_KEY" "e2e-bindery-api-key"
  put_secret "${token}" "${project_id}" "/seerr/API_KEY" "e2e-seerr-api-key"
  # 60-150 characters (Unpackerr API key rules).
  put_secret "${token}" "${project_id}" "/unpackerr/METRICS_API_KEY" "$(openssl rand -hex 40)"
  put_secret "${token}" "${project_id}" "/unpackerr/UI_PASSWORD" "e2e-unpackerr-ui"
  put_secret "${token}" "${project_id}" "/streamystats/SESSION_SECRET" "e2e-streamystats-session-secret-0123456789"
  put_secret "${token}" "${project_id}" "/streamystats/INTERNAL_API_KEY" "e2e-streamystats-internal-api-key"
  put_secret "${token}" "${project_id}" "/streamystats/NEXT_SERVER_ACTIONS_ENCRYPTION_KEY" "$(openssl rand -base64 32)"
  put_secret "${token}" "${project_id}" "/audiobookshelf/JWT_SECRET_KEY" "e2e-audiobookshelf-jwt"
  put_secret "${token}" "${project_id}" "/navidrome/PASSWORD_ENCRYPTION_KEY" "e2e-navidrome-encryption-key"
  put_secret "${token}" "${project_id}" "/navidrome/LASTFM_API_KEY" "e2e-navidrome-lastfm"
  put_secret "${token}" "${project_id}" "/navidrome/LASTFM_SECRET" "e2e-navidrome-lastfm-secret"
  put_secret "${token}" "${project_id}" "/jellyfin-auto-collections/JELLYFIN_API_KEY" "e2e-jellyfin-api-key"
  put_secret "${token}" "${project_id}" "/jellyfin-auto-collections/JELLYFIN_USER_ID" "e2e-jellyfin-user"
  put_secret "${token}" "${project_id}" "/homepage/JELLYFIN_API_KEY" "e2e-homepage-jellyfin"
  put_secret "${token}" "${project_id}" "/homepage/AUDIOBOOKSHELF_API_KEY" "e2e-homepage-audiobookshelf"
  put_secret "${token}" "${project_id}" "/homepage/NAVIDROME_USER" "e2e"
  put_secret "${token}" "${project_id}" "/homepage/NAVIDROME_TOKEN" "e2e-homepage-navidrome-token"
  put_secret "${token}" "${project_id}" "/homepage/NAVIDROME_SALT" "e2e-salt"
  put_secret "${token}" "${project_id}" "/audiomuse-ai/POSTGRES_USERNAME" "audiomuse"
  put_secret "${token}" "${project_id}" "/audiomuse-ai/POSTGRES_PASSWORD" "e2e-audiomuse-db"
  put_secret "${token}" "${project_id}" "/audiomuse-ai/ADMIN_USERNAME" "e2e"
  put_secret "${token}" "${project_id}" "/audiomuse-ai/ADMIN_PASSWORD" "e2e-audiomuse-admin"
  put_secret "${token}" "${project_id}" "/audiomuse-ai/API_TOKEN" "e2e-audiomuse-api-token"
  put_secret "${token}" "${project_id}" "/audiomuse-ai/NAVIDROME_USER" "e2e"
  put_secret "${token}" "${project_id}" "/audiomuse-ai/NAVIDROME_PASSWORD" "e2e-navidrome-password"
  log "secret seed completed"
}

require_tools
wait_ready
bootstrap_instance
login_user
ensure_project
ensure_identity
seed_secrets
log "credentials written under ${OUT_DIR}"
