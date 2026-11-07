# Infisical Secrets

All cluster secrets are synchronized from [Infisical](https://infisical.com) by the External Secrets Operator through the `infisical` ClusterSecretStore (hourly refresh). No credentials are stored in this repository. Every key below must exist in Infisical at the listed path before the consuming component can start; missing keys leave the generated `Secret` incomplete and the pod fails with `CreateContainerConfigError`.

Every `ExternalSecret` key in this repository pins `decodingStrategy: None`: values
are delivered exactly as stored in Infisical. Store secrets **raw** — a hex string
like `openssl rand -hex 32` output, a chosen username like `authelia`, a
`wg genkey` key — never base64-encoded. (`decodingStrategy: Auto` base64-decodes
any value that happens to parse as base64, which silently corrupts hex secrets,
8-character usernames, and WireGuard keys; `None` guarantees the raw passthrough
the RFC 3986-unreserved guidance below and the CNPG bootstrap both assume.)

## Bootstrap exception

The External Secrets Operator's own Infisical credentials (Secret `universal-auth-credentials` in `external-secrets`) are not synchronized from Infisical: the operator cannot fetch the credentials that grant access to Infisical, so `host/bootstrap.sh` asks for them on the first server and hands them to k3s, which creates the Secret — see [k3s.md](k3s.md#first-server). They come from the Infisical console under **Settings → Machine Identity → Universal Auth**.

The same credentials read `/argocd/BASE_DOMAIN` once during bootstrap: Argo CD's repo-server cannot render any Application, External Secrets included, without the domain, so `host/bootstrap.sh` seeds the `homeworld-domain` Secret in `argocd`, and the `homeworld-domain` ExternalSecret adopts it once External Secrets runs.

The agents VM ([agents-vm.md](agents-vm.md)) is not a cluster workload and does not use the External Secrets Operator: it has its own read-only Machine Identity (Universal Auth), granted read access to the `/agents` folder only. `host/bootstrap.sh` asks for its client ID, client secret and the project ID on the Ryzen and stores them root-only in `/etc/homeworld/agents-vm.env`; the VM fetches the `/agents/*` keys below at every boot.

The cluster domain is the one coordinate kept out of git: manifests carry the `base-domain.invalid` placeholder, and Argo CD's homeworld plugin replaces it with `/argocd/BASE_DOMAIN` at render time ([argocd.md](argocd.md#homeworld-plugin)). The API server needs it outside Argo CD, so `host/bootstrap.sh` also records it in each node's `/etc/homeworld/env` ([k3s.md](k3s.md)). The other non-secret cluster coordinates are committed as literal values: the `192.168.8.50` Gateway VIP, the Infisical endpoint (`https://eu.infisical.com`, project `homeworld`, environment `prod`) in `apps/external-secrets/2_secret_store.yaml`, and the Velero B2 target (`homeworld-velero` in `eu-central-003`) in `apps/velero/helm/values.yaml`.

| Component | Infisical path | Description | Generation |
| :--- | :--- | :--- | :--- |
| **Agents VM** | `/agents/OPENCHAMBER_UI_PASSWORD` | Password protecting the OpenChamber web UI. | Chosen strong password |
| | `/agents/PASEO_PASSWORD` | Paseo daemon password (clients send it as a bearer token); required, because the daemon listens on the VM's network address. | Chosen strong password |
| | `/agents/OPENAI_API_KEY` | OpenAI API key for Codex CLI and OpenCode. | From OpenAI |
| | `/agents/MISTRAL_API_KEY` | Optional Mistral API key for Mistral Vibe; without it, Vibe uses the key saved by `vibe --setup`. | From Mistral AI Studio |
| | `/agents/GITHUB_TOKEN` | GitHub token for agent git operations. | From GitHub (needs the Copilot Requests permission, [agents-vm.md](agents-vm.md#agent-logins)) |
| **AFFiNE** | `/affine/PRIVATE_KEY` | Server signing and encryption key (sessions, tokens, and the BYOK provider keys workspace owners store server-side), rendered into the read-only `private.key` of the server's configuration directory. Rotating it invalidates every stored BYOK key and session. | `openssl ecparam -name prime256v1 -genkey -noout` (P-256 private-key PEM, including the BEGIN/END lines) |
| | `/affine/POSTGRES_USERNAME` | CloudNativePG application username. | Fixed: `affine` (the CNPG `owner` user) |
| | `/affine/POSTGRES_PASSWORD` | CloudNativePG application password. Must contain only RFC 3986 unreserved characters; it is embedded unescaped in the PostgreSQL connection URL. | `openssl rand -hex 32` (hex output is RFC 3986 unreserved) |
| | `/affine/VALKEY_PASSWORD` | Valkey password for the cache, sessions, socket.io adapter and job queues. | `openssl rand -hex 32` |
| | `/affine/RUSTFS_ACCESS_KEY` | RustFS S3 access key for the blob, avatar, and AI storages. | Chosen access key ID (≥8 characters, no whitespace, `=` or `,`) |
| | `/affine/RUSTFS_SECRET_KEY` | RustFS S3 secret key for the blob, avatar, and AI storages. | `openssl rand -hex 16` |
| | `/affine/EXA_API_KEY` | Exa API key for AFFiNE AI web search. | From Exa |
| | `/affine/UNSPLASH_API_KEY` | Unsplash access key for image search in documents. | From Unsplash (application access key) |
| **Argo CD** | `/argocd/BASE_DOMAIN` | The cluster domain (`example.com`, no wildcard or trailing dot): every app is served on `<app>.<domain>`. The homeworld Config Management Plugin substitutes it for the `base-domain.invalid` placeholder ([argocd.md](argocd.md#homeworld-plugin)); `host/bootstrap.sh` reads it once to seed the Secret before External Secrets runs. | The domain whose Cloudflare zone `/cloudflare/API_TOKEN` edits |
| | `/argocd/VALKEY_PASSWORD` | Valkey password for the controllers' cache; rendered into both the `password` key (Valkey chart) and the Argo CD chart's `redis-password` key. | `openssl rand -hex 32` |
| **Audiobookshelf** | `/audiobookshelf/JWT_SECRET_KEY` | Signs Audiobookshelf's session and API tokens; without it the server generates one into its database. | `openssl rand -hex 32` |
| **AudioMuse-AI** | `/audiomuse-ai/POSTGRES_USERNAME` | CloudNativePG application username. | Fixed: `audiomuse` (the CNPG `owner` user) |
| | `/audiomuse-ai/POSTGRES_PASSWORD` | CloudNativePG application password. | `openssl rand -hex 32` |
| | `/audiomuse-ai/ADMIN_USERNAME` | The first AudioMuse-AI admin, created on the first start. | Chosen username |
| | `/audiomuse-ai/ADMIN_PASSWORD` | Its password (later changes are made in the UI). | `openssl rand -hex 32` |
| | `/audiomuse-ai/API_TOKEN` | Bearer token for Navidrome's AudioMuse-AI plugin, entered in the plugin's settings as well. | `openssl rand -hex 32` |
| | `/audiomuse-ai/NAVIDROME_USER` | The Navidrome account AudioMuse-AI reads the library with; the playlists it creates belong to it. | The Navidrome user created for it ([README](../README.md#15-set-up-the-media-stack)) |
| | `/audiomuse-ai/NAVIDROME_PASSWORD` | That account's Navidrome password. | Chosen when creating the account |
| **Authelia** | `/authelia/SESSION_SECRET` | Session cookie encryption secret. | `openssl rand -hex 32` |
| | `/authelia/STORAGE_ENCRYPTION_KEY` | At-rest encryption key for the SQL configuration storage. | `openssl rand -hex 32` |
| | `/authelia/USERS_DATABASE` | Full `users_database.yml` content (the authentication backend). | Handwritten YAML; per-user Argon2id digest: `docker run --rm -it ghcr.io/authelia/authelia authelia crypto hash generate argon2` |
| | `/authelia/POSTGRES_USERNAME` | CloudNativePG application username. | Fixed: `authelia` (the CNPG `owner` user) |
| | `/authelia/POSTGRES_PASSWORD` | CloudNativePG application password. | `openssl rand -hex 32` |
| | `/authelia/VALKEY_PASSWORD` | Valkey password for session storage. | `openssl rand -hex 32` |
| | `/authelia/OIDC_HMAC_SECRET` | HMAC secret for the OIDC provider endpoints. | `openssl rand -hex 32` |
| | `/authelia/OIDC_JWK_RS256` | RSA private key (JWK) for signing OIDC tokens. | `openssl genrsa 2048` (private-key PEM, including the BEGIN/END lines; Authelia derives the public key) |
| | `/authelia/RESET_PASSWORD_JWT_SECRET` | JWT secret for the password-reset flow. | `openssl rand -hex 32` |
| | `/authelia/OIDC_CLIENT_SECRET_ARGOCD` | Argo CD OIDC client secret. | `openssl rand -hex 32` |
| | `/authelia/OIDC_CLIENT_SECRET_AFFINE` | AFFiNE OIDC client secret (also rendered into AFFiNE's `config.json` by the `affine-config` ExternalSecret). | `openssl rand -hex 32` |
| | `/authelia/OIDC_CLIENT_SECRET_ACTUAL_BUDGET` | Actual Budget OIDC client secret (also delivered to the `actual-budget` namespace as `actual-budget-secrets`). | `openssl rand -hex 32` |
| | `/authelia/OIDC_CLIENT_SECRET_CODER` | Coder OIDC client secret (also delivered to coderd by the `coder-secrets` ExternalSecret). | `openssl rand -hex 32` |
| | `/authelia/OIDC_CLIENT_SECRET_ENVOY` | Envoy Gateway OIDC client secret (shared by every gateway-OIDC route; delivered to each protected app's namespace — envoy-gateway, homepage, longhorn-system, victoria-metrics, homeassistant, openchamber, and the media apps prowlarr, sonarr, radarr, lidarr, bazarr, maintainerr, houndarr and audiomuse-ai — as `envoy-oidc-client-secret`). | `openssl rand -hex 32` |
| | `/authelia/OIDC_CLIENT_SECRET_AUDIOBOOKSHELF` | Audiobookshelf OIDC client secret (entered once in Audiobookshelf's authentication settings). | `openssl rand -hex 32` |
| | `/authelia/OIDC_CLIENT_SECRET_BINDERY` | Bindery OIDC client secret, set in Bindery's provider settings by the media-config job. | `openssl rand -hex 32` |
| | `/authelia/OIDC_CLIENT_SECRET_CLEANUPARR` | Cleanuparr OIDC client secret (entered once in Cleanuparr's account settings). | `openssl rand -hex 32` |
| | `/authelia/OIDC_CLIENT_SECRET_FORGEJO` | Forgejo OIDC client secret. | `openssl rand -hex 32` |
| | `/authelia/OIDC_CLIENT_SECRET_GRAFANA` | Grafana OIDC client secret. | `openssl rand -hex 32` |
| | `/authelia/OIDC_CLIENT_SECRET_HEADLAMP` | Headlamp OIDC client secret. | `openssl rand -hex 32` |
| | `/authelia/OIDC_CLIENT_SECRET_HOMEASSISTANT` | Home Assistant OIDC client secret. | `openssl rand -hex 32` |
| | `/authelia/OIDC_CLIENT_SECRET_IMMICH` | Immich OIDC client secret. | `openssl rand -hex 32` |
| | `/authelia/OIDC_CLIENT_SECRET_RUSTFS` | RustFS console OIDC client secret. | `openssl rand -hex 32` |
| | `/authelia/OIDC_CLIENT_SECRET_VELERO_UI` | Velero UI OIDC client secret. | `openssl rand -hex 32` |
| | `/authelia/OIDC_CLIENT_SECRET_VAULTWARDEN` | Vaultwarden OIDC client secret. | `openssl rand -hex 32` |
| **Bazarr** | `/bazarr/API_KEY` | Bazarr API key, seeded into `config.yaml` on the first start (later changes are made in Bazarr's settings) and shared with exportarr, the media-config job and the Homepage widget. | `openssl rand -hex 16` |
| | `/bazarr/POSTGRES_USERNAME` | CloudNativePG application username. | Fixed: `bazarr` (the CNPG `owner` user) |
| | `/bazarr/POSTGRES_PASSWORD` | CloudNativePG application password. | `openssl rand -hex 32` |
| **Bindery** | `/bindery/API_KEY` | Bindery API key (`BINDERY_API_KEY`), shared with the media-config job. | `openssl rand -hex 32` |
| **Cleanuparr** | `/cleanuparr/POSTGRES_USERNAME` | CloudNativePG application username. | Fixed: `cleanuparr` (the CNPG `owner` user) |
| | `/cleanuparr/POSTGRES_PASSWORD` | CloudNativePG application password. | `openssl rand -hex 32` |
| **Cloudflare** | `/cloudflare/API_TOKEN` | Cloudflare DNS API token (Zone → DNS → Edit **plus** Zone → Zone → Read, so external-dns and cert-manager can resolve the zone ID for each record) shared by the cert-manager ClusterIssuers (DNS-01) and external-dns (the wildcard record). | From the Cloudflare dashboard (My Profile → API Tokens) |
| **Coder** | `/coder/POSTGRES_USERNAME` | CloudNativePG application username. | Fixed: `coder` (the CNPG `owner` user) |
| | `/coder/POSTGRES_PASSWORD` | CloudNativePG application password (also templated into coderd's `CODER_PG_CONNECTION_URL`). | `openssl rand -hex 32` |
| **Collabora** | `/opencloud/COLLABORA_ADMIN_USER` | Collabora admin console username. | Chosen username |
| | `/opencloud/COLLABORA_ADMIN_PASSWORD` | Collabora admin console password. | `openssl rand -hex 32` |
| | `/opencloud/COLLABORA_PROOF_KEY` | WOPI proof private key for OpenCloud ↔ Collabora requests. | `openssl genrsa -out proof_key 4096` (matching the chart's 4096-bit requirement; existing 2048-bit keys still verify) |
| | `/opencloud/COLLABORA_PROOF_KEY_PUB` | WOPI proof public key counterpart. | `openssl rsa -in proof_key -pubout -out proof_key.pub` |
| **Forgejo** | `/forgejo/POSTGRES_USERNAME` | CloudNativePG application username. | Fixed: `forgejo` (the CNPG `owner` user) |
| | `/forgejo/POSTGRES_PASSWORD` | CloudNativePG application password. | `openssl rand -hex 32` |
| **Home Assistant** | `/homeassistant/POSTGRES_PASSWORD` | CloudNativePG application password for the recorder database; rendered into both the `postgres-credentials` secret (CNPG bootstrap) and the `RECORDER_DB_URL` connection string. | `openssl rand -hex 32` (RFC 3986 unreserved characters only — it is embedded unescaped in the URL) |
| | `/homeassistant/MOSQUITTO_PASSWORD_HOMEASSISTANT` | Mosquitto password for the `homeassistant` MQTT user. Also entered in Home Assistant's MQTT integration (Settings → Devices & services → MQTT → Reconfigure), which stores its own copy. | `openssl rand -hex 32` |
| | `/homeassistant/MOSQUITTO_PASSWORD_ZIGBEE2MQTT` | Mosquitto password for the `zigbee2mqtt` MQTT user; Zigbee2MQTT reads it from `ZIGBEE2MQTT_CONFIG_MQTT_PASSWORD`. | `openssl rand -hex 32` |
| **Grafana** | `/grafana/GF_SECURITY_ADMIN_USER` | Admin username (required for startup; login is via Authelia OIDC). | Chosen username |
| | `/grafana/GF_SECURITY_ADMIN_PASSWORD` | Admin password (required for startup; login is via Authelia OIDC). | Chosen strong password |
| **Homepage** | `/homepage/ARGOCD_TOKEN` | Read-only Argo CD account API token for the Argo CD widget. | Manual — README §11 |
| | `/homepage/GRAFANA_TOKEN` | Grafana service account token for the Grafana widget. | Manual — README §11 |
| | `/homepage/HASS_TOKEN` | Home Assistant long-lived access token for the Home Assistant widget. | Manual — README §11 |
| | `/homepage/IMMICH_API_KEY` | Immich API key for the Immich widget. | Manual — README §11 |
| | `/homepage/JELLYFIN_API_KEY` | Jellyfin API key for the Jellyfin widget, also read by the media-config job (the Sonarr, Radarr, Lidarr and Maintainerr Jellyfin connections, skipped until it exists). | Manual — README §15 |
| | `/homepage/AUDIOBOOKSHELF_API_KEY` | Audiobookshelf API key for the Audiobookshelf widget. | Manual — README §15 |
| | `/homepage/NAVIDROME_USER` | Navidrome user for the Navidrome widget. | Manual — README §15 |
| | `/homepage/NAVIDROME_TOKEN` | Subsonic token for that user: `md5(password + salt)`. | Manual — README §15 |
| | `/homepage/NAVIDROME_SALT` | The salt used for the token. | Manual — README §15 (`openssl rand -hex 8`) |
| **Immich** | `/immich/POSTGRES_USERNAME` | CloudNativePG application username. | Fixed: `immich` (the CNPG `owner` user) |
| | `/immich/POSTGRES_PASSWORD` | CloudNativePG application password. | `openssl rand -hex 32` |
| | `/immich/VALKEY_PASSWORD` | Valkey password for job queues. | `openssl rand -hex 32` |
| **Jellyfin-Auto-Collections** | `/jellyfin-auto-collections/JELLYFIN_API_KEY` | Jellyfin API key for the collections job. | Manual — README §15 (Jellyfin **Dashboard → API Keys**) |
| | `/jellyfin-auto-collections/JELLYFIN_USER_ID` | ID of the Jellyfin user whose library the lists are matched against. | Manual — README §15 (from the user's dashboard URL) |
| **Lidarr** | `/lidarr/API_KEY` | Lidarr API key (`LIDARR__AUTH__APIKEY` overrides `config.xml`), shared with its exportarr sidecar and Cleanuparr, Houndarr, Unpackerr, the media-config job and the Homepage widget (media-config stores it in Prowlarr; Cleanuparr and Houndarr store it in their own settings). | `openssl rand -hex 16` (32 hex characters, the Servarr key format) |
| | `/lidarr/POSTGRES_USERNAME` | CloudNativePG application username. | Fixed: `lidarr` (the CNPG `owner` user) |
| | `/lidarr/POSTGRES_PASSWORD` | CloudNativePG application password. | `openssl rand -hex 32` |
| **Longhorn** | `/longhorn/CRYPTO_KEY_VALUE` | Storage encryption key for the `longhorn-crypto` StorageClass. | `openssl rand -hex 32` (LUKS passphrase; existing encrypted volumes remain unlockable only with the value they were created with) |
| **Navidrome** | `/navidrome/PASSWORD_ENCRYPTION_KEY` | Encrypts the stored user passwords (Subsonic token authentication needs them reversible). Changing it invalidates every stored password. | `openssl rand -hex 32` |
| | `/navidrome/LASTFM_API_KEY` | Last.fm API key for artist bios and images and per-user scrobbling. | From [Last.fm API accounts](https://www.last.fm/api/account/create) |
| | `/navidrome/LASTFM_SECRET` | Last.fm shared secret for the same API account. | From the same Last.fm API account |
| **Notesnook** | `/notesnook/NOTESNOOK_API_SECRET` | API session signing secret. | `openssl rand -hex 32` |
| | `/notesnook/SMTP_USERNAME` | SMTP username for the SSE mail service (verification/2FA mail). | SMTP relay credentials |
| | `/notesnook/SMTP_PASSWORD` | SMTP password for the SSE mail service. | SMTP relay credentials |
| | `/notesnook/SMTP_HOST` | SMTP relay hostname for the SSE mail service. | SMTP relay hostname |
| | `/notesnook/SMTP_PORT` | SMTP relay port for the SSE mail service (465 or 587). | SMTP relay port |
| | `/notesnook/DOCUMENTDB_USERNAME` | DocumentDB gateway username. | Chosen username |
| | `/notesnook/DOCUMENTDB_PASSWORD` | DocumentDB gateway password. | `openssl rand -hex 32` |
| | `/notesnook/RUSTFS_ACCESS_KEY` | RustFS S3 access key for note attachments. | Chosen access key ID (≥8 characters, no whitespace, `=` or `,`) |
| | `/notesnook/RUSTFS_SECRET_KEY` | RustFS S3 secret key for note attachments. | `openssl rand -hex 16` |
| **OpenCloud** | `/opencloud/IDM_ADMIN_PASSWORD` | OpenCloud IDM administrator password. | `openssl rand -hex 32` |
| **Prowlarr** | `/prowlarr/API_KEY` | Prowlarr API key (`PROWLARR__AUTH__APIKEY` overrides `config.xml`), shared with its exportarr sidecar, the media-config job and the Homepage widget (media-config stores it in Bindery). | `openssl rand -hex 16` (32 hex characters, the Servarr key format) |
| | `/prowlarr/POSTGRES_USERNAME` | CloudNativePG application username. | Fixed: `prowlarr` (the CNPG `owner` user) |
| | `/prowlarr/POSTGRES_PASSWORD` | CloudNativePG application password. | `openssl rand -hex 32` |
| **qBittorrent** | `/qbittorrent/SERVER_NAMES` | Preferred ProtonVPN servers from gluetun's server list (port-forwarding-capable). | Server name from the ProtonVPN server list |
| | `/qbittorrent/WIREGUARD_PRIVATE_KEY` | ProtonVPN WireGuard private key. | From a ProtonVPN WireGuard configuration (with NAT-PMP port forwarding enabled) |
| | `/qbittorrent/WIREGUARD_ADDRESSES` | ProtonVPN WireGuard interface address (i.e. `10.2.0.2/32`). | From the same ProtonVPN WireGuard configuration |
| | `/qbittorrent/WEBUI_USERNAME` | qBittorrent WebUI username, shared with the Homepage widget and the media-config job (Bindery's client). At least 3 characters, no colon. | Chosen username |
| | `/qbittorrent/WEBUI_PASSWORD` | qBittorrent WebUI password, seeded into `qBittorrent.conf` as a PBKDF2 hash by the config-bootstrap init container, and set in Bindery's client by the media-config job. At least 6 characters. | Chosen strong password |
| | `/qbittorrent/WEBUI_API_KEY` | Stateless WebAPI key (the qBittorrent WebAPI key mechanism) seeded into `qBittorrent.conf`, used by the metrics exporter, the port-forward sync job and the *arrs' download clients (set by the media-config job). Must be exactly 32 characters (`qbt_` prefix + 28, `src/base/utils/apikey.cpp`); qBittorrent **silently ignores** a non-empty key of the wrong length and Bearer auth stops working with no error. | `printf 'qbt_%s' "$(openssl rand -hex 14)"` |
| | `/qbittorrent/GLUETUN_CONTROL_ROLE` | gluetun control-server role JSON (`{"auth":"apikey","apikey":"..."}`); the port-forward sync job parses the key back out. | `printf '{"auth":"apikey","apikey":"%s"}' "$(openssl rand -hex 16)"` |
| **Radarr** | `/radarr/API_KEY` | Radarr API key (`RADARR__AUTH__APIKEY` overrides `config.xml`), shared with its exportarr sidecar and Bazarr, Recyclarr, Unpackerr, the media-config job and the Homepage widget (media-config stores it in Prowlarr, Seerr and Maintainerr; Cleanuparr and Houndarr store it in their own settings). | `openssl rand -hex 16` (32 hex characters, the Servarr key format) |
| | `/radarr/POSTGRES_USERNAME` | CloudNativePG application username. | Fixed: `radarr` (the CNPG `owner` user) |
| | `/radarr/POSTGRES_PASSWORD` | CloudNativePG application password. | `openssl rand -hex 32` |
| **RustFS** | `/rustfs/RUSTFS_ACCESS_KEY` | Root S3 access key for the storage Tenant. | Chosen access key ID (≥8 characters, no whitespace, `=` or `,`) |
| | `/rustfs/RUSTFS_SECRET_KEY` | Root S3 secret key for the storage Tenant. | `openssl rand -hex 16` |
| **RustFS Operator** | `/rustfs-operator/JWT_SECRET` | Console session-cookie JWT secret (Secret `rustfs-operator-console-secret`, key `jwt-secret`); the chart's generated Secret is patch-deleted from the render because its `randAlphaNum` fallback rotates on every offline render. | `openssl rand -hex 32` |
| **Seerr** | `/seerr/API_KEY` | Seerr API key (`API_KEY` overrides the stored key), shared with the Homepage widget and the media-config job (which stores it in Maintainerr). | `openssl rand -hex 32` |
| | `/seerr/POSTGRES_USERNAME` | CloudNativePG application username. | Fixed: `seerr` (the CNPG `owner` user) |
| | `/seerr/POSTGRES_PASSWORD` | CloudNativePG application password. | `openssl rand -hex 32` |
| **Sonarr** | `/sonarr/API_KEY` | Sonarr API key (`SONARR__AUTH__APIKEY` overrides `config.xml`), shared with its exportarr sidecar and Bazarr, Recyclarr, Unpackerr, the media-config job and the Homepage widget (media-config stores it in Prowlarr, Seerr and Maintainerr; Cleanuparr and Houndarr store it in their own settings). | `openssl rand -hex 16` (32 hex characters, the Servarr key format) |
| | `/sonarr/POSTGRES_USERNAME` | CloudNativePG application username. | Fixed: `sonarr` (the CNPG `owner` user) |
| | `/sonarr/POSTGRES_PASSWORD` | CloudNativePG application password. | `openssl rand -hex 32` |
| **Streamystats** | `/streamystats/POSTGRES_USERNAME` | CloudNativePG application username. | Fixed: `streamystats` (the CNPG `owner` user) |
| | `/streamystats/POSTGRES_PASSWORD` | CloudNativePG application password. Must contain only RFC 3986 unreserved characters; it is embedded unescaped in the PostgreSQL connection URL. | `openssl rand -hex 32` (hex output is RFC 3986 unreserved) |
| | `/streamystats/SESSION_SECRET` | Signs the session JWTs. | `openssl rand -hex 32` |
| | `/streamystats/INTERNAL_API_KEY` | Authenticates the frontend and the job server to each other. | `openssl rand -hex 32` |
| | `/streamystats/NEXT_SERVER_ACTIONS_ENCRYPTION_KEY` | Next.js server-action encryption key; stable so sessions survive redeploys. | `openssl rand -base64 32` |
| **Supernote** | `/supernote/MARIADB_ROOT_PASSWORD` | MariaDB root password (MariaDB Operator `rootPasswordSecretKeyRef`). | `openssl rand -hex 32` |
| | `/supernote/MARIADB_PASSWORD` | MariaDB password for the `supernote` application user, also used by the schema seed SqlJob. | `openssl rand -hex 32` |
| | `/supernote/VALKEY_PASSWORD` | Valkey password for the backend's cache. | `openssl rand -hex 32` |
| **Unpackerr** | `/unpackerr/METRICS_API_KEY` | API key with the `system:metrics:read` role, sent by the ServiceMonitor as its bearer token. 60 to 150 characters. | `openssl rand -hex 40` |
| | `/unpackerr/UI_PASSWORD` | Password of the web UI's local `admin` user (reached over `kubectl port-forward`). | `openssl rand -base64 24` |
| **Velero** | `/velero/B2_APPLICATION_KEY_ID` | Backblaze B2 key ID for backup storage. | From the Backblaze B2 console (App Keys) |
| | `/velero/B2_APPLICATION_KEY` | Backblaze B2 application key for backup storage. | From the Backblaze B2 console (App Keys) |
| | `/velero/KOPIA_REPOSITORY_PASSWORD` | Kopia repository encryption password. | `openssl rand -hex 32` (must stay unchanged for the lifetime of the repository) |
| **Velero UI** | `/velero-ui/AUTH_SECRET_PASSPHRASE` | JWT signing key (at least 32 bytes). | `openssl rand -hex 32` |
| **Vaultwarden** | `/vaultwarden/ADMIN_TOKEN` | Admin panel token, preferably an Argon2 PHC string. | `docker run --rm -it docker.io/vaultwarden/server /vaultwarden hash` |
| | `/vaultwarden/POSTGRES_USERNAME` | CloudNativePG application username. | Fixed: `vaultwarden` (the CNPG `owner` user) |
| | `/vaultwarden/POSTGRES_PASSWORD` | CloudNativePG application password. Must contain only RFC 3986 unreserved characters; it is embedded unescaped in the PostgreSQL connection URL. | `openssl rand -hex 32` (hex output is RFC 3986 unreserved) |
| **Woodpecker CI** | `/woodpecker/FORGEJO_CLIENT` | Forgejo OAuth2 application client ID. | Manual — README §10 |
| | `/woodpecker/FORGEJO_SECRET` | Forgejo OAuth2 application client secret. | Manual — README §10 |
| | `/woodpecker/AGENT_SECRET` | Shared secret between Woodpecker server and agents. | `openssl rand -hex 32` |
| | `/woodpecker/POSTGRES_USERNAME` | CloudNativePG application username. | Fixed: `woodpecker` (the CNPG `owner` user) |
| | `/woodpecker/POSTGRES_PASSWORD` | CloudNativePG application password. | `openssl rand -hex 32` |
| | `/woodpecker/PROMETHEUS_AUTH_TOKEN` | Bearer token for scraping Woodpecker metrics. | `openssl rand -hex 32` |

## Setup notes

Some secrets are produced by manual one-time procedures rather than generated directly:

- `/woodpecker/FORGEJO_CLIENT` and `/woodpecker/FORGEJO_SECRET` are created by the **Forgejo OAuth Application for Woodpecker CI** procedure in the [README's Manual Setup](../README.md#manual-setup) section.
- The four `/homepage/*` tokens are created by the **Create API Tokens for Homepage Widgets** procedure in the [README's Manual Setup](../README.md#manual-setup) section.
- The media apps' UI-generated keys (`/homepage/JELLYFIN_API_KEY`, `/homepage/AUDIOBOOKSHELF_API_KEY`, the `/homepage/NAVIDROME_*` trio and the `/jellyfin-auto-collections/*` pair) are created by the **Set Up the Media Stack** procedure in the [README's Manual Setup](../README.md#manual-setup) section, after the apps' first start; until then the Homepage and Jellyfin-Auto-Collections ExternalSecrets stay unready. The Servarr, Bazarr, Seerr and Bindery API keys are generated up front and injected, so the apps start with them.
- The four `/agents/*` keys are read by the agents VM described in [agents-vm.md](agents-vm.md), which also covers access and coding-agent logins.

Generation constraints worth knowing:

- The fifteen `/authelia/OIDC_CLIENT_SECRET_*` values are 64-character hex strings from `openssl rand -hex 32`: hex output is RFC 3986 unreserved, which avoids token-endpoint encoding issues, and exceeds Authelia's 40-character recommendation for client secrets.
- S3 secret keys (`/rustfs/RUSTFS_SECRET_KEY`, `/notesnook/RUSTFS_SECRET_KEY`, `/affine/RUSTFS_SECRET_KEY`) use `openssl rand -hex 16` to stay within the 40-character secret-key limit MinIO-compatible stores accept; access key IDs are chosen and must be at least 8 characters with no whitespace, `=` or `,`.
- The RustFS users behind the `/notesnook/RUSTFS_*` and `/affine/RUSTFS_*` keypairs do not require manual registration: the `Tenant` in `apps/rustfs/0_tenant.yaml` declares their buckets, policies, and users, and the RustFS Operator provisions them from the Secrets synced by `apps/rustfs/-1_user_secrets.yaml` once the Tenant workload is ready. If equivalent users were previously created through the RustFS console, remove any console user carrying the same access key before the first sync, then confirm all items provisioned with `kubectl -n rustfs get tenant rustfs -o jsonpath='{.status.provisioning}'`.
