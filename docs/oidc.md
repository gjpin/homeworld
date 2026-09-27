# OIDC

| Application | Authelia OIDC | Sign-in |
| --- | --- | --- |
| prometheus-operator-crd | No | No user login. |
| envoy-gateway | No | No user login. `envoy.${BASE_DOMAIN}` is the admin listener, not an OIDC app. |
| cilium | No | Hubble UI is cluster-internal (no HTTPRoute; reached via `kubectl port-forward` or direct WireGuard node access) and has no login. Agents, Envoy, and the operator use their service accounts. |
| cert-manager | No | No user login. |
| external-dns | No | No user login. |
| metrics-server | No | No user login. |
| kubelet-serving-cert-approver | No | No user login. |
| longhorn | No | The UI has no login. |
| velero | No | Controller only. The UI is `velero-ui`. |
| velero-ui | Yes | Authelia. Built-in basic auth is disabled. Any signed-in user can manage every backup; there is no admin group. |
| argocd | Yes | Authelia. Local admin and Dex are disabled. `argocd-admin` is admin; everyone else is read-only. CLI SSO login (`argocd login --sso`) uses the public `argocd-cli` client. |
| cloudnative-pg | No | No user login. |
| documentdb-operator | No | No user login. |
| dragonfly-operator | No | No user login. |
| rustfs-operator | No | The operator uses its service account. Console login belongs to the `rustfs` Tenant. |
| external-secrets | No | No user login. |
| crowdsec | No | No user login. |
| crowdsec-envoy-bouncer | No | Machine bouncer, not a user login. |
| grafana-operator | No | No user login. Grafana itself is a separate app. |
| rustfs | Yes | Console SSO through Authelia. S3 still uses the root access keys. `consoleAdmin` maps to the built-in console admin policy. |
| victoria-metrics | No | VictoriaMetrics, VictoriaLogs, and VictoriaTraces UIs use no authentication (access control via CrowdSec extAuth at the Gateway). |
| authelia | No | This is the identity provider. |
| homeassistant | Yes | Home Assistant authenticates via Authelia using the hass-oidc-auth custom integration, configured automatically: a pinned init container installs the plugin, a rootless bootstrap init container seeds `configuration.yaml` (Home Assistant's default template plus the `auth_oidc` provider) together with the companion `automations.yaml`/`scripts.yaml`/`scenes.yaml` files on the first start of an empty PVC, and the client secret is injected as an environment variable read via Home Assistant's `!env_var` tag, so it never lands on the PVC. The bootstrap seeds only missing files; later git changes to the seeded `auth_oidc` block must be applied by editing `/config/configuration.yaml` directly. Home Assistant local login remains as a fallback, and the `homeassistant-admin` group maps to the HA admin role. Mosquitto and Zigbee2MQTT, deployed in the same component, have no OIDC: Mosquitto has no user login, and the Zigbee2MQTT web UI uses its own local login behind the CrowdSec WAF. |
| radicale | No | No web UI. OpenCloud proxies CalDAV and CardDAV and supplies the user. |
| immich | Yes | Authelia. Password login is disabled. `immich-admin` is an Immich admin; everyone else is a user. |
| otel-collector | No | No user login. |
| forgejo | Yes | Authelia. Local sign-in, basic auth, the local admin user, and legacy OpenID 2.0 sign-in are disabled. `forgejo-admin` is a site admin. Git HTTPS still accepts personal tokens; SSH is unchanged. |
| grafana | Yes | Authelia. The password form is hidden (`disable_login_form` + OIDC `auto_login`). `grafana-admin` is a Grafana server admin; everyone else is a Viewer. The admin password secret remains so the process can start, and the HTTP API keeps basic auth enabled so the Grafana Operator can reconcile (it authenticates with the admin credentials). |
| homepage | No | Homepage has no built-in authentication. The public dashboard route is protected by the CrowdSec Envoy bouncer (WAF); service widgets use read-only API tokens and the dashboard exposes links and status, not secrets. |
| notesnook | No | Notesnook manages authentication via its dedicated Identity service (`auth.notes.${BASE_DOMAIN}`). End-to-end zero-knowledge encryption requires client-side key derivation from the user password, which is incompatible with external OIDC providers. |
| openchamber | No | OpenChamber has no OIDC support. The web UI is protected by its own `--ui-password` (from Infisical via External Secrets) plus CrowdSec WAF, and is reached only over WireGuard at `openchamber.${BASE_DOMAIN}`; no relay is deployed (`openchamber-relay` is unnecessary with direct WireGuard connectivity, see [openchamber.md](openchamber.md)). Device pairing (QR code) connects desktop/mobile clients directly to the same URL. |
| collabora | No | The admin UI is HTTP basic auth. Document editing uses OpenCloud WOPI, which already authenticated the user. |
| opencloud | Yes | Already an Authelia client (`web`, `OpenCloudDesktop`, `OpenCloudAndroid`, `OpenCloudIOS`). Unchanged. |
| woodpecker | Delegated (via Forgejo) | User authentication is delegated to Forgejo via OAuth2, which in turn authenticates via Authelia OIDC. Direct generic OIDC is not used because Woodpecker requires Forgejo access tokens to manage webhooks, repository permissions, and commit statuses. |
| vaultwarden | Yes | Authelia (optional SSO with role mapping: `vaultwarden-admin` grants the admin role, `vaultwarden-user` the user role, invited users in neither group default to the user role). Master-password login remains available (`SSO_ONLY=false`) as a fallback because the official Bitwarden Android app has a known WebView rendering issue with Authelia's login page. Vault decryption always requires the master password. SSO signups are disabled; only admin-invited emails can join, and signups stay closed for direct registration. |