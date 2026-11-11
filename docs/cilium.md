# Cilium

The cluster runs Cilium as its CNI in kube-proxy-replacement mode with WireGuard pod-to-pod encryption. This page records the [Cilium k3s installation](https://docs.cilium.io/en/stable/installation/k3s/) prerequisites and where each is implemented, plus the cluster-specific settings and their reasons. `host/bootstrap.sh` installs the first release ([docs/k3s.md](k3s.md)); the `cilium` Argo CD application (`apps/cilium`) owns it from the first sync on.

## Prerequisites

| Prerequisite | Implementation |
| --- | --- |
| k3s without flannel and without its network policy controller | `flannel-backend: none` and `disable-network-policy: true` in `host/files/k3s/config.yaml.in` |
| kube-proxy disabled (kube-proxy-free) | `disable-kube-proxy: true` in the same file; `kubeProxyReplacement: true` in `apps/cilium/helm/values.yaml` |
| Pod CIDR matching k3s's default | `ipam.mode: cluster-pool` with `clusterPoolIPv4PodCIDRList: 10.42.0.0/16` in values |
| API server reachable before the Service network exists | `k8sServiceHost: 127.0.0.1`, `k8sServicePort: "6444"`: on a k3s server, `127.0.0.1:6444` is the local kube-apiserver (`:6443` is the k3s supervisor in front of it); every node is a server |
| systemd already mounts cgroupv2 and bpffs; do not let Cilium remount them | `cgroup.autoMount.enabled: false` with `cgroup.hostRoot: /sys/fs/cgroup`, and `bpf.autoMount.enabled: false`, in values (the latter also drops the privileged `mount-bpf-fs` init container from the agent DaemonSet) |
| No module loading from containers | `SYS_MODULE` (and `SYSLOG`) dropped from `ciliumAgent` and `cleanCiliumState` in values; `host/files/modules/homeworld.conf` preloads WireGuard and the other modules the hosts need |
| Node firewall open for the datapath | firewalld `homeworld-nodes` zone: health `4240`, Hubble peers `4244`, WireGuard `51871/udp`, VXLAN `8472/udp`; `cilium_*` and `lxc*` interfaces and the Pod/Service CIDRs in the `trusted` zone ([docs/fedora.md](fedora.md#firewall)) |

Device auto-detection is left on: it selects each node's LAN NIC and never the agents VM bridge (`virbr-agents`) or its taps on homeworld-ryzen.

## Cluster-specific settings

- **Socket load balancing in the host namespace only** (`socketLB.hostNamespaceOnly: true`): gVisor pods keep their sockets in gVisor's own netstack, so Cilium's per-socket BPF hooks never see their `connect()` calls and ClusterIP Services would be unreachable from them. Pods use the per-packet load balancer instead; the host namespace keeps socket-level load balancing.
- **Kernel host routing on homeworld-ryzen** (`apps/cilium/helm/agents_vm_host_node_config.yaml`): a `CiliumNodeConfig` selected by the `node.homeworld/profile: homeworld-ryzen` label sets `enable-host-legacy-routing`. With eBPF host routing, a pod's packet to the agents VM is redirected straight onto `virbr-agents` without passing netfilter, so the host has no conntrack entry for the connection and firewalld's `ct state invalid drop` rule in its forward chain drops the VM's reply. Kernel routing sends the traffic through netfilter, where the VM firewall policies ([docs/agents-vm.md](agents-vm.md)) apply. The other nodes keep eBPF host routing.
- **Envoy reads the BPF maps**: `bpf.autoMount.enabled: false` also removes `/sys/fs/bpf` from the chart's Envoy DaemonSet, so `apps/cilium/helm/kustomization.yaml` adds it back. Without it Envoy cannot read the ipcache, every `serverNames` rule fails, and endpoint creation stalls waiting on Envoy.
- **Gateway VIP never on homeworld-ryzen**: the `envoy-gateway` `CiliumL2AnnouncementPolicy` excludes the `homeworld-ryzen` profile, so the VIP fails over between homeworld-corebox and homeworld-dragon only. Traffic from the agents VM to the VIP enters homeworld-ryzen on `virbr-agents`, which is not a Cilium device; announced elsewhere, that traffic leaves through the LAN like any client's. Envoy still runs on homeworld-ryzen.

## Known issues

- **`cilium connectivity test` fails with PodSecurity errors**: the CLI's test pods add `NET_RAW`, which PSS `baseline` forbids. The `cilium` namespace enforces `pod-security.kubernetes.io/enforce=privileged` (required by the privileged agents regardless), matching the documented workaround.

## Operational notes

- **Host firewall disabled:** the Cilium host firewall stays off (firewalld guards the hosts). The host-network `cilium-agent`/`cilium-envoy`/`cilium-operator` pods are outside Cilium's policy scope either way, so node-level policy for them is accepted as absent (also recorded in [docs/network-policies.md](network-policies.md)); enabling the host firewall would require host-scoped policies for all node traffic without adding enforcement for these pods.
- **Gateway virtual IP:** every Gateway publishes the `192.168.8.50` Gateway VIP through `spec.addresses`, which Envoy Gateway renders as the Envoy Service's `spec.externalIPs`. The kube-proxy replacement load-balances that address, `l2announcements.enabled` in values lets Cilium answer ARP for it, and the `envoy-gateway` `CiliumL2AnnouncementPolicy` (`apps/cilium/2_l2_announcement_policy.yaml`) selects the Envoy Service. One node at a time holds the `cilium-l2announce-envoy-gateway-*` lease in the `cilium` namespace; failover takes 10–20 seconds with the default lease timings. L2 announcements ignore `externalTrafficPolicy`, so the Envoy data plane runs as a DaemonSet (`apps/envoy-gateway/2_envoy_proxy.yaml`, [docs/envoy-gateway.md](envoy-gateway.md)) and the announcing node always has a local Envoy pod for the Service's `externalTrafficPolicy: Local`.
- **Kubernetes API VIP:** `192.168.8.51` is kube-vip's, not Cilium's ([docs/k3s.md](k3s.md)); Cilium does not depend on it.
- Rebuilding a node requires re-running the bootstrap ([docs/k3s.md](k3s.md#rebuilding-a-node)); joining servers get the CNI from the running DaemonSet.
- Upgrades are git-driven from the first Argo CD sync on: Renovate opens one version-aligned PR bumping both the Helm chart and the CRD tag, and the `cilium` Argo CD application rolls them out. Renovate opens one PR per minor (upstream only supports consecutive minors); run the pre-flight check and read the minor's upgrade notes before merging ([upgrades.md](upgrades.md#cilium-pre-flight-check)).
