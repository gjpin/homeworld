# Homeworld

## Features
- Highly available [k3s](docs/k3s.md) on [Fedora Server](docs/fedora.md): three servers with embedded etcd, SELinux enforcing, LUKS root unlocked through Tang, firewalld, and host configuration pulled from git
- Unattended updates: daily Fedora packages, serialized [kured](docs/fedora.md#updates-and-reboots) reboots gated on vmalert alerts, automated Fedora release upgrades, and k3s upgrades through system-upgrade-controller
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
- Distributed block storage with Longhorn (three replicas) and bulk NFS storage on the [NAS](docs/nas.md)
- Automated encrypted [Velero backups](docs/velero.md) to Backblaze B2
- Unified telemetry pipeline with OpenTelemetry Collector, VictoriaMetrics, VictoriaLogs, and VictoriaTraces
- Declarative dashboards and monitoring via Grafana Operator, with Prometheus Operator ServiceMonitors and PodMonitors consumed by the OpenTelemetry Operator's Target Allocator
- Automated dependency updates and [upgrade procedures](docs/upgrades.md) via Renovate
- [Coder](docs/coder.md) cloud development workspaces on Kubernetes, with Coder Agents running AI coding agents from the control plane
- AI agent [virtual machine](docs/openchamber.md) (OpenChamber, Paseo, ThinkRail, OpenCode, Claude Code, Codex CLI, Pi agent, Antigravity CLI, Copilot CLI on Fedora) with a rebuildable root and pinned tools

## Apps
User-facing applications:
| App | Domain(s) | Description |
| --- | --- | --- |
| Actual Budget | `budget.homeworld.internal` | Envelope-budgeting sync server and web app with Authelia sign-in and Enable Banking bank sync. |
| AFFiNE | `affine.homeworld.internal` | Docs, whiteboards, and databases with Authelia sign-in, Manticore-backed search, CalDAV calendars through OpenCloud, and AI through workspace-owned provider keys ([docs/affine.md](docs/affine.md)). |
| Coder | `coder.homeworld.internal`<br>`*.coder.homeworld.internal` | Cloud development workspaces and Coder Agents; the wildcard serves workspace apps ([docs/coder.md](docs/coder.md)). |
| Collabora | `office.homeworld.internal` | WOPI office editor for OpenCloud. |
| Forgejo | `git.homeworld.internal` | Git forge. |
| Home Assistant | `home.homeworld.internal`<br>`z2m.homeworld.internal` | Home automation and Zigbee bridge. |
| Homepage | `homepage.homeworld.internal` | Application dashboard aggregating links, status, and live service widgets. |
| Immich | `photos.homeworld.internal` | Photo and video management. |
| Notesnook | `notes.homeworld.internal`<br>`auth.notes.homeworld.internal`<br>`sse.notes.homeworld.internal`<br>`monograph.notes.homeworld.internal` | End-to-end encrypted note-taking sync server with auth, SSE, and Monograph. |
| OpenChamber | `openchamber.homeworld.internal`<br>`paseo.homeworld.internal`<br>`thinkrail.homeworld.internal` | Routes to the AI agent VM on the Ryzen node: the OpenChamber web server, the Paseo daemon, and ThinkRail (behind the Gateway's Authelia sign-in). |
| OpenCloud | `cloud.homeworld.internal` | Files, sharing, search, collaboration, CalDAV, and CardDAV. |
| qBittorrent | `qbittorrent.homeworld.internal` | Torrent client with a gluetun VPN sidecar, a three-layer kill switch (gluetun firewall, Cilium egress allowlist, readiness gate), and VPN port-forwarding (see [qbittorrent.md](docs/qbittorrent.md)). |
| Supernote | `supernote.homeworld.internal` | Supernote Private Cloud: device sync, web file manager, and note conversion (amd64 nodes only). |
| Vaultwarden | `vault.homeworld.internal` | Bitwarden-compatible password manager with optional Authelia SSO sign-in. |
| Woodpecker CI | `ci.homeworld.internal` | Continuous integration engine integrated with Forgejo. |

## Platform
Operators, foundations, and supporting services:
| App | Domain(s) | Description |
| --- | --- | --- |
| Admission Policies | — | CEL ValidatingAdmissionPolicies protecting Pod Security Admission labels. |
| Argo CD | `argocd.homeworld.internal` | GitOps continuous delivery. |
| Authelia | `auth.homeworld.internal` | Identity provider for every OIDC sign-in (applications and the gateway-OIDC routes). |
| cert-manager | — | TLS certificates for every Gateway listener from the private Homeworld CA. |
| Cilium | — | kube-proxy-free eBPF CNI with WireGuard pod-to-pod encryption and Hubble relay/UI observability (cluster-internal). |
| CloudNativePG | — | PostgreSQL operator. |
| CrowdSec | — | Security Engine, PostgreSQL-backed LAPI, and AppSec WAF. |
| CrowdSec Envoy Bouncer | — | Envoy Gateway external-authorization bouncer. |
| csi-driver-nfs | — | NFS CSI node plugin mounting the NAS shares behind the static Immich, OpenCloud, and qBittorrent volumes. |
| DocumentDB Operator | — | DocumentDB, a MongoDB-compatible datastore, operator. |
| Dragonfly Operator | — | Dragonfly, a Redis-compatible datastore, operator. |
| Envoy Gateway | `envoy.homeworld.internal` | Gateway API implementation and its admin console. |
| External Secrets | — | Infisical-backed secret synchronization. |
| Grafana | `grafana.homeworld.internal` | Dashboards and observability visualization. |
| Grafana Operator | — | Grafana instance, dashboard, and datasource operator. |
| Kube Control Plane | — | Scrape targets for the k3s-embedded API servers, scheduler, controller manager, and etcd (a ServiceMonitor and ScrapeConfigs; no workloads). |
| Kube State Metrics | — | Cluster-state `kube_*` metrics for the OpenTelemetry pipeline and the CloudNativePG dashboard. |
| Kubelet Serving Cert Approver | — | Approves kubelet serving certificate CSRs so metrics-server scrapes kubelets over verified TLS. |
| kured | — | Serialized node reboots for package updates and Fedora release upgrades, gated on vmalert alerts. |
| Longhorn | `longhorn.homeworld.internal` | Distributed block-storage management. |
| MariaDB Operator | — | MariaDB operator; provisions MariaDB instances, their databases and users, and SQL seed jobs. |
| Metrics Server | — | Resource metrics for `kubectl top` and HPA, scraped from kubelets over verified TLS. |
| OpenTelemetry Collector | — | Telemetry collection and export. |
| OpenTelemetry Operator | — | Manages the collector and its Target Allocator, which discovers ServiceMonitor and PodMonitor scrape targets. |
| Prometheus Operator CRDs | — | Custom resource definitions required for monitoring resources; consumed by the OpenTelemetry Operator's Target Allocator. |
| Radicale | — | Internal CalDAV and CardDAV backend authenticated by OpenCloud. |
| RustFS | `s3.homeworld.internal`<br>`console.rustfs.homeworld.internal` | Shared S3-compatible object storage and Tenant console. |
| RustFS Operator | `rustfs.homeworld.internal` | RustFS storage operator and management console. |
| Snapshot Controller | — | CSI volume-snapshot controller driving the Longhorn CSI driver for Velero data movement and CNPG volume-snapshot backups. |
| System Upgrade Controller | — | k3s upgrades from version-pinned Plans, one server at a time. |
| trust-manager | — | Publishes the Homeworld CA certificate as the `homeworld-ca` ConfigMap in every namespace for in-cluster HTTPS clients. |
| Velero | — | Whole-cluster backups to Backblaze B2. |
| Velero UI | `velero.homeworld.internal` | Web interface for managing Velero. |
| VictoriaLogs | `victoria-logs.homeworld.internal` | Logs backend (VictoriaLogs Single, web UI). |
| VictoriaMetrics | `victoria-metrics.homeworld.internal` | Metrics backend (VictoriaMetrics Single, vmui) and vmalert, whose alerts gate node reboots. |
| VictoriaTraces | `victoria-traces.homeworld.internal` | Traces backend (VictoriaTraces Single, Jaeger/Tempo-compatible query APIs; visualize via Grafana). |

## Manual Setup

This is a fresh-install runbook, in order. Every cluster coordinate is committed as a literal value; if yours differ, change them in git (and in the router, NAS, and Infisical steps below) before the first node bootstrap:

| Constant | Value | Where it is set |
| --- | --- | --- |
| Domain | `homeworld.internal` | Every Gateway, route, and app config under `apps/`; the CA name constraint (step 3); the router's DNS rewrite ([docs/openwrt.md](docs/openwrt.md)) |
| Gateway VIP | `192.168.8.50` | Every Gateway's `spec.addresses`; `host/cluster.env`; the router's DNS rewrite; outside the router's DHCP pool ([docs/openwrt.md](docs/openwrt.md) section 17) |
| Kubernetes API VIP | `192.168.8.51` | `host/cluster.env` (kube-vip and the k3s `tls-san`); outside the router's DHCP pool |
| Node addresses | `192.168.8.10`–`.12` | The router's static leases; entered at bootstrap and kept on each node in `/etc/homeworld/env` (never in git) |
| NAS | `192.168.8.20` | `host/cluster.env`; the static NFS PersistentVolumes (Immich, OpenCloud, qBittorrent); the router's static lease ([docs/nas.md](docs/nas.md)) |
| Agents VM subnet | `10.20.0.0/24` (VM `10.20.0.10`) | `host/cluster.env`; `host/agents-vm/network.xml`; the router's static route; the OpenChamber EndpointSlices; Home Assistant's LAN egress exceptions |
| Tang | `http://192.168.8.1:7500` | `host/cluster.env`; the router ([docs/openwrt.md](docs/openwrt.md) section 17) |
| Infisical | `https://eu.infisical.com`, project `homeworld`, environment `prod` | `apps/external-secrets/2_secret_store.yaml` and its egress policy; the agents VM's secrets loader (`host/agents-vm/provision.sh`) |
| Velero B2 target | bucket `homeworld-velero` in `eu-central-003` | `apps/velero/helm/values.yaml` and its egress policies |
| Git source | `https://github.com/gjpin/homeworld.git` at `HEAD` (`main`) | Every Argo CD `Application` (`apps/app-of-apps.yaml` and the child Applications); the hosts' hourly pull (`REPO_TARBALL` in `host/cluster.env`) |

### 1. Configure the Router
Set up the OpenWrt router before anything else. Follow [docs/openwrt.md](docs/openwrt.md), including its section 17 for the cluster: the nodes' and the NAS's static leases, the agents VM route, and the Tang server the nodes' encrypted disks unlock through. Its AdGuard Home answers every `*.homeworld.internal` name with the Gateway VIP, for the Pixel network and the WireGuard peers alike.

### 2. Prepare the NAS
Create the per-app NFS shares, their owners, and the exports on OpenMediaVault, and restrict NFS to the nodes. Follow [docs/nas.md](docs/nas.md).

### 3. Create the Homeworld CA
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
Store the PEM contents in Infisical as `/cert-manager/CA_CERT` (`homeworld-ca.crt`) and `/cert-manager/CA_KEY` (`homeworld-ca.key`), keep an offline backup of both, and delete the local key afterwards. cert-manager's `homeworld-ca` ClusterIssuer signs every Gateway certificate with it (and renews them automatically); trust-manager and Argo CD read only the certificate. Before the CA itself expires, repeat this step and re-trust the new certificate on every device (step 9).

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
| `platform` | Gateway-OIDC routes (victoria-metrics, victoria-logs, victoria-traces, longhorn, homepage, envoy admin listener, z2m); sign-in requires the group (deny-by-default) |
| `argocd-admin` | Argo CD admin (everyone else is read-only) |
| `forgejo-admin` | Forgejo site admin |
| `grafana-admin` | Grafana server admin (everyone else is a Viewer) |
| `immich-admin` | Immich admin (everyone else is a user) |
| `opencloud-admin` / `opencloud-spaceadmin` / `opencloud-user` / `opencloud-user-light` | OpenCloud roles; sign-in requires one of these groups (deny-by-default) |
| `vaultwarden-admin` / `vaultwarden-user` | Vaultwarden sign-in groups (role mapping is not supported by the upstream image; admin access is assigned in the admin panel via `ADMIN_TOKEN`) |
| `homeassistant-admin` | Home Assistant admin role |
| `affine-user` | AFFiNE sign-in; required (deny-by-default). AFFiNE roles are not mapped from groups: the instance admin is the account created in AFFiNE's `/admin` setup ([docs/affine.md](docs/affine.md)) |
| `coder-user` | Coder sign-in; required (deny-by-default). Coder roles are not mapped from groups: the first user to sign in becomes Owner ([docs/coder.md](docs/coder.md)) |

After editing the Infisical value, the change reaches the cluster on the ExternalSecret's hourly refresh (or immediately with `kubectl -n authelia delete secret authelia-files`, which External Secrets recreates at once). Authelia reads the database only at startup (`watch: false`), so finish with `kubectl -n authelia rollout restart deploy/authelia`.

### 5. Provision Infisical Secrets
Every component synchronizes its secrets from Infisical via the External Secrets Operator. The complete list of required keys, per component, is documented in [docs/secrets.md](docs/secrets.md). Create every key before bootstrapping the cluster; a missing key leaves the generated `Secret` incomplete and the pod fails with `CreateContainerConfigError`.

The Velero keys come from Backblaze: create the `homeworld-velero` bucket in `eu-central-003` (bucket-default SSE-B2, lifecycle rule deleting hidden versions after one day) and a dedicated application key limited to it, then store the key as `/velero/B2_APPLICATION_KEY_ID`/`/velero/B2_APPLICATION_KEY` alongside a `/velero/KOPIA_REPOSITORY_PASSWORD` you keep recoverable. Follow [docs/velero.md](docs/velero.md).

Two Machine Identities (Universal Auth) live outside the synchronized keys (see [docs/secrets.md](docs/secrets.md)): the External Secrets Operator's own, which cannot fetch the credentials that grant it access to Infisical, and the agents VM's read-only identity for the `/agents` folder. Create both now; the node bootstrap asks for their client IDs and secrets.

### 6. Install Fedora on the Nodes
Install Fedora Server with an encrypted root on each node, set its hostname, and copy your SSH key to its admin account. Follow [docs/fedora.md](docs/fedora.md#install).

### 7. Bootstrap the k3s Cluster
Run `host/bootstrap.sh <profile>` on the first node, then on the other two. It applies the host configuration from git, binds the encrypted root to Tang, installs k3s, and on the first node installs Cilium and a minimal Argo CD and hands it the root Application. Argo CD then deploys everything else from git in sync-wave order ([docs/argocd.md](docs/argocd.md)), and in its first wave adopts its own release with `apps/argocd/helm` (Dragonfly as Redis, ServiceMonitors, OIDC, gVisor). Follow [docs/k3s.md](docs/k3s.md#bootstrap).

From then on Argo CD owns its own release: change it through git, never with `helm upgrade`. Its web UI is `https://argocd.homeworld.internal` (trust the CA first, step 9), with Authelia sign-in for `argocd-admin` members.

### 8. Zigbee Coordinator
Label the node with the physical Zigbee USB adapter attached:
```bash
kubectl label node <node-name> environment=zigbee
```
This pins `homeassistant-zigbee2mqtt` to the host hardware where the serial dongle is connected. The first start seeds `/app/data/configuration.yaml` with the broker and frontend pre-wired; fill in `serial.port` with your adapter's path under the mounted `/dev/serial/by-id` (Zigbee2MQTT cannot start without it).

### 9. Trust the Homeworld CA on Your Devices
Install `homeworld-ca.crt` (the certificate only, never the key) on every device that opens `*.homeworld.internal`, whether on the Pixel network or over WireGuard:
- **Android**: *Settings → Security & privacy → More security settings → Encryption & credentials → Install a certificate → CA certificate*. Browsers trust it; individual apps trust user-installed CAs only if they opt in, so check each app you use (Immich, Bitwarden, Home Assistant, OpenCloud, DAVx⁵, Notesnook, OpenChamber, Paseo).
- **macOS**: `sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain homeworld-ca.crt`
- **Linux**: copy it to `/usr/local/share/ca-certificates/homeworld-ca.crt` and run `sudo update-ca-certificates`; Firefox keeps its own store (*Settings → Privacy & Security → Certificates → View Certificates → Import*).
- **Windows**: `certutil -addstore -f Root homeworld-ca.crt` from an elevated prompt.

Names resolve only through the router, so keep Android's *Private DNS* on **Automatic** (a named provider bypasses the router, also over WireGuard) and keep browser "secure DNS" on the system resolver. Git over SSH uses `git@git.homeworld.internal` on port 22.

Woodpecker pipeline pods do not mount the CA: a pipeline that clones `https://git.homeworld.internal` must supply it to the clone step itself (the git plugin's `custom_ssl_path`/`custom_ssl_url` settings) or clone over SSH.

### 10. Create the Forgejo OAuth Application for Woodpecker CI
Woodpecker CI authenticates users and receives repository webhooks via Forgejo OAuth2:
1. In Forgejo, navigate to **Site Administration** -> **Applications** -> **Create OAuth2 Application**.
   - **Application Name**: `Woodpecker CI`
   - **Redirect URI**: `https://ci.homeworld.internal/authorize`
2. Save the generated credentials into Infisical:
   - `/woodpecker/FORGEJO_CLIENT`: `<Client ID>`
   - `/woodpecker/FORGEJO_SECRET`: `<Client Secret>`

### 11. Create API Tokens for Homepage Widgets
The Homepage dashboard's live widgets authenticate to four services with dedicated read-only tokens, stored in Infisical under `/homepage/*` (see [docs/secrets.md](docs/secrets.md)):
1. **Argo CD**: sign in as an `argocd-admin` user, then open **Settings → Accounts → `homepage` → Tokens → Generate New**. Save the token to `/homepage/ARGOCD_TOKEN`. The API-key-only `homepage` account and its read-only RBAC mapping are declared in `apps/argocd/helm/values.yaml`.
2. **Grafana**: open **Administration → Users → Service accounts**, add the service account `homepage`, then **Add service account token**. Save it to `/homepage/GRAFANA_TOKEN`.
3. **Home Assistant**: open your profile → **Security** tab → **Long-lived access tokens → Create Token**. Save it to `/homepage/HASS_TOKEN`.
4. **Immich**: open **Account Settings → API Keys → New API Key**. Save it to `/homepage/IMMICH_API_KEY`.

Homepage reads its dashboard configuration (`apps/homepage/0_config.yaml`) at startup; after changing it, restart the pod with `kubectl -n homepage rollout restart deploy/homepage`.

### 12. Set Up Coder
Sign in to `https://coder.homeworld.internal` with a `coder-user` account; the first sign-in becomes the deployment Owner. Then make the `coder-workspace` package on GitHub public after the image workflow's first push, push the workspace template from `apps/coder/template/`, and configure an LLM provider for Coder Agents, following [docs/coder.md](docs/coder.md).

### 13. Use the Agents VM
The Ryzen node builds the agents VM during its bootstrap ([docs/openchamber.md](docs/openchamber.md)):

- **Browser**: `https://openchamber.homeworld.internal` (sign in with `/agents/OPENCHAMBER_UI_PASSWORD`), `https://paseo.homeworld.internal` (`/agents/PASEO_PASSWORD`) and `https://thinkrail.homeworld.internal` (Authelia, `platform` group), from the Pixel network or over WireGuard.
- **Apps**: pair the Paseo and OpenChamber desktop and mobile apps directly with the VM (`10.20.0.10`) or through the same hostnames; no relay is used.
- **SSH and editors**: `ssh agent@10.20.0.10` with the keys entered at bootstrap.
- **Coding agent logins**: once, over SSH; the credentials persist on the VM's `/home` across rebuilds:
  ```bash
  opencode auth login   # OpenCode
  codex login           # Codex CLI
  claude                # Claude Code
  pi                    # then run /login inside the Pi session
  agy                   # Antigravity CLI
  copilot login         # Copilot CLI (device-code flow)
  ```
  `/agents/OPENAI_API_KEY` and `/agents/GITHUB_TOKEN` reach the agents that OpenChamber and Paseo start, so Codex and OpenCode also work without an interactive login. Copilot CLI prefers `GITHUB_TOKEN` over its stored login, so that token must carry the Copilot Requests permission, otherwise `copilot login` appears to succeed but is silently shadowed.

### 14. Set Up AFFiNE
Open `https://affine.homeworld.internal/admin` right after the first sync and create the instance admin account in the setup wizard; `affine-user` members then sign in through Authelia. AI keys are not set in git: each workspace owner adds them under **Workspace Settings → Integrations → AI BYOK**, following [docs/affine.md](docs/affine.md).

## One-Time Codes

Authelia sends no email. When you register a TOTP app or security key, it asks for a one-time code, which it writes to a file inside its pod instead of mailing it:

```bash
kubectl -n authelia exec deploy/authelia -- cat /config/notification.txt
```

The newest code is at the bottom. The file lives on an emptyDir, so it empties when the pod restarts.
