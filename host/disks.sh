#!/bin/bash
# Choose which attached SSD/NVMe disks hold Longhorn and the agents VM disks
# (docs/fedora.md, "Data disks"). Run as root by bootstrap.sh, or by hand:
#
#   sudo host/disks.sh [--treat-as-ssd SERIAL]...
#
# Nothing is erased unless you choose to format a disk and type its serial.
# Skip is the default for every disk. The choices live on the node, in
# /etc/homeworld/storage.env, /etc/crypttab and /etc/fstab, never in git;
# apply.sh only reads them. A rerun leaves configured disks alone.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }
[ -f /etc/homeworld/node.env ] || { echo "/etc/homeworld/node.env missing: run host/bootstrap.sh <profile>" >&2; exit 1; }
. /etc/homeworld/node.env
# shellcheck source=/dev/null
. "$here/nodes/$PROFILE.env"

treat_as_ssd=" "
while [ $# -gt 0 ]; do
  case "$1" in
    --treat-as-ssd) [ $# -ge 2 ] || { echo "--treat-as-ssd needs a serial" >&2; exit 1; }
      treat_as_ssd+="$2 "; shift 2 ;;
    *) echo "usage: $0 [--treat-as-ssd SERIAL]..." >&2; exit 1 ;;
  esac
done

state=/etc/homeworld/storage.env
disks_dir=/var/lib/homeworld-disks
keys_dir=/etc/cryptsetup-keys.d
vm_images=/var/lib/libvirt/images/agents
vm_gib=${AGENTS_VM_RESERVED_GIB:-200}
min_longhorn_gib=20
gib=$((1024 * 1024 * 1024))
mount_opts=defaults,nosuid,nodev,noexec,nofail,x-systemd.device-timeout=60s

LONGHORN_DISKS=""
AGENTS_VM_ON_DISK=0
STORAGE_MOUNTS=""
# shellcheck source=/dev/null
[ -f "$state" ] && . "$state"

probe=""
cleanup() {
  if [ -n "$probe" ]; then
    umount "$probe" 2>/dev/null || true
    rmdir "$probe" 2>/dev/null || true
  fi
}
trap cleanup EXIT

log() { echo; echo "== $*"; }
warn() { echo "warning: $*" >&2; }
human() { numfmt --to=iec-i --suffix=B --format=%.1f "$1"; }
ask() { # ask VAR PROMPT: an empty answer or end of input leaves VAR empty.
  local answer=""
  read -r -p "$2" answer || answer=""
  printf -v "$1" '%s' "$answer"
}

for p in cryptsetup jq xfsprogs; do
  rpm -q "$p" >/dev/null 2>&1 || dnf -y -q install "$p"
done

# --- inspecting disks -------------------------------------------------------
tree() { # tree DEV: the device and its children as one JSON object.
  lsblk -Jbp -o NAME,TYPE,SIZE,ROTA,TRAN,MODEL,SERIAL,FSTYPE,LABEL,UUID,MOUNTPOINTS,PTTYPE,PARTN "$1" |
    jq '.blockdevices[0]'
}

# Every disk holding a filesystem the running system boots from.
system_disks() {
  local m src
  for m in / /boot /boot/efi; do
    src=$(findmnt -nvo SOURCE "$m" 2>/dev/null) || continue
    lsblk -nsrpo NAME,TYPE "$src" | awk '$2 == "disk" {print $1}'
  done | sort -u
}

in_use() { # in_use JSON: mounted, swap, or holding a mapping, LVM or RAID.
  local uuid
  jq -e '[recurse(.children[]?)] | any(
      ((.mountpoints // []) | map(select(.)) | length > 0)
      or (.type | test("^(crypt|lvm|raid|md|mpath)"))
      or ((.fstype // "") | test("^(LVM2_member|linux_raid_member|zfs_member)$")))' \
    <<<"$1" >/dev/null && return 0
  for uuid in $(jq -r '[recurse(.children[]?) | .uuid // empty] | .[]' <<<"$1"); do
    grep -qs "$uuid" /etc/fstab /etc/crypttab && return 0
  done
  return 1
}

# fs_stats DEV FSTYPE: "SIZE USED" in bytes, read through a temporary mount
# whose options never replay a journal, or nothing when it cannot be mounted.
fs_stats() {
  local opts=ro,nosuid,nodev,noexec out
  case "$2" in
    xfs) opts+=,norecovery,nouuid ;;
    ext4 | ext3 | ext2) opts+=,noload ;;
    btrfs) opts+=,rescue=nologreplay ;;
    ntfs | exfat | vfat) ;;
    *) return 0 ;;
  esac
  probe=$(mktemp -d /run/homeworld-disk.XXXXXX)
  if mount -t "$2" -o "$opts" "$1" "$probe" 2>/dev/null; then
    out=$(df -B1 --output=size,used "$probe" | tail -1)
    umount "$probe"
    # shellcheck disable=SC2086 # two numbers
    echo $out
  fi
  rmdir "$probe"
  probe=""
}

largest_free() { # largest_free DEV: "START SECTORS" of the largest gap, if any.
  sfdisk -F "$1" 2>/dev/null | awk 'NF == 4 && $1 ~ /^[0-9]+$/ {print $1, $3}' | sort -k2 -n | tail -1
}

free_bytes() { # free_bytes DEV: size of the largest gap on a GPT disk.
  local gap
  gap=$(largest_free "$1")
  [ -n "$gap" ] || { echo 0; return; }
  echo $((${gap#* } * $(blockdev --getss "$1")))
}

is_empty() { # is_empty JSON DEV: no partitions, table or known signature.
  jq -e '(.children // [] | length == 0) and (.fstype == null) and (.pttype == null)' <<<"$1" >/dev/null &&
    [ -z "$(wipefs -n "$2" 2>/dev/null)" ]
}

disk_id() { # disk_id JSON: the serial, or the device name of a disk without one.
  jq -r '.serial // (.name | sub(".*/"; ""))' <<<"$1"
}

kind() { # kind JSON: HDD, NVMe or SSD.
  local tran rota id
  tran=$(jq -r '.tran // ""' <<<"$1")
  rota=$(jq -r '.rota' <<<"$1")
  id=$(disk_id "$1")
  if [ "$rota" = true ]; then
    case "$treat_as_ssd" in
      *" $id "*) echo SSD; return ;;
    esac
    echo HDD
  elif [ "$tran" = nvme ]; then
    echo NVMe
  else
    echo SSD
  fi
}

print_contents() { # print_contents JSON DEV
  local line name fstype label size used stats free
  if is_empty "$1" "$2"; then
    echo "      empty"
    return
  fi
  # Unit separators: read would collapse the empty fields between tabs.
  while IFS=$'\x1f' read -r name fstype label size; do
    line="      $name  ${fstype:-no filesystem}"
    [ -z "$label" ] || line+=" \"$label\""
    line+="  $(human "$size")"
    if [ "$fstype" = crypto_LUKS ]; then
      line+=", encrypted"
    elif [ -n "$fstype" ] && ! in_use "$1"; then
      stats=$(fs_stats "$name" "$fstype")
      if [ -n "$stats" ]; then
        used=${stats#* }
        line+=", $(human "$used") used"
      else
        line+=", used space unknown"
      fi
    fi
    echo "$line"
  done < <(jq -r '[recurse(.children[]?)
      | select(.type == "part" or .type == "disk")
      | select(.type == "part" or .fstype != null)]
    | .[] | [.name, .fstype // "", .label // "", (.size | tostring)] | join("\u001f")' <<<"$1")
  if [ "$(jq -r '.pttype // ""' <<<"$1")" = gpt ]; then
    free=$(free_bytes "$2")
    [ "$free" -lt "$gib" ] || echo "      unallocated: $(human "$free")"
  fi
}

# --- recording the choices --------------------------------------------------
# set_line FILE FIELD KEY LINE: LINE replaces any line whose FIELD equals KEY.
set_line() {
  local tmp
  touch "$1"
  tmp=$(mktemp)
  awk -v f="$2" -v k="$3" '$f != k' "$1" >"$tmp"
  echo "$4" >>"$tmp"
  cat "$tmp" >"$1"
  rm -f "$tmp"
  restorecon "$1" 2>/dev/null || true
}

save_state() {
  local tmp
  tmp=$(mktemp)
  {
    echo "# Written by host/disks.sh. Read by apply.sh, the agents VM scripts and"
    echo "# homeworld-postboot (docs/fedora.md, \"Data disks\")."
    echo "LONGHORN_DISKS=\"$LONGHORN_DISKS\""
    echo "AGENTS_VM_ON_DISK=$AGENTS_VM_ON_DISK"
    echo "STORAGE_MOUNTS=\"$STORAGE_MOUNTS\""
  } >"$tmp"
  install -m 0644 "$tmp" "$state"
  rm -f "$tmp"
  restorecon "$state" 2>/dev/null || true
}

add_mount() {
  case " $STORAGE_MOUNTS " in
    *" $1 "*) ;;
    *) STORAGE_MOUNTS="${STORAGE_MOUNTS:+$STORAGE_MOUNTS }$1" ;;
  esac
}

volume_name() { # volume_name JSON PARTN: a Longhorn-safe name, unique on this node.
  local base name i=2
  base=$(disk_id "$1" | tr '[:upper:]' '[:lower:]' |
    sed -e 's/[^a-z0-9]\{1,\}/-/g' -e 's/^-//' -e 's/-$//' | cut -c1-40)
  base=${base%-}
  [ -z "$2" ] || base+="-p$2"
  name=$base
  while case " $STORAGE_MOUNTS " in *" $disks_dir/$name "*) true ;; *) false ;; esac; do
    name=$base-$i
    i=$((i + 1))
  done
  echo "$name"
}

# --- setting a volume up ----------------------------------------------------
recovery=""
recovery_passphrase() {
  local again
  [ -z "$recovery" ] || return 0
  echo "New encrypted disks get a recovery passphrase. Store it offline: it opens"
  echo "them if this node's root disk is lost."
  while :; do
    read -r -s -p "Recovery passphrase: " recovery || recovery=""; echo
    read -r -s -p "Again: " again || again=""; echo
    if [ "${#recovery}" -ge 12 ] && [ "$recovery" = "$again" ]; then
      return 0
    fi
    [ -t 0 ] || { echo "no usable recovery passphrase on standard input" >&2; exit 1; }
    echo "They must match and hold at least 12 characters."
  done
}

new_key() { # new_key NAME: a random key file readable only by root.
  install -d -m 0700 "$keys_dir"
  (umask 077 && head -c 64 /dev/urandom >"$keys_dir/hw-$1.key")
  restorecon -R "$keys_dir" 2>/dev/null || true
}

add_crypttab() { # add_crypttab NAME DEV
  set_line /etc/crypttab 1 "hw-$1" \
    "hw-$1 UUID=$(cryptsetup luksUUID "$2") $keys_dir/hw-$1.key luks,nofail,x-systemd.device-timeout=60s"
}

mount_volume() { # mount_volume NAME SPEC FSTYPE
  local dir=$disks_dir/$1
  mkdir -p "$dir"
  # Immutable while unmounted: nothing can land on the root disk by mistake
  # when the disk is missing.
  mountpoint -q "$dir" || chattr +i "$dir"
  set_line /etc/fstab 2 "$dir" "$2 $dir $3 $mount_opts,x-systemd.before=k3s.service 0 2"
  systemctl daemon-reload
  mountpoint -q "$dir" || mount "$dir"
  add_mount "$dir"
}

use_for_longhorn() { # use_for_longhorn NAME RESERVED-BYTES
  local dir=$disks_dir/$1/longhorn
  mkdir -p "$dir"
  restorecon -RF "$dir" 2>/dev/null || true
  LONGHORN_DISKS="${LONGHORN_DISKS:+$LONGHORN_DISKS }$1=$dir=$2"
  save_state
  echo "$dir: Longhorn"
}

use_for_vm() { # use_for_vm NAME
  local dir=$disks_dir/$1/agents-vm
  mkdir -p "$dir" "$vm_images"
  mountpoint -q "$vm_images" || chattr +i "$vm_images"
  set_line /etc/fstab 2 "$vm_images" \
    "$dir $vm_images none bind,nofail,x-systemd.before=virtqemud.service,x-systemd.before=libvirt-guests.service 0 0"
  systemctl daemon-reload
  mountpoint -q "$vm_images" || mount "$vm_images"
  restorecon -RF "$vm_images"
  add_mount "$vm_images"
  AGENTS_VM_ON_DISK=1
  save_state
  echo "$vm_images: agents VM disks"
}

# new_volume NAME PARTITION ROLE: encrypt, format, mount and assign an erased
# partition. Longhorn takes a reserve of 0 as unset and holds back 30% instead,
# so a filesystem of its own gets a token reserve.
new_volume() {
  local name=$1 part=$2 role=$3
  log "Encrypting $part (LUKS2, XFS)"
  new_key "$name"
  printf %s "$recovery" | cryptsetup luksFormat --type luks2 --batch-mode --key-file=- "$part"
  printf %s "$recovery" | cryptsetup luksAddKey --key-file=- "$part" "$keys_dir/hw-$name.key"
  cryptsetup open --key-file "$keys_dir/hw-$name.key" "$part" "hw-$name"
  mkfs.xfs -q "/dev/mapper/hw-$name"
  add_crypttab "$name" "$part"
  mount_volume "$name" "/dev/mapper/hw-$name" xfs
  restorecon "$disks_dir/$name" 2>/dev/null || true
  case "$role" in
    longhorn) use_for_longhorn "$name" "$gib" ;;
    agents-vm) use_for_vm "$name" ;;
  esac
}

partition_path() { # partition_path DISK PARTN
  udevadm settle
  lsblk -nrpo NAME,TYPE,PARTN "$1" | awk -v n="$2" '$2 == "part" && $3 == n {print $1}'
}

# carve_partition DISK SIZE-GIB: a Linux partition in the largest gap (the
# whole gap with an empty size), printing its number.
carve_partition() {
  local start before after
  start=$(largest_free "$1")
  start=${start% *}
  before=$(lsblk -nrpo PARTN "$1" | sort -n | tail -1)
  printf 'start=%s%s, type=L\n' "$start" "${2:+, size=${2}GiB}" | sfdisk -q --append --wipe-partitions always "$1"
  udevadm settle
  after=$(lsblk -nrpo PARTN "$1" | sort -n | tail -1)
  [ "$after" != "$before" ] || { echo "no new partition on $1" >&2; exit 1; }
  echo "$after"
}

# build_on_free JSON DISK ROLE: new volumes in existing or just-erased GPT space.
build_on_free() {
  local json=$1 disk=$2 role=$3 n vm_n
  recovery_passphrase
  # Partitions first: the kernel will not reread the table of a disk in use.
  if [ "$role" = both ]; then
    # The room the VM's full-size disks need, plus LUKS and XFS overhead.
    vm_n=$(carve_partition "$disk" "$((vm_gib + 5))")
    n=$(carve_partition "$disk" "")
    new_volume "$(volume_name "$json" "$vm_n")" "$(partition_path "$disk" "$vm_n")" agents-vm
    role=longhorn
  else
    n=$(carve_partition "$disk" "")
  fi
  new_volume "$(volume_name "$json" "$n")" "$(partition_path "$disk" "$n")" "$role"
}

confirm_serial() { # confirm_serial JSON DISK VERB: type the serial to go on.
  local want reply
  want=$(disk_id "$1")
  ask reply "Type $want to $3: "
  [ "$reply" = "$want" ] && return 0
  echo "That does not match. Leaving $2 alone."
  return 1
}

erase_disk() { # erase_disk DISK: partition table, signatures and, if it can, every block.
  local part
  for part in $(lsblk -nrpo NAME,TYPE "$1" | awk '$2 == "part" {print $1}'); do
    wipefs -q -a -f "$part"
  done
  wipefs -q -a -f "$1"
  if ! blkdiscard -f "$1" 2>/dev/null; then
    warn "$1 does not support discard: old unencrypted data may stay recoverable on it"
  fi
  printf 'label: gpt\n' | sfdisk -q "$1"
  udevadm settle
}

# give_longhorn SIZE USED ROLE: the bytes to reserve so Longhorn keeps to the
# amount chosen here. Printed last, on stdout; prompts go to stderr.
give_longhorn() {
  local size=$1 used=$2 role=$3 free most reply=""
  free=$((size - used))
  [ "$role" != both ] || free=$((free - vm_gib * gib))
  most=$((free / gib))
  while :; do
    {
      echo "$(human "$free") is free next to your data. Longhorn stops placing replicas"
      echo "here once under 25% of this filesystem is free, and may schedule up to 150%"
      echo "of its share in thin volumes, so leave your data room to grow."
    } >&2
    read -r -p "GiB to give Longhorn (1-$most): " reply || reply=""
    case "$reply" in
      '' | *[!0-9]*) ;;
      *)
        if [ "$reply" -ge 1 ] && [ "$reply" -le "$most" ]; then
          echo $((size - reply * gib))
          return 0
        fi
        ;;
    esac
    [ -t 0 ] || return 1
    echo "Enter a whole number from 1 to $most." >&2
  done
}

vm_role_available() {
  [ "$AGENTS_VM" = 1 ] && [ "$AGENTS_VM_ON_DISK" != 1 ] && {
    # Mounting over existing VM disks would hide them.
    [ ! -d "$vm_images" ] || [ -z "$(ls -A "$vm_images")" ]
  }
}

choose_role() { # choose_role VAR AVAILABLE-BYTES [longhorn-only]
  local var=$1 room=$2 only=${3:-} reply="" roles=() i
  [ "$room" -lt $((min_longhorn_gib * gib)) ] || roles+=(longhorn)
  if [ -z "$only" ] && vm_role_available; then
    [ "$room" -lt $((vm_gib * gib)) ] || roles+=(agents-vm)
    [ "$room" -lt $(((vm_gib + 5 + min_longhorn_gib) * gib)) ] || roles+=(both)
  fi
  if [ "${#roles[@]}" = 0 ]; then
    echo "  Not enough room: Longhorn needs ${min_longhorn_gib} GiB and the agents VM ${vm_gib} GiB."
    printf -v "$var" '%s' ""
    return 0
  fi
  if [ "${#roles[@]}" = 1 ]; then
    echo "  Role: ${roles[0]}"
    printf -v "$var" '%s' "${roles[0]}"
    return 0
  fi
  echo "  Use it for:"
  i=1
  for reply in "${roles[@]}"; do
    echo "    $i) $reply"
    i=$((i + 1))
  done
  echo "    Enter) skip"
  ask reply "  Choice: "
  case "$reply" in
    '' | *[!0-9]*) printf -v "$var" '%s' "" ;;
    *)
      if [ "$reply" -ge 1 ] && [ "$reply" -le "${#roles[@]}" ]; then
        printf -v "$var" '%s' "${roles[$((reply - 1))]}"
      else
        printf -v "$var" '%s' ""
      fi
      ;;
  esac
}

# keep_volume JSON DEV FSTYPE: reuse a filesystem, its contents untouched.
keep_volume() {
  local json=$1 dev=$2 fstype=$3 partn name spec only="" role reserved stats size used inner attempts pass
  partn=$(lsblk -nrpo PARTN "$dev" | head -1)
  name=$(volume_name "$json" "$partn")
  if [ "$fstype" = crypto_LUKS ]; then
    attempts=0
    until [ -e "/dev/mapper/hw-$name" ]; do
      attempts=$((attempts + 1))
      [ "$attempts" -le 3 ] || { echo "Leaving $dev alone."; return 0; }
      read -r -s -p "Passphrase of $dev: " pass || pass=""; echo
      printf %s "$pass" | cryptsetup open --key-file=- "$dev" "hw-$name" ||
        { [ -t 0 ] || { echo "Leaving $dev alone."; return 0; }; }
    done
    udevadm settle
    inner=$(blkid -o value -s TYPE "/dev/mapper/hw-$name" || true)
    spec=/dev/mapper/hw-$name
    fstype=$inner
    case "$fstype" in
      ext4 | xfs) ;;
      *)
        echo "$dev holds ${inner:-no filesystem}, not ext4 or XFS. Leaving it alone."
        cryptsetup close "hw-$name"
        return 0
        ;;
    esac
  else
    only=longhorn-only
    spec=UUID=$(blkid -o value -s UUID "$dev")
    echo "  Not encrypted: Longhorn only, whose volumes are encrypted themselves."
  fi
  stats=$(fs_stats "$spec" "$fstype")
  if [ -z "$stats" ]; then
    echo "Could not read $dev. Leaving it alone."
    [ "$only" = longhorn-only ] || cryptsetup close "hw-$name"
    return 0
  fi
  size=${stats% *}
  used=${stats#* }
  choose_role role $((size - used)) "$only"
  if [ -z "$role" ]; then
    [ "$only" = longhorn-only ] || cryptsetup close "hw-$name"
    return 0
  fi
  reserved=0
  if [ "$role" != agents-vm ]; then
    if ! reserved=$(give_longhorn "$size" "$used" "$role"); then
      echo "Leaving $dev alone."
      [ "$only" = longhorn-only ] || cryptsetup close "hw-$name"
      return 0
    fi
  fi
  if [ "$only" != longhorn-only ]; then
    new_key "$name"
    printf %s "$pass" | cryptsetup luksAddKey --key-file=- "$dev" "$keys_dir/hw-$name.key"
    add_crypttab "$name" "$dev"
  fi
  mount_volume "$name" "$spec" "$fstype"
  case "$role" in
    longhorn) use_for_longhorn "$name" "$reserved" ;;
    agents-vm) use_for_vm "$name" ;;
    both)
      use_for_vm "$name"
      use_for_longhorn "$name" "$reserved"
      ;;
  esac
}

# --- the menu ---------------------------------------------------------------
sys=$(system_disks)
log "Disks attached to this node"
index=0
choices=()
while read -r disk; do
  [ -n "$disk" ] || continue
  json=$(tree "$disk")
  [ "$(jq -r '.size' <<<"$json")" -gt 0 ] || continue
  model=$(jq -r '.model // "unknown model"' <<<"$json")
  serial=$(jq -r '.serial // "no serial"' <<<"$json")
  type=$(kind "$json")
  bus=$(jq -r '.tran // "-"' <<<"$json")
  note=""
  if grep -qx "$disk" <<<"$sys"; then
    note="system disk, not selectable"
  elif jq -e '[recurse(.children[]?) | (.mountpoints // [])[] | select(.)]
      | any(startswith("/var/lib/homeworld-disks/"))' <<<"$json" >/dev/null; then
    note="already configured"
  elif in_use "$json"; then
    note="in use, not selectable (unmount it or stop what holds it, then rerun)"
  elif [ "$type" = HDD ]; then
    note="spinning disk, not selectable (SSD/NVMe only; a USB enclosure can misreport an SSD: --treat-as-ssd $(disk_id "$json"))"
  fi
  if [ -z "$note" ]; then
    index=$((index + 1))
    choices+=("$disk")
    printf '%2d) ' "$index"
  else
    printf ' -) '
  fi
  printf '%s  %s  %s  %s  %s / %s\n' "$disk" "$(human "$(jq -r '.size' <<<"$json")")" "$type" "$bus" "$model" "$serial"
  [ -z "$note" ] || echo "      $note"
  [ "$bus" != usb ] || [ -n "$note" ] ||
    echo "      warning: on USB, a brief disconnect can fault every replica on this disk"
  print_contents "$json" "$disk"
done < <(lsblk -dnrpo NAME,TYPE | awk '$2 == "disk" && $1 !~ /\/(zram|ram)[0-9]+$/ {print $1}')

if [ "${#choices[@]}" = 0 ]; then
  echo
  echo "No disk to choose from. Longhorn and the agents VM stay on the root disk."
  exit 0
fi

index=0
for disk in "${choices[@]}"; do
  index=$((index + 1))
  json=$(tree "$disk")
  labels=()
  actions=()
  while IFS=$'\t' read -r dev fstype; do
    case "$fstype" in
      crypto_LUKS) labels+=("Keep the data, unlock $dev and use the free space"); actions+=("keep $dev $fstype") ;;
      *) labels+=("Keep the data, use the free space on $dev ($fstype, not encrypted, Longhorn only)"); actions+=("keep $dev $fstype") ;;
    esac
  done < <(jq -r '[recurse(.children[]?) | select(.fstype == "crypto_LUKS" or .fstype == "ext4" or .fstype == "xfs")]
    | .[] | [.name, .fstype] | @tsv' <<<"$json")
  empty=0
  is_empty "$json" "$disk" && empty=1
  if [ "$empty" = 0 ] && [ "$(jq -r '.pttype // ""' <<<"$json")" = gpt ]; then
    free=$(free_bytes "$disk")
    if [ "$free" -ge $((min_longhorn_gib * gib)) ]; then
      labels+=("Keep the data, add an encrypted partition in the $(human "$free") of free space")
      actions+=("free")
    fi
  fi
  if [ "$empty" = 1 ]; then
    labels+=("Format and encrypt it (LUKS2, XFS)")
  else
    labels+=("ERASE the whole disk, then format and encrypt it (LUKS2, XFS)")
  fi
  actions+=("format")

  log "Disk $index: $disk"
  print_contents "$json" "$disk"
  i=1
  for label in "${labels[@]}"; do
    echo "  $i) $label"
    i=$((i + 1))
  done
  echo "  Enter) skip"
  ask reply "Choice: "
  case "$reply" in
    '' | *[!0-9]*) echo "Skipped."; continue ;;
  esac
  if [ "$reply" -lt 1 ] || [ "$reply" -gt "${#actions[@]}" ]; then
    echo "Skipped."
    continue
  fi
  # shellcheck disable=SC2086 # the action's words
  set -- ${actions[$((reply - 1))]}
  case "$1" in
    keep)
      keep_volume "$json" "$2" "$3"
      ;;
    free)
      choose_role role "$free"
      if [ -z "$role" ]; then
        echo "Skipped."
      elif confirm_serial "$json" "$disk" "add a partition to $disk"; then
        build_on_free "$json" "$disk" "$role"
      fi
      ;;
    format)
      choose_role role "$(jq -r '.size' <<<"$json")"
      if [ -z "$role" ]; then
        echo "Skipped."
        continue
      fi
      if [ "$empty" = 1 ]; then
        echo "$disk looks empty, but data without a known signature looks the same."
      else
        echo "Everything on $disk will be erased:"
        print_contents "$json" "$disk"
      fi
      if ! confirm_serial "$json" "$disk" "erase $disk"; then
        continue
      fi
      # The disk may have changed since the menu was drawn.
      json=$(tree "$disk")
      if in_use "$json" || grep -qx "$disk" <<<"$sys"; then
        echo "$disk is in use now. Leaving it alone."
        continue
      fi
      recovery_passphrase
      erase_disk "$disk"
      build_on_free "$(tree "$disk")" "$disk" "$role"
      ;;
  esac
done

log "Done"
if [ -n "$LONGHORN_DISKS$STORAGE_MOUNTS" ]; then
  echo "Back up each new LUKS header offline (docs/fedora.md):"
  echo "  cryptsetup luksHeaderBackup <partition> --header-backup-file <node>-<partition>-luks-header.img"
fi
if [ -x /usr/local/bin/k3s ] && [ -n "$LONGHORN_DISKS" ]; then
  echo "Longhorn reads its disk annotation only for a node with no disks yet. On a"
  echo "node that already has one, add the path to the Longhorn Node (docs/k3s.md)."
fi
