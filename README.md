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
- Gateway API routing with [Envoy Gateway](docs/envoy-gateway.md)
- Private `homeworld.internal` domain: router-local DNS (AdGuard Home wildcard to a Cilium-announced Gateway VIP) and TLS from a name-constrained private CA via cert-manager, distributed to in-cluster clients by trust-manager
- Zero-secret GitOps with Infisical and External Secrets Operator ([required secrets](docs/secrets.md))
- [OIDC](docs/oidc.md)
- [Operator-managed PostgreSQL clusters via CloudNativePG](docs/upgrades.md#1-automated-major-database-upgrades-cloudnativepg)
- [MongoDB-compatible document storage via DocumentDB Operator](docs/upgrades.md#7-documentdb-engine-upgrades)
- Redis-compatible in-memory caching via Dragonfly Operator
- Operator-managed MariaDB via MariaDB Operator
- S3-compatible object storage via RustFS Operator
- Distributed block storage with Longhorn
- Automated encrypted [Velero backups](docs/velero.md) to Backblaze B2
- Unified telemetry pipeline with OpenTelemetry Collector, VictoriaMetrics, VictoriaLogs, and VictoriaTraces
- Declarative dashboards and monitoring via Grafana Operator, with Prometheus Operator ServiceMonitors and PodMonitors consumed by the OpenTelemetry Operator's Target Allocator
- Automated dependency updates and [upgrade procedures](docs/upgrades.md) via Renovate
- Persistent AI agent workspace ([OpenChamber](docs/openchamber.md), OpenCode, Codex CLI, Pi agent, Grok Build, Antigravity CLI, Copilot CLI on Debian 13) with PR-gated daily package refreshes

## Apps
| App | Domain(s) | Description |
| --- | --- | --- |
| Admission Policies | — | CEL ValidatingAdmissionPolicies protecting Pod Security Admission labels. |
| Argo CD | `argocd.homeworld.internal` | GitOps continuous delivery. |
| Authelia | `auth.homeworld.internal` | Identity provider for every OIDC sign-in (applications and the gateway-OIDC routes). |
| cert-manager | — | TLS certificates for every Gateway listener from the private Homeworld CA. |
| Cilium | — | kube-proxy-free eBPF CNI with WireGuard pod-to-pod encryption and Hubble relay/UI observability (cluster-internal). |
| CloudNativePG | — | PostgreSQL operator. |
| Collabora | `office.homeworld.internal` | WOPI office editor for OpenCloud. |
| CrowdSec | — | Security Engine, PostgreSQL-backed LAPI, and AppSec WAF. |
| DocumentDB Operator | — | DocumentDB, a MongoDB-compatible datastore, operator. |
| CrowdSec Envoy Bouncer | — | Envoy Gateway external-authorization bouncer. |
| Dragonfly Operator | — | Dragonfly, a Redis-compatible datastore, operator. |
| Envoy Gateway | `envoy.homeworld.internal` | Gateway API implementation and its admin console. |
| External Secrets | — | Infisical-backed secret synchronization. |
| Forgejo | `git.homeworld.internal` | Git forge. |
| Generic Device Plugin | — | Exposes the host `/dev/net/tun` device to non-privileged pods through the device plugin API (`devic.es/tun`); required by gluetun. |
| Grafana | `grafana.homeworld.internal` | Dashboards and observability visualization. |
| Grafana Operator | — | Grafana instance, dashboard, and datasource operator. |
| Home Assistant | `home.homeworld.internal`<br>`z2m.homeworld.internal` | Home automation and Zigbee bridge. |
| Homepage | `homepage.homeworld.internal` | Application dashboard aggregating links, status, and live service widgets. |
| Immich | `photos.homeworld.internal` | Photo and video management. |
| Kubelet Serving Cert Approver | — | Approves kubelet serving certificate CSRs so metrics-server scrapes kubelets over verified TLS. |
| Kube Control Plane | — | Scrape targets for the Talos-managed API servers, scheduler, controller manager, and etcd (ServiceMonitors and a ScrapeConfig; no workloads). |
| Kube State Metrics | — | Cluster-state `kube_*` metrics for the OpenTelemetry pipeline and the CloudNativePG dashboard. |
| Longhorn | `longhorn.homeworld.internal` | Distributed block-storage management. |
| Snapshot Controller | — | CSI volume-snapshot controller driving the Longhorn CSI driver for Velero data movement and CNPG volume-snapshot backups. |
| MariaDB Operator | — | MariaDB operator; provisions MariaDB instances, their databases and users, and SQL seed jobs. |
| Metrics Server | — | Resource metrics for `kubectl top` and HPA, scraped from kubelets over verified TLS. |
| Notesnook | `notes.homeworld.internal`<br>`auth.notes.homeworld.internal`<br>`sse.notes.homeworld.internal`<br>`monograph.notes.homeworld.internal` | End-to-end encrypted note-taking sync server with auth, SSE, and Monograph. |
| OpenChamber | `openchamber.homeworld.internal` | Persistent AI agent workspace: OpenChamber web server, OpenCode, Codex CLI, the Pi agent, Grok Build, the Antigravity CLI, and the Copilot CLI on Debian 13 with a PVC-backed HOME. |
| VictoriaMetrics | `victoria-metrics.homeworld.internal` | Metrics backend (VictoriaMetrics Single, vmui). |
| VictoriaLogs | `victoria-logs.homeworld.internal` | Logs backend (VictoriaLogs Single, web UI). |
| VictoriaTraces | `victoria-traces.homeworld.internal` | Traces backend (VictoriaTraces Single, Jaeger/Tempo-compatible query APIs; visualize via Grafana). |
| OpenTelemetry Collector | — | Telemetry collection and export. |
| OpenTelemetry Operator | — | Manages the collector and its Target Allocator, which discovers ServiceMonitor and PodMonitor scrape targets. |
| OpenCloud | `cloud.homeworld.internal` | Files, sharing, search, collaboration, CalDAV, and CardDAV. |
| Prometheus Operator CRDs | — | Custom resource definitions required for monitoring resources; consumed by the OpenTelemetry Operator's Target Allocator. |
| qBittorrent | `qbittorrent.homeworld.internal` | Torrent client with a gluetun VPN sidecar, a three-layer kill switch (gluetun firewall, Cilium egress allowlist, readiness gate), and VPN port-forwarding (see [qbittorrent.md](docs/qbittorrent.md)). |
| Radicale | — | Internal CalDAV and CardDAV backend authenticated by OpenCloud. |
| RustFS | `s3.homeworld.internal`<br>`console.rustfs.homeworld.internal` | Shared S3-compatible object storage and Tenant console. |
| RustFS Operator | `rustfs.homeworld.internal` | RustFS storage operator and management console. |
| trust-manager | — | Publishes the Homeworld CA certificate as the `homeworld-ca` ConfigMap in every namespace for in-cluster HTTPS clients. |
| Supernote | `supernote.homeworld.internal` | Supernote Private Cloud: device sync, web file manager, and note conversion (amd64 nodes only). |
| Velero | — | Whole-cluster backups to Backblaze B2. |
| Velero UI | `velero.homeworld.internal` | Web interface for managing Velero. |
| Vaultwarden | `vault.homeworld.internal` | Bitwarden-compatible password manager with optional Authelia SSO sign-in. |
| Woodpecker CI | `ci.homeworld.internal` | Continuous integration engine integrated with Forgejo. |

## Manual Setup

This is a fresh-install runbook, in order. Every cluster coordinate is committed as a literal value; if yours differ, change them in git (and in the router, Talos, and Infisical steps below) before the first sync:

| Constant | Value | Where it is set |
| --- | --- | --- |
| Domain | `homeworld.internal` | Every Gateway, route, and app config under `apps/`; the CA name constraint (step 2); the router's DNS rewrite ([docs/openwrt.md](docs/openwrt.md)) |
| Gateway VIP | `192.168.8.50` | Every Gateway's `spec.addresses`; the router's DNS rewrite; reserved on the router ([docs/talos.md](docs/talos.md) step 2) |
| Infisical | `https://eu.infisical.com`, project `homeworld`, environment `prod` | `apps/external-secrets/2_secret_store.yaml` and its egress policy |
| Velero B2 target | bucket `homeworld-velero` in `eu-central-003` | `apps/velero/helm/values.yaml` and its egress policies |
| Git source | `https://github.com/gjpin/homeworld.git` at `HEAD` | Every Argo CD `Application` (`apps/app-of-apps.yaml` and the child Applications) |

### 1. Configure the Router
Set up the OpenWrt router before anything else. Follow [docs/openwrt.md](docs/openwrt.md). Its AdGuard Home answers every `*.homeworld.internal` name with the Gateway VIP, for the Pixel network and the WireGuard peers alike.

### 2. Create the Homeworld CA
Every HTTPS endpoint is served with a certificate from a private root CA. Create it once on your workstation with OpenSSL 1.1.1 or newer (macOS ships LibreSSL, so use Homebrew's `openssl`). It is valid for 10 years and name-constrained to `homeworld.internal`, so it cannot sign certificates for any other domain, even if the key leaks:
```bash
openssl req -x509 -newkey rsa:4096 -sha256 -days 3650 -nodes \
  -keyout homeworld-ca.key -out homeworld-ca.crt \
  -subj "/CN=Homeworld Root CA" \
  -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
  -addext "keyUsage=critical,keyCertSign,cRLSign" \
  -addext "nameConstraints=critical,permitted;DNS:homeworld.internal"

# Check the constraint and the expiry date
openssl x509 -in homeworld-ca.crt -noout -enddate -ext nameConstraints
```
Store the PEM contents in Infisical as `/cert-manager/CA_CERT` (`homeworld-ca.crt`) and `/cert-manager/CA_KEY` (`homeworld-ca.key`), keep an offline backup of both, and delete the local key afterwards. cert-manager's `homeworld-ca` ClusterIssuer signs every Gateway certificate with it (and renews them automatically); trust-manager and Argo CD read only the certificate. Before the CA itself expires, repeat this step and re-trust the new certificate on every device (step 8).

### 3. Create the Authelia Users Database
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
| `platform` | Gateway-OIDC routes (victoria-metrics, victoria-logs, victoria-traces, longhorn, homepage, envoy admin listener, z2m); sign-in requires the group (deny-by-default) |
| `argocd-admin` | Argo CD admin (everyone else is read-only) |
| `forgejo-admin` | Forgejo site admin |
| `grafana-admin` | Grafana server admin (everyone else is a Viewer) |
| `immich-admin` | Immich admin (everyone else is a user) |
| `opencloud-admin` / `opencloud-spaceadmin` / `opencloud-user` / `opencloud-user-light` | OpenCloud roles; sign-in requires one of these groups (deny-by-default) |
| `vaultwarden-admin` / `vaultwarden-user` | Vaultwarden sign-in groups (role mapping is not supported by the upstream image; admin access is assigned in the admin panel via `ADMIN_TOKEN`) |
| `homeassistant-admin` | Home Assistant admin role |

After editing the Infisical value, the change reaches the cluster on the ExternalSecret's hourly refresh (or immediately with `kubectl -n authelia delete secret authelia-files`, which External Secrets recreates at once). Authelia reads the database only at startup (`watch: false`), so finish with `kubectl -n authelia rollout restart deploy/authelia`.

### 4. Provision Infisical Secrets
Every component synchronizes its secrets from Infisical via the External Secrets Operator. The complete list of required keys, per component, is documented in [docs/secrets.md](docs/secrets.md). Create every key before bootstrapping Argo CD; a missing key leaves the generated `Secret` incomplete and the pod fails with `CreateContainerConfigError`.

The Velero keys come from Backblaze: create the `homeworld-velero` bucket in `eu-central-003` (bucket-default SSE-B2, lifecycle rule deleting hidden versions after one day) and a dedicated application key limited to it, then store the key as `/velero/B2_APPLICATION_KEY_ID`/`/velero/B2_APPLICATION_KEY` alongside a `/velero/KOPIA_REPOSITORY_PASSWORD` you keep recoverable. Follow [docs/velero.md](docs/velero.md).

The one key not synchronized from Infisical (see [docs/secrets.md](docs/secrets.md)) is the External Secrets Operator's own Infisical Universal Auth credentials: create the Machine Identity now, and seed its client ID and secret during the Talos bootstrap (the operator cannot fetch the credentials that grant it access to Infisical).

### 5. Bootstrap the Talos Cluster (Three Control Planes)
Bring up the Talos control plane: static DHCP leases for the nodes plus two reserved virtual IPs on the router (`CONTROL_PLANE_VIP` for the Kubernetes API and `192.168.8.50` for the Envoy Gateway), ISO installation, machine configuration generation, etcd bootstrap, the gVisor RuntimeClass, Cilium, the External Secrets Infisical credentials, WireGuard, and Longhorn disk provisioning. Follow [docs/talos.md](docs/talos.md).

### 6. Bootstrap Argo CD
From the same workstation shell (the kubeconfig from step 5, `helm` and `yq` installed, and a clone of this repository as the working directory), install a minimal Argo CD and hand it the root Application. Argo CD then deploys everything else from git in sync-wave order ([docs/argocd.md](docs/argocd.md)), and in its first wave adopts its own release with `apps/argocd/helm` (Dragonfly as Redis, ServiceMonitors, OIDC, gVisor):
```bash
# Argo CD applies the Pod Security labels from apps/app-of-apps.yaml only to
# namespaces it creates itself, so create this one with them.
kubectl apply -f - <<'NAMESPACE'
apiVersion: v1
kind: Namespace
metadata:
  name: argocd
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: v1.37
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/audit-version: v1.37
    pod-security.kubernetes.io/warn: restricted
    pod-security.kubernetes.io/warn-version: v1.37
NAMESPACE

# Same chart and version as apps/argocd/helm/kustomization.yaml
helm install argocd argo-cd \
  --repo "$(yq '.helmCharts[0].repo' apps/argocd/helm/kustomization.yaml)" \
  --version "$(yq '.helmCharts[0].version' apps/argocd/helm/kustomization.yaml)" \
  --namespace argocd \
  --values bootstrap/argocd-values.yaml \
  --wait

kubectl apply --server-side -f apps/app-of-apps.yaml

# Follow progress until every Application is Synced and Healthy
kubectl -n argocd get applications -w
```
From then on Argo CD owns its own release: change it through git, never with `helm upgrade`. Its web UI is `https://argocd.homeworld.internal` (trust the CA first, step 8), with Authelia sign-in for `argocd-admin` members.

### 7. Zigbee Coordinator
Label the node with the physical Zigbee USB adapter attached:
```bash
kubectl label node <node-name> environment=zigbee
```
This pins `homeassistant-zigbee2mqtt` to the host hardware where the serial dongle is connected. The first start seeds `/app/data/configuration.yaml` with the broker and frontend pre-wired; fill in `serial.port` with your adapter's path under the mounted `/dev/serial/by-id` (Zigbee2MQTT cannot start without it).

### 8. Trust the Homeworld CA on Your Devices
Install `homeworld-ca.crt` (the certificate only, never the key) on every device that opens `*.homeworld.internal`, whether on the Pixel network or over WireGuard:
- **Android**: *Settings → Security & privacy → More security settings → Encryption & credentials → Install a certificate → CA certificate*. Browsers trust it; individual apps trust user-installed CAs only if they opt in, so check each app you use (Immich, Bitwarden, Home Assistant, OpenCloud, DAVx⁵, Notesnook, OpenChamber).
- **macOS**: `sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain homeworld-ca.crt`
- **Linux**: copy it to `/usr/local/share/ca-certificates/homeworld-ca.crt` and run `sudo update-ca-certificates`; Firefox keeps its own store (*Settings → Privacy & Security → Certificates → View Certificates → Import*).
- **Windows**: `certutil -addstore -f Root homeworld-ca.crt` from an elevated prompt.

Names resolve only through the router, so keep Android's *Private DNS* on **Automatic** (a named provider bypasses the router, also over WireGuard) and keep browser "secure DNS" on the system resolver. Git over SSH uses `git@git.homeworld.internal` on port 22.

Woodpecker pipeline pods do not mount the CA: a pipeline that clones `https://git.homeworld.internal` must supply it to the clone step itself (the git plugin's `custom_ssl_path`/`custom_ssl_url` settings) or clone over SSH.

### 9. Create the Forgejo OAuth Application for Woodpecker CI
Woodpecker CI authenticates users and receives repository webhooks via Forgejo OAuth2:
1. In Forgejo, navigate to **Site Administration** -> **Applications** -> **Create OAuth2 Application**.
   - **Application Name**: `Woodpecker CI`
   - **Redirect URI**: `https://ci.homeworld.internal/authorize`
2. Save the generated credentials into Infisical:
   - `/woodpecker/FORGEJO_CLIENT`: `<Client ID>`
   - `/woodpecker/FORGEJO_SECRET`: `<Client Secret>`

### 10. Create API Tokens for Homepage Widgets
The Homepage dashboard's live widgets authenticate to four services with dedicated read-only tokens, stored in Infisical under `/homepage/*` (see [docs/secrets.md](docs/secrets.md)):
1. **Argo CD**: sign in as an `argocd-admin` user, then open **Settings → Accounts → `homepage` → Tokens → Generate New**. Save the token to `/homepage/ARGOCD_TOKEN`. The API-key-only `homepage` account and its read-only RBAC mapping are declared in `apps/argocd/helm/values.yaml`.
2. **Grafana**: open **Administration → Users → Service accounts**, add the service account `homepage`, then **Add service account token**. Save it to `/homepage/GRAFANA_TOKEN`.
3. **Home Assistant**: open your profile → **Security** tab → **Long-lived access tokens → Create Token**. Save it to `/homepage/HASS_TOKEN`.
4. **Immich**: open **Account Settings → API Keys → New API Key**. Save it to `/homepage/IMMICH_API_KEY`.

Homepage reads its dashboard configuration (`apps/homepage/0_config.yaml`) at startup; after changing it, restart the pod with `kubectl -n homepage rollout restart deploy/homepage`.

### 11. Access OpenChamber and Log In to the Coding Agents
After the `openchamber` workspace deploys (see [docs/openchamber.md](docs/openchamber.md) for the architecture, bootstrap, and PR-gated update flow):

- **Image bootstrap**: the first deployment references the `main-bootstrap` placeholder tag, so the pod reports `ImagePullBackOff` until the first image build commits a real tag. After that first build, make the `gjpin/openchamber` GHCR package public so the cluster can pull it without credentials.
- **OpenChamber remote access**: reachable only over WireGuard at `https://openchamber.homeworld.internal`; sign in with the `/openchamber/OPENCHAMBER_UI_PASSWORD` Infisical secret. Desktop and mobile apps connect to the same URL directly via QR-code pairing (*Settings → Remote Instances*); no relay or tunnel is needed.
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