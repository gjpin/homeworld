# Bootstrap cluster (three k3s servers)

The cluster runs three [k3s](https://docs.k3s.io/) servers with embedded etcd
on Fedora Server ([docs/fedora.md](fedora.md)); every server also schedules
workloads (no dedicated agents). Three etcd members keep quorum through the
loss of any one node.

| Address | Role |
| --- | --- |
| `192.168.8.10`–`.12` | Node static DHCP leases (Ryzen, CoreBox, Radxa) |
| `192.168.8.51` | Kubernetes API VIP: [kube-vip](https://kube-vip.io/) static pod in ARP mode on every server, leader-elected; joining servers register through it |
| `192.168.8.50` | Gateway VIP: announced by Cilium L2 announcements from every node except the Ryzen ([docs/cilium.md](cilium.md)) |
| `10.42.0.0/16`, `10.43.0.0/16` | Pod and Service CIDRs (k3s defaults; Cilium cluster-pool IPAM) |
| `10.20.0.0/24` | Agents VM subnet, routed through the Ryzen ([docs/agents-vm.md](agents-vm.md)) |

In-cluster clients reach the API through the `kubernetes` Service. Cilium
itself talks to the local API server on `127.0.0.1:6444`, which on a k3s
server is kube-apiserver (`:6443` is the k3s supervisor in front of it).

## Host configuration in git

Everything on the hosts comes from the `host/` tree:

| Path | Purpose |
| --- | --- |
| `host/bootstrap.sh <profile>` | One-time node bootstrap, run by hand (below) |
| `host/disks.sh` | Interactive choice of the data disks for Longhorn and the agents VM, run by bootstrap.sh or by hand ([docs/fedora.md](fedora.md#data-disks)) |
| `host/apply.sh` | Idempotent converger, run hourly by `homeworld-pull.timer` |
| `host/cluster.env` | Cluster coordinates (literal values, as everywhere in git) |
| `host/versions.env` | Fedora release, the k3s version bootstrap installs, gVisor, kube-vip, helm |
| `host/nodes/<profile>.env` | Per-hardware profile: expected arch/CPU/RAM, agents VM flag, kubelet `system-reserved`, Longhorn reserve |
| `host/files/` | k3s config template, PSA defaults, containerd gVisor handler and device ownership, kube-vip static pod, firewalld, sysctls, kernel modules, dnf5-automatic, kured helpers, systemd units |
| `host/agents-vm/` | The agents VM on the Ryzen ([docs/agents-vm.md](agents-vm.md)) |

`homeworld-pull.timer` downloads the public `main` branch over HTTPS every
hour (randomized by up to 20 minutes per node) and runs its `host/apply.sh`.
The script changes only what differs: packages, firewalld zones and
policies, sshd (key-only, listening on the node address), gVisor
(sha512-verified), the containerd drop-ins, the k3s configuration, the kube-vip manifest, the
dnf5-automatic and kured helpers, the Longhorn disk annotation, and the
agents subnet route. Files k3s or containerd read only at start are written
but not reloaded: apply.sh leaves `/var/lib/homeworld/reboot-required`, and
kured reboots the node in its window ([docs/fedora.md](fedora.md)). Node
addresses and the cluster domain never live in git: bootstrap.sh records them
in `/etc/homeworld/env`.

apply.sh never changes the k3s version. bootstrap.sh installs
`K3S_VERSION`, and from then on the system-upgrade-controller Plans in
`apps/system-upgrade-controller` own every upgrade
([docs/upgrades.md](upgrades.md)).

### k3s configuration

`host/files/k3s/config.yaml.in` (rendered to `/etc/rancher/k3s/config.yaml`)
is identical on every server apart from the node address and profile label:

- `selinux: true`, `secrets-encryption: true`, `protect-kernel-defaults: true`
  (the matching sysctls are written before k3s first starts);
- no flannel, no kube-proxy and no k3s network policy controller: Cilium
  replaces all three;
- the packaged Traefik, ServiceLB, local-path storage and metrics-server are
  disabled (the repo ships its own), and so are the packaged `runtimes`
  RuntimeClasses; the `gvisor` RuntimeClass comes from
  `host/files/manifests/homeworld-runtimeclasses.yaml`;
- kubelet `rotate-server-certificates` (approved by
  kubelet-serving-cert-approver, so metrics-server scrapes kubelets over
  verified TLS) and `system-reserved` memory from the profile;
- kube-scheduler and kube-controller-manager bind on all addresses and etcd
  exposes its metrics listener on `2381`, for the `apps/kube-control-plane`
  ScrapeConfigs;
- a Pod Security Admission configuration (`host/files/k3s/psa.yaml`):
  enforce baseline and audit/warn restricted for namespaces without labels,
  with `kube-system` exempt (kube-vip and the k3s-managed CoreDNS);
- an authentication configuration (`host/files/k3s/authentication.yaml.in`)
  that trusts ID tokens Authelia issues to the `headlamp` client, mapping
  `preferred_username` and `groups` with an `oidc:` prefix, and keeps anonymous
  requests off, which k3s leaves to this file once it exists. The API server
  fetches the issuer's discovery document and keys through the
  `envoy-node-access` ClusterIP (`GATEWAY_CLUSTER_IP`), which `apply.sh` maps to
  `auth.<domain>` in `/etc/hosts`: a node cannot use the Gateway VIP, because the
  one announcing it gets no ARP answer and Cilium's socket load balancer skips
  external IPs that are not local to the host. Pods get the same address through
  CoreDNS ([network-policies.md](network-policies.md#how-policy-matches)). It retries in the background, so it starts without Authelia and
  only rejects these tokens until Authelia is up; the k3s admin kubeconfig
  works regardless. It reloads the file while running, so changes need no
  reboot.

The node label `node.homeworld/profile=<profile>` selects the
Ryzen for the Gateway VIP exclusion and its Cilium node configuration, and
corebox, the only node with an Intel GPU, for the Intel GPU device plugin.

The Gateway API CRDs come from k3s's bundled `gateway-api-crd` addon
(standard channel), which k3s re-applies on every start and moves with every
k3s release; Envoy Gateway's chart copy is patched out of its render.

## Bootstrap

Prerequisites:

1. The router serves the static leases, reserves both VIPs and runs Tang
   ([docs/openwrt.md](openwrt.md)); the NAS exports are in place
   ([docs/nas.md](nas.md)).
2. Every node runs a fresh Fedora Server install with an encrypted root and
   an admin user whose `~/.ssh/authorized_keys` holds your key
   ([docs/fedora.md](fedora.md)). Set each node's hostname in the installer:
   it becomes the Kubernetes node name.
3. The Infisical secrets exist (README step 5), including the cluster
   domain (`/argocd/BASE_DOMAIN`), the External Secrets Universal Auth
   identity and, for the Ryzen, the read-only
   `/agents/*` identity ([docs/secrets.md](secrets.md)).

### First server

On any one node (as the admin user, from a checkout of this repository):

```bash
sudo dnf -y install git
git clone https://github.com/gjpin/homeworld.git
cd homeworld
sudo host/bootstrap.sh <ryzen|corebox|radxa>
```

The script checks the profile against the hardware and asks for:

- this node's address, all three node addresses, and the Ryzen's address
  (the agents VM host);
- the role: `init` on the first server;
- the cluster domain (`/argocd/BASE_DOMAIN`), which the API server's
  authentication configuration needs from the first start;
- on the Ryzen only: the agents VM's Infisical client ID, client secret and
  project ID, and the SSH public keys for the VM's `agent` user;
- the LUKS passphrase of the root device, to bind it to Tang (compare the key
  thumbprint it prints with the router's first);
- the data disks for Longhorn and the agents VM, and a recovery passphrase for
  any it encrypts ([docs/fedora.md](fedora.md#data-disks));
- the External Secrets Operator's Infisical Universal Auth client ID and
  secret, with which it reads the cluster domain from Infisical and checks it
  against the one you entered.

It prints the cluster token (also in `/etc/rancher/k3s/token`), grows the
root LV, binds Clevis, sets up the chosen data disks, runs apply.sh, installs the pinned k3s and starts it.
On the first server it then renders the Cilium CRDs (from the tag in
`apps/cilium/0_crds.yaml`), the Cilium release (`apps/cilium/helm`), a
minimal Argo CD (the chart pinned in `apps/argocd/helm` with
`bootstrap/argocd-values.yaml` plus the homeworld plugin from
`apps/argocd/helm/values.yaml`, [argocd.md](argocd.md#homeworld-plugin)),
the `homeworld-domain` Secret the plugin renders with, the root
`apps/app-of-apps.yaml`, and the `external-secrets` namespace with the
`universal-auth-credentials` Secret,
and drops them into the k3s auto-deploying manifests directory
(`/var/lib/rancher/k3s/server/manifests`). k3s applies every known kind and
retries the rest (the Cilium ServiceMonitors wait for their CRDs), so the
CNI comes up and the node turns Ready. Argo CD then adopts Cilium and its own
release from git.

Once Argo CD reports `cilium` and `argocd` Synced and Healthy, the script
removes the one-shot files and their k3s `Addon` objects (k3s re-applies
files still present at every start; removing them never deletes the
resources) and the bootstrap-only Argo CD Redis objects that `apps/argocd`
replaces with Valkey. The credentials file is removed as soon as k3s has
applied it. Only `homeworld-runtimeclasses.yaml` stays.

### Other servers

On each remaining node, run the same command with role `join` and the
cluster token from the first server. The node registers through the API VIP
(`https://192.168.8.51:6443`) and joins etcd.

### Check

```bash
sudo k3s kubectl get nodes -o wide
sudo k3s kubectl -n argocd get applications
```

For a workstation kubeconfig, copy `/etc/rancher/k3s/k3s.yaml` from any
server and replace its `server:` URL with `https://192.168.8.51:6443` (the
VIP is in the API server certificate's SANs).

## Longhorn

Longhorn keeps its data on the disks chosen with `host/disks.sh`
([docs/fedora.md](fedora.md#data-disks)), or without any in `/var/lib/longhorn`
on the node's encrypted root filesystem (bootstrap.sh grows the root LV to the
whole volume group). The `node.longhorn.io/create-default-disk=config` node label
and the `node.longhorn.io/default-disks-config` annotation, which apply.sh sets,
create those disks. On root, the profile's `LONGHORN_RESERVED_GIB` sets the
per-node reserve: on the Ryzen it also covers the agents VM disks unless they
have a data disk. A disk of its own gets a token 1 GiB, because Longhorn takes a
reserve of 0 as unset and holds back 30%.

Longhorn reads the annotation only for a node with no disks yet. To add a data
disk to a node that already has one, run disks.sh, then add the path it prints to
`spec.disks` of the node's `nodes.longhorn.io` resource.

## etcd snapshots

k3s snapshots etcd to `/var/lib/rancher/k3s/server/db/snapshots` on every
server (its defaults: every 12 hours, five kept). Restoring follows
https://docs.k3s.io/datastore/backup-restore.

## Rebuilding a node

Delete the node object (`kubectl delete node <name>`; k3s removes its etcd
member), reinstall Fedora, and run bootstrap.sh with role `join`. The
other two servers keep quorum meanwhile.

## References

- [k3s: High Availability Embedded etcd](https://docs.k3s.io/datastore/ha-embedded)
- [k3s: Auto-Deploying Manifests](https://docs.k3s.io/installation/packaged-components)
- [k3s: SELinux support](https://docs.k3s.io/advanced#selinux-support)
- [k3s: CIS hardening guide](https://docs.k3s.io/security/hardening-guide)
- [Cilium: k3s installation](https://docs.cilium.io/en/stable/installation/k3s/)
- [kube-vip: static pods](https://kube-vip.io/docs/installation/static/)
