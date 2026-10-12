# Envoy Gateway

Every Gateway merges into one Envoy data plane (`mergeGateways: true` in `apps/envoy-gateway/2_envoy_proxy.yaml`) behind the Gateway VIP `192.168.8.50`.

## Why Envoy runs as a DaemonSet

- **The VIP lives on one node.** Cilium answers ARP for `192.168.8.50` from a single node at a time, the holder of the `cilium-l2announce-envoy-gateway-*` lease ([docs/cilium.md](cilium.md)). All Gateway traffic enters the cluster on that node.
- **Cilium picks that node without looking at Envoy.** L2 announcements ignore `externalTrafficPolicy`, so the lease can land on any node, whether or not it runs an Envoy pod.
- **`externalTrafficPolicy: Local` keeps client IPs.** Without SNAT, Envoy sees the real client address, so CrowdSec decisions and the `X-Envoy-External-Address` header (Vaultwarden's `IP_HEADER`) carry the actual client. The catch is that `Local` only delivers to an Envoy pod on the receiving node; with none there, traffic to the VIP is dropped.
- **A DaemonSet satisfies both.** An Envoy pod on every node means whichever node holds the lease, including after a failover, has a local Envoy to serve the VIP.

A Deployment would only work with `externalTrafficPolicy: Cluster`, which forwards to Envoy on another node and replaces every client address with a node IP.
