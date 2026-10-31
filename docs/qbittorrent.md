# qBittorrent

Torrent client whose traffic is routed through a [gluetun](https://github.com/qdm12/gluetun) VPN sidecar (ProtonVPN over WireGuard), so all BitTorrent communication leaves the cluster encrypted through a VPN provider. qBittorrent also keeps its own WebUI login, exposes Prometheus metrics through an exporter sidecar, and continuously syncs the VPN provider's forwarded port so it stays connectable while seeding.

## Overview

| | |
| :--- | :--- |
| Component | `apps/qbittorrent` |
| Domain | `qbittorrent.base-domain.invalid` |
| Data | `qbittorrent-config` PVC (256Mi, Longhorn) mounted at `/config`; `media` (the shared NAS share `homeworld-media`, NFS, [nas.md](nas.md#media-share)) mounted at `/data`, downloads under `/data/torrents/<category>` |
| Dependencies | csi-driver-nfs, External Secrets, Envoy Gateway, OpenTelemetry operator |
| Secrets | `/qbittorrent/*` Infisical keys (see [secrets.md](secrets.md)) |

A single Deployment runs one pod with a shared network namespace containing three containers — qBittorrent, gluetun, and the Prometheus exporter — plus a rootless `qbittorrent-config-bootstrap` init container that seeds `qBittorrent.conf` on the first start of an empty PVC (see [Configuration seeding](#configuration-seeding)). The pod runs on the standard runtime (runc): gluetun sets up policy routing (`ip rule`), which gVisor's netlink does not implement, so it cannot run under gVisor. SELinux confines every container as `container_t` with the pod's own MCS categories, and gluetun's `NET_ADMIN`/`NET_RAW` act only on the pod's network namespace. gluetun uses the kernel WireGuard module (loaded on every node), so the pod needs no `/dev/net/tun`. qBittorrent and its init container run as the media share's owner, UID/GID `20004`, the exporter as its image's non-root user and gluetun as root (to manage the namespace's firewall and routes), and the pod keeps the host user namespace because NFS has no idmapped mounts. The `Recreate` strategy keeps two pods from ever owning the same tunnel routing state on a node.

## The kill switch

qBittorrent must not be able to send a single packet outside the VPN tunnel. Three independent layers enforce that; a leak requires all of them to fail at once.

**Layer 1 — gluetun's iptables firewall (in-pod).** gluetun owns the pod's network namespace. From container start — before the tunnel exists — it installs default-deny iptables rules (all chains DROP, IPv4 and IPv6) that permit only the VPN endpoint, established connections, loopback, and its own DNS bootstrap, and moves the default route onto the WireGuard interface once the tunnel is up. If the tunnel drops, the rules stay in blocking state while gluetun reconnects: qBittorrent's packets have no route out of the pod. `FIREWALL_INPUT_PORTS` opens inbound cluster traffic (WebUI, control server, health, metrics) and does not touch the outbound kill switch. `VPN_PORT_FORWARDING` holes are punched only on the tunnel interface. A `postStart` hook deletes stale tunnel ip rules left by an abruptly terminated container restart inside the same network namespace (the WireGuard table 51820).

**Layer 2 — the Cilium egress policy (cluster-wide).** The default-deny egress rule in `apps/qbittorrent/-2_network_policy.yaml` independently allows only two destinations off-node: ProtonVPN's WireGuard port (UDP 51820 — endpoint selection is dynamic, so the rule is port-scoped rather than FQDN-scoped) and the Cloudflare DNS-over-TLS bootstrap addresses gluetun needs before the tunnel is up (`1.1.1.1`/`1.0.0.1` on `:53`/`:853`). There is no TCP egress rule at all, so tracker and peer traffic cannot leave the pod even if gluetun crashed and its firewall was wiped. While the tunnel is up, all BitTorrent traffic is WireGuard-encapsulated to the provider endpoint — the only egress Cilium permits anyway.

**Layer 3 — the readiness gate (lifecycle).** gluetun serves a health endpoint on `:9999` that answers 200 only while the tunnel is healthy. Because all containers share the pod's network namespace, the *qbittorrent* container's readiness probe targets that port: when the VPN is down the pod flips `NotReady`, its endpoints drop from the Service, and the WebUI returns 503 at the gateway. A gluetun liveness probe on the same endpoint restarts a hung tunnel (the container's own liveness mechanism — `HEALTH_RESTART_VPN` is not set anywhere in this deployment; the restart comes from the probe killing the container, and gluetun reconnects on start).

**DNS goes through the tunnel too.** The pod sets `dnsPolicy: None` with `dnsConfig` pointing at `127.0.0.1` only — with the default ClusterFirst policy the kubelet would append the loopback resolver *after* the cluster DNS server, so the None policy is what keeps the cluster resolver out of `resolv.conf` entirely; the Cilium policy additionally denies the main pod any route to kube-dns. gluetun's built-in DNS-over-TLS resolver listens on that loopback address, so every qBittorrent lookup resolves through the encrypted tunnel and dies with it. The one documented residual: while the tunnel is down, gluetun's resolver bootstrap remains reachable (encrypted DoT to Cloudflare only), so hostname lookups are the sole traffic class that still succeeds; every payload connection still dies at layers 1 and 2.

Containers start in parallel, so qBittorrent may boot before the tunnel exists. That window is harmless by construction: layers 1 and 2 are already blocking at container start, and early announce attempts simply time out until gluetun brings the tunnel up.

## Network setup

```
                                               Internet
          VPN tunnel (UDP 51820, ProtonVPN WireGuard),    ^   |
          carrying all BitTorrent traffic both ways,      |   |
          and Cloudflare DoT bootstrap (1.1.1.1/:53)      |   |
                                                          |   |
                              +---------------------------+---+-------------------------------+
                              | Cilium egress allowlist: the only destinations                |
                              | eth0 may carry traffic to (no TCP rule exists)                |
                              +---------------------------+---+-------------------------------+
+---------------------------------------------------------+---+------------------------------------+
| qbittorrent pod (one shared network namespace)          |   |                                    |
| runc, container_t - no gVisor (ip rule)                |   | eth0 - the pod's only NIC          |
| gluetun iptables: default-deny (outbound via wg0 only)  |   |                                    |
|                                                         |   |                                    |
|  +--------------------------------+     +---------------+---+---------------+                    |
|  | qbittorrent                    |     | gluetun    (VPN sidecar)          |                    |
|  | WebUI / WebAPI   :8080         |     | iptables firewall                 |                    |
|  | BitTorrent traffic             |wg0  | DoT DNS resolver                  |                    |
|  | readiness probe ->             |     | health server    :9999            |                    |
|  | gluetun health  :9999          |     | control server   :8000            |                    |
|  | (shared network namespace)     |     | VPN tunnel client                 |                    |
|  +----+---------------------------+     +-----------------------------------+                    |
|       |  127.0.0.1:8080             DNS: all containers -> 127.0.0.1:53 -> gluetun DoT           |
|       |                             resolver, resolving through the tunnel                       |
|  +----+------------------------+                                                                 |
|  | exporter   :17871           |                                                                 |
|  | Prometheus metrics          |                                                                 |
|  | scrapes WebAPI on loopback  |                                                                 |
|  +-----------------------------+                                                                 |
+---------+---------------+-----------------+-------------------------+----------------------------+
          ^               ^                 ^                         ^
          |               |                 |                         |
      Envoy Gateway   OTel collector     port-forward             kubelet probes
                      (Target Allocator) sync CronJob             -> :8080/:9999/:17871
      -> :8080        -> :17871          -> :8000/:8080           (from the node)

```

| Port | Serves | Reachable from (CiliumNetworkPolicy) |
| :--- | :--- | :--- |
| `8080` | qBittorrent WebUI / WebAPI | Envoy Gateway, port-forward sync job, the media stack (Sonarr, Radarr, Lidarr, Bindery, Cleanuparr, qbit_manage), kubelet probes; loopback from the exporter |
| `8000` | gluetun HTTP control server | port-forward sync job only (API-key authenticated) |
| `9999` | gluetun health server | kubelet probes (gluetun liveness/startup, qbittorrent readiness) |
| `17871` | exporter metrics (`/metrics`), health (`/healthz`) | OpenTelemetry collector, kubelet probes |
| `6881` | BitTorrent listening port | through the tunnel only — the VPN-forwarded port, reachable by peers via the provider, never exposed on a Kubernetes Service |

## VPN provider and port forwarding

gluetun connects to ProtonVPN over WireGuard (`VPN_SERVICE_PROVIDER=protonvpn`, `VPN_TYPE=wireguard`, set in the manifest). The WireGuard private key and interface address come from a ProtonVPN WireGuard configuration generated with NAT-PMP port forwarding enabled, and `SERVER_NAMES` pins the preferred servers from gluetun's vendored server list (pick port-forwarding-capable ones).

Port forwarding uses ProtonVPN's NAT-PMP (`VPN_PORT_FORWARDING_PROVIDER=protonvpn`). A five-minute CronJob (a rootless, gVisor-sandboxed `alpine` shell script) reads the forwarded port from gluetun's authenticated control server and applies it to qBittorrent's listening-port setting through the WebAPI, so the seeded `Session\Port` value is only the bootstrap default. qBittorrent's own UPnP/NAT-PMP port mapping stays disabled (it would fight the VPN's forwarded port and map ports onto the node network).

## Authentication

The WebUI keeps its own username/password login — no OIDC (see [oidc.md](oidc.md)): the route is also an API endpoint for non-browser clients, which cannot complete an OIDC redirect. Humans sign in with the WebUI credential pair; the metrics exporter and the port-forward sync job authenticate with a stateless WebAPI key instead of the password; the Homepage widget authenticates with the WebUI credentials. The IP-subnet auth whitelist is deliberately unused — external access always authenticates.

## Configuration seeding

The `qbittorrent-config-bootstrap` init container seeds `/config/qBittorrent/qBittorrent.conf` and `categories.json` only when they do not exist (qBittorrent never overwrites an existing config), so the seed applies once on an empty PVC and the config stays user-owned state afterwards. Seeded settings: the WebUI port, username, PBKDF2-hashed password, and API key; the Host-header whitelist (`WebUI\ServerDomains`, a quoted semicolon-separated list, since Qt's INI parser reads an unquoted `;` as the start of a comment, holding the cluster domain plus the in-cluster Service names — the short `qbittorrent` for the sync job, and `qbittorrent.qbittorrent[.svc[.cluster.local]]` for the media stack's clients in other namespaces — so they pass qBittorrent's DNS-rebinding defense; loopback and pod-IP requests pass it by matching the listener address); loopback auth disabled (`WebUI\LocalHostAuth=false`), so the metrics exporter's requests over the pod's loopback interface need no credentials (it still sends the stateless WebAPI key); the save path `/data/torrents` with automatic torrent management on, and one category per *arr (`tv`, `movies`, `music`, `books`, `audiobooks`) saving under `/data/torrents/<category>` on the shared media volume, so imports into `/data/media` hardlink instead of copying ([nas.md](nas.md#media-share)); the initial listening port; and UPnP/port-forwarding off. Later git changes to these values must be applied by editing the files directly (Home Assistant bootstrap convention). Everything TRaSH-guides classifies as personal preference — rate limits, queueing, seeding goals, anonymous mode — is deliberately left to the WebUI (leave `*.rar` unexcluded: Unpackerr extracts packed downloads), where qbit_manage's share limits and Cleanuparr's blacklist sync also act.

## Monitoring

The exporter serves Prometheus metrics on `:17871`, scraped by the OpenTelemetry collector through a `60s` ServiceMonitor discovered by the operator's Target Allocator. The collector's scrape egress into the namespace and the pod's metrics ingress are both explicitly allowed in the Cilium policies; nothing else may reach the port.

## Post-deploy verification

Items that can only be confirmed on the live cluster:

1. **Volumes and tunnel interface** — both volumes mount read-write (files on the NAS share appear as `20004:20004`), and gluetun brings up the kernel WireGuard interface without SELinux denials (`ausearch -m avc` on the node); check gluetun's logs and the init container on first boot.
2. **Seeded credentials** — the exporter logs in with the API key and the sync job's first run authenticates (proves the conf-seeded `WebUI\APIKey` was accepted).
3. **Tunnel bootstrap** — the tunnel establishes with the pod's DNS pointed at `127.0.0.1` (gluetun's DoT resolver chain working end to end).
4. **Egress scope** — gluetun traffic goes only to the VPN tunnel endpoint and the DoT bootstrap (hubble flows or gluetun's firewall debug).
5. **Kill-switch drill** — stop the tunnel through the control server (`PUT /v1/vpn/status`, `{"status":"stopped"}`) and confirm the pod flips `NotReady`, the WebUI returns 503 at the gateway, and no tracker/peer traffic leaves the pod; then let gluetun restore the tunnel.
6. **Port forwarding** — gluetun logs the forwarded port, the sync job applies it, and qBittorrent reports itself connectable.
