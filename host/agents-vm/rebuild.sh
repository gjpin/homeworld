#!/bin/bash
# Rebuild the agents VM root disk from the pinned Fedora Cloud Base image
# (docs/openchamber.md). /home lives on its own disk and survives.
# Usage: agents-vm-rebuild [--if-pending]
#   --if-pending  only act when host.sh staged new inputs (nightly timer).
set -euo pipefail

state=/var/lib/homeworld
src=$state/agents-vm.next
images=/var/lib/libvirt/images/agents

log() { echo "agents-vm-rebuild: $*"; }

if [ ! -e "$src/inputs" ]; then
  [ "${1:-}" = --if-pending ] && exit 0
  echo "agents-vm-rebuild: nothing staged in $src (host/apply.sh stages it)" >&2
  exit 1
fi
. "$src/cluster.env"
. "$src/versions.env"
. /etc/homeworld/agents-vm.env
release=$FEDORA_RELEASE
arch=$(uname -m)
mkdir -p "$images"

# --- base image: Fedora Cloud Base, CHECKSUM signed by the release key ----
base=$images/base-f$release.qcow2
if [ ! -e "$base" ]; then
  url=https://download.fedoraproject.org/pub/fedora/linux/releases/$release/Cloud/$arch/images
  dl=$(mktemp -d)
  trap 'rm -rf "$dl"' EXIT
  listing=$(curl -fsSL "$url/")
  sums=$(printf '%s' "$listing" | grep -oE "Fedora-Cloud-$release-[0-9.]+-$arch-CHECKSUM" | sed -n 1p)
  image=$(printf '%s' "$listing" | grep -oE "Fedora-Cloud-Base-Generic-$release-[0-9.]+\.$arch\.qcow2" | sed -n 1p)
  curl -fsSL -o "$dl/$sums" "$url/$sums"
  curl -fsSL -o "$dl/$image" "$url/$image"
  # fedora-gpg-keys ships the keys of the current and the next release.
  gpg --batch --quiet --homedir "$dl" --import "/etc/pki/rpm-gpg/RPM-GPG-KEY-fedora-$release-primary"
  gpg --batch --quiet --homedir "$dl" --verify "$dl/$sums"
  (cd "$dl" && grep "^SHA256 ($image)" "$sums" | sha256sum -c --quiet -)
  mv "$dl/$image" "$base"
  rm -rf "$dl"
  trap - EXIT
  find "$images" -name 'base-f*.qcow2' ! -name "base-f$release.qcow2" -delete
  log "verified $image"
fi

# --- cloud-init seed ------------------------------------------------------
b64() { base64 -w0 "$1"; }
ca=$(k3s kubectl -n kube-system get configmap homeworld-ca -o jsonpath='{.data.ca\.crt}' 2>/dev/null || true)
seed=$(mktemp -d)
trap 'rm -rf "$seed"' EXIT
{
  echo "AGENTS_INFISICAL_CLIENT_ID=$AGENTS_INFISICAL_CLIENT_ID"
  echo "AGENTS_INFISICAL_CLIENT_SECRET=$AGENTS_INFISICAL_CLIENT_SECRET"
  echo "AGENTS_INFISICAL_PROJECT_ID=$AGENTS_INFISICAL_PROJECT_ID"
} >"$seed/infisical.env"
printf '%s\n' "$ca" >"$seed/homeworld-ca.crt"
keys=$(printf '%s\n' "$AGENT_SSH_KEYS" | sed '/^$/d; s/^/      - /')
sed -e "s|@INFISICAL_ENV_B64@|$(b64 "$seed/infisical.env")|" \
  -e "s|@VERSIONS_B64@|$(b64 "$src/versions.env")|" \
  -e "s|@PROVISION_B64@|$(b64 "$src/provision.sh")|" \
  -e "s|@CONFIG_B64@|$(b64 "$src/agents-config.sh")|" \
  -e "s|@INSTRUCTIONS_B64@|$(b64 "$src/agents-instructions.md")|" \
  -e "s|@CA_B64@|$(b64 "$seed/homeworld-ca.crt")|" \
  -e "s|@TIMEZONE@|$TIMEZONE|" \
  "$src/user-data.in" |
  awk -v keys="$keys" '$0 == "@AGENT_SSH_KEYS@" {print keys; next} {print}' >"$seed/user-data"
printf 'instance-id: agents-%s\nlocal-hostname: agents\n' "$(date +%s)" >"$seed/meta-data"

# --- domain ---------------------------------------------------------------
virsh -q destroy agents 2>/dev/null || true
virsh -q undefine agents --nvram 2>/dev/null || true
rm -f "$images/root.qcow2" "$images/seed.iso"
qemu-img convert -q -O qcow2 "$base" "$images/root.qcow2"
qemu-img resize -q "$images/root.qcow2" 40G
[ -e "$images/home.qcow2" ] || qemu-img create -q -f qcow2 "$images/home.qcow2" 160G
cloud-localds "$images/seed.iso" "$seed/user-data" "$seed/meta-data"
restorecon -R "$images"
virt-install -q --import --name agents --osinfo fedora-unknown \
  --virt-type kvm --cpu host-passthrough --vcpus 8 --memory 16384 \
  --boot uefi --autostart --noautoconsole --graphics none \
  --disk "$images/root.qcow2,bus=virtio" \
  --disk "$images/home.qcow2,bus=virtio" \
  --disk "$images/seed.iso,device=cdrom" \
  --network "network=homeworld-agents,mac=$AGENTS_VM_MAC,model=virtio" \
  --channel unix,target.type=virtio,target.name=org.qemu.guest_agent.0
# A lower CPU weight than the host's own services (cgroup v2 cpu.weight).
virsh -q schedinfo agents --live --config --set cpu_shares=256 >/dev/null

cp "$src/inputs" "$state/agents-vm.built"
rm -rf "$src"
log "rebuilt the agents VM root (Fedora $release)"
