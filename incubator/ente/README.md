export ENTE_KEY_ENCRYPTION=$(openssl rand -base64 32)
export ENTE_KEY_HASH=$(openssl rand -base64 64)
export ENTE_JWT_SECRET=$(openssl rand -base64 32 | tr '+/' '-_' | tr -d '=')