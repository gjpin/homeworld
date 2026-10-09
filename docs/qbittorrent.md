# qBittorrent

Torrent client whose traffic is routed through a [gluetun](https://github.com/qdm12/gluetun) VPN sidecar (WireGuard for ProtonVPN, OpenVPN for Private Internet Access), so all BitTorrent communication leaves the cluster encrypted through a VPN provider. qBittorrent also keeps its own WebUI login, exposes Prometheus metrics through an exporter sidecar, and continuously syncs the VPN provider's forwarded port so it stays connectable while seeding.

## Overview

| | |
| :--- | :--- |
| Component | `apps/qbittorrent` |
| Domain | `qbittorrent.${BASE_DOMAIN}` |
| Data | `qbittorrent-config` PVC (1Gi) mounted at `/config`, `qbittorrent-downloads` PVC (250Gi) mounted at `/downloads` (both Longhorn) |
| Dependencies | `apps/generic-device-plugin` (the `/dev/net/tun` device), External Secrets, Envoy Gateway, CrowdSec bouncer, OpenTelemetry operator |
| Secrets | `/qbittorrent/*` Infisical keys (see [secrets.md](secrets.md)) |

A single Deployment runs one pod with a shared network namespace containing three containers — qBittorrent, gluetun, and the Prometheus exporter — plus a rootless `qbittorrent-config-bootstrap` init container that seeds `qBittorrent.conf` on the first start of an empty PVC (see [Configuration seeding](#configuration-seeding)). The pod runs in an unprivileged user namespace (`hostUsers: false`) on the standard runtime (gVisor does not implement the TUN device gluetun requires), is restricted to homelab nodes, and uses the `Recreate` strategy so two pods never own the same tunnel routing state on a node.

## The kill switch

qBittorrent must not be able to send a single packet outside the VPN tunnel. Three independent layers enforce that; a leak requires all of them to fail at once.

**Layer 1 — gluetun's iptables firewall (in-pod).** gluetun owns the pod's network namespace. From container start — before the tunnel exists — it installs default-deny iptables rules (all chains DROP, IPv4 and IPv6) that permit only the VPN endpoint, established connections, loopback, and its own DNS bootstrap, and moves the default route into the `tun` device once the tunnel is up. If the tunnel drops, the rules stay in blocking state while gluetun reconnects: qBittorrent's packets have no route out of the pod. `FIREWALL_INPUT_PORTS` opens inbound cluster traffic (WebUI, control server, health, metrics) and does not touch the outbound kill switch. `VPN_PORT_FORWARDING` holes are punched only on the tunnel interface. A `postStart` hook deletes stale tunnel ip rules left by an abruptly terminated container restart inside the same network namespace (the WireGuard table 51820; a no-op under OpenVPN).

**Layer 2 — the Cilium egress policy (cluster-wide).** The default-deny egress rule in `apps/qbittorrent/-2_network_policy.yaml` independently allows only two destinations off-node: the VPN providers' tunnel ports (UDP 51820 for ProtonVPN's WireGuard, UDP 8080 for Private Internet Access's OpenVPN — endpoint selection is dynamic, so the rule is port-scoped rather than FQDN-scoped) and the Cloudflare DNS-over-TLS bootstrap addresses gluetun needs before the tunnel is up (`1.1.1.1`/`1.0.0.1` on `:53`/`:853`). There is no TCP egress rule at all, so tracker and peer traffic cannot leave the pod even if gluetun crashed and its firewall was wiped. While the tunnel is up, all BitTorrent traffic is tunnel-encapsulated (WireGuard or OpenVPN) to the provider endpoint — the only egress Cilium permits anyway.

**Layer 3 — the readiness gate (lifecycle).** gluetun serves a health endpoint on `:9999` that answers 200 only while the tunnel is healthy. Because all containers share the pod's network namespace, the *qbittorrent* container's readiness probe targets that port: when the VPN is down the pod flips `NotReady`, its endpoints drop from the Service, and the WebUI returns 503 at the gateway. A gluetun liveness probe on the same endpoint restarts a hung tunnel (the container's own liveness mechanism — `HEALTH_RESTART_VPN` is not set anywhere in this deployment; the restart comes from the probe killing the container, and gluetun reconnects on start).

**DNS goes through the tunnel too.** The pod sets `dnsPolicy: None` with `dnsConfig` pointing at `127.0.0.1` only — with the default ClusterFirst policy the kubelet would append the loopback resolver *after* the cluster DNS server, so the None policy is what keeps the cluster resolver out of `resolv.conf` entirely; the Cilium policy additionally denies the main pod any route to kube-dns. gluetun's built-in DNS-over-TLS resolver listens on that loopback address, so every qBittorrent lookup resolves through the encrypted tunnel and dies with it. The one documented residual: while the tunnel is down, gluetun's resolver bootstrap remains reachable (encrypted DoT to Cloudflare only), so hostname lookups are the sole traffic class that still succeeds; every payload connection still dies at layers 1 and 2.

Containers start in parallel, so qBittorrent may boot before the tunnel exists. That window is harmless by construction: layers 1 and 2 are already blocking at container start, and early announce attempts simply time out until gluetun brings the tunnel up.

## Network setup

```
                                               Internet
          VPN tunnel (UDP 51820 ProtonVPN / 8080 PIA),    ^   |
          carrying all BitTorrent traffic both ways,      |   |
          and Cloudflare DoT bootstrap (1.1.1.1/:53)      |   |
                                                          |   |
                              +---------------------------+---+-------------------------------+
                              | Cilium egress allowlist: the only destinations                |
                              | eth0 may carry traffic to (no TCP rule exists)                |
                              +---------------------------+---+-------------------------------+
+---------------------------------------------------------+---+------------------------------------+
| qbittorrent pod (one shared network namespace)          |   |                                    |
| hostUsers: false - standard runtime (no gVisor: TUN)    |   | eth0 - the pod's only NIC          |
| gluetun iptables: default-deny (outbound via tun only)  |   |                                    |
|                                                         |   |                                    |
|  +--------------------------------+     +---------------+---+---------------+                    |
|  | qbittorrent                    |     | gluetun    (VPN sidecar)          |                    |
|  | WebUI / WebAPI   :8080         |tun0 | iptables firewall                 |                    |
|  | BitTorrent traffic             |====>| DoT DNS resolver                  |                    |
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
      (CrowdSec WAF)  (Target Allocator) sync CronJob             -> :8080/:9999/:17871
      -> :8080        -> :17871          -> :8000/:8080           (from the node)

```

| Port | Serves | Reachable from (CiliumNetworkPolicy) |
| :--- | :--- | :--- |
| `8080` | qBittorrent WebUI / WebAPI | Envoy Gateway, port-forward sync job, kubelet probes; loopback from the exporter |
| `8000` | gluetun HTTP control server | port-forward sync job only (API-key authenticated) |
| `9999` | gluetun health server | kubelet probes (gluetun liveness/startup, qbittorrent readiness) |
| `17871` | exporter metrics (`/metrics`), health (`/healthz`) | OpenTelemetry collector, kubelet probes |
| `6881` | BitTorrent listening port | through the tunnel only — the VPN-forwarded port, reachable by peers via the provider, never exposed on a Kubernetes Service |

## VPN providers and port forwarding

Provider selection is data, not manifest structure: gluetun reads `VPN_SERVICE_PROVIDER` (`protonvpn` or `private internet access` — gluetun's literal provider identifiers, spaces included) together with `VPN_TYPE` (`wireguard` for ProtonVPN, `openvpn` for Private Internet Access, which gluetun supports natively over OpenVPN only) and consumes only the active provider's credential set (ProtonVPN: WireGuard key and address; PIA: username and password, authenticating the OpenVPN tunnel and the port-forwarding API). Switching providers is a three-key Infisical edit (`VPN_SERVICE_PROVIDER`, `VPN_TYPE`, and `VPN_PORT_FORWARDING_PROVIDER` mirroring the provider) plus a pod restart; the inactive provider's keys hold placeholder values, and gluetun validates credentials for the active VPN type only. `SERVER_NAMES` pins the preferred servers from gluetun's vendored server list — required for PIA port forwarding, which is per-server (pick a port-forwarding-capable server).

Port forwarding uses each provider's native mechanism (ProtonVPN NAT-PMP, PIA API). A five-minute CronJob (a rootless, gVisor-sandboxed `alpine` shell script) reads the forwarded port from gluetun's authenticated control server and applies it to qBittorrent's listening-port setting through the WebAPI, so the seeded `Session\Port` value is only the bootstrap default. qBittorrent's own UPnP/NAT-PMP port mapping stays disabled (it would fight the VPN's forwarded port and map ports onto the node network).

## Authentication

The WebUI keeps its own username/password login behind the Gateway-level CrowdSec extAuth — no OIDC (see [oidc.md](oidc.md)): the route is also an API endpoint for non-browser clients, which cannot complete an OIDC redirect. Humans sign in with the WebUI credential pair; the metrics exporter and the port-forward sync job authenticate with a stateless WebAPI key instead of the password; the Homepage widget authenticates with the WebUI credentials. The IP-subnet auth whitelist is deliberately unused — external access always authenticates.

## Configuration seeding

The `qbittorrent-config-bootstrap` init container seeds `/config/qBittorrent/qBittorrent.conf` only when it does not exist (qBittorrent never overwrites an existing config), so the seed applies once on an empty PVC and the config stays user-owned state afterwards. Seeded settings: the WebUI port, username, PBKDF2-hashed password, and API key; the Host-header whitelist (`WebUI\ServerDomains`, holding the public domain plus the in-cluster Service name so the sync job and scripts reach the WebUI as `http://qbittorrent:8080` without failing qBittorrent's DNS-rebinding defense — loopback and pod-IP requests pass it by matching the listener address); loopback auth stays enabled — the metrics exporter authenticates with the stateless WebAPI key over the pod's loopback interface; the save path; the initial listening port; and UPnP/port-forwarding off. Later git changes to these values must be applied by editing the file directly (Home Assistant bootstrap convention). Everything TRaSH-guides classifies as personal preference — rate limits, queueing, seeding goals, anonymous mode, `*.rar` exclusions — is deliberately left to the WebUI.

## Monitoring

The exporter serves Prometheus metrics on `:17871`, scraped by the OpenTelemetry collector through a `60s` ServiceMonitor discovered by the operator's Target Allocator. The collector's scrape egress into the namespace and the pod's metrics ingress are both explicitly allowed in the Cilium policies; nothing else may reach the port.

## Post-deploy verification

Items that can only be confirmed on the live cluster:

1. **TUN device and volumes** — the pod schedules (the `devic.es/tun` resource exists on homelab nodes) and gluetun opens `/dev/net/tun` without an SELinux denial on Talos; both PVCs mount read-write under the unprivileged user namespace (Longhorn's xfs must support idmap mounts per the Kubernetes user-namespaces requirements); check gluetun's logs and the init container on first boot.
2. **Seeded credentials** — the exporter logs in with the API key and the sync job's first run authenticates (proves the conf-seeded `WebUI\APIKey` was accepted).
3. **Tunnel bootstrap** — the tunnel establishes with the pod's DNS pointed at `127.0.0.1` (gluetun's DoT resolver chain working end to end).
4. **Egress scope** — gluetun traffic goes only to the VPN tunnel endpoint and the DoT bootstrap (hubble flows or gluetun's firewall debug).
5. **Kill-switch drill** — stop the tunnel through the control server (`PUT /v1/vpn/status`, `{"status":"stopped"}`) and confirm the pod flips `NotReady`, the WebUI returns 503 at the gateway, and no tracker/peer traffic leaves the pod; then let gluetun restore the tunnel.
6. **Port forwarding** — gluetun logs the forwarded port, the sync job applies it, and qBittorrent reports itself connectable.
