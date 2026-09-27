# Infisical Secrets

All cluster secrets are synchronized from [Infisical](https://infisical.com) by the External Secrets Operator through the `infisical` ClusterSecretStore (hourly refresh). No credentials are stored in this repository. Every key below must exist in Infisical at the listed path before the consuming component can start; missing keys leave the generated `Secret` incomplete and the pod fails with `CreateContainerConfigError`.

| Component | Infisical path | Description |
| :--- | :--- | :--- |
| **Authelia** | `/authelia/SESSION_SECRET` | Session cookie encryption secret. |
| | `/authelia/STORAGE_ENCRYPTION_KEY` | At-rest encryption key for the SQL configuration storage. |
| | `/authelia/USERS_DATABASE` | Full `users_database.yml` content (the authentication backend). |
| | `/authelia/POSTGRES_USERNAME` | CloudNativePG application username. |
| | `/authelia/POSTGRES_PASSWORD` | CloudNativePG application password. |
| | `/authelia/DRAGONFLY_PASSWORD` | Dragonfly (Redis) password for session storage. |
| | `/authelia/SMTP_PASSWORD` | SMTP relay password for notification emails. |
| | `/authelia/OIDC_HMAC_SECRET` | HMAC secret for the OIDC provider endpoints. |
| | `/authelia/OIDC_JWK_RS256` | RSA private key (JWK) for signing OIDC tokens. |
| | `/authelia/RESET_PASSWORD_JWT_SECRET` | JWT secret for the password-reset flow. |
| | `/authelia/OIDC_CLIENT_SECRET_ARGOCD` | Argo CD OIDC client secret. |
| | `/authelia/OIDC_CLIENT_SECRET_FORGEJO` | Forgejo OIDC client secret. |
| | `/authelia/OIDC_CLIENT_SECRET_GRAFANA` | Grafana OIDC client secret. |
| | `/authelia/OIDC_CLIENT_SECRET_HOMEASSISTANT` | Home Assistant OIDC client secret. |
| | `/authelia/OIDC_CLIENT_SECRET_IMMICH` | Immich OIDC client secret. |
| | `/authelia/OIDC_CLIENT_SECRET_RUSTFS` | RustFS console OIDC client secret. |
| | `/authelia/OIDC_CLIENT_SECRET_VELERO_UI` | Velero UI OIDC client secret. |
| | `/authelia/OIDC_CLIENT_SECRET_VAULTWARDEN` | Vaultwarden OIDC client secret. |
| **Collabora** | `/opencloud/COLLABORA_ADMIN_USER` | Collabora admin console username. |
| | `/opencloud/COLLABORA_ADMIN_PASSWORD` | Collabora admin console password. |
| | `/opencloud/COLLABORA_PROOF_KEY` | WOPI proof private key for OpenCloud ↔ Collabora requests. |
| | `/opencloud/COLLABORA_PROOF_KEY_PUB` | WOPI proof public key counterpart. |
| **CrowdSec** | `/crowdsec/DB_PASSWORD` | LAPI PostgreSQL password. |
| | `/crowdsec/ENROLL_KEY` | CrowdSec Central API enrollment key. |
| | `/crowdsec/BOUNCER_KEY_envoy` | Envoy Gateway bouncer API key. |
| **Forgejo** | `/forgejo/POSTGRES_USERNAME` | CloudNativePG application username. |
| | `/forgejo/POSTGRES_PASSWORD` | CloudNativePG application password. |
| **Grafana** | `/grafana/GF_SECURITY_ADMIN_USER` | Admin username (required for startup; login is via Authelia OIDC). |
| | `/grafana/GF_SECURITY_ADMIN_PASSWORD` | Admin password (required for startup; login is via Authelia OIDC). |
| **Homepage** | `/homepage/ARGOCD_TOKEN` | Read-only Argo CD account API token for the Argo CD widget (created by the procedure in the README's Manual Setup). |
| | `/homepage/GRAFANA_TOKEN` | Grafana service account token for the Grafana widget (created by the procedure in the README's Manual Setup). |
| | `/homepage/HASS_TOKEN` | Home Assistant long-lived access token for the Home Assistant widget (created by the procedure in the README's Manual Setup). |
| | `/homepage/IMMICH_API_KEY` | Immich API key for the Immich widget (created by the procedure in the README's Manual Setup). |
| **Immich** | `/immich/POSTGRES_USERNAME` | CloudNativePG application username. |
| | `/immich/POSTGRES_PASSWORD` | CloudNativePG application password. |
| | `/immich/DRAGONFLY_PASSWORD` | Dragonfly (Redis) password for cache and job queues. |
| **Longhorn** | `/longhorn/CRYPTO_KEY_VALUE` | Storage encryption key for the `longhorn-crypto` StorageClass. |
| **Notesnook** | `/notesnook/NOTESNOOK_API_SECRET` | API session signing secret. |
| | `/notesnook/DOCUMENTDB_USERNAME` | DocumentDB gateway username. |
| | `/notesnook/DOCUMENTDB_PASSWORD` | DocumentDB gateway password. |
| | `/notesnook/RUSTFS_ACCESS_KEY` | RustFS S3 access key for note attachments. |
| | `/notesnook/RUSTFS_SECRET_KEY` | RustFS S3 secret key for note attachments. |
| | `/notesnook/SMTP_USERNAME` | SMTP relay username for invitation and notification emails. |
| | `/notesnook/SMTP_PASSWORD` | SMTP relay password. |
| | `/notesnook/SMTP_HOST` | SMTP relay hostname. |
| | `/notesnook/SMTP_PORT` | SMTP relay port. |
| **OpenChamber** | `/openchamber/OPENCHAMBER_UI_PASSWORD` | Password protecting the OpenChamber web UI. |
| | `/openchamber/OPENAI_API_KEY` | OpenAI API key for Codex CLI and OpenCode. |
| | `/openchamber/GITHUB_TOKEN` | GitHub token for agent git operations. |
| **OpenCloud** | `/opencloud/IDM_ADMIN_PASSWORD` | OpenCloud IDM administrator password. |
| | `/opencloud/RUSTFS_ACCESS_KEY` | RustFS S3 access key for primary storage. |
| | `/opencloud/RUSTFS_SECRET_KEY` | RustFS S3 secret key for primary storage. |
| **RustFS** | `/rustfs/RUSTFS_ACCESS_KEY` | Root S3 access key for the storage Tenant. |
| | `/rustfs/RUSTFS_SECRET_KEY` | Root S3 secret key for the storage Tenant. |
| **Velero** | `/velero/B2_APPLICATION_KEY_ID` | Backblaze B2 key ID for backup storage. |
| | `/velero/B2_APPLICATION_KEY` | Backblaze B2 application key for backup storage. |
| | `/velero/KOPIA_REPOSITORY_PASSWORD` | Kopia repository encryption password. |
| **Velero UI** | `/velero-ui/BASIC_AUTH_USERNAME` | Velero UI basic-auth username (required for startup; login is via Authelia OIDC). |
| | `/velero-ui/BASIC_AUTH_PASSWORD` | Velero UI basic-auth password (required for startup; login is via Authelia OIDC). |
| | `/velero-ui/AUTH_SECRET_PASSPHRASE` | Session/cookie signing passphrase. |
| **Vaultwarden** | `/vaultwarden/ADMIN_TOKEN` | Admin panel token, preferably an Argon2 PHC string (generate with `docker run --rm -it docker.io/vaultwarden/server /vaultwarden hash`). |
| | `/vaultwarden/POSTGRES_USERNAME` | CloudNativePG application username. |
| | `/vaultwarden/POSTGRES_PASSWORD` | CloudNativePG application password. Must contain only RFC 3986 unreserved characters; it is embedded unescaped in the PostgreSQL connection URL. |
| | `/vaultwarden/SMTP_USERNAME` | SMTP relay username for invitation and notification emails. |
| | `/vaultwarden/SMTP_PASSWORD` | SMTP relay password. |
| | `/vaultwarden/SMTP_HOST` | SMTP relay hostname (implicit TLS on port 465 is configured in the manifest). |
| **Woodpecker CI** | `/woodpecker/FORGEJO_CLIENT` | Forgejo OAuth2 application client ID (created by the procedure in the README's Manual Setup). |
| | `/woodpecker/FORGEJO_SECRET` | Forgejo OAuth2 application client secret (created by the procedure in the README's Manual Setup). |
| | `/woodpecker/AGENT_SECRET` | Shared secret between Woodpecker server and agents. |
| | `/woodpecker/POSTGRES_USERNAME` | CloudNativePG application username. |
| | `/woodpecker/POSTGRES_PASSWORD` | CloudNativePG application password. |
| | `/woodpecker/PROMETHEUS_AUTH_TOKEN` | Bearer token for scraping Woodpecker metrics. |

## Setup notes

Some secrets are produced by manual one-time procedures rather than generated directly:

- `/woodpecker/FORGEJO_CLIENT` and `/woodpecker/FORGEJO_SECRET` are created by the **Forgejo OAuth Application for Woodpecker CI** procedure in the [README's Manual Setup](../README.md#manual-setup) section.
- The three `/openchamber/*` keys are used by the agent workspace described in [openchamber.md](openchamber.md), which also covers workspace access and coding-agent logins.
