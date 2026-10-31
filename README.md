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
- One wildcard for every app: ExternalDNS publishes `*.<domain>` to a Cilium-announced Gateway VIP, and cert-manager issues a Let's Encrypt wildcard certificate through DNS-01; the domain itself stays out of git ([homeworld plugin](docs/argocd.md#homeworld-plugin))
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
| Actual Budget | `budget.base-domain.invalid` | Envelope-budgeting sync server and web app with Authelia sign-in and Enable Banking bank sync. |
| AFFiNE | `affine.base-domain.invalid` | Docs, whiteboards, and databases with Authelia sign-in, Manticore-backed search, CalDAV calendars through OpenCloud, and AI through workspace-owned provider keys ([docs/affine.md](docs/affine.md)). |
| Coder | `coder.base-domain.invalid`<br>`*.coder.base-domain.invalid` | Cloud development workspaces and Coder Agents; the wildcard serves workspace apps ([docs/coder.md](docs/coder.md)). |
| Collabora | `office.base-domain.invalid` | WOPI office editor for OpenCloud. |
| Forgejo | `git.base-domain.invalid` | Git forge. |
| Home Assistant | `home.base-domain.invalid`<br>`z2m.base-domain.invalid` | Home automation and Zigbee bridge. |
| Homepage | `homepage.base-domain.invalid` | Application dashboard aggregating links, status, and live service widgets. |
| Immich | `photos.base-domain.invalid` | Photo and video management. |
| Notesnook | `notes.base-domain.invalid`<br>`auth.notes.base-domain.invalid`<br>`sse.notes.base-domain.invalid`<br>`monograph.notes.base-domain.invalid` | End-to-end encrypted note-taking sync server with auth, SSE, and Monograph. |
| OpenChamber | `openchamber.base-domain.invalid`<br>`paseo.base-domain.invalid`<br>`thinkrail.base-domain.invalid` | Routes to the AI agent VM on the Ryzen node: the OpenChamber web server, the Paseo daemon, and ThinkRail (behind the Gateway's Authelia sign-in). |
| OpenCloud | `cloud.base-domain.invalid` | Files, sharing, search, collaboration, CalDAV, and CardDAV. |
| Supernote | `supernote.base-domain.invalid` | Supernote Private Cloud: device sync, web file manager, and note conversion (amd64 nodes only). |
| Vaultwarden | `vault.base-domain.invalid` | Bitwarden-compatible password manager with optional Authelia SSO sign-in. |
| Woodpecker CI | `ci.base-domain.invalid` | Continuous integration engine integrated with Forgejo. |

## *arr Stack
Media automation, download and streaming apps sharing the NAS media library ([docs/media-stack.md](docs/media-stack.md)):
| App | Domain(s) | Description |
| --- | --- | --- |
| Audiobookshelf | `audiobookshelf.base-domain.invalid` | Audiobook and podcast server with Authelia sign-in and mobile apps; reads the audiobooks Bindery imports. |
| AudioMuse-AI | `audiomuse.base-domain.invalid` | Sonic analysis of the music library: similar songs, mood and genre playlists written into Navidrome, and Navidrome's Instant Mix through its plugin; behind the Gateway's Authelia sign-in. |
| Bazarr | `bazarr.base-domain.invalid` | Subtitle manager for Sonarr and Radarr, behind the Gateway's Authelia sign-in. |
| beets | — | Job tagging new Lidarr albums in place every 15 minutes: MusicBrainz tags, cover art, genres, synced lyrics and ReplayGain. |
| Bindery | `bindery.base-domain.invalid` | Book and audiobook manager (the Readarr successor) with Authelia sign-in; imports into the shared media library. |
| Cleanuparr | `cleanuparr.base-domain.invalid` | Download queue cleaner and malware blocker for qBittorrent and the *arrs, with Authelia sign-in. |
| Feishin | `feishin.base-domain.invalid` | Web music player for Navidrome, signed in with Navidrome accounts. |
| FlareSolverr | — | Cloudflare challenge solver used only by Prowlarr (no route, no login). |
| Gluetun | — | ProtonVPN WireGuard sidecar in the qBittorrent pod: tunnels all BitTorrent traffic and DNS, keeps a default-deny firewall as the kill switch, and provides the forwarded port qBittorrent seeds on ([qbittorrent.md](docs/qbittorrent.md)). |
| Houndarr | `houndarr.base-domain.invalid` | Rate-limited background searches for missing episodes, films and albums in Sonarr, Radarr and Lidarr, behind the Gateway's Authelia sign-in. |
| Jellyfin | `jellyfin.base-domain.invalid` | Media server for movies, TV and music with Intel QuickSync hardware transcoding. |
| Jellyfin-Auto-Collections | — | Daily job building Jellyfin collections from IMDb and Letterboxd lists. |
| Lidarr | `lidarr.base-domain.invalid` | Music manager, behind the Gateway's Authelia sign-in. |
| Maintainerr | `maintainerr.base-domain.invalid` | Rule-based library cleanup through Jellyfin, Seerr, Sonarr and Radarr, behind the Gateway's Authelia sign-in. |
| Media Config | — | Hourly job wiring the media stack through the apps' APIs: download clients, root folders, Prowlarr app links, Jellyfin connections, delay profiles, Seerr and Maintainerr servers, Bazarr's English subtitle profile, Bindery's integrations. |
| Navidrome | `navidrome.base-domain.invalid` | Music streaming server with the Subsonic API for mobile and desktop players. |
| Prowlarr | `prowlarr.base-domain.invalid` | Indexer manager for the *arrs and Bindery, behind the Gateway's Authelia sign-in. |
| qbit_manage | — | qBittorrent lifecycle job: tracker tags, share limits, unregistered and orphaned cleanup. |
| qBittorrent | `qbittorrent.base-domain.invalid` | Torrent client with a gluetun VPN sidecar, a three-layer kill switch (gluetun firewall, Cilium egress allowlist, readiness gate), and VPN port-forwarding (see [qbittorrent.md](docs/qbittorrent.md)). |
| Radarr | `radarr.base-domain.invalid` | Movie manager, behind the Gateway's Authelia sign-in. |
| Recyclarr | — | Hourly job syncing TRaSH Guides quality profiles and custom formats into Sonarr and Radarr. |
| Seerr | `seerr.base-domain.invalid` | Movie and series requests with Jellyfin accounts. |
| Sonarr | `sonarr.base-domain.invalid` | TV series manager, behind the Gateway's Authelia sign-in. |
| Streamystats | `streamystats.base-domain.invalid` | Jellyfin watch statistics and recommendations, signed in with Jellyfin accounts. |
| Unpackerr | — | Extracts packed (RAR) downloads for Sonarr, Radarr and Lidarr so they import. |

## Platform
Operators, foundations, and supporting services:
| App | Domain(s) | Description |
| --- | --- | --- |
| Admission Policies | — | CEL ValidatingAdmissionPolicies protecting Pod Security Admission labels. |
| Argo CD | `argocd.base-domain.invalid` | GitOps continuous delivery. |
| Authelia | `auth.base-domain.invalid` | Identity provider for every OIDC sign-in (applications and the gateway-OIDC routes). |
| cert-manager | — | The shared Gateway's Let's Encrypt wildcard certificate (DNS-01 through Cloudflare). |
| Cilium | — | kube-proxy-free eBPF CNI with WireGuard pod-to-pod encryption and Hubble relay/UI observability (cluster-internal). |
| CloudNativePG | — | PostgreSQL operator. |
| CrowdSec | — | Security Engine, PostgreSQL-backed LAPI, and AppSec WAF. |
| CrowdSec Envoy Bouncer | — | Envoy Gateway external-authorization bouncer. |
| csi-driver-nfs | — | NFS CSI node plugin mounting the NAS shares behind the static Immich, OpenCloud, and media-stack volumes. |
| DocumentDB Operator | — | DocumentDB, a MongoDB-compatible datastore, operator. |
| Dragonfly Operator | — | Dragonfly, a Redis-compatible datastore, operator. |
| Envoy Gateway | `envoy.base-domain.invalid` | Gateway API implementation and its admin console. |
| ExternalDNS | — | Publishes the wildcard DNS record pointing every app hostname at the Gateway VIP (Cloudflare). |
| External Secrets | — | Infisical-backed secret synchronization. |
| Grafana | `grafana.base-domain.invalid` | Dashboards and observability visualization. |
| Grafana Operator | — | Grafana instance, dashboard, and datasource operator. |
| Intel GPU Plugin | — | Intel's device plugin advertising the corebox iGPU (`gpu.intel.com/i915`) for Jellyfin's QuickSync transcoding. |
| Kube Control Plane | — | Scrape targets for the k3s-embedded API servers, scheduler, controller manager, and etcd (a ServiceMonitor and ScrapeConfigs; no workloads). |
| Kube State Metrics | — | Cluster-state `kube_*` metrics for the OpenTelemetry pipeline and the CloudNativePG dashboard. |
| Kubelet Serving Cert Approver | — | Approves kubelet serving certificate CSRs so metrics-server scrapes kubelets over verified TLS. |
| kured | — | Serialized node reboots for package updates and Fedora release upgrades, gated on vmalert alerts. |
| Longhorn | `longhorn.base-domain.invalid` | Distributed block-storage management. |
| MariaDB Operator | — | MariaDB operator; provisions MariaDB instances, their databases and users, and SQL seed jobs. |
| Metrics Server | — | Resource metrics for `kubectl top` and HPA, scraped from kubelets over verified TLS. |
| OpenTelemetry Collector | — | Telemetry collection and export. |
| OpenTelemetry Operator | — | Manages the collector and its Target Allocator, which discovers ServiceMonitor and PodMonitor scrape targets. |
| Prometheus Operator CRDs | — | Custom resource definitions required for monitoring resources; consumed by the OpenTelemetry Operator's Target Allocator. |
| Radicale | — | Internal CalDAV and CardDAV backend authenticated by OpenCloud. |
| RustFS | `s3.base-domain.invalid`<br>`console.rustfs.base-domain.invalid` | Shared S3-compatible object storage and Tenant console. |
| RustFS Operator | `rustfs.base-domain.invalid` | RustFS storage operator and management console. |
| Snapshot Controller | — | CSI volume-snapshot controller driving the Longhorn CSI driver for Velero data movement and CNPG volume-snapshot backups. |
| System Upgrade Controller | — | k3s upgrades from version-pinned Plans, one server at a time. |
| Velero | — | Whole-cluster backups to Backblaze B2. |
| Velero UI | `velero.base-domain.invalid` | Web interface for managing Velero. |
| VictoriaLogs | `victoria-logs.base-domain.invalid` | Logs backend (VictoriaLogs Single, web UI). |
| VictoriaMetrics | `victoria-metrics.base-domain.invalid` | Metrics backend (VictoriaMetrics Single, vmui) and vmalert, whose alerts gate node reboots. |
| VictoriaTraces | `victoria-traces.base-domain.invalid` | Traces backend (VictoriaTraces Single, Jaeger/Tempo-compatible query APIs; visualize via Grafana). |

## Manual Setup

This is a fresh-install runbook, in order. Every cluster coordinate except the domain is committed as a literal value; if yours differ, change them in git (and in the router, NAS, and Infisical steps below) before the first node bootstrap. The domain lives only in Infisical: git carries the placeholder `base-domain.invalid`, which reads as "your domain" throughout this repository and its docs:

| Constant | Value | Where it is set |
| --- | --- | --- |
| Domain | Infisical `/argocd/BASE_DOMAIN` (placeholder `base-domain.invalid` in git) | Substituted into every Gateway, route, and app config under `apps/` by Argo CD's homeworld plugin ([docs/argocd.md](docs/argocd.md#homeworld-plugin)) and into the agents VM's seed; the router's rebind exception (`DNS_REBIND_DOMAIN`, [docs/openwrt.md](docs/openwrt.md)) |
| Gateway VIP | `192.168.8.50` | The Gateway's `spec.addresses`; the ExternalDNS wildcard record (`apps/external-dns/2_dns_endpoint.yaml`); `host/cluster.env`; outside the router's DHCP pool ([docs/openwrt.md](docs/openwrt.md) section 17) |
| Kubernetes API VIP | `192.168.8.51` | `host/cluster.env` (kube-vip and the k3s `tls-san`); outside the router's DHCP pool |
| Node addresses | `192.168.8.10`–`.12` | The router's static leases; entered at bootstrap and kept on each node in `/etc/homeworld/env` (never in git) |
| NAS | `192.168.8.20` | `host/cluster.env`; the static NFS PersistentVolumes (Immich, OpenCloud, the media stack); the router's static lease ([docs/nas.md](docs/nas.md)) |
| Agents VM subnet | `10.20.0.0/24` (VM `10.20.0.10`) | `host/cluster.env`; `host/agents-vm/network.xml`; the router's static route; the OpenChamber EndpointSlices; Home Assistant's LAN egress exceptions |
| Tang | `http://192.168.8.1:7500` | `host/cluster.env`; the router ([docs/openwrt.md](docs/openwrt.md) section 17) |
| Infisical | `https://eu.infisical.com`, project `homeworld`, environment `prod` | `apps/external-secrets/2_secret_store.yaml` and its egress policy; the agents VM's secrets loader (`host/agents-vm/provision.sh`) |
| Velero B2 target | bucket `homeworld-velero` in `eu-central-003` | `apps/velero/helm/values.yaml` and its egress policies |
| Git source | `https://github.com/gjpin/homeworld.git` at `HEAD` (`main`) | Every Argo CD `Application` (`apps/app-of-apps.yaml` and the child Applications); the hosts' hourly pull (`REPO_TARBALL` in `host/cluster.env`) |

### 1. Configure the Router
Set up the OpenWrt router before anything else. Follow [docs/openwrt.md](docs/openwrt.md), including its section 17 for the cluster: the nodes' and the NAS's static leases, the agents VM route, and the Tang server the nodes' encrypted disks unlock through. Set `DNS_REBIND_DOMAIN` to your domain: its public wildcard record answers with the private Gateway VIP, which AdGuard Home's rebind protection would otherwise drop.

### 2. Prepare the NAS
Create the per-app NFS shares, their owners, and the exports on OpenMediaVault, and restrict NFS to the nodes. Follow [docs/nas.md](docs/nas.md).

### 3. Set Up the Domain
Every app is served on `<app>.<domain>` from one wildcard DNS record and one wildcard certificate. The domain's DNS must be hosted on Cloudflare:
1. Create a Cloudflare API token (*My Profile → API Tokens*) with **Zone → DNS → Edit** and **Zone → Zone → Read** on the domain's zone. ExternalDNS publishes the `*.<domain>` A record to `192.168.8.50` with it, and cert-manager answers the Let's Encrypt DNS-01 challenges for the wildcard certificate.
2. Store the token in Infisical as `/cloudflare/API_TOKEN` and the domain itself (`example.com`, no wildcard or trailing dot) as `/argocd/BASE_DOMAIN` ([docs/secrets.md](docs/secrets.md)).

The record points at a private address, so the apps answer only on the Pixel network and over WireGuard even though the names resolve publicly. Certificate Transparency logs publish the domain (not the app names: the certificate covers `*.<domain>` plus the `*.notes`, `*.rustfs` and `*.coder` second-level wildcards).

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
| `platform` | Gateway-OIDC routes (victoria-metrics, victoria-logs, victoria-traces, longhorn, homepage, envoy admin listener, z2m, prowlarr, sonarr, radarr, lidarr, bazarr, maintainerr, houndarr, audiomuse); sign-in requires the group (deny-by-default) |
| `argocd-admin` | Argo CD admin (everyone else is read-only) |
| `forgejo-admin` | Forgejo site admin |
| `grafana-admin` | Grafana server admin (everyone else is a Viewer) |
| `immich-admin` | Immich admin (everyone else is a user) |
| `opencloud-admin` / `opencloud-spaceadmin` / `opencloud-user` / `opencloud-user-light` | OpenCloud roles; sign-in requires one of these groups (deny-by-default) |
| `vaultwarden-admin` / `vaultwarden-user` | Vaultwarden sign-in groups (role mapping is not supported by the upstream image; admin access is assigned in the admin panel via `ADMIN_TOKEN`) |
| `homeassistant-admin` | Home Assistant admin role |
| `affine-user` | AFFiNE sign-in; required (deny-by-default). AFFiNE roles are not mapped from groups: the instance admin is the account created in AFFiNE's `/admin` setup ([docs/affine.md](docs/affine.md)) |
| `coder-user` | Coder sign-in; required (deny-by-default). Coder roles are not mapped from groups: the first user to sign in becomes Owner ([docs/coder.md](docs/coder.md)) |
| `audiobookshelf-admin` / `audiobookshelf-user` | Audiobookshelf sign-in; required (deny-by-default). Roles are assigned in Audiobookshelf |
| `bindery-admin` / `bindery-user` | Bindery sign-in; required (deny-by-default). `bindery-admin` is mapped to the admin role on every login |
| `cleanuparr-admin` | Cleanuparr sign-in; required (deny-by-default). Every Cleanuparr account is an administrator |

After editing the Infisical value, the change reaches the cluster on the ExternalSecret's hourly refresh (or immediately with `kubectl -n authelia delete secret authelia-files`, which External Secrets recreates at once). Authelia reads the database only at startup (`watch: false`), so finish with `kubectl -n authelia rollout restart deploy/authelia`.

### 5. Provision Infisical Secrets
Every component synchronizes its secrets from Infisical via the External Secrets Operator. The complete list of required keys, per component, is documented in [docs/secrets.md](docs/secrets.md). Create every key before bootstrapping the cluster; a missing key leaves the generated `Secret` incomplete and the pod fails with `CreateContainerConfigError`.

The Velero keys come from Backblaze: create the `homeworld-velero` bucket in `eu-central-003` (bucket-default SSE-B2, lifecycle rule deleting hidden versions after one day) and a dedicated application key limited to it, then store the key as `/velero/B2_APPLICATION_KEY_ID`/`/velero/B2_APPLICATION_KEY` alongside a `/velero/KOPIA_REPOSITORY_PASSWORD` you keep recoverable. Follow [docs/velero.md](docs/velero.md).

Two Machine Identities (Universal Auth) live outside the synchronized keys (see [docs/secrets.md](docs/secrets.md)): the External Secrets Operator's own, which cannot fetch the credentials that grant it access to Infisical, and the agents VM's read-only identity for the `/agents` folder. Create both now; the node bootstrap asks for their client IDs and secrets.

### 6. Install Fedora on the Nodes
Install Fedora Server with an encrypted root on each node, set its hostname, and copy your SSH key to its admin account. Follow [docs/fedora.md](docs/fedora.md#install).

### 7. Bootstrap the k3s Cluster
Run `host/bootstrap.sh <profile>` on the first node, then on the other two. It applies the host configuration from git, binds the encrypted root to Tang, installs k3s, and on the first node installs Cilium and a minimal Argo CD and hands it the root Application. Argo CD then deploys everything else from git in sync-wave order ([docs/argocd.md](docs/argocd.md)), and in its first wave adopts its own release with `apps/argocd/helm` (Dragonfly as Redis, ServiceMonitors, OIDC, gVisor). Follow [docs/k3s.md](docs/k3s.md#bootstrap).

From then on Argo CD owns its own release: change it through git, never with `helm upgrade`. Its web UI is `https://argocd.base-domain.invalid`, with Authelia sign-in for `argocd-admin` members.

### 8. Zigbee Coordinator
Label the node with the physical Zigbee USB adapter attached:
```bash
kubectl label node <node-name> environment=zigbee
```
This pins `homeassistant-zigbee2mqtt` to the host hardware where the serial dongle is connected. The first start seeds `/app/data/configuration.yaml` with the broker and frontend pre-wired; fill in `serial.port` with your adapter's path under the mounted `/dev/serial/by-id` (Zigbee2MQTT cannot start without it).

### 9. Reach the Apps from Your Devices
Every `*.<domain>` name resolves publicly to the Gateway VIP `192.168.8.50`, which answers on the Pixel network and through WireGuard only. The certificates are publicly trusted, so devices and apps need no extra setup. Git over SSH uses `git@git.<domain>` on port 22.

### 10. Create the Forgejo OAuth Application for Woodpecker CI
Woodpecker CI authenticates users and receives repository webhooks via Forgejo OAuth2:
1. In Forgejo, navigate to **Site Administration** -> **Applications** -> **Create OAuth2 Application**.
   - **Application Name**: `Woodpecker CI`
   - **Redirect URI**: `https://ci.base-domain.invalid/authorize`
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
Sign in to `https://coder.base-domain.invalid` with a `coder-user` account; the first sign-in becomes the deployment Owner. Then make the `coder-workspace` package on GitHub public after the image workflow's first push, push the workspace template from `apps/coder/template/`, and configure an LLM provider for Coder Agents, following [docs/coder.md](docs/coder.md).

### 13. Use the Agents VM
The Ryzen node builds the agents VM during its bootstrap ([docs/openchamber.md](docs/openchamber.md)):

- **Browser**: `https://openchamber.base-domain.invalid` (sign in with `/agents/OPENCHAMBER_UI_PASSWORD`), `https://paseo.base-domain.invalid` (`/agents/PASEO_PASSWORD`) and `https://thinkrail.base-domain.invalid` (Authelia, `platform` group), from the Pixel network or over WireGuard.
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
Open `https://affine.base-domain.invalid/admin` right after the first sync and create the instance admin account in the setup wizard; `affine-user` members then sign in through Authelia. AI keys are not set in git: each workspace owner adds them under **Workspace Settings → Integrations → AI BYOK**, following [docs/affine.md](docs/affine.md).

### 15. Set Up the Media Stack
The media apps ([docs/media-stack.md](docs/media-stack.md)) keep most of their settings in their own databases. The connections between them are made by the hourly **media-config** job (`apps/media-config`) through the apps' APIs, so they need no UI steps and come back if removed:
- Sonarr, Radarr and Lidarr: the qBittorrent download client (categories `tv`, `movies`, `music`), the root folders `/data/media/tv`, `/data/media/movies` and `/data/media/music`, the global delay profile (a fresh release waits 6 hours for a better one, unless it is already the best quality), and a Jellyfin library-refresh connection once the Jellyfin API key exists. In Lidarr also: upgrades off on every quality profile, propers and repacks not preferred, imports **copied** instead of hardlinked, and **Write Audio Tags** set to **For new downloads only** (beets then retags the library in place; retagging a hardlinked file would corrupt the torrent it is seeding).
- Prowlarr: the Sonarr, Radarr and Lidarr app links (full sync) and the FlareSolverr proxy, applied to indexers tagged `flaresolverr`.
- Seerr: Sonarr and Radarr as the default servers with the combined 2160p profiles, once Seerr's first sign-in is done and Recyclarr has created the profiles.
- Maintainerr: Sonarr, Radarr, Seerr and (once the key exists) Jellyfin.
- Bazarr: an **English** language profile, set as the default for every new series and film (the profile is created once; later edits to it in the UI are kept).
- Bindery: the Prowlarr server (its indexers are re-synced every run), the qBittorrent client (categories `books` and `audiobooks`) and the Authelia OIDC provider.

Recyclarr manages the Sonarr and Radarr quality profiles (2160p preferred, otherwise the best lower resolution available; one download per title, no upgrades); pick **WEB-2160p (Combined)** in Sonarr and **WEBDL 2160p (Combined)** in Radarr when adding series and films (Seerr uses them by default). Lidarr's default **Any** profile is used for the music root folder. Run either job at once instead of waiting for the hour with `kubectl -n media-config create job --from=cronjob/media-config media-config-now` (or `-n recyclarr ... cronjob/recyclarr`).

What remains is the setup that creates accounts or picks content:
1. **Prowlarr**: add the indexers, and tag `flaresolverr` the ones behind Cloudflare.
2. **Bazarr**: enable the subtitle providers under **Settings → Providers**; only the providers listed in `apps/bazarr/-2_network_policy.yaml` are reachable, and OpenSubtitles.com needs an account.
3. **Jellyfin**: run the setup wizard, add the libraries under `/data/media`, and create API keys under **Dashboard → API Keys** for Homepage and media-config (`/homepage/JELLYFIN_API_KEY`), for Jellyfin-Auto-Collections (`/jellyfin-auto-collections/JELLYFIN_API_KEY`, with the user ID from the user's dashboard URL in `/jellyfin-auto-collections/JELLYFIN_USER_ID`), and for Streamystats (entered in its setup, step 12). Install the TMDb Box Sets plugin from the catalog.
4. **Seerr**: sign in with a Jellyfin administrator and point it at `http://jellyfin.jellyfin.svc.cluster.local:8096`; the next media-config run adds the Sonarr and Radarr servers.
5. **Bindery**: create the local admin (the fallback login); sign-in through Authelia works once media-config has added the provider.
6. **Audiobookshelf**: create the root user, add the libraries `/data/media/audiobooks` and `/data/media/podcasts`, enable OpenID Connect under **Settings → Authentication** (issuer `https://auth.base-domain.invalid`, client `audiobookshelf`, secret `/authelia/OIDC_CLIENT_SECRET_AUDIOBOOKSHELF`, *Match existing users by username*, auto-register off, no group claim), and create an API key for Homepage (`/homepage/AUDIOBOOKSHELF_API_KEY`).
7. **Navidrome**: create the admin user and a Homepage user; store `/homepage/NAVIDROME_USER`, a random salt as `/homepage/NAVIDROME_SALT`, and `md5(password + salt)` as `/homepage/NAVIDROME_TOKEN`. Create the account AudioMuse-AI uses with the `/audiomuse-ai/NAVIDROME_USER` and `/audiomuse-ai/NAVIDROME_PASSWORD` values (the playlists AudioMuse-AI creates belong to it; make them public in Navidrome to share them). Under **Plugins**, enable **AudioMuse-AI Instant Mix** with **AudioMuse-AI API URL** `http://audiomuse-ai-flask-service.audiomuse-ai.svc.cluster.local:8000` and **API Token** `/audiomuse-ai/API_TOKEN`. Navidrome rescans the library hourly, so Lidarr and beets need no connection to it.
8. **AudioMuse-AI**: sign in with `/audiomuse-ai/ADMIN_USERNAME` (created on the first start; the Navidrome server is already configured), start the first analysis under **Analysis and Clustering**, and schedule analysis and clustering under **Administration → Scheduled Tasks** so new music is analysed.
9. **Cleanuparr**: complete the first-run setup over `kubectl -n cleanuparr port-forward svc/cleanuparr 11011` (the setup endpoints are anonymous until the first account exists), then add qBittorrent (the WebAPI key `/qbittorrent/WEBUI_API_KEY`), Sonarr, Radarr and Lidarr, configure the Authelia OIDC provider (client `cleanuparr`, secret `/authelia/OIDC_CLIENT_SECRET_CLEANUPARR`) and link your account, and turn off **Status Check**. Enable the Queue Cleaner, the Malware Blocker (`blacklist` for Sonarr and Radarr, `blacklist_permissive` for Lidarr) and Blacklist Sync (`blacklist_permissive`); leave the Download Cleaner and the Seeker's proactive search off (qbit_manage and Houndarr own those jobs). Start with **Dry Run** on.
10. **Houndarr**: add the Sonarr, Radarr and Lidarr instances in its UI.
11. **Maintainerr**: create the cleanup rules; keep its qBittorrent and Jellyfin delete fallbacks off.
12. **Streamystats**: on the first visit, add the Jellyfin server with **Jellyfin URL** `http://jellyfin.jellyfin.svc.cluster.local:8096` and the Streamystats API key from Jellyfin (it can reach Jellyfin only in-cluster).
13. **qbit_manage** acts for real (`dry_run: False`). Deploy it only on a qbit_manage release whose `SUPPORTED_VERSIONS.json` lists the pinned qBittorrent.

Unpackerr, beets and Feishin need no setup: they are configured from git (beets has no UI, and Feishin's users sign in with their Navidrome accounts). Unpackerr's web UI (queue and history) is reached with `kubectl -n unpackerr port-forward svc/unpackerr 5656` and the user `admin` with the password `/unpackerr/UI_PASSWORD`.

## One-Time Codes

Authelia sends no email. When you register a TOTP app or security key, it asks for a one-time code, which it writes to a file inside its pod instead of mailing it:

```bash
kubectl -n authelia exec deploy/authelia -- cat /config/notification.txt
```

The newest code is at the bottom. The file lives on an emptyDir, so it empties when the pod restarts.
