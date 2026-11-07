#!/bin/bash
# Agents VM host side, called by host/apply.sh on the node whose profile sets
# AGENTS_VM=1 (docs/agents-vm.md). Keeps libvirt, the routed network and
# the rebuild timer in place, and schedules a root rebuild for the nightly
# window when the VM's inputs (this directory, the Fedora release) change.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
host=$(dirname "$here")
. "$host/cluster.env"
. "$host/versions.env"

state=/var/lib/homeworld
libexec=/usr/local/libexec/homeworld

log() { echo "agents-vm: $*"; }
put() {
  if [ -f "$3" ] && cmp -s "$2" "$3"; then
    return 1
  fi
  install -D -m "$1" "$2" "$3"
  restorecon -F "$3" 2>/dev/null || true
  log "updated $3"
}

systemctl enable --now virtqemud.socket virtnetworkd.socket virtstoraged.socket >/dev/null 2>&1
put 0644 "$here/libvirt-guests" /etc/sysconfig/libvirt-guests || true
systemctl enable libvirt-guests.service >/dev/null 2>&1

# Routed network. Redefining it briefly drops the VM's link, so only on change.
if put 0644 "$here/network.xml" "$state/agents-network.xml" ||
  ! virsh -q net-info homeworld-agents >/dev/null 2>&1; then
  virsh -q net-destroy homeworld-agents 2>/dev/null || true
  virsh -q net-undefine homeworld-agents 2>/dev/null || true
  virsh -q net-define "$state/agents-network.xml"
  virsh -q net-autostart homeworld-agents
  virsh -q net-start homeworld-agents
  log "network homeworld-agents defined"
fi
virsh -q net-info homeworld-agents | grep 'Active: *yes' >/dev/null || virsh -q net-start homeworld-agents

put 0755 "$here/rebuild.sh" "$libexec/agents-vm-rebuild" || true
units_changed=0
for u in agents-vm-rebuild.service agents-vm-rebuild.timer; do
  put 0644 "$here/$u" "/etc/systemd/system/$u" && units_changed=1 || true
done
[ "$units_changed" = 1 ] && systemctl daemon-reload
systemctl enable --now agents-vm-rebuild.timer >/dev/null 2>&1

if [ ! -e /etc/homeworld/agents-vm.env ]; then
  log "/etc/homeworld/agents-vm.env missing (bootstrap.sh writes it); not building the VM"
  exit 0
fi

# On a chosen data disk, a missing mount must never build a VM on the root
# disk (rebuild.sh refuses too).
if [ -f /etc/homeworld/storage.env ]; then
  . /etc/homeworld/storage.env
  if [ "${AGENTS_VM_ON_DISK:-0}" = 1 ] && ! mountpoint -q /var/lib/libvirt/images/agents; then
    log "the VM disk is not mounted at /var/lib/libvirt/images/agents; not building the VM"
    exit 0
  fi
fi

# The rebuild works from a copy of this checkout, so a later pull cannot
# change the inputs between scheduling and the nightly window.
inputs=$( (cat "$here"/*; echo "FEDORA_RELEASE=$FEDORA_RELEASE") | sha256sum | cut -d' ' -f1)
if [ "$(cat "$state/agents-vm.built" 2>/dev/null)" != "$inputs" ]; then
  rm -rf "$state/agents-vm.next"
  mkdir -p "$state/agents-vm.next"
  cp -a "$here/." "$state/agents-vm.next/"
  cp "$host/cluster.env" "$host/versions.env" "$state/agents-vm.next/"
  echo "$inputs" >"$state/agents-vm.next/inputs"
  if virsh -q dominfo agents >/dev/null 2>&1; then
    log "inputs changed: rebuild scheduled for the nightly window"
  else
    log "no VM yet: building now"
    "$libexec/agents-vm-rebuild" --if-pending
  fi
fi
