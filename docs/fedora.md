# Fedora hosts

Every node runs Fedora Server with an encrypted root, SELinux enforcing and
firewalld, configured from git by `host/apply.sh` ([docs/k3s.md](k3s.md)).
The Fedora release is pinned in `host/versions.env` (`FEDORA_RELEASE`).

## Install

1. Download the Fedora Server installer for the node's architecture
   (`x86_64` for the Ryzen and the CoreBox, `aarch64` for the Radxa) and boot
   it.
2. In the installer:
   - **Installation Destination**: the node's single disk, automatic
     partitioning, **Encrypt my data**. The passphrase becomes the LUKS
     recovery slot: store it offline (below).
   - **Network & Host Name**: the hostname (`ryzen`, `corebox`, `radxa`);
     it becomes the Kubernetes node name. Leave the address on DHCP: the
     router's static lease pins it ([docs/openwrt.md](openwrt.md) section 17).
   - **User Creation**: an administrator (wheel) account. Leave root
     disabled.
3. After the first boot, copy your SSH key to the admin account
   (`ssh-copy-id`). bootstrap.sh refuses to run otherwise, because it turns
   off password and keyboard-interactive SSH logins and binds sshd to the
   node address.

Then run `host/bootstrap.sh <profile>` ([docs/k3s.md](k3s.md#bootstrap)).

### Root volume size

Fedora Server's automatic partitioning gives the root LV about 15 GiB and
leaves the rest of the volume group free. bootstrap.sh grows the root LV to
the whole volume group (`lvextend -r -l +100%FREE`) before anything else
lands on it: root holds `/var/lib/longhorn`, the container images and, on the
Ryzen, the agents VM disks. Longhorn's per-node reserve
(`LONGHORN_RESERVED_GIB` in `host/nodes/<profile>.env`) keeps that space
free for the OS and the VM.

## Disk encryption: LUKS, Clevis and Tang

The root filesystem is LUKS-encrypted. bootstrap.sh binds every LUKS device
to the Tang server on the router (`http://192.168.8.1:7500`, from
`host/cluster.env`) with Clevis and adds `rd.neednet=1` to the kernel
command line, so the initramfs fetches the network key and unlocks the disk
unattended while the node is on the home network. A disk removed from the
network (a stolen node, a disk sent for repair) does not unlock.

The installer passphrase stays as a second key slot. When Tang is
unreachable (router down, Tang keys lost), the boot waits for that
passphrase on the console.

Keep these offline, never only in Vaultwarden (it runs on this cluster):

| Item | How |
| --- | --- |
| Tang keys | Copy `/usr/share/tang/db` from the router ([docs/openwrt.md](openwrt.md) section 17) |
| Each node's LUKS recovery passphrase | The one entered in the installer |
| Each node's LUKS header | `sudo cryptsetup luksHeaderBackup <device> --header-backup-file <node>-luks-header.img` (`lsblk -o NAME,FSTYPE` shows the `crypto_LUKS` device) |

After replacing the router or restoring Tang keys from backup, check that
`clevis luks list -d <device>` still names `http://192.168.8.1:7500`. A new
Tang key pair needs a rebind: `clevis luks unbind -d <device> -s <slot>` and
run bootstrap.sh again (it binds every unbound device).

## SELinux

SELinux is enforcing. The k3s policy (`k3s-selinux`) comes from Rancher's
signed el9 stable repository (`host/files/dnf/rancher-k3s-common.repo`), and
k3s runs with `selinux: true`, so runc containers are confined as
`container_t` with per-pod MCS categories. gVisor pods are not
SELinux-labelled (runsc rejects the label; gVisor's own kernel is their
boundary). The host-integrated workloads that need `spc_t` and the NFS
labelling are documented in [docs/pod-security.md](pod-security.md).

## Updates and reboots

| What | When (Europe/Lisbon) | Owner |
| --- | --- | --- |
| Fedora package updates | daily | `dnf5-automatic.timer`: `apply_updates = yes`, `reboot = never` |
| Host configuration from git | hourly | `homeworld-pull.timer` ([docs/k3s.md](k3s.md)) |
| k3s upgrades | 01:00–02:00 | system-upgrade-controller ([docs/upgrades.md](upgrades.md)) |
| Agents VM root rebuild | 02:00–02:30, only when its pins change | `agents-vm-rebuild.timer` ([docs/openchamber.md](openchamber.md)) |
| Reboots | 02:30–06:30 | kured |

[kured](https://kured.dev/) reboots one node at a time. Its reboot sentinel
(`/usr/local/libexec/homeworld/kured-sentinel`) asks for a reboot when:

- `dnf5 needs-restarting` reports "Reboot is required" (a new kernel, glibc,
  systemd, …);
- apply.sh changed a file that k3s or containerd reads only at start
  (`/var/lib/homeworld/reboot-required`);
- a Fedora release upgrade is staged (below).

Before taking the lock, kured queries VictoriaMetrics for firing vmalert
alerts (`apps/victoria-metrics/helm/alert/values.yaml`); any firing alert
blocks the reboot:

| Alert | Fires when |
| --- | --- |
| `LonghornVolumeNotHealthy` | A Longhorn volume is degraded or faulted |
| `NodeNotReady` | A node is not Ready |
| `NodeCordoned` | A node is cordoned (also while kured or system-upgrade-controller works on it, so they never overlap) |
| `NodePostbootFailed` | A node failed its post-boot checks (below) |
| `EtcdNoLeader`, `EtcdMemberDown` | etcd has no leader or fewer than three healthy members |
| `PersistentVolumeFillingUp` | A volume is over 80% full |

kured drains the node (30 minutes at most) and runs the reboot command
(`kured-reboot`): `dnf5 offline reboot` when an upgrade is staged, otherwise
`systemctl reboot`. It holds its lock until the node is back, so the next
node waits.

### Post-boot check

`homeworld-postboot.service` runs on every boot and checks that SELinux is
enforcing, the `k3s` SELinux module is loaded, k3s is active and the node is
Ready, and, after an offline upgrade, that the node runs the target release.
On failure it taints the node `node.homeworld.internal/postboot-failed` and
cordons it: `NodePostbootFailed` fires and no further node reboots. (kured
uncordons the node it rebooted, but never touches the taint.) Fix the cause,
then:

```bash
sudo systemctl restart homeworld-postboot   # removes the taint when the checks pass
kubectl uncordon <node>
```

## Fedora release upgrades

Renovate opens a pull request when a new Fedora release reaches
endoflife.date (`FEDORA_RELEASE` in `host/versions.env`). After the merge,
on each node, the next apply.sh run downloads the upgrade
(`dnf5 system-upgrade download --releasever=<N>`) and leaves
`/var/lib/homeworld/fedora-upgrade-staged`. kured then reboots the nodes into
the offline upgrade one at a time in its window, and the post-boot check
clears the marker once the node runs release N. A node whose upgrade did
not apply stays tainted and halts the rollout.

The same pin drives the agents VM's base image, so a release bump also
rebuilds the VM root in its window.

Third-party repositories that have not published the new release yet
(inside the agents VM: HashiCorp, Adoptium) fall back to the previous
release until they do.

## Firewall

firewalld (nftables backend) stays enabled; Cockpit is disabled.

| Zone | Sources or interfaces | Allowed |
| --- | --- | --- |
| `homeworld-lan` (default) | the LAN NIC | SSH, Kubernetes API (`6443`) |
| `homeworld-nodes` | the three node addresses | SSH, etcd (`2379`–`2381`), Kubernetes API, kubelet (`10250`), scheduler and controller-manager metrics (`10257`, `10259`), Cilium health and Hubble peers (`4240`, `4244`), Cilium WireGuard (`51871/udp`), VXLAN (`8472/udp`) |
| `trusted` | Pod and Service CIDRs, `cilium_*` and `lxc*` interfaces | everything |
| `homeworld-agents` (Ryzen) | `virbr-agents` | DHCP and DNS to libvirt's dnsmasq |

The Gateway VIP (`443`, `22`) is load-balanced by Cilium's eBPF datapath
before netfilter sees it. The agents VM policies on the Ryzen are listed in
[docs/openchamber.md](openchamber.md).

## Trust

`homeworld-pull` fetches `main` from GitHub over HTTPS and runs it as root
without a signature check: whoever can push to `main` controls the hosts, as
they already control the cluster through Argo CD.
