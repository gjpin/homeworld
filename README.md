# Homeworld

## Features
- Gitops with [ArgoCD](docs/argocd.md)
- [App-of-Apps sync wave orchestration](docs/argocd.md#application-health-checks) via custom Application health checks
- Declarative CRD lifecycle and upgrade management via [Server-Side Apply and sync waves](docs/argocd.md#crd-lifecycle-and-upgrade-management)
- [Restricted Pod Security Standards](docs/pod-security.md#pod-security-standards)
- [Kubernetes 1.36 User Namespaces](docs/pod-security.md#user-namespaces) (`hostUsers: false`)
- [gVisor runtime sandboxing](docs/pod-security.md#gvisor-runtime-sandboxing) with Talos `runsc`
- Tight [network policies](docs/network-policies.md)
- Ingress protection via CrowdSec Security Engine and AppSec WAF
- Gateway API routing with Envoy Gateway
- Automated DNS and TLS certificate management via ExternalDNS and cert-manager
- Zero-secret GitOps with Infisical and External Secrets Operator
- [OIDC](docs/oidc.md)
- Operator-managed PostgreSQL clusters via CloudNativePG
- Redis-compatible in-memory caching via Dragonfly Operator
- S3-compatible object storage via RustFS Operator
- Distributed block storage with Longhorn
- Automated encrypted [Velero backups](docs/velero.md) to Backblaze B2
- Unified telemetry pipeline with OpenTelemetry Collector and OpenObserve
- Declarative dashboards and monitoring via Grafana Operator and Prometheus Operator ServiceMonitors
- Automated dependency updates and [upgrade procedures](docs/upgrades.md) via Renovate

## Apps
| App | Domain(s) | Description |
| --- | --- | --- |
| Admission Policies | — | CEL ValidatingAdmissionPolicies protecting Pod Security Admission labels. |
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
| Home Assistant | `home.${BASE_DOMAIN}`<br>`z2m.${BASE_DOMAIN}` | Home automation and Zigbee bridge. |
| Immich | `photos.${BASE_DOMAIN}` | Photo and video management. |
| Longhorn | `longhorn.${BASE_DOMAIN}` | Distributed block-storage management. |
| OpenObserve | `openobserve.${BASE_DOMAIN}` | Logs, metrics, and traces backend. |
| OpenTelemetry Collector | — | Telemetry collection and export. |
| OpenCloud | `cloud.${BASE_DOMAIN}` | Files, sharing, search, collaboration, CalDAV, and CardDAV. |
| Prometheus Operator CRDs | — | Custom resource definitions required for monitoring resources. |
| Radicale | — | Internal CalDAV and CardDAV backend authenticated by OpenCloud. |
| Runtime Class | — | Cluster-scoped RuntimeClass for gVisor sandboxing. |
| RustFS | `s3.${BASE_DOMAIN}`<br>`console.rustfs.${BASE_DOMAIN}` | Shared S3-compatible object storage and Tenant console. |
| RustFS Operator | `rustfs.${BASE_DOMAIN}` | RustFS storage operator and management console. |
| Velero | — | Whole-cluster backups to Backblaze B2. |
| Velero UI | `velero.${BASE_DOMAIN}` | Web interface for managing Velero. |
| Woodpecker CI | `ci.${BASE_DOMAIN}` | Continuous integration engine integrated with Forgejo. |

## Manual Setup

### Forgejo OAuth Application for Woodpecker CI
Woodpecker CI authenticates users and receives repository webhooks via Forgejo OAuth2:
1. In Forgejo, navigate to **Site Administration** -> **Applications** -> **Create OAuth2 Application**.
   - **Application Name**: `Woodpecker CI`
   - **Redirect URI**: `https://ci.${BASE_DOMAIN}/authorize`
2. Save the generated credentials into Infisical:
   - `/woodpecker/FORGEJO_CLIENT`: `<Client ID>`
   - `/woodpecker/FORGEJO_SECRET`: `<Client Secret>`
3. Set the agent shared secret, metrics token, and database credentials in Infisical:
   - `/woodpecker/AGENT_SECRET`: `<secure-random-token>`
   - `/woodpecker/POSTGRES_USERNAME`: `woodpecker`
   - `/woodpecker/POSTGRES_PASSWORD`: `<secure-password>`
   - `/woodpecker/PROMETHEUS_AUTH_TOKEN`: `<secure-token>`

## Node Setup

### Zigbee Coordinator
Label the node with the physical Zigbee USB adapter attached:
```bash
kubectl label node <node-name> environment=zigbee
```
This pins `homeassistant-zigbee2mqtt` to the host hardware where the serial dongle is connected.