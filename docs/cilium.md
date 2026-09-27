# Cilium

The cluster runs Cilium as its CNI in kube-proxy-replacement mode. This page records the [Sidero prerequisites](https://docs.siderolabs.com/kubernetes-guides/cni/deploying-cilium#prerequisites) and where each is implemented, plus [known issues](https://docs.siderolabs.com/kubernetes-guides/cni/deploying-cilium#known-issues) and their resolutions. The step-by-step bootstrap commands live in [docs/talos.md](talos.md); the `cilium` Argo CD application (`apps/cilium`) owns the release from the first sync on.

## Prerequisites

| Prerequisite | Implementation |
| --- | --- |
| Machine config: CNI set to `none` (Helm/Cilium CLI methods) | `KubeFlannelCNIConfig` deleted in `/tmp/cilium-talos-prereqs.yaml`, applied via `--config-patch-control-plane` at `gen config` time ([docs/talos.md](talos.md)) |
| Machine config (kube-proxy-free): kube-proxy disabled | `KubeProxyConfig` with `enabled: false` in the same patch |
| IPAM mode must be `kubernetes` | `ipam.mode: kubernetes` in `apps/cilium/helm/values.yaml` |
| Talos already mounts cgroupv2 and bpffs; do not let Cilium remount them | `cgroup.autoMount.enabled: false` and `cgroup.hostRoot: /sys/fs/cgroup` in values |
| `SYS_MODULE` dropped from the capability set (Talos forbids workloads loading kernel modules) | `securityContext.capabilities` override in values (`ciliumAgent` and `cleanCiliumState` without `SYS_MODULE`/`SYSLOG`) |
| KubePrism enabled and configured on port 7445 | enabled on port 7445 by default (no `KubePrismConfig` patch needed); the chart targets `k8sServiceHost: localhost` / `k8sServicePort: "7445"` |

## Known issues

- **CoreDNS breaks together with `bpf.masquerade`**: Talos defaults `forwardKubeDNSToHost=true`, which forwards CoreDNS to the host resolver's link-local address; BPF masquerading makes that address unreachable from pod networks. `bpf.masquerade: true` stays enabled (values), and the `ResolverConfig` patch in the bootstrap sets `hostDNS.forwardKubeDNSToHost: false`.
- **`cilium connectivity test` fails with PodSecurity errors**: the CLI's test pods add `NET_RAW`, which PSS `baseline` forbids. The `cilium` namespace enforces `pod-security.kubernetes.io/enforce=privileged` (required by the privileged agents regardless), matching the documented workaround.
- **GCP internal load balancers**: not applicable to this bare-metal cluster.

## Operational notes

- Rebuilding a node requires re-running the bootstrap ([docs/talos.md](talos.md)); the machine configuration alone does not restore the CNI. This is the accepted trade-off of the manifest-apply bootstrap in exchange for a single owner (Argo CD) and no machine-config embedded render to keep fresh.
- Upgrades are git-driven from the first Argo CD sync on: Renovate opens one version-aligned PR bumping both the Helm chart and the CRD tag, and the `cilium` Argo CD application rolls them out.
