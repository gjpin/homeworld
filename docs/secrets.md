# Infisical Secrets

All cluster secrets are synchronized from [Infisical](https://infisical.com) by the External Secrets Operator through the `infisical` ClusterSecretStore (hourly refresh). No credentials are stored in this repository. Every key below must exist in Infisical at the listed path before the consuming component can start; missing keys leave the generated `Secret` incomplete and the pod fails with `CreateContainerConfigError`.

| Component | Infisical path | Description | Generation |
| :--- | :--- | :--- | :--- |
| **Authelia** | `/authelia/SESSION_SECRET` | Session cookie encryption secret. | `openssl rand -hex 32` |
| | `/authelia/STORAGE_ENCRYPTION_KEY` | At-rest encryption key for the SQL configuration storage. | `openssl rand -hex 32` |
| | `/authelia/USERS_DATABASE` | Full `users_database.yml` content (the authentication backend). | Handwritten YAML; per-user Argon2id digest: `docker run --rm -it docker.io/authelia/authelia authelia crypto hash generate argon2` |
| | `/authelia/POSTGRES_USERNAME` | CloudNativePG application username. | Fixed: `authelia` (the CNPG `owner` user) |
| | `/authelia/POSTGRES_PASSWORD` | CloudNativePG application password. | `openssl rand -hex 32` |
| | `/authelia/DRAGONFLY_PASSWORD` | Dragonfly (Redis) password for session storage. | `openssl rand -hex 32` |
| | `/authelia/SMTP_PASSWORD` | SMTP relay password for notification emails. | From the SMTP relay provider |
| | `/authelia/OIDC_HMAC_SECRET` | HMAC secret for the OIDC provider endpoints. | `openssl rand -hex 32` |
| | `/authelia/OIDC_JWK_RS256` | RSA private key (JWK) for signing OIDC tokens. | `openssl genrsa 2048` (private-key PEM, including the BEGIN/END lines; Authelia derives the public key) |
| | `/authelia/RESET_PASSWORD_JWT_SECRET` | JWT secret for the password-reset flow. | `openssl rand -hex 32` |
| | `/authelia/OIDC_CLIENT_SECRET_ARGOCD` | Argo CD OIDC client secret. | `openssl rand -hex 32` |
| | `/authelia/OIDC_CLIENT_SECRET_FORGEJO` | Forgejo OIDC client secret. | `openssl rand -hex 32` |
| | `/authelia/OIDC_CLIENT_SECRET_GRAFANA` | Grafana OIDC client secret. | `openssl rand -hex 32` |
| | `/authelia/OIDC_CLIENT_SECRET_HOMEASSISTANT` | Home Assistant OIDC client secret. | `openssl rand -hex 32` |
| | `/authelia/OIDC_CLIENT_SECRET_IMMICH` | Immich OIDC client secret. | `openssl rand -hex 32` |
| | `/authelia/OIDC_CLIENT_SECRET_RUSTFS` | RustFS console OIDC client secret. | `openssl rand -hex 32` |
| | `/authelia/OIDC_CLIENT_SECRET_VELERO_UI` | Velero UI OIDC client secret. | `openssl rand -hex 32` |
| | `/authelia/OIDC_CLIENT_SECRET_VAULTWARDEN` | Vaultwarden OIDC client secret. | `openssl rand -hex 32` |
| **Collabora** | `/opencloud/COLLABORA_ADMIN_USER` | Collabora admin console username. | Chosen username |
| | `/opencloud/COLLABORA_ADMIN_PASSWORD` | Collabora admin console password. | `openssl rand -hex 32` |
| | `/opencloud/COLLABORA_PROOF_KEY` | WOPI proof private key for OpenCloud ↔ Collabora requests. | `openssl genrsa -out proof_key 2048` |
| | `/opencloud/COLLABORA_PROOF_KEY_PUB` | WOPI proof public key counterpart. | `openssl rsa -in proof_key -pubout -out proof_key.pub` |
| **CrowdSec** | `/crowdsec/DB_PASSWORD` | LAPI PostgreSQL password. | `openssl rand -hex 32` |
| | `/crowdsec/ENROLL_KEY` | CrowdSec Central API enrollment key. | From the CrowdSec console (app.crowdsec.net) |
| | `/crowdsec/BOUNCER_KEY_envoy` | Envoy Gateway bouncer API key. | `openssl rand -hex 32` (the LAPI entrypoint registers it from the `BOUNCER_KEY_envoy` env var) |
| **Forgejo** | `/forgejo/POSTGRES_USERNAME` | CloudNativePG application username. | Fixed: `forgejo` (the CNPG `owner` user) |
| | `/forgejo/POSTGRES_PASSWORD` | CloudNativePG application password. | `openssl rand -hex 32` |
| **Grafana** | `/grafana/GF_SECURITY_ADMIN_USER` | Admin username (required for startup; login is via Authelia OIDC). | Chosen username |
| | `/grafana/GF_SECURITY_ADMIN_PASSWORD` | Admin password (required for startup; login is via Authelia OIDC). | Chosen strong password |
| **Homepage** | `/homepage/ARGOCD_TOKEN` | Read-only Argo CD account API token for the Argo CD widget. | Manual — README §5 |
| | `/homepage/GRAFANA_TOKEN` | Grafana service account token for the Grafana widget. | Manual — README §5 |
| | `/homepage/HASS_TOKEN` | Home Assistant long-lived access token for the Home Assistant widget. | Manual — README §5 |
| | `/homepage/IMMICH_API_KEY` | Immich API key for the Immich widget. | Manual — README §5 |
| **Immich** | `/immich/POSTGRES_USERNAME` | CloudNativePG application username. | Fixed: `immich` (the CNPG `owner` user) |
| | `/immich/POSTGRES_PASSWORD` | CloudNativePG application password. | `openssl rand -hex 32` |
| | `/immich/DRAGONFLY_PASSWORD` | Dragonfly (Redis) password for cache and job queues. | `openssl rand -hex 32` |
| **Longhorn** | `/longhorn/CRYPTO_KEY_VALUE` | Storage encryption key for the `longhorn-crypto` StorageClass. | `openssl rand -hex 32` (LUKS passphrase; existing encrypted volumes remain unlockable only with the value they were created with) |
| **Notesnook** | `/notesnook/NOTESNOOK_API_SECRET` | API session signing secret. | `openssl rand -hex 32` |
| | `/notesnook/DOCUMENTDB_USERNAME` | DocumentDB gateway username. | Chosen username |
| | `/notesnook/DOCUMENTDB_PASSWORD` | DocumentDB gateway password. | `openssl rand -hex 32` |
| | `/notesnook/RUSTFS_ACCESS_KEY` | RustFS S3 access key for note attachments. | Chosen access key ID (≥8 characters, no whitespace, `=` or `,`) |
| | `/notesnook/RUSTFS_SECRET_KEY` | RustFS S3 secret key for note attachments. | `openssl rand -hex 16` |
| | `/notesnook/SMTP_USERNAME` | SMTP relay username for invitation and notification emails. | From the SMTP relay provider |
| | `/notesnook/SMTP_PASSWORD` | SMTP relay password. | From the SMTP relay provider |
| | `/notesnook/SMTP_HOST` | SMTP relay hostname. | From the SMTP relay provider |
| | `/notesnook/SMTP_PORT` | SMTP relay port. | From the SMTP relay provider |
| **OpenChamber** | `/openchamber/OPENCHAMBER_UI_PASSWORD` | Password protecting the OpenChamber web UI. | Chosen strong password |
| | `/openchamber/OPENAI_API_KEY` | OpenAI API key for Codex CLI and OpenCode. | From OpenAI |
| | `/openchamber/GITHUB_TOKEN` | GitHub token for agent git operations. | From GitHub (needs the Copilot Requests permission — README §6) |
| **OpenCloud** | `/opencloud/IDM_ADMIN_PASSWORD` | OpenCloud IDM administrator password. | `openssl rand -hex 32` |
| | `/opencloud/RUSTFS_ACCESS_KEY` | RustFS S3 access key for primary storage. | Chosen access key ID (≥8 characters, no whitespace, `=` or `,`) |
| | `/opencloud/RUSTFS_SECRET_KEY` | RustFS S3 secret key for primary storage. | `openssl rand -hex 16` |
| **RustFS** | `/rustfs/RUSTFS_ACCESS_KEY` | Root S3 access key for the storage Tenant. | Chosen access key ID (≥8 characters, no whitespace, `=` or `,`) |
| | `/rustfs/RUSTFS_SECRET_KEY` | Root S3 secret key for the storage Tenant. | `openssl rand -hex 16` |
| **Velero** | `/velero/B2_APPLICATION_KEY_ID` | Backblaze B2 key ID for backup storage. | From the Backblaze B2 console (App Keys) |
| | `/velero/B2_APPLICATION_KEY` | Backblaze B2 application key for backup storage. | From the Backblaze B2 console (App Keys) |
| | `/velero/KOPIA_REPOSITORY_PASSWORD` | Kopia repository encryption password. | `openssl rand -hex 32` (must stay unchanged for the lifetime of the repository) |
| **Velero UI** | `/velero-ui/BASIC_AUTH_USERNAME` | Velero UI basic-auth username (required for startup; login is via Authelia OIDC). | Chosen username |
| | `/velero-ui/BASIC_AUTH_PASSWORD` | Velero UI basic-auth password (required for startup; login is via Authelia OIDC). | `openssl rand -hex 32` |
| | `/velero-ui/AUTH_SECRET_PASSPHRASE` | Session/cookie signing passphrase. | `openssl rand -hex 32` |
| **Vaultwarden** | `/vaultwarden/ADMIN_TOKEN` | Admin panel token, preferably an Argon2 PHC string. | `docker run --rm -it docker.io/vaultwarden/server /vaultwarden hash` |
| | `/vaultwarden/POSTGRES_USERNAME` | CloudNativePG application username. | Fixed: `vaultwarden` (the CNPG `owner` user) |
| | `/vaultwarden/POSTGRES_PASSWORD` | CloudNativePG application password. Must contain only RFC 3986 unreserved characters; it is embedded unescaped in the PostgreSQL connection URL. | `openssl rand -hex 32` (hex output is RFC 3986 unreserved) |
| | `/vaultwarden/SMTP_USERNAME` | SMTP relay username for invitation and notification emails. | From the SMTP relay provider |
| | `/vaultwarden/SMTP_PASSWORD` | SMTP relay password. | From the SMTP relay provider |
| | `/vaultwarden/SMTP_HOST` | SMTP relay hostname (implicit TLS on port 465 is configured in the manifest). | From the SMTP relay provider |
| **Woodpecker CI** | `/woodpecker/FORGEJO_CLIENT` | Forgejo OAuth2 application client ID. | Manual — README §4 |
| | `/woodpecker/FORGEJO_SECRET` | Forgejo OAuth2 application client secret. | Manual — README §4 |
| | `/woodpecker/AGENT_SECRET` | Shared secret between Woodpecker server and agents. | `openssl rand -hex 32` |
| | `/woodpecker/POSTGRES_USERNAME` | CloudNativePG application username. | Fixed: `woodpecker` (the CNPG `owner` user) |
| | `/woodpecker/POSTGRES_PASSWORD` | CloudNativePG application password. | `openssl rand -hex 32` |
| | `/woodpecker/PROMETHEUS_AUTH_TOKEN` | Bearer token for scraping Woodpecker metrics. | `openssl rand -hex 32` |

## Setup notes

Some secrets are produced by manual one-time procedures rather than generated directly:

- `/woodpecker/FORGEJO_CLIENT` and `/woodpecker/FORGEJO_SECRET` are created by the **Forgejo OAuth Application for Woodpecker CI** procedure in the [README's Manual Setup](../README.md#manual-setup) section.
- The four `/homepage/*` tokens are created by the **Create API Tokens for Homepage Widgets** procedure in the [README's Manual Setup](../README.md#manual-setup) section.
- The three `/openchamber/*` keys are used by the agent workspace described in [openchamber.md](openchamber.md), which also covers workspace access and coding-agent logins.

Generation constraints worth knowing:

- The eight `/authelia/OIDC_CLIENT_SECRET_*` values are 64-character hex strings from `openssl rand -hex 32`: hex output is RFC 3986 unreserved, which avoids token-endpoint encoding issues, and exceeds Authelia's 40-character recommendation for client secrets.
- S3 secret keys (`/rustfs/RUSTFS_SECRET_KEY`, `/notesnook/RUSTFS_SECRET_KEY`, `/opencloud/RUSTFS_SECRET_KEY`) use `openssl rand -hex 16` to stay within the 40-character secret-key limit MinIO-compatible stores accept; access key IDs are chosen and must be at least 8 characters with no whitespace, `=` or `,`.
- The RustFS users behind the `/notesnook/RUSTFS_*` and `/opencloud/RUSTFS_*` keypairs do not require manual registration: the `Tenant` in `apps/rustfs/0_tenant.yaml` declares their buckets, policies, and users, and the RustFS Operator provisions them from the Secrets synced by `apps/rustfs/-1_user_secrets.yaml` once the Tenant workload is ready. If equivalent users were previously created through the RustFS console, remove any console user carrying the same access key before the first sync, then confirm all items provisioned with `kubectl -n rustfs get tenant rustfs -o jsonpath='{.status.provisioning}'`.
