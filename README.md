# Homeworld

## Features
- Gitops with [ArgoCD](docs/argocd.md)
   - [App-of-Apps sync wave orchestration](docs/argocd.md#application-health-checks) via custom Application health checks
   - Declarative CRD lifecycle and upgrade management via [Server-Side Apply and sync waves](docs/argocd.md#crd-lifecycle-and-upgrade-management)
- [Restricted Pod Security Standards](docs/pod-security.md#pod-security-standards)
- [User Namespaces](docs/pod-security.md#user-namespaces)
- [gVisor runtime sandboxing](docs/pod-security.md#gvisor-runtime-sandboxing)
- Tight [network policies](docs/network-policies.md)
- Ingress protection via CrowdSec Security Engine and AppSec WAF
- Gateway API routing with Envoy Gateway
- Automated DNS and TLS certificate management via ExternalDNS and cert-manager
- Zero-secret GitOps with Infisical and External Secrets Operator ([required secrets](docs/secrets.md))
- [OIDC](docs/oidc.md)
- [Operator-managed PostgreSQL clusters via CloudNativePG](docs/upgrades.md#1-automated-major-database-upgrades-cloudnativepg)
- [MongoDB-compatible document storage via DocumentDB Operator](docs/upgrades.md#7-documentdb-engine-upgrades)
- Redis-compatible in-memory caching via Dragonfly Operator
- S3-compatible object storage via RustFS Operator
- Distributed block storage with Longhorn
- Automated encrypted [Velero backups](docs/velero.md) to Backblaze B2
- Unified telemetry pipeline with OpenTelemetry Collector, VictoriaMetrics, VictoriaLogs, and VictoriaTraces
- Declarative dashboards and monitoring via Grafana Operator and Prometheus Operator ServiceMonitors
- Automated dependency updates and [upgrade procedures](docs/upgrades.md) via Renovate
- Persistent AI agent workspace ([OpenChamber](docs/openchamber.md), OpenCode, Codex CLI, Pi agent, Grok Build, Antigravity CLI, Copilot CLI on Debian 13) with PR-gated daily package refreshes

## Apps
| App | Domain(s) | Description |
| --- | --- | --- |
| Admission Policies | — | CEL ValidatingAdmissionPolicies protecting Pod Security Admission labels. |
| Argo CD | `argocd.${BASE_DOMAIN}`<br>`grpc.argocd.${BASE_DOMAIN}` | GitOps continuous delivery and its gRPC API. |
| Authelia | `auth.${BASE_DOMAIN}` | Identity provider for OpenCloud. |
| cert-manager | — | TLS certificate management. |
| Cilium | — | kube-proxy-free eBPF CNI with WireGuard pod-to-pod encryption and Hubble relay/UI observability (cluster-internal). |
| CloudNativePG | — | PostgreSQL operator. |
| Collabora | `office.${BASE_DOMAIN}` | WOPI office editor for OpenCloud. |
| CrowdSec | — | Security Engine, PostgreSQL-backed LAPI, and AppSec WAF. |
| DocumentDB Operator | — | DocumentDB, a MongoDB-compatible datastore, operator. |
| CrowdSec Envoy Bouncer | — | Envoy Gateway external-authorization bouncer. |
| Dragonfly Operator | — | Dragonfly, a Redis-compatible datastore, operator. |
| Envoy Gateway | `envoy.${BASE_DOMAIN}` | Gateway API implementation and control-plane metrics. |
| ExternalDNS | — | DNS record management. |
| External Secrets | — | Infisical-backed secret synchronization. |
| Forgejo | `git.${BASE_DOMAIN}` | Git forge. |
| Grafana | `grafana.${BASE_DOMAIN}` | Dashboards and observability visualization. |
| Grafana Operator | — | Grafana instance, dashboard, and datasource operator. |
| Home Assistant | `home.${BASE_DOMAIN}`<br>`z2m.${BASE_DOMAIN}` | Home automation and Zigbee bridge. |
| Homepage | `homepage.${BASE_DOMAIN}` | Application dashboard aggregating links, status, and live service widgets. |
| Immich | `photos.${BASE_DOMAIN}` | Photo and video management. |
| Kubelet Serving Cert Approver | — | Approves kubelet serving certificate CSRs so metrics-server scrapes kubelets over verified TLS. |
| Longhorn | `longhorn.${BASE_DOMAIN}` | Distributed block-storage management. |
| Metrics Server | — | Resource metrics for `kubectl top` and HPA, scraped from kubelets over verified TLS. |
| Notesnook | `notes.${BASE_DOMAIN}`<br>`auth.notes.${BASE_DOMAIN}`<br>`sse.notes.${BASE_DOMAIN}`<br>`monograph.notes.${BASE_DOMAIN}`<br>`themes.notes.${BASE_DOMAIN}`<br>`cors.notes.${BASE_DOMAIN}`<br>`inbox.notes.${BASE_DOMAIN}` | End-to-end encrypted note-taking sync server with auth, SSE, Monograph, Themes, CORS proxy, and Inbox API. |
| OpenChamber | `openchamber.${BASE_DOMAIN}` | Persistent AI agent workspace: OpenChamber web server, OpenCode, Codex CLI, the Pi agent, Grok Build, the Antigravity CLI, and the Copilot CLI on Debian 13 with a PVC-backed HOME. |
| VictoriaMetrics | `victoria-metrics.${BASE_DOMAIN}` | Metrics backend (VictoriaMetrics Single, vmui). |
| VictoriaLogs | `victoria-logs.${BASE_DOMAIN}` | Logs backend (VictoriaLogs Single, web UI). |
| VictoriaTraces | `victoria-traces.${BASE_DOMAIN}` | Traces backend (VictoriaTraces Single, Jaeger/Tempo-compatible query APIs; visualize via Grafana). |
| OpenTelemetry Collector | — | Telemetry collection and export. |
| OpenCloud | `cloud.${BASE_DOMAIN}` | Files, sharing, search, collaboration, CalDAV, and CardDAV. |
| Prometheus Operator CRDs | — | Custom resource definitions required for monitoring resources. |
| Radicale | — | Internal CalDAV and CardDAV backend authenticated by OpenCloud. |
| RustFS | `s3.${BASE_DOMAIN}`<br>`console.rustfs.${BASE_DOMAIN}` | Shared S3-compatible object storage and Tenant console. |
| RustFS Operator | `rustfs.${BASE_DOMAIN}` | RustFS storage operator and management console. |
| Velero | — | Whole-cluster backups to Backblaze B2. |
| Velero UI | `velero.${BASE_DOMAIN}` | Web interface for managing Velero. |
| Vaultwarden | `vault.${BASE_DOMAIN}` | Bitwarden-compatible password manager with optional Authelia SSO sign-in. |
| Woodpecker CI | `ci.${BASE_DOMAIN}` | Continuous integration engine integrated with Forgejo. |

## Manual Setup

### 1. Bootstrap the Talos Cluster (Single Node)
Before deploying any application, bring up the Talos control plane: ISO installation, machine configuration generation, etcd bootstrap, creating the gVisor RuntimeClass, enabling workloads on the control plane, WireGuard, and Longhorn disk provisioning. Follow [docs/talos.md](docs/talos.md).

### 2. Zigbee Coordinator
Label the node with the physical Zigbee USB adapter attached:
```bash
kubectl label node <node-name> environment=zigbee
```
This pins `homeassistant-zigbee2mqtt` to the host hardware where the serial dongle is connected.

### 3. Provision Infisical Secrets
Every component synchronizes its secrets from Infisical via the External Secrets Operator. The complete list of required keys, per component, is documented in [docs/secrets.md](docs/secrets.md). Create the keys for a component in Infisical before deploying it; a missing key leaves the generated `Secret` incomplete and the pod fails with `CreateContainerConfigError`.

### 4. Create the Authelia Users Database
Every OIDC sign-in resolves against Authelia's file-backed user database, stored in Infisical as `/authelia/USERS_DATABASE` (the full `users_database.yml` content). Generate an Argon2id digest per user, then list their groups — group memberships drive each application's role mapping:
```bash
# Prints: Digest: $argon2id$...
docker run --rm -it ghcr.io/authelia/authelia authelia crypto hash generate argon2
```
```yaml
users:
  alice:
    displayname: Alice
    password: '$argon2id$...' # the digest from the command above
    email: alice@example.com
    groups:
      - argocd-admin
      - homeassistant-admin
```
| Group | Grants |
| --- | --- |
| `argocd-admin` | Argo CD admin (everyone else is read-only) |
| `forgejo-admin` | Forgejo site admin |
| `grafana-admin` | Grafana server admin (everyone else is a Viewer) |
| `immich-admin` | Immich admin (everyone else is a user) |
| `opencloud-admin` / `opencloud-spaceadmin` / `opencloud-user` / `opencloud-user-light` | OpenCloud roles; sign-in requires one of these groups (deny-by-default) |
| `vaultwarden-admin` / `vaultwarden-user` | Vaultwarden admin / user role (invited users in neither group default to the user role) |
| `homeassistant-admin` | Home Assistant admin role |

After editing the Infisical value, the change reaches the cluster on the ExternalSecret's hourly refresh (or immediately with `kubectl -n authelia delete secret authelia-files`, which External Secrets recreates at once). Authelia reads the database only at startup (`watch: false`), so finish with `kubectl -n authelia rollout restart deploy/authelia`.

### 5. Create the Forgejo OAuth Application for Woodpecker CI
Woodpecker CI authenticates users and receives repository webhooks via Forgejo OAuth2:
1. In Forgejo, navigate to **Site Administration** -> **Applications** -> **Create OAuth2 Application**.
   - **Application Name**: `Woodpecker CI`
   - **Redirect URI**: `https://ci.${BASE_DOMAIN}/authorize`
2. Save the generated credentials into Infisical:
   - `/woodpecker/FORGEJO_CLIENT`: `<Client ID>`
   - `/woodpecker/FORGEJO_SECRET`: `<Client Secret>`

### 6. Create API Tokens for Homepage Widgets
The Homepage dashboard's live widgets authenticate to four services with dedicated read-only tokens, stored in Infisical under `/homepage/*` (see [docs/secrets.md](docs/secrets.md)):
1. **Argo CD**: sign in as an `argocd-admin` user, then open **Settings → Accounts → `homepage` → Tokens → Generate New**. Save the token to `/homepage/ARGOCD_TOKEN`. The API-key-only `homepage` account and its read-only RBAC mapping are declared in `apps/argocd/helm/values.yaml`.
2. **Grafana**: open **Administration → Users → Service accounts**, add the service account `homepage`, then **Add service account token**. Save it to `/homepage/GRAFANA_TOKEN`.
3. **Home Assistant**: open your profile → **Security** tab → **Long-lived access tokens → Create Token**. Save it to `/homepage/HASS_TOKEN`.
4. **Immich**: open **Account Settings → API Keys → New API Key**. Save it to `/homepage/IMMICH_API_KEY`.

Homepage reads its dashboard configuration (`apps/homepage/0_config.yaml`) at startup; after changing it, restart the pod with `kubectl -n homepage rollout restart deploy/homepage`.

### 7. Access OpenChamber and Log In to the Coding Agents
After the `openchamber` workspace deploys (see [docs/openchamber.md](docs/openchamber.md) for the architecture, bootstrap, and PR-gated update flow):

- **OpenChamber remote access**: reachable only over WireGuard at `https://openchamber.${BASE_DOMAIN}`; sign in with the `/openchamber/OPENCHAMBER_UI_PASSWORD` Infisical secret. Desktop and mobile apps connect to the same URL directly via QR-code pairing (*Settings → Remote Instances*); no relay or tunnel is needed.
- **Coding agent logins**: exec into the workspace and authenticate once per agent — the artifacts persist on the `openchamber-agent-home` PVC across pod restarts and image updates:
  ```bash
  kubectl exec -it -n openchamber deploy/openchamber -- bash
  opencode auth login   # OpenCode
  codex login           # Codex CLI
  pi                    # then run /login inside the Pi session
  grok login --device-auth  # Grok Build (device-code flow for the headless pod; works with a SuperGrok subscription)
  agy                   # Antigravity CLI (prints an auth URL + code on first launch for the headless pod)
  copilot login         # Copilot CLI (device-code flow)
  ```
  `/openchamber/OPENAI_API_KEY` and `/openchamber/GITHUB_TOKEN` are injected as environment variables, so Codex and OpenCode also work without interactive login. Copilot CLI checks `COPILOT_GITHUB_TOKEN`, then `GH_TOKEN`, then `GITHUB_TOKEN` before its stored login, so the injected `GITHUB_TOKEN` takes precedence: it must carry the Copilot Requests permission, otherwise `copilot login` appears to succeed but is silently shadowed.