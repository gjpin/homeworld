# Bootstrap cluster (single node)

## Bootstrap
1. Download ISO from [factory](https://factory.talos.dev/) and boot node.
   - Extensions:
      - siderolabs/gvisor
      - siderolabs/tailscale
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

# Generate configuration file
# Backup the generated files: controlplane.yaml, worker.yaml, talosconfig
talosctl gen config --with-secrets secrets.yaml $CLUSTER_NAME https://$CONTROL_PLANE_IPS:6443 --install-disk /dev/$DISK_NAME

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

# Bootstrap etcd cluster
talosctl bootstrap

# Download kubeconfig
talosctl kubeconfig

# Check if node is healthy
talosctl health

# Verify node registration
kubectl get nodes
```

## Create the gVisor RuntimeClass
1. Run in workstation:
```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: gvisor
handler: runsc
EOF
```

## Enable workloads on control plane
1. Run in workstation:
```bash
# Create patch to remove taints and labels
cat >/tmp/allow-workloads-on-cp.yaml <<'EOF'
apiVersion: v1alpha1
kind: KubeNodeConfig
taints:
  node-role.kubernetes.io/control-plane:
    $patch: delete
labels:
  node.kubernetes.io/exclude-from-external-load-balancers:
    $patch: delete
EOF

# Apply patch
talosctl patch machineconfig --patch @/tmp/allow-workloads-on-cp.yaml
```

## Configure WireGuard
1. Follow https://docs.siderolabs.com/talos/v1.14/networking/advanced/wireguard

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

# Reboot the nodes
for ip in "${CONTROL_PLANE_IPS[@]}"; do
  echo "Rebooting node: $ip"
  talosctl reboot --nodes "$ip"
done

# Expose paths to kubelet
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
```

## References:
- [Getting Started](https://docs.siderolabs.com/talos/v1.14/getting-started/getting-started)
- [Production Clusters](https://docs.siderolabs.com/talos/v1.14/getting-started/prodnotes)
- [Enable workloads on your control plane nodes](https://docs.siderolabs.com/talos/v1.14/deploy-and-manage-workloads/workloads-on-controlplane)
- [WireGuard](https://docs.siderolabs.com/talos/v1.14/networking/advanced/wireguard)
- [Longhorn](https://docs.siderolabs.com/kubernetes-guides/csi/longhorn#v1-data-engine)
- [Longhorn - Talos support](https://longhorn.io/docs/1.12.1/advanced-resources/os-distro-specific/talos-linux-support/)