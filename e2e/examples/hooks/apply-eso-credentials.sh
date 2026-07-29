#!/usr/bin/env bash
# Apply External Secrets universal-auth credentials for local Infisical.
# Reads client id/secret from seed-infisical.sh output (or env overrides).
set -euo pipefail

OUT_DIR="${INFISICAL_E2E_OUT:-/tmp/homeworld-e2e-infisical}"
INFISICAL_HOST="${INFISICAL_HOST:-$(cat "${OUT_DIR}/host" 2>/dev/null || echo 'http://host.docker.internal:8080')}"
INFISICAL_CLIENT_ID="${INFISICAL_CLIENT_ID:-$(cat "${OUT_DIR}/client_id" 2>/dev/null || true)}"
INFISICAL_CLIENT_SECRET="${INFISICAL_CLIENT_SECRET:-$(cat "${OUT_DIR}/client_secret" 2>/dev/null || true)}"
INFISICAL_PROJECT_SLUG="${INFISICAL_PROJECT_SLUG:-$(cat "${OUT_DIR}/project_slug" 2>/dev/null || echo homeworld)}"
INFISICAL_ENVIRONMENT_SLUG="${INFISICAL_ENVIRONMENT_SLUG:-$(cat "${OUT_DIR}/environment_slug" 2>/dev/null || echo prod)}"

if [[ -z "${INFISICAL_CLIENT_ID}" || -z "${INFISICAL_CLIENT_SECRET}" ]]; then
  echo "[apply-eso-credentials] missing INFISICAL_CLIENT_ID/SECRET (run seed-infisical.sh first)" >&2
  exit 1
fi

# Base64 without newlines (GNU/BSD).
b64() { printf '%s' "$1" | base64 | tr -d '\n'; }

NS=external-secrets
kubectl get ns "${NS}" >/dev/null 2>&1 || kubectl create namespace "${NS}"

kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: universal-auth-credentials
  namespace: ${NS}
type: Opaque
data:
  clientId: $(b64 "${INFISICAL_CLIENT_ID}")
  clientSecret: $(b64 "${INFISICAL_CLIENT_SECRET}")
EOF

# Export for subsequent envsubst of ClusterSecretStore if callers need them.
export INFISICAL_HOST INFISICAL_CLIENT_ID INFISICAL_CLIENT_SECRET
export INFISICAL_PROJECT_SLUG INFISICAL_ENVIRONMENT_SLUG

# Materialize a small env file for later hooks / manual envsubst.
cat >"${OUT_DIR}/eso.env" <<EOF
export INFISICAL_HOST=${INFISICAL_HOST}
export INFISICAL_CLIENT_ID=${INFISICAL_CLIENT_ID}
export INFISICAL_CLIENT_SECRET=${INFISICAL_CLIENT_SECRET}
export INFISICAL_PROJECT_SLUG=${INFISICAL_PROJECT_SLUG}
export INFISICAL_ENVIRONMENT_SLUG=${INFISICAL_ENVIRONMENT_SLUG}
EOF

echo "[apply-eso-credentials] applied Secret/${NS}/universal-auth-credentials"
echo "[apply-eso-credentials] INFISICAL_HOST=${INFISICAL_HOST}"
echo "[apply-eso-credentials] env exported to ${OUT_DIR}/eso.env"
