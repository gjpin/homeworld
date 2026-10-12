# Cilium

The cluster runs Cilium as its CNI in kube-proxy-replacement mode. This page records the [Sidero prerequisites](https://docs.siderolabs.com/kubernetes-guides/cni/deploying-cilium#prerequisites) and where each is implemented, plus [known issues](https://docs.siderolabs.com/kubernetes-guides/cni/deploying-cilium#known-issues) and their resolutions. The step-by-step bootstrap commands live in [docs/talos.md](talos.md); the `cilium` Argo CD application (`apps/cilium`) owns the release from the first sync on.

## Prerequisites

| Prerequisite | Implementation |
| --- | --- |
| Machine config: CNI set to `none` (Helm/Cilium CLI methods) | `KubeFlannelCNIConfig` deleted in `/tmp/cilium-talos-prereqs.yaml`, applied via `--config-patch-control-plane` at `gen config` time ([docs/talos.md](talos.md)) |
| Machine config (kube-proxy-free): kube-proxy disabled | `KubeProxyConfig` with `enabled: false` in the same patch |
| IPAM mode must be `kubernetes` | `ipam.mode: kubernetes` in `apps/cilium/helm/values.yaml` |
| Talos already mounts cgroupv2 and bpffs; do not let Cilium remount them | `cgroup.autoMount.enabled: false` with `cgroup.hostRoot: /sys/fs/cgroup`, and `bpf.autoMount.enabled: false`, in values (the latter also drops the privileged `mount-bpf-fs` init container from the agent DaemonSet) |
| `SYS_MODULE` dropped from the capability set (Talos forbids workloads loading kernel modules) | `securityContext.capabilities` override in values (`ciliumAgent` and `cleanCiliumState` without `SYS_MODULE`/`SYSLOG`) |
| KubePrism enabled and configured on port 7445 | enabled on port 7445 by default (no `KubePrismConfig` patch needed); the chart targets `k8sServiceHost: localhost` / `k8sServicePort: "7445"` |

## Known issues

- **CoreDNS breaks together with `bpf.masquerade`**: Talos defaults `forwardKubeDNSToHost=true`, which forwards CoreDNS to the host resolver's link-local address; BPF masquerading makes that address unreachable from pod networks. `bpf.masquerade: true` stays enabled (values), and the `ResolverConfig` patch in the bootstrap sets `hostDNS.forwardKubeDNSToHost: false`.
- **`cilium connectivity test` fails with PodSecurity errors**: the CLI's test pods add `NET_RAW`, which PSS `baseline` forbids. The `cilium` namespace enforces `pod-security.kubernetes.io/enforce=privileged` (required by the privileged agents regardless), matching the documented workaround.
- **GCP internal load balancers**: not applicable to this bare-metal cluster.

## Operational notes

- **Host firewall disabled:** the Cilium host firewall stays off. The host-network `cilium-agent`/`cilium-envoy`/`cilium-operator` pods are outside Cilium's policy scope either way, so node-level policy for them is accepted as absent (also recorded in [docs/network-policies.md](network-policies.md)); enabling the host firewall would require host-scoped policies for all node traffic without adding enforcement for these pods.
- **Gateway virtual IP:** every Gateway publishes the `192.168.8.50` Gateway VIP through `spec.addresses`, which Envoy Gateway renders as the Envoy Service's `spec.externalIPs`. The kube-proxy replacement load-balances that address, `l2announcements.enabled` in values lets Cilium answer ARP for it, and the `envoy-gateway` `CiliumL2AnnouncementPolicy` (`apps/cilium/2_l2_announcement_policy.yaml`) selects the Envoy Service. One node at a time holds the `cilium-l2announce-envoy-gateway-*` lease in the `cilium` namespace; failover takes 10–20 seconds with the default lease timings. L2 announcements ignore `externalTrafficPolicy`, so the Envoy data plane runs as a DaemonSet (`apps/envoy-gateway/2_envoy_proxy.yaml`, [docs/envoy-gateway.md](envoy-gateway.md)) and the announcing node always has a local Envoy pod for the Service's `externalTrafficPolicy: Local`.
- Rebuilding a node requires re-running the bootstrap ([docs/talos.md](talos.md)); the machine configuration alone does not restore the CNI. This is the accepted trade-off of the manifest-apply bootstrap in exchange for a single owner (Argo CD) and no machine-config embedded render to keep fresh.
- Upgrades are git-driven from the first Argo CD sync on: Renovate opens one version-aligned PR bumping both the Helm chart and the CRD tag, and the `cilium` Argo CD application rolls them out.
