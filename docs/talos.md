# Bootstrap cluster (three control planes)

> [!NOTE]
> This guide uses a Layer 2 VIP as the Kubernetes API endpoint. To use a DNS
> name with one A record per control plane instead, ask an AI agent to adapt
> this guide first. The change touches the `gen config` endpoint, removes the
> `Layer2VIPConfig` per-node patch and the VIP router reservation, and must be
> decided before bootstrap: the endpoint is baked into every machine config
> and kubeconfig.

The cluster runs three control plane nodes that also schedule workloads (no
dedicated workers). Three etcd members keep quorum through the loss of any one
node. The Kubernetes API endpoint is a Talos-managed Layer 2 virtual IP shared
by the control planes; in-cluster clients (including Cilium) reach the API
servers through KubePrism (`localhost:7445`), which load-balances across all
three and keeps working when the VIP is moving.

## Bootstrap
Workstation requirements: `talosctl`, `kubectl`, `helm`, `yq`, and `git`.
1. Each hardware platform has its own [Image Factory](https://factory.talos.dev/)
   schematic: download the node's ISO from its schematic and boot it. The
   installer image comes from the same schematic (set per node below), or the
   extensions are missing after installation. Every schematic carries the
   shared extensions — `siderolabs/gvisor`, `siderolabs/iscsi-tools`, and
   `siderolabs/util-linux-tools` — plus the
   platform's CPU microcode and GPU driver. No workload uses the GPUs; the
   drivers let them enter their low-power idle states instead of staying
   unmanaged at firmware defaults.

   | Hardware | Arch | Platform extensions | Schematic ID |
   | --- | --- | --- | --- |
   | Desktop: AMD Ryzen 7 3700X, AMD Radeon RX 560 | `amd64` | `siderolabs/amd-ucode`, `siderolabs/amdgpu` | [`a74fbde82970b8887ebc715a94b4d5566e3ca76a11babc1b7ccfaeaa75c54732`](https://factory.talos.dev/?arch=amd64&platform=metal&schematic-id=a74fbde82970b8887ebc715a94b4d5566e3ca76a11babc1b7ccfaeaa75c54732&target=metal&version=1.14.2) |
   | Chuwi CoreBox: Intel Core i3 (12th gen) | `amd64` | `siderolabs/intel-ucode`, `siderolabs/i915` | [`a731ab59386273e96cc78a9823e953dd6753f263dc026724cf6175304720742b`](https://factory.talos.dev/?arch=amd64&platform=metal&schematic-id=a731ab59386273e96cc78a9823e953dd6753f263dc026724cf6175304720742b&target=metal&version=1.14.2) |
   | Radxa Dragon Q8B: Qualcomm SC8280XP | `arm64` | — | — (unsupported, see below) |

   Each schematic ID links to its Image Factory page (ISO and installer
   downloads) for the current Talos release; Renovate keeps the `version`
   in these links on the latest Talos release. The ISO is also available
   directly at
   `https://factory.talos.dev/image/<schematic-id>/<talos-version>/metal-<arch>.iso`.
   To review or rebuild a schematic, `curl
   https://factory.talos.dev/schematics/<schematic-id>` prints its
   definition, and `curl -X POST --data-binary @schematic.yaml
   https://factory.talos.dev/schematics` returns the ID of an edited one.

   > [!WARNING]
   > Talos cannot run on the Radxa Dragon Q8B yet. The Image Factory has no
   > overlay for the board, and the generic `arm64` Talos kernel is built
   > without the SC8280XP clock controller, pin controller, and PCIe/USB PHY
   > drivers (`CONFIG_SC_GCC_8280XP`, `CONFIG_PINCTRL_SC8280XP`,
   > `CONFIG_PHY_QCOM_QMP`), so its storage and network never come up. The
   > Radxa UEFI "Third-party OS Compatibility Settings" used for Debian only
   > adjust the firmware-provided hardware description; Debian boots because
   > its own kernel builds these drivers, which the Talos kernel does not.
2. In the router, set a static DHCP lease for each node and reserve one
   additional unused address in the same subnet for the Kubernetes API VIP.
   The VIP must not be assignable by the DHCP server.
3. Unplug the Talos USB drives (Talos is running in RAM)
4. In workstation, from a `bash` shell (the loops use bash array indexing;
   keep the same shell for the WireGuard and Longhorn steps below):
```bash
# Control plane nodes, in the same order in every array below.
# The first node is the etcd bootstrap node.
CONTROL_PLANE_IPS=(<cp-1-ip> <cp-2-ip> <cp-3-ip>)
CONTROL_PLANE_NAMES=(cp-1 cp-2 cp-3)

# Shared Kubernetes API VIP and the node subnet (CIDR) it lives in
export CONTROL_PLANE_VIP=<vip>
export NODE_SUBNET=<node-subnet-cidr>

# View the install disks and network links of every node (maintenance mode)
for ip in "${CONTROL_PLANE_IPS[@]}"; do
  echo "== $ip"
  talosctl get disks --insecure --nodes "$ip"
  talosctl get links --insecure --nodes "$ip"
done

# Per-node install disk serial and VIP link name, same order as above.
# Prefer stable disk properties (serial/wwid) over /dev/sd* or /dev/nvme* names.
DISK_SERIALS=(<cp-1-disk-serial> <cp-2-disk-serial> <cp-3-disk-serial>)
LINKS=(<cp-1-link> <cp-2-link> <cp-3-link>)

# Per-node Image Factory schematic ID (table in step 1), matching each
# node's hardware, same order as above
SCHEMATIC_IDS=(<cp-1-schematic-id> <cp-2-schematic-id> <cp-3-schematic-id>)

# Set cluster env vars
export CLUSTER_NAME=<cluster_name>
export TALOS_VERSION=<talos-version>

# Generate secrets bundle
# Backup the generate file: secrets.yaml
talosctl gen secrets -o secrets.yaml

# Create Talos config patch shared by all control planes
cat >/tmp/cilium-talos-prereqs.yaml <<EOF
# No Flannel; Cilium is applied as a manifest
apiVersion: v1alpha1
kind: KubeFlannelCNIConfig
\$patch: delete
---
# No kube-proxy; Cilium replaces it
apiVersion: v1alpha1
kind: KubeProxyConfig
enabled: false
---
# Required by bpf.masquerade (docs/cilium.md)
apiVersion: v1alpha1
kind: ResolverConfig
hostDNS:
  enabled: true
  forwardKubeDNSToHost: false
---
# Kubelet serving certificates include the node IP
apiVersion: v1alpha1
kind: KubeletConfig
extraArgs:
  rotate-server-certificates: true
---
# Enable workloads on the control plane nodes, and pin the kubelet node IP
# to the node subnet (the Cilium WireGuard interface carries other
# addresses)
apiVersion: v1alpha1
kind: KubeNodeConfig
nodeIP:
  validSubnets:
    - ${NODE_SUBNET}
taints:
  node-role.kubernetes.io/control-plane:
    \$patch: delete
labels:
  node.kubernetes.io/exclude-from-external-load-balancers:
    \$patch: delete
---
# Serve kube-scheduler and kube-controller-manager metrics on the node
# addresses (default 127.0.0.1) for the apps/kube-control-plane
# ServiceMonitors; /metrics still requires an authorized bearer token
apiVersion: v1alpha1
kind: KubeSchedulerConfig
extraArgs:
  bind-address: 0.0.0.0
---
apiVersion: v1alpha1
kind: KubeControllerManagerConfig
extraArgs:
  bind-address: 0.0.0.0
---
# etcd peers advertise only node subnet addresses; the plain-HTTP metrics
# listener (no client certificate) feeds the apps/kube-control-plane etcd
# ScrapeConfig
cluster:
  etcd:
    advertisedSubnets:
      - ${NODE_SUBNET}
    extraArgs:
      listen-metrics-urls: http://0.0.0.0:2381
EOF

# Create the per-node patches: hostname, installer image from the node's own
# schematic, install disk, and the shared VIP announced on the node's LAN link
for i in "${!CONTROL_PLANE_IPS[@]}"; do
cat >"/tmp/${CONTROL_PLANE_NAMES[$i]}.yaml" <<EOF
apiVersion: v1alpha1
kind: HostnameConfig
hostname: ${CONTROL_PLANE_NAMES[$i]}
auto:
  \$patch: delete
---
apiVersion: v1alpha1
kind: UnattendedInstallConfig
installer:
  image: factory.talos.dev/metal-installer/${SCHEMATIC_IDS[$i]}:${TALOS_VERSION}
provisioning:
  diskSelector:
    match: disk.serial == "${DISK_SERIALS[$i]}"
---
apiVersion: v1alpha1
kind: Layer2VIPConfig
name: ${CONTROL_PLANE_VIP}
link: ${LINKS[$i]}
EOF
done

# Generate configuration file
# Backup the generated files: controlplane.yaml, talosconfig, and the
# per-node patches (/tmp/cp-*.yaml)
talosctl gen config --with-secrets secrets.yaml $CLUSTER_NAME https://$CONTROL_PLANE_VIP:6443 \
  --config-patch-control-plane @/tmp/cilium-talos-prereqs.yaml \
  --output-types controlplane,talosconfig

# Validate the rendered per-node configurations
for name in "${CONTROL_PLANE_NAMES[@]}"; do
  talosctl machineconfig patch controlplane.yaml --patch "@/tmp/$name.yaml" |
    talosctl validate --mode metal --strict --config /dev/stdin
done

# Apply the control plane configuration to every node
for i in "${!CONTROL_PLANE_IPS[@]}"; do
  talosctl apply-config --insecure --nodes "${CONTROL_PLANE_IPS[$i]}" \
    --file controlplane.yaml --config-patch "@/tmp/${CONTROL_PLANE_NAMES[$i]}.yaml"
done

# Merge talosconfig into the default configuration
talosctl config merge ./talosconfig

# Set correct context
talosctl config context "$CLUSTER_NAME"

# Set endpoints to every control plane node, never the VIP: the VIP depends
# on etcd and kube-apiserver health, and the Talos API must stay reachable
# for recovery when they are down
talosctl config endpoints "${CONTROL_PLANE_IPS[@]}"

# Set default node to the bootstrap node
export BOOTSTRAP_NODE="${CONTROL_PLANE_IPS[0]}"
talosctl config nodes "$BOOTSTRAP_NODE"

# Wait till every node comes up
for ip in "${CONTROL_PLANE_IPS[@]}"; do
  until talosctl version --nodes "$ip" >/dev/null 2>&1; do
    echo "waiting for $ip ..."
    sleep 5
  done
  echo "$ip is up"
done

# Prepare Cilium; no cluster access needed yet
# Upstream Cilium source: CRDs only (chart ships none). The tag always
# matches the Cilium chart pinned in apps/cilium/helm/kustomization.yaml.
git clone https://github.com/gjpin/homeworld.git /tmp/homeworld
git clone --depth 1 --branch "$(yq '.helmCharts[0].version' /tmp/homeworld/apps/cilium/helm/kustomization.yaml)" https://github.com/cilium/cilium.git /tmp/cilium-src

# Render the release Argo CD will adopt
kubectl kustomize --enable-helm /tmp/homeworld/apps/cilium/helm > /tmp/cilium.yaml

# Helm renders no release namespace
cat > /tmp/cilium-namespace.yaml <<'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: cilium
  labels:
    pod-security.kubernetes.io/enforce: privileged
    pod-security.kubernetes.io/enforce-version: v1.37
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/audit-version: v1.37
    pod-security.kubernetes.io/warn: restricted
    pod-security.kubernetes.io/warn-version: v1.37
  annotations:
    security.homeworld/exception-reason: Cilium kube-proxy replacement requires privileged agents with BPF, bpffs, hostPath, and host network integration; PSS baseline forbids these host integrations.
EOF

# Bootstrap etcd cluster: run ONCE, on the bootstrap node only. The other
# control planes join etcd on their own.
# Pauses at 18/19 until Cilium runs; keep backgrounded
talosctl bootstrap --nodes "$BOOTSTRAP_NODE" &
BOOTSTRAP_PID=$!

# Download kubeconfig once the API server is up; it targets the VIP, which
# comes up after etcd is bootstrapped
until talosctl kubeconfig --nodes "$BOOTSTRAP_NODE" 2>/dev/null; do
  echo "waiting for the API server ..."
  sleep 5
done

# Create the gVisor RuntimeClass used by sandboxed workloads
cat <<'EOF' | kubectl apply -f -
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: gvisor
handler: runsc
EOF

# Install Cilium CRDs server-side; annotations too large
kubectl apply --server-side --force-conflicts -f /tmp/cilium-src/pkg/k8s/apis/cilium.io/client/crds/v2/

# Install Cilium; the nodes turn Ready
kubectl apply -f /tmp/cilium-namespace.yaml
kubectl apply -f /tmp/cilium.yaml
kubectl -n cilium rollout status daemonset/cilium

# Wait for the paused bootstrap to finish
wait $BOOTSTRAP_PID

# Check if the cluster is healthy (all three nodes, etcd members, and
# control plane components)
talosctl health --nodes "$BOOTSTRAP_NODE"

# Verify etcd membership and node registration
talosctl etcd members --nodes "$BOOTSTRAP_NODE"
kubectl get nodes -o wide
```

## Seed External Secrets Infisical credentials
The External Secrets Operator authenticates to Infisical with Universal Auth credentials. Generate a Machine Identity in the
Infisical console (**Settings → Machine Identity → Universal Auth**) and create
its client ID/secret:

```bash
# The namespace mirrors the labels Argo CD would manage on creation
# (apps/app-of-apps.yaml, external-secrets-app) because Argo only applies
# managedNamespaceMetadata when it creates the namespace itself.
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: external-secrets
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: v1.37
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/audit-version: v1.37
    pod-security.kubernetes.io/warn: restricted
    pod-security.kubernetes.io/warn-version: v1.37
EOF

kubectl create secret generic universal-auth-credentials \
  --namespace external-secrets \
  --from-literal=clientId='<infisical-client-id>' \
  --from-literal=clientSecret='<infisical-client-secret>'
```

## Configure WireGuard
Cilium's WireGuard encryption (`encryption.type: wireguard` in
apps/cilium/helm/values.yaml) expects every node to carry a WireGuard key.
Key material is node-local secret material and stays out of this git tree:

1. Generate a keypair per node:
   `wg genkey | tee privatekey | wg pubkey > publickey`.
2. Distribute the private keys through the Talos machine config following
   https://docs.siderolabs.com/talos/v1.14/networking/advanced/wireguard
   (keys are injected per node, never committed here).
3. Cilium discovers peer public keys from the cluster automatically once
   each node's key exists (node-to-node encryption; see
   https://docs.cilium.io/en/stable/security/network/encryption-wireguard/).

Generated keys must never land in this repository or in Infisical project
secrets: they are per-node machine config values.

## Longhorn
```bash
# Inspect available disks
talosctl get disks

# Create the UserVolumeConfig (example for 2 disks)
# Adapt selector based on output of the previous step
cat >/tmp/longhorn-user-disks.yaml <<'EOF'
apiVersion: v1alpha1
kind: UserVolumeConfig
name: longhorn-1
provisioning:
  diskSelector:
    match: '!system_disk'
  grow: true
---
apiVersion: v1alpha1
kind: UserVolumeConfig
name: longhorn-2
provisioning:
  diskSelector:
    match: '!system_disk'
  grow: true
EOF

# Apply the UserVolumeConfig configuration to storage nodes
for ip in "${CONTROL_PLANE_IPS[@]}"; do
    echo "Applying patch to node: $ip"
    talosctl patch machineconfig --nodes "$ip" --patch @/tmp/longhorn-user-disks.yaml
done

# Expose paths to kubelet: Longhorn manager and engine pods mount the data
# directories through hostPath, which requires the kubelet extraMounts.
# The patch must be applied (and the node rebooted) BEFORE the longhorn
# Argo CD application first syncs.
cat >/tmp/longhorn-paths.yaml <<'EOF'
machine:
  kubelet:
    extraMounts:
      - destination: /var/mnt/longhorn-1
        type: bind
        source: /var/mnt/longhorn-1
        options: [bind, rshared, rw]
      - destination: /var/mnt/longhorn-2
        type: bind
        source: /var/mnt/longhorn-2
        options: [bind, rshared, rw]
EOF

# Apply the kubelet extraMounts patch to storage nodes
for ip in "${CONTROL_PLANE_IPS[@]}"; do
    echo "Applying kubelet extraMounts patch to node: $ip"
    talosctl patch machineconfig --nodes "$ip" --patch @/tmp/longhorn-paths.yaml
done

# Reboot the nodes one at a time so both machine config patches take effect.
# talosctl reboot waits for the node to come back, and the health check gates
# the next reboot, so etcd keeps quorum (two of three members) throughout.
for ip in "${CONTROL_PLANE_IPS[@]}"; do
  echo "Rebooting node: $ip"
  talosctl reboot --nodes "$ip"
  talosctl health --nodes "$ip"
done
```

The Longhorn values pin `defaultSettings.defaultDataPath: /var/mnt/longhorn-1`, so
the first Longhorn disk is wired declaratively. The second disk
(`/var/mnt/longhorn-2`) is added to the node through the Longhorn node CR once
the cluster is up — node names are host-specific and cannot live in git — on
every node (the Longhorn node name is the Talos hostname, e.g. `cp-1`), for
example:

```bash
kubectl -n longhorn-system patch node.longhorn.io <node-name> --type merge \
  -p '{"spec":{"disks":{"longhorn-2":{"path":"/var/mnt/longhorn-2","allowScheduling":true,"storageReserved":0,"tags":[],"diskType":"filesystem"}}}}'
```

The same one-time, host-specific step applies after re-provisioning a node (the
`nodes.longhorn.io` object is created by longhorn-manager with only the default
disk).

## References:
- [Getting Started](https://docs.siderolabs.com/talos/v1.14/getting-started/getting-started)
- [Production Clusters](https://docs.siderolabs.com/talos/v1.14/getting-started/prodnotes)
- [Virtual (shared) IP](https://docs.siderolabs.com/talos/v1.14/networking/advanced/vip)
- [Layer2VIPConfig](https://docs.siderolabs.com/talos/v1.14/reference/configuration/network/layer2vipconfig)
- [KubePrism](https://docs.siderolabs.com/talos/v1.14/configure-your-talos-cluster/system-configuration/kubeprism)
- [Multihoming](https://docs.siderolabs.com/talos/v1.14/networking/multihoming)
- [Unattended install](https://docs.siderolabs.com/talos/v1.14/configure-your-talos-cluster/lifecycle-management/unattended-install)
- [Deploy Cilium on Talos](https://docs.siderolabs.com/kubernetes-guides/cni/deploying-cilium)
- [Enable workloads on your control plane nodes](https://docs.siderolabs.com/talos/v1.14/deploy-and-manage-workloads/workloads-on-controlplane)
- [Deploy the Metrics Server](https://docs.siderolabs.com/kubernetes-guides/monitoring-and-observability/deploy-metrics-server)
- [WireGuard](https://docs.siderolabs.com/talos/v1.14/networking/advanced/wireguard)
- [Longhorn](https://docs.siderolabs.com/kubernetes-guides/csi/longhorn#v1-data-engine)
- [Longhorn - Talos support](https://longhorn.io/docs/1.12.1/advanced-resources/os-distro-specific/talos-linux-support/)