# OIDC

| Application | Authelia OIDC | Sign-in |
| --- | --- | --- |
| prometheus-operator-crd | No | No user login. |
| envoy-gateway | No | No user login. `envoy.${BASE_DOMAIN}` is the admin listener, not an OIDC app. |
| cert-manager | No | No user login. |
| external-dns | No | No user login. |
| longhorn | No | The UI has no login. |
| velero | No | Controller only. The UI is `velero-ui`. |
| velero-ui | Yes | Authelia. Built-in basic auth is disabled. Any signed-in user can manage every backup; there is no admin group. |
| argocd | Yes | Authelia. Local admin and Dex are disabled. `argocd-admin` is admin; everyone else is read-only. |
| cloudnative-pg | No | No user login. |
| dragonfly-operator | No | No user login. |
| rustfs-operator | No | The operator uses its service account. Console login belongs to the `rustfs` Tenant. |
| external-secrets | No | No user login. |
| crowdsec | No | No user login. |
| crowdsec-envoy-bouncer | No | Machine bouncer, not a user login. |
| grafana-operator | No | No user login. Grafana itself is a separate app. |
| rustfs | Yes | Console SSO through Authelia. S3 still uses the root access keys. `consoleAdmin` maps to the built-in console admin policy. |
| openobserve | No | The open-source build has no SSO. Enterprise SSO expects Dex, which this repo does not add. |
| authelia | No | This is the identity provider. |
| homeassistant | No | Home Assistant 2025.7.0, Mosquitto 2.0.21, and Zigbee2MQTT 2.5.1 have no built-in OIDC. |
| radicale | No | No web UI. OpenCloud proxies CalDAV and CardDAV and supplies the user. |
| immich | Yes | Authelia. Password login is disabled. `immich-admin` is an Immich admin; everyone else is a user. |
| otel-collector | No | No user login. |
| forgejo | Yes | Authelia. Local sign-in, basic auth, and the local admin user are disabled. `forgejo-admin` is a site admin. Git HTTPS still accepts personal tokens; SSH is unchanged. |
| grafana | Yes | Authelia. The password form is disabled. `grafana-admin` is a Grafana server admin; everyone else is a Viewer. The admin password secret remains so the process can start. |
| notesnook | No | Notesnook manages authentication via its dedicated Identity service (`auth.notes.${BASE_DOMAIN}`). End-to-end zero-knowledge encryption requires client-side key derivation from the user password, which is incompatible with external OIDC providers. |
| collabora | No | The admin UI is HTTP basic auth. Document editing uses OpenCloud WOPI, which already authenticated the user. |
| opencloud | Yes | Already an Authelia client (`web`, `OpenCloudDesktop`, `OpenCloudAndroid`, `OpenCloudIOS`). Unchanged. |
| woodpecker | Delegated (via Forgejo) | User authentication is delegated to Forgejo via OAuth2, which in turn authenticates via Authelia OIDC. Direct generic OIDC is not used because Woodpecker requires Forgejo access tokens to manage webhooks, repository permissions, and commit statuses. |