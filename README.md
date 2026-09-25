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
- Zero-secret GitOps with Infisical and External Secrets Operator ([required secrets](docs/secrets.md))
- [OIDC](docs/oidc.md)
- Operator-managed PostgreSQL clusters via CloudNativePG
- Redis-compatible in-memory caching via Dragonfly Operator
- S3-compatible object storage via RustFS Operator
- Distributed block storage with Longhorn
- Automated encrypted [Velero backups](docs/velero.md) to Backblaze B2
- Unified telemetry pipeline with OpenTelemetry Collector and OpenObserve
- Declarative dashboards and monitoring via Grafana Operator and Prometheus Operator ServiceMonitors
- Automated dependency updates and [upgrade procedures](docs/upgrades.md) via Renovate
- Persistent AI agent workspace ([OpenChamber](docs/openchamber.md), OpenCode, Codex CLI, Pi agent on Debian 13) with PR-gated daily package refreshes

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
| Notesnook | `notes.${BASE_DOMAIN}`<br>`auth.notes.${BASE_DOMAIN}`<br>`sse.notes.${BASE_DOMAIN}`<br>`monograph.notes.${BASE_DOMAIN}`<br>`themes.notes.${BASE_DOMAIN}`<br>`cors.notes.${BASE_DOMAIN}`<br>`inbox.notes.${BASE_DOMAIN}` | End-to-end encrypted note-taking sync server with auth, SSE, Monograph, Themes, CORS proxy, and Inbox API. |
| OpenChamber | `openchamber.${BASE_DOMAIN}` | Persistent AI agent workspace: OpenChamber web server, OpenCode, Codex CLI, and the Pi agent on Debian 13 with a PVC-backed HOME. |
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

### 1. Bootstrap the Talos Cluster (Single Node)
Before deploying any application, bring up the Talos control plane: ISO installation, machine configuration generation, etcd bootstrap, enabling workloads on the control plane, WireGuard, and Longhorn disk provisioning. Follow [docs/talos.md](docs/talos.md).

### 2. Provision Infisical Secrets
Every component synchronizes its secrets from Infisical via the External Secrets Operator. The complete list of required keys, per component, is documented in [docs/secrets.md](docs/secrets.md). Create the keys for a component in Infisical before deploying it; a missing key leaves the generated `Secret` incomplete and the pod fails with `CreateContainerConfigError`.

### 3. Create the Forgejo OAuth Application for Woodpecker CI
Woodpecker CI authenticates users and receives repository webhooks via Forgejo OAuth2:
1. In Forgejo, navigate to **Site Administration** -> **Applications** -> **Create OAuth2 Application**.
   - **Application Name**: `Woodpecker CI`
   - **Redirect URI**: `https://ci.${BASE_DOMAIN}/authorize`
2. Save the generated credentials into Infisical:
   - `/woodpecker/FORGEJO_CLIENT`: `<Client ID>`
   - `/woodpecker/FORGEJO_SECRET`: `<Client Secret>`

### 4. Access OpenChamber and Log In to the Coding Agents
After the `openchamber` workspace deploys (see [docs/openchamber.md](docs/openchamber.md) for the architecture, bootstrap, and PR-gated update flow):

- **OpenChamber remote access**: reachable only over WireGuard at `https://openchamber.${BASE_DOMAIN}`; sign in with the `/openchamber/OPENCHAMBER_UI_PASSWORD` Infisical secret. Desktop and mobile apps connect to the same URL directly via QR-code pairing (*Settings → Remote Instances*); no relay or tunnel is needed.
- **Coding agent logins**: exec into the workspace and authenticate once per agent — the artifacts persist on the `openchamber-agent-home` PVC across pod restarts and image updates:
  ```bash
  kubectl exec -it -n openchamber deploy/openchamber -- bash
  opencode auth login   # OpenCode
  codex login           # Codex CLI
  pi                    # then run /login inside the Pi session
  ```
  `/openchamber/OPENAI_API_KEY` and `/openchamber/GITHUB_TOKEN` are injected as environment variables, so Codex and OpenCode also work without interactive login.

## Node Setup

### Zigbee Coordinator
Label the node with the physical Zigbee USB adapter attached:
```bash
kubectl label node <node-name> environment=zigbee
```
This pins `homeassistant-zigbee2mqtt` to the host hardware where the serial dongle is connected.