# Bootstrap cluster (single node)

## Bootstrap
Workstation requirements: `talosctl`, `kubectl`, `helm`, and `git`.
1. Download ISO from [factory](https://factory.talos.dev/) and boot node.
   - Extensions:
      - siderolabs/gvisor
      - siderolabs/netbird
      - siderolabs/iscsi-tools
      - siderolabs/util-linux-tools
2. Set static DHCP for node in router
3. Unplug Talos USB drive (it's running in RAM)
4. In workstation:
```bash
# Set control plane IP
export CONTROL_PLANE_IPS=<control-plane-ip>

# View available disks
talosctl get disks --insecure --nodes $CONTROL_PLANE_IPS

# Set cluster and disk env vars
export CLUSTER_NAME=<cluster_name>
export DISK_NAME=<control_plane_disk_name>

# Generate secrets bundle
# Backup the generate file: secrets.yaml
talosctl gen secrets -o secrets.yaml

# Create Talos config patch
cat >/tmp/cilium-talos-prereqs.yaml <<'EOF'
# No Flannel; Cilium is applied as a manifest
apiVersion: v1alpha1
kind: KubeFlannelCNIConfig
$patch: delete
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
# Enable workloads on the control plane node
apiVersion: v1alpha1
kind: KubeNodeConfig
taints:
  node-role.kubernetes.io/control-plane:
    $patch: delete
labels:
  node.kubernetes.io/exclude-from-external-load-balancers:
    $patch: delete
EOF

# Generate configuration file
# Backup the generated files: controlplane.yaml, worker.yaml, talosconfig
talosctl gen config --with-secrets secrets.yaml $CLUSTER_NAME https://$CONTROL_PLANE_IPS:6443 --install-disk /dev/$DISK_NAME --config-patch-control-plane @/tmp/cilium-talos-prereqs.yaml

# Apply the control plane configuration
talosctl apply-config --insecure --nodes $CONTROL_PLANE_IPS --file controlplane.yaml

# Merge talosconfig into the default configuration
talosctl config merge ./talosconfig

# Set correct context
talosctl config context "$CLUSTER_NAME"

# Set endpoints
talosctl config endpoints $CONTROL_PLANE_IPS

# Set default node
talosctl config nodes "$CONTROL_PLANE_IPS"

# Wait till node comes up
until talosctl version >/dev/null 2>&1; do
  echo "waiting for $CONTROL_PLANE_IPS ..."
  sleep 5
done
echo "node is up"

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

# Bootstrap etcd cluster
# Pauses at 18/19 until Cilium runs; keep backgrounded
talosctl bootstrap &
BOOTSTRAP_PID=$!

# Download kubeconfig once the API server is up
until talosctl kubeconfig 2>/dev/null; do
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

# Install Cilium; the node turns Ready
kubectl apply -f /tmp/cilium-namespace.yaml
kubectl apply -f /tmp/cilium.yaml
kubectl -n cilium rollout status daemonset/cilium

# Wait for the paused bootstrap to finish
wait $BOOTSTRAP_PID

# Check if node is healthy
talosctl health

# Verify node registration
kubectl get nodes
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

# Reboot the nodes so both machine config patches take effect
for ip in "${CONTROL_PLANE_IPS[@]}"; do
  echo "Rebooting node: $ip"
  talosctl reboot --nodes "$ip"
done
```

The Longhorn values pin `defaultSettings.defaultDataPath: /var/mnt/longhorn-1`, so
the first Longhorn disk is wired declaratively. The second disk
(`/var/mnt/longhorn-2`) is added to the node through the Longhorn node CR once
the cluster is up — node names are host-specific and cannot live in git — for
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
- [Deploy Cilium on Talos](https://docs.siderolabs.com/kubernetes-guides/cni/deploying-cilium)
- [Enable workloads on your control plane nodes](https://docs.siderolabs.com/talos/v1.14/deploy-and-manage-workloads/workloads-on-controlplane)
- [Deploy the Metrics Server](https://docs.siderolabs.com/kubernetes-guides/monitoring-and-observability/deploy-metrics-server)
- [WireGuard](https://docs.siderolabs.com/talos/v1.14/networking/advanced/wireguard)
- [Longhorn](https://docs.siderolabs.com/kubernetes-guides/csi/longhorn#v1-data-engine)
- [Longhorn - Talos support](https://longhorn.io/docs/1.12.1/advanced-resources/os-distro-specific/talos-linux-support/)