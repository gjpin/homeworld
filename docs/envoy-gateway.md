# Envoy Gateway

One Gateway (`apps/envoy-gateway/2_gateway.yaml`) serves every app behind the Gateway VIP `192.168.8.50`: its HTTPS listeners cover `*.base-domain.invalid` and the `*.notes`, `*.rustfs` and `*.coder` second-level wildcards with a single Let's Encrypt certificate (cert-manager's Gateway shim, DNS-01), and a TCP listener on port 22 carries Forgejo's git SSH. Components attach HTTPRoutes (and Forgejo its TCPRoute) to it from their own namespaces; the Gateway-level CrowdSec extAuth policy covers every route, and route-level gateway-OIDC policies merge with it (`mergeType: StrategicMerge`). The `envoy-merged` GatewayClass keeps `mergeGateways: true` (`apps/envoy-gateway/2_envoy_proxy.yaml`).

## Why Envoy runs as a DaemonSet

- **The VIP lives on one node.** Cilium answers ARP for `192.168.8.50` from a single node at a time, the holder of the `cilium-l2announce-envoy-gateway-*` lease ([docs/cilium.md](cilium.md)). All Gateway traffic enters the cluster on that node.
- **Cilium picks that node without looking at Envoy.** L2 announcements ignore `externalTrafficPolicy`, so the lease can land on any node, whether or not it runs an Envoy pod.
- **`externalTrafficPolicy: Local` keeps client IPs.** Without SNAT, Envoy sees the real client address, so CrowdSec decisions and the `X-Envoy-External-Address` header (Vaultwarden's `IP_HEADER`) carry the actual client. The catch is that `Local` only delivers to an Envoy pod on the receiving node; with none there, traffic to the VIP is dropped.
- **A DaemonSet satisfies both.** An Envoy pod on every node means whichever node holds the lease, including after a failover, has a local Envoy to serve the VIP.

A Deployment would only work with `externalTrafficPolicy: Cluster`, which forwards to Envoy on another node and replaces every client address with a node IP.

The announcement policy never picks the Ryzen node (it runs the agents VM, whose traffic to the VIP must leave through the LAN), so the VIP fails over between the other two nodes; Envoy still runs on the Ryzen like on every node ([docs/cilium.md](cilium.md#cluster-specific-settings)).
