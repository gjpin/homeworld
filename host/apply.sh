#!/bin/bash
# Converge this node on the host configuration in git (docs/k3s.md).
#
# Run by homeworld-pull.service (hourly, from the public main branch) and
# once by bootstrap.sh. Idempotent: it changes only what differs. It never
# changes the k3s version (system-upgrade-controller owns that). Changes that
# k3s or containerd only read at start are not applied live: they leave a
# marker that kured turns into a serialized reboot in its window.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
. "$here/cluster.env"
. "$here/versions.env"
. /etc/homeworld/node.env
# shellcheck source=/dev/null
. "$here/nodes/$PROFILE.env"
. /etc/homeworld/env

files=$here/files
state=/var/lib/homeworld
libexec=/usr/local/libexec/homeworld
mkdir -p "$state" "$libexec"
k3s_installed=$([ -x /usr/local/bin/k3s ] && echo 1 || echo 0)

log() { echo "apply: $*"; }

# put MODE SRC DEST: install SRC at DEST when the content differs; returns 0
# (true) only when it changed something.
put() {
  if [ -f "$3" ] && cmp -s "$2" "$3"; then
    return 1
  fi
  install -D -m "$1" "$2" "$3"
  restorecon -F "$3" 2>/dev/null || true
  log "updated $3"
}

# render SRC: substitute the @PLACEHOLDERS@ of a template on stdout.
render() {
  sed -e "s|@NODE_IP@|$NODE_IP|g" \
    -e "s|@API_VIP@|$API_VIP|g" \
    -e "s|@PROFILE@|$PROFILE|g" \
    -e "s|@SYSTEM_RESERVED_MEMORY@|$SYSTEM_RESERVED_MEMORY|g" \
    -e "s|@KUBE_VIP_VERSION@|$KUBE_VIP_VERSION|g" \
    -e "s|@LAN_IFACE@|$lan_iface|g" \
    -e "s|@JOIN@|$join|g" \
    -e "s|@BASE_DOMAIN@|$BASE_DOMAIN|g" \
    "$1"
}

# needs_reboot WHAT: k3s reads WHAT only at start.
needs_reboot() {
  if [ "$k3s_installed" = 1 ]; then
    echo "$1" >>"$state/reboot-required"
    log "$1 changed: kured reboots this node in its window"
  fi
}

lan_iface=$(ip -o -4 addr show | awk -v ip="$NODE_IP" '{split($4, a, "/")} a[1] == ip && !found {print $2; found = 1}')
if [ -z "$lan_iface" ]; then
  echo "apply: no interface carries $NODE_IP" >&2
  exit 1
fi
if [ "$K3S_ROLE" = init ]; then
  join="cluster-init: true"
else
  join="server: https://$API_VIP:6443"
fi

# --- packages -------------------------------------------------------------
put 0644 "$files/dnf/rancher-k3s-common.repo" /etc/yum.repos.d/rancher-k3s-common.repo || true
packages=(
  container-selinux k3s-selinux policycoreutils-python-utils
  firewalld iscsi-initiator-utils nfs-utils cryptsetup wireguard-tools
  clevis-luks clevis-dracut dnf5-plugin-automatic
  bzip2 curl jq tar yq
)
if [ "$AGENTS_VM" = 1 ]; then
  packages+=(libvirt-daemon-kvm qemu-kvm virt-install cloud-utils xorriso)
fi
missing=()
for p in "${packages[@]}"; do
  rpm -q "$p" >/dev/null 2>&1 || missing+=("$p")
done
if [ "${#missing[@]}" -gt 0 ]; then
  dnf -y -q install "${missing[@]}"
fi
timedatectl set-timezone "$TIMEZONE"
# NFS volumes keep their nfs_t label (the CSI driver drops context= mount
# options); container_t reaches them through this container-selinux boolean.
[ "$(getsebool virt_use_nfs | awk '{print $3}')" = on ] || setsebool -P virt_use_nfs on
# Jellyfin's QuickSync transcoding (container_t) maps the iGPU render node
# allocated by the Intel GPU device plugin; recent container-selinux turns
# this boolean on by default, older releases lack it.
if getsebool container_use_dri_devices >/dev/null 2>&1; then
  [ "$(getsebool container_use_dri_devices | awk '{print $3}')" = on ] || setsebool -P container_use_dri_devices on
fi

# --- kernel ---------------------------------------------------------------
put 0644 "$files/sysctl/90-homeworld.conf" /etc/sysctl.d/90-homeworld.conf && sysctl -q --system || true
put 0644 "$files/modules/homeworld.conf" /etc/modules-load.d/homeworld.conf && systemctl restart systemd-modules-load || true

# --- firewalld ------------------------------------------------------------
fw_changed=0
fw() { # fw ZONE-OR-POLICY-ARGS QUERY-FLAG ADD-FLAG VALUE
  local target=$1 query=$2 add=$3 value=$4
  if ! firewall-cmd --permanent $target "$query=$value" >/dev/null 2>&1; then
    firewall-cmd --permanent $target "$add=$value" >/dev/null
    fw_changed=1
  fi
}
fw_zone() { firewall-cmd --permanent --get-zones | tr ' ' '\n' | grep -x "$1" >/dev/null || { firewall-cmd --permanent --new-zone="$1" >/dev/null; fw_changed=1; }; }
fw_policy() { firewall-cmd --permanent --get-policies | tr ' ' '\n' | grep -x "$1" >/dev/null || { firewall-cmd --permanent --new-policy="$1" >/dev/null; fw_changed=1; }; }
fw_target() { [ "$(firewall-cmd --permanent "$1" --get-target)" = "$2" ] || { firewall-cmd --permanent "$1" --set-target="$2" >/dev/null; fw_changed=1; }; }

systemctl enable --now firewalld >/dev/null 2>&1
systemctl disable --now cockpit.socket >/dev/null 2>&1 || true

# The LAN NIC: SSH and the Kubernetes API only. The Gateway VIP (443/22) is
# load-balanced by Cilium's eBPF datapath before netfilter sees it.
fw_zone homeworld-lan
fw --zone=homeworld-lan --query-service --add-service ssh
fw --zone=homeworld-lan --query-port --add-port 6443/tcp
# The other nodes: etcd, kubelet, control-plane metrics, Cilium health,
# metrics and Hubble peers, Cilium WireGuard and VXLAN.
fw_zone homeworld-nodes
for ip in $NODE_IPS; do
  fw --zone=homeworld-nodes --query-source --add-source "$ip/32"
done
for src in $(firewall-cmd --permanent --zone=homeworld-nodes --list-sources); do
  case " $NODE_IPS " in
    *" ${src%/32} "*) ;;
    *) firewall-cmd --permanent --zone=homeworld-nodes --remove-source="$src" >/dev/null; fw_changed=1 ;;
  esac
done
fw --zone=homeworld-nodes --query-service --add-service ssh
for p in 2379-2380/tcp 2381/tcp 6443/tcp 10250/tcp 10257/tcp 10259/tcp 4240/tcp 4244/tcp 9962-9965/tcp 51871/udp 8472/udp; do
  fw --zone=homeworld-nodes --query-port --add-port "$p"
done
# Pod and service traffic, and Cilium's own devices.
for src in "$POD_CIDR" "$SERVICE_CIDR"; do
  fw --zone=trusted --query-source --add-source "$src"
done
for i in cilium_host cilium_net cilium_vxlan cilium_wg0 'lxc+'; do
  fw --zone=trusted --query-interface --add-interface "$i"
done

if [ "$AGENTS_VM" = 1 ]; then
  # The agents VM (docs/openchamber.md): the host offers it DHCP and DNS only.
  fw_zone homeworld-agents
  fw --zone=homeworld-agents --query-service --add-service dhcp
  fw --zone=homeworld-agents --query-service --add-service dns
  # VM -> anywhere: the internet, never the LAN, the host, the NAS or the
  # cluster, except the Gateway VIP for Forgejo (HTTPS and SSH).
  fw_policy agents-out
  fw --policy=agents-out --query-ingress-zone --add-ingress-zone homeworld-agents
  fw --policy=agents-out --query-egress-zone --add-egress-zone ANY
  fw_target --policy=agents-out ACCEPT
  for port in 443 22; do
    fw --policy=agents-out --query-rich-rule --add-rich-rule "rule priority=-20 family=ipv4 destination address=$GATEWAY_VIP port port=$port protocol=tcp accept"
  done
  for cidr in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 100.64.0.0/10 169.254.0.0/16 224.0.0.0/4; do
    fw --policy=agents-out --query-rich-rule --add-rich-rule "rule priority=-10 family=ipv4 destination address=$cidr reject"
  done
  for cidr in fc00::/7 fe80::/10 ff00::/8; do
    fw --policy=agents-out --query-rich-rule --add-rich-rule "rule priority=-10 family=ipv6 destination address=$cidr reject"
  done
  # LAN and WireGuard clients -> VM: any port, except ThinkRail, which has
  # no login of its own and is reached only through the Gateway's sign-in.
  fw_policy lan-to-agents
  fw --policy=lan-to-agents --query-ingress-zone --add-ingress-zone homeworld-lan
  fw --policy=lan-to-agents --query-egress-zone --add-egress-zone homeworld-agents
  fw_target --policy=lan-to-agents ACCEPT
  fw --policy=lan-to-agents --query-rich-rule --add-rich-rule 'rule priority=-10 port port=24242 protocol=tcp reject'
  # Node IPs and pods (Envoy) -> VM: OpenChamber, Paseo and ThinkRail only.
  fw_policy nodes-to-agents
  fw --policy=nodes-to-agents --query-ingress-zone --add-ingress-zone homeworld-nodes
  fw --policy=nodes-to-agents --query-ingress-zone --add-ingress-zone trusted
  fw --policy=nodes-to-agents --query-egress-zone --add-egress-zone homeworld-agents
  fw_target --policy=nodes-to-agents REJECT
  # This host -> VM: the same ports, plus DHCP replies.
  fw_policy host-to-agents
  fw --policy=host-to-agents --query-ingress-zone --add-ingress-zone HOST
  fw --policy=host-to-agents --query-egress-zone --add-egress-zone homeworld-agents
  fw_target --policy=host-to-agents REJECT
  fw --policy=host-to-agents --query-port --add-port 68/udp
  fw --policy=host-to-agents --query-protocol --add-protocol icmp
  for policy in nodes-to-agents host-to-agents; do
    fw --policy=$policy --query-port --add-port 3000/tcp
    fw --policy=$policy --query-port --add-port 6767/tcp
    fw --policy=$policy --query-port --add-port 24242/tcp
  done
fi
if [ "$fw_changed" = 1 ]; then
  firewall-cmd --reload >/dev/null
  log "firewalld reloaded"
fi
# Every interface without an explicit zone (the LAN NIC) lands here.
[ "$(firewall-cmd --get-default-zone)" = homeworld-lan ] || firewall-cmd --set-default-zone=homeworld-lan >/dev/null

# Every non-VM-host node routes the agents subnet through the VM host (the
# router has the same route for LAN clients).
if [ "$AGENTS_VM" != 1 ]; then
  ip route replace "$AGENTS_CIDR" via "$AGENTS_VM_HOST_IP" dev "$lan_iface"
  conn=$(nmcli -g GENERAL.CONNECTION device show "$lan_iface")
  if ! nmcli -g ipv4.routes connection show "$conn" | grep "$AGENTS_CIDR" >/dev/null; then
    nmcli connection modify "$conn" +ipv4.routes "$AGENTS_CIDR $AGENTS_VM_HOST_IP"
    log "persisted route $AGENTS_CIDR via $AGENTS_VM_HOST_IP"
  fi
fi

# --- sshd -----------------------------------------------------------------
tmp=$(mktemp)
render "$files/sshd.conf.in" >"$tmp"
if put 0600 "$tmp" /etc/ssh/sshd_config.d/10-homeworld.conf; then
  sshd -t && systemctl reload-or-restart sshd
fi

# --- gVisor ---------------------------------------------------------------
if ! { /usr/local/bin/runsc --version 2>/dev/null | grep "release-$GVISOR_VERSION" >/dev/null &&
  [ -x /usr/local/bin/gvisor-bin/gvisor_sentry ]; }; then
  dl=$(mktemp -d)
  url=https://storage.googleapis.com/gvisor/releases/release/$GVISOR_VERSION/$(uname -m)
  curl -fsSL -o "$dl/gvisor.tar.bz2" "$url/gvisor.tar.bz2"
  curl -fsSL -o "$dl/gvisor.tar.bz2.sha512" "$url/gvisor.tar.bz2.sha512"
  (cd "$dl" && sha512sum -c --quiet gvisor.tar.bz2.sha512)
  mkdir "$dl/x"
  tar -xjf "$dl/gvisor.tar.bz2" -C "$dl/x" runsc containerd-shim-runsc-v1 gvisor-bin
  # Replace the sidecar directory before runsc, which looks for it next to
  # itself; running sandboxes keep their already-open binaries.
  rm -rf /usr/local/bin/gvisor-bin.new
  mv "$dl/x/gvisor-bin" /usr/local/bin/gvisor-bin.new
  rm -rf /usr/local/bin/gvisor-bin
  mv /usr/local/bin/gvisor-bin.new /usr/local/bin/gvisor-bin
  install -m 0755 "$dl/x/containerd-shim-runsc-v1" /usr/local/bin/containerd-shim-runsc-v1
  install -m 0755 "$dl/x/runsc" /usr/local/bin/runsc
  restorecon -R /usr/local/bin
  rm -rf "$dl"
  log "installed gVisor release-$GVISOR_VERSION"
fi
put 0755 "$files/libexec/runsc-selinux-strip" "$libexec/runsc-selinux-strip" || true
put 0644 "$files/containerd/runsc.toml" /etc/containerd/runsc.toml || true
put 0644 "$files/containerd/gvisor.toml" /var/lib/rancher/k3s/agent/etc/containerd/config-v3.toml.d/gvisor.toml &&
  needs_reboot "containerd gVisor handler" || true

# --- containerd -----------------------------------------------------------
put 0644 "$files/containerd/devices.toml" /var/lib/rancher/k3s/agent/etc/containerd/config-v3.toml.d/devices.toml &&
  needs_reboot "containerd device ownership" || true

# --- k3s ------------------------------------------------------------------
put 0644 "$files/k3s/psa.yaml" /etc/rancher/k3s/psa.yaml && needs_reboot "Pod Security Admission defaults" || true
# The API server reloads this file itself; no reboot.
render "$files/k3s/authentication.yaml.in" >"$tmp"
put 0600 "$tmp" /etc/rancher/k3s/authentication.yaml || true
# The API server reaches the issuer through a ClusterIP, because a node cannot
# use the Gateway VIP (apps/envoy-gateway/0_node_access_service.yaml).
issuer_host="$GATEWAY_CLUSTER_IP auth.$BASE_DOMAIN"
if ! grep -qxF "$issuer_host" /etc/hosts; then
  sed -i "/ auth\.${BASE_DOMAIN//./\\.}\$/d" /etc/hosts
  echo "$issuer_host" >>/etc/hosts
  log "updated /etc/hosts for auth.$BASE_DOMAIN"
fi
render "$files/k3s/config.yaml.in" >"$tmp"
put 0600 "$tmp" /etc/rancher/k3s/config.yaml && needs_reboot "k3s configuration" || true
if [ "$k3s_installed" = 1 ]; then
  # The k3s installer and system-upgrade-controller replace the binary; the
  # k3s-selinux file context labels it container_runtime_exec_t.
  restorecon /usr/local/bin/k3s
fi
render "$files/k3s/kube-vip.yaml.in" >"$tmp"
put 0600 "$tmp" /var/lib/rancher/k3s/agent/pod-manifests/kube-vip.yaml || true
rm -f "$tmp"

# --- updates and reboots --------------------------------------------------
put 0644 "$files/dnf/automatic.conf" /etc/dnf/automatic.conf || true
# Longhorn attaches volumes through the host's iSCSI initiator.
systemctl enable --now iscsid.socket >/dev/null 2>&1
systemctl enable --now dnf5-automatic.timer >/dev/null 2>&1
for f in kured-sentinel kured-reboot homeworld-postboot homeworld-pull; do
  put 0755 "$files/libexec/$f" "$libexec/$f" || true
done
put 0644 "$here/cluster.env" /etc/homeworld/cluster.env || true
units_changed=0
for u in homeworld-pull.service homeworld-pull.timer homeworld-postboot.service; do
  put 0644 "$files/systemd/$u" "/etc/systemd/system/$u" && units_changed=1 || true
done
[ "$units_changed" = 1 ] && systemctl daemon-reload
systemctl enable homeworld-postboot.service homeworld-pull.timer >/dev/null 2>&1
systemctl start homeworld-pull.timer

# Fedora major upgrades: download once, then kured performs the offline
# upgrade reboot (kured-sentinel/kured-reboot) one node at a time.
. /etc/os-release
if [ "$VERSION_ID" -lt "$FEDORA_RELEASE" ] && [ ! -e "$state/fedora-upgrade-staged" ]; then
  log "staging the Fedora $FEDORA_RELEASE upgrade"
  dnf5 -y -q system-upgrade download --releasever="$FEDORA_RELEASE"
  echo "$FEDORA_RELEASE" >"$state/fedora-upgrade-staged"
fi

# --- cluster-side node settings ---------------------------------------------
if [ "$k3s_installed" = 1 ] && systemctl is-active -q k3s; then
  disks="[{\"path\":\"/var/lib/longhorn\",\"allowScheduling\":true,\"storageReserved\":$((LONGHORN_RESERVED_GIB * 1024 * 1024 * 1024))}]"
  k3s kubectl annotate node "$(hostname)" --overwrite \
    "node.longhorn.io/default-disks-config=$disks" >/dev/null 2>&1 || true
fi

# --- agents VM ------------------------------------------------------------
if [ "$AGENTS_VM" = 1 ]; then
  "$here/agents-vm/host.sh"
fi

log "done"
