# Apps

| App | Domain(s) | Description |
| --- | --- | --- |
| Argo CD | `argocd.${BASE_DOMAIN}`<br>`grpc.argocd.${BASE_DOMAIN}` | GitOps continuous delivery and its gRPC API. |
| Authelia | `auth.${BASE_DOMAIN}` | Identity provider for OpenCloud. |
| cert-manager | — | TLS certificate management. |
| CloudNativePG | — | PostgreSQL operator. |
| Collabora | `office.${BASE_DOMAIN}` | WOPI office editor for OpenCloud. |
| CrowdSec | — | Security Engine, PostgreSQL-backed LAPI, and AppSec WAF. |
| CrowdSec Envoy Bouncer | — | Envoy Gateway external-authorization bouncer. |
| Dragonfly Operator | — | Dragonfly, a Redis-compatible datastore, operator. |
| Envoy Gateway | `envoy.${BASE_DOMAIN}` | Gateway API implementation and control-plane metrics. |
| ExternalDNS | — | DNS record management. |
| External Secrets | — | Infisical-backed secret synchronization. |
| Forgejo | `git.${BASE_DOMAIN}` | Git forge. |
| Grafana | `grafana.${BASE_DOMAIN}` | Dashboards and observability visualization. |
| Grafana Operator | — | Grafana instance, dashboard, and datasource operator. |
| Home Assistant | `home.${BASE_DOMAIN}` | Home automation. |
| Immich | `photos.${BASE_DOMAIN}` | Photo and video management. |
| Longhorn | `longhorn.${BASE_DOMAIN}` | Distributed block-storage management. |
| OpenObserve | `openobserve.${BASE_DOMAIN}` | Logs, metrics, and traces backend. |
| OpenTelemetry Collector | — | Telemetry collection and export. |
| OpenCloud | `cloud.${BASE_DOMAIN}` | Files, sharing, search, collaboration, CalDAV, and CardDAV. |
| Prometheus Operator CRDs | — | Custom resource definitions required for monitoring resources. |
| Radicale | — | Internal CalDAV and CardDAV backend authenticated by OpenCloud. |
| RustFS | `s3.${BASE_DOMAIN}`<br>`console.rustfs.${BASE_DOMAIN}` | Shared S3-compatible object storage and Tenant console. |
| RustFS Operator | `rustfs.${BASE_DOMAIN}` | RustFS storage operator and management console. |
| Syncthing | `sync.${BASE_DOMAIN}` | Peer-to-peer file synchronization. |
| Velero | — | Whole-cluster backups to Backblaze B2. |
| Velero UI | `velero.${BASE_DOMAIN}` | Web interface for managing Velero. |


# ArgoCD
* **Sync wave 0**
   * argocd: enables Helm inflation for the Kustomize-rendered chart profiles
* **Sync wave 1**
   * prometheus-operator-crd: CRDs required by service monitors
   * external-secrets: External Secrets Operator and Infisical ClusterSecretStore
* **Sync wave 2**
   * envoy-gateway: Gateway API and provides CRDs required by HTTP/GRPC routes
* **Sync wave 3**
   * cert-manager: TLS certificates management
   * external-dns: manages DNS records
   * longhorn: block storage
* **Sync wave 4**
   * cloudnative-pg: postgresql operator
   * dragonfly-operator: dragonfly (redis-compatible) operator
   * grafana-operator: Grafana instance, dashboard, and datasource operator
   * rustfs-operator: RustFS storage operator, console, and STS endpoint
   * velero: whole-cluster backups after External Secrets and Longhorn
* **Sync wave 5**
   * crowdsec: PostgreSQL-backed CrowdSec LAPI, Envoy log agent, and AppSec WAF,
     after CloudNativePG and External Secrets
   * openobserve: standalone logs, metrics, and traces backend
   * rustfs: shared S3-compatible storage Tenant, after the RustFS Operator,
     External Secrets, and Longhorn
   * velero-ui: web interface for Velero, after the Velero server
* **Sync wave 6**
   * crowdsec-envoy-bouncer: pinned community Envoy external-auth bouncer,
     after CrowdSec and Envoy Gateway; the Gateway policies remain owned by
     their respective application directories and are fail-closed
   * authelia: OpenCloud identity provider, after CloudNativePG, Dragonfly,
     External Secrets, and Prometheus Operator CRDs
   * homeassistant
   * immich
   * otel-collector
   * forgejo
   * grafana
   * radicale: internal CalDAV and CardDAV backend, before OpenCloud's
     authenticated DAV proxy
   * syncthing
* **Sync wave 7**
   * collabora: standalone Collabora chart and WOPI endpoint
* **Sync wave 8**
   * opencloud: OpenCloud, Tika, RustFS storage integration, authenticated DAV
     proxy, and routes