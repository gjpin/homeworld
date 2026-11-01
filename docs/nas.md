# NAS (OpenMediaVault NFS)

The NAS (`192.168.8.20`, a Raspberry Pi running Raspberry Pi OS and
OpenMediaVault on a btrfs RAID10 filesystem) is the cluster's only bulk
storage. Node disks hold Longhorn's small application volumes; the photo
library, the OpenCloud users' files and the media library with its torrents live on the NAS
over NFSv4.1 through [csi-driver-nfs](https://github.com/kubernetes-csi/csi-driver-nfs).

## Hardware setup

The disks hang off a Radxa Penta SATA HAT on the Raspberry Pi 5's PCIe
connector. Before installing OpenMediaVault, enable the PCIe x1 port at
Gen 3, turn off the unused Wi-Fi and Bluetooth radios, load the
32-bit DMA overlay the HAT's SATA controller needs on the Pi 5, and let
the kernel drive the external fan
(references:
[raspberry-pi-pcie-devices#615](https://github.com/geerlingguy/raspberry-pi-pcie-devices/issues/615),
[Radxa Penta SATA HAT for Raspberry Pi 5](https://docs.radxa.com/en/accessories/storage/penta-sata-hat/penta-for-rpi5)).

The fan's PWM line is GPIO 27, active-high, as in Radxa's own Pi 5
configuration
([`rpi5.env`](https://github.com/radxa/rockpi-penta/blob/master/rockpi-penta/usr/bin/rockpi-penta/env/rpi5.env)).
The firmware's
[`pwm-gpio-fan`](https://github.com/raspberrypi/linux/blob/rpi-6.12.y/arch/arm/boot/dts/overlays/README)
overlay steps it through 45, 60, 80 and 100 % at CPU temperatures of 55,
60, 67.5 and 75 °C (5 °C hysteresis; tune with `fan_temp0`–`fan_temp3` and
`fan_temp0_speed`–`fan_temp3_speed`). It replaces Radxa's `rockpi-penta`
package, whose fan service targets libgpiod v1 and fails on the Pi 5's
Raspberry Pi OS; do not install both.

```bash
# On the NAS:
f=/boot/firmware/config.txt
changed=
for line in dtparam=pciex1 dtparam=pciex1_gen=3 \
  dtoverlay=disable-wifi dtoverlay=disable-bt dtoverlay=pcie-32bit-dma-pi5 \
  dtoverlay=pwm-gpio-fan,fan_gpio=27; do
  grep -qxF "$line" "$f" && continue
  # Append under an [all] filter, opening one unless the last section already is.
  [ "$(grep '^\[' "$f" | tail -n 1)" = '[all]' ] ||
    echo '[all]' | sudo tee -a "$f" >/dev/null
  echo "$line" | sudo tee -a "$f" >/dev/null
  changed=1
done
[ -z "$changed" ] || sudo reboot
```

The script appends only the missing lines and reboots only when it changed
something, so it is safe to re-run. A line that already sits under a
narrower filter (for example `[cm5]`) counts as present; move it under
`[all]` by hand. After the reboot, `lsblk` lists every disk on the HAT.

## Shares

One shared folder and one NFS export per app, each owned by a dedicated
numeric ID. The exception is `homeworld-media`, shared by the whole media
stack ([Media share](#media-share)):

| Share | Owner (UID:GID) | Snapshots | Claim |
| --- | --- | --- | --- |
| `homeworld-immich` | `20001:20001` | yes | `immich/photos` |
| `homeworld-opencloud` | `20002:20002` | yes | `opencloud/opencloud-users` |
| `homeworld-media` | `20004:20004` | no (restic copies `media/books` and `media/audiobooks`) | `media` in each media-stack namespace ([Media share](#media-share)) |

In OpenMediaVault:

1. **Users → Groups / Users**: create a group and a user per share with the
   IDs above (for example `homeworld-immich` with UID and GID `20001`), no
   login shell.
2. **Storage → Shared Folders**: create each share on the btrfs filesystem,
   then on the NAS shell set its root to the owner with the setgid bit:
   `chown 20001:20001 <path>` and `chmod 2770 <path>`.
3. **Services → NFS → Settings**: enable NFS with versions 4.1 and 4.2
   only.
4. **Services → NFS → Shares**: one entry per share and node address
   (`192.168.8.10`, `.11`, `.12`), each with
   `rw,sync,no_subtree_check,all_squash,anonuid=<ID>,anongid=<ID>,sec=sys`.
   Never `no_root_squash`.
5. Apply the pending configuration (the UI's apply button, or
   `omv-salt deploy run fstab nfs`), then check `exportfs -v`.

Clients mount through the NFSv4 pseudo-root, so the path a node sees is
`192.168.8.20:/homeworld-<app>`:

```bash
# From a node:
sudo mount -t nfs -o nfsvers=4.1 192.168.8.20:/homeworld-immich /mnt
sudo touch /mnt/probe && ls -ln /mnt/probe   # owned by 20001:20001
sudo rm /mnt/probe && sudo umount /mnt
```

`all_squash` maps every client UID, root included, to the share's owner.
gVisor's gofer opens and chowns files on the host as root, which
`root_squash` would break; with `sec=sys` node root was never kept out by
`root_squash` anyway, and one export per app keeps each app to its own
share.

Snapshot the Immich and OpenCloud shares on the NAS (btrfs read-only
snapshots of the shared folder, on a schedule): Velero skips NFS volumes, so
these snapshots and the restic backups below are their only point-in-time
copies. The media share is not snapshotted: films, series and music can
be fetched again, and snapshots of a churning torrent tree would pin
deleted data.

## Off-site backups

The btrfs snapshots share the NAS's disks; restic copies the Immich and
OpenCloud shares nightly to Backblaze B2, encrypted on the NAS before upload
(restic encrypts every repository with AES-256 under its password). The NAS
backs itself up rather than going through the cluster, so a restore needs
neither a running cluster nor Velero. Of the media share only the books
and audiobooks are backed up: they are small and hard to fetch again.

### B2 bucket and key

1. Create a private bucket `homeworld-nas` in `eu-central-003` (the Velero
   region), separate from `homeworld-velero`, with bucket-default SSE-B2.
2. Set its lifecycle to keep only the last version of each file: restic
   deletes pack files itself during `prune`, and B2 would otherwise keep the
   hidden versions forever.
3. Create an application key limited to `homeworld-nas` with list, read,
   write, and delete permissions.

### Restic on the NAS

Install restic (`sudo apt install restic`) and create its configuration as
root:

```bash
sudo install -d -m 0700 /etc/restic
openssl rand -base64 32 | sudo tee /etc/restic/password >/dev/null
sudo chmod 0600 /etc/restic/password
sudo tee /etc/restic/homeworld.env >/dev/null <<'ENV'
RESTIC_REPOSITORY=s3:https://s3.eu-central-003.backblazeb2.com/homeworld-nas
RESTIC_PASSWORD_FILE=/etc/restic/password
RESTIC_CACHE_DIR=/var/cache/restic
AWS_ACCESS_KEY_ID=<B2 key ID>
AWS_SECRET_ACCESS_KEY=<B2 application key>
ENV
sudo chmod 0600 /etc/restic/homeworld.env
```

The password is the only way to decrypt the repository: store a copy in
Infisical as `/nas/RESTIC_PASSWORD` (nothing in the cluster reads it;
Infisical is off-site) and another offline next to the CA key backups, then
initialize the repository:

```bash
sudo sh -c 'set -a; . /etc/restic/homeworld.env; restic init'
```

Each run backs up a temporary read-only btrfs snapshot of each share, so
files changing during the upload cannot produce an inconsistent copy. The
OpenMediaVault shared folders are btrfs subvolumes under the data
filesystem's mount point (`/srv/dev-disk-by-uuid-<UUID>`, shown under
**Storage → File Systems**). `/usr/local/sbin/homeworld-restic` (mode
`0700`):

```sh
#!/bin/sh
set -eu
POOL=/srv/dev-disk-by-uuid-<UUID>
STAGE="$POOL/.restic"
mkdir -p "$STAGE"
for share in homeworld-immich homeworld-opencloud homeworld-media; do
  snap="$STAGE/$share"
  # A run that failed midway leaves its snapshot behind.
  if [ -d "$snap" ]; then btrfs subvolume delete "$snap"; fi
  btrfs subvolume snapshot -r "$POOL/$share" "$snap"
  if [ "$share" = homeworld-media ]; then
    # Only the books and audiobooks; the rest can be fetched again.
    restic backup --host nas --tag "$share" "$snap/media/books" "$snap/media/audiobooks"
  else
    restic backup --host nas --tag "$share" --exclude-file /etc/restic/excludes "$snap"
  fi
  btrfs subvolume delete "$snap"
done
restic forget --host nas --group-by host,tags \
  --keep-daily 7 --keep-weekly 4 --keep-monthly 12
# Sundays: drop unreferenced data and re-read a sample of the repository.
if [ "$(date +%u)" = 7 ]; then
  restic prune
  restic check --read-data-subset=5%
fi
```

`/etc/restic/excludes` leaves out what Immich regenerates from the originals
(thumbnails and transcoded videos), which keeps the repository close to the
size of the library itself:

```
/srv/dev-disk-by-uuid-<UUID>/.restic/homeworld-immich/thumbs
/srv/dev-disk-by-uuid-<UUID>/.restic/homeworld-immich/encoded-video
```

Immich's own database dumps land in the share's `backups/` folder, so they
travel with the photos.

Schedule it with systemd. `/etc/systemd/system/homeworld-restic.service`:

```ini
[Unit]
Description=Back up the NAS shares to Backblaze B2
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
EnvironmentFile=/etc/restic/homeworld.env
CacheDirectory=restic
ExecStart=/usr/local/sbin/homeworld-restic
Nice=10
IOSchedulingClass=idle
```

`/etc/systemd/system/homeworld-restic.timer`:

```ini
[Unit]
Description=Nightly NAS backup to Backblaze B2

[Timer]
OnCalendar=*-*-* 03:30 Europe/Lisbon
Persistent=true

[Install]
WantedBy=timers.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now homeworld-restic.timer
sudo systemctl start homeworld-restic.service   # first run; uploads everything
journalctl -u homeworld-restic.service          # result of the last run
```

03:30 is after Immich's nightly database dump. The first upload sends the
whole library; later runs send only changed data.

### Restore

```bash
sudo sh -c 'set -a; . /etc/restic/homeworld.env
  restic snapshots --tag homeworld-immich
  restic restore latest --host nas --tag homeworld-immich \
    --target /srv/dev-disk-by-uuid-<UUID>/.restore'
```

Restore onto the data filesystem (the SD card cannot hold a library).
Snapshots hold the staging path, so the files land under
`.restore/srv/dev-disk-by-uuid-<UUID>/.restic/homeworld-immich/`. Move
them into the share and restore its ownership (`chown -R 20001:20001`, the
share's ID from the table above). Immich regenerates the excluded
thumbnails and videos from its admin jobs page.

## Media share

`homeworld-media` holds the whole media stack's data in one filesystem, in
the TRaSH-guides layout:

```
/data/torrents/{tv,movies,music,books,audiobooks}   qBittorrent categories
/data/media/{tv,movies,music,books,audiobooks,podcasts}   libraries
/data/jellyfin/metadata   Jellyfin's artwork, trickplay and chapter images
```

Sonarr, Radarr and Bindery import a finished download by hardlinking it
from `torrents/` into `media/`, so a file costs its space once and keeps
seeding. Lidarr copies instead: beets retags the music library in place,
and retagging a hardlink would change the data the torrent seeds, so music
takes its space twice until qbit_manage removes the seeded torrent. Hardlinks and renames only work inside one filesystem, so:

- `torrents/` and `media/` are plain directories in the one shared folder.
  Never make them separate shared folders: each OpenMediaVault shared
  folder is a btrfs subvolume, and a hardlink cannot cross subvolumes.
- Every writer (qBittorrent, Sonarr, Radarr, Lidarr, Bindery, Unpackerr,
  qbit_manage) mounts its claim once at `/data`: two mounts of the same export are two
  filesystems to the kernel, and a hardlink between them fails with `EXDEV`.
- Every pod sees the same paths, so no remote path mappings are needed.

The whole stack runs as the share's owner, `20004`. A PersistentVolume
binds a single claim, so each consuming namespace has its own static PV
(`homeworld-media-<app>`, all pointing at the same export, each with a
unique `volumeHandle`). Navidrome gets a read-only PV. Jellyfin mounts
`media/` read-only and `jellyfin/metadata` read-write, so its metadata
grows on the NAS instead of its Longhorn config volume (its database stays
there); it needs no backup, since Jellyfin rebuilds it from the media and
its metadata providers. Audiobookshelf mounts its audiobooks read-only and
its podcasts read-write. beets mounts `media/music` read-write (it tags the
files in place and creates no links).

Create the directories once after creating the share:

```bash
# On the NAS:
cd <path of homeworld-media>
install -d -o 20004 -g 20004 -m 2770 \
  torrents torrents/tv torrents/movies torrents/music torrents/books torrents/audiobooks \
  media media/tv media/movies media/music media/books media/audiobooks media/podcasts \
  jellyfin jellyfin/metadata
```

Check hardlinks from a cluster pod before the first import: in a pod that
mounts the share at `/data` (any of the writers),
`touch /data/torrents/t && ln /data/torrents/t /data/media/t && stat -c %h /data/torrents/t`
prints `2`; remove both files afterwards. Most writers run under gVisor,
whose gofer performs the link, so the check covers the sandbox too.

## Firewall

Only the nodes may reach NFS. With nftables on the NAS
(`/etc/nftables.conf`, `systemctl enable --now nftables`), adding rules for
any other service the NAS offers:

```
table inet filter {
  chain input {
    type filter hook input priority filter; policy drop;
    ct state established,related accept
    iif lo accept
    ip protocol icmp accept
    ip saddr 192.168.8.0/24 tcp dport { 22, 80, 443 } accept
    ip saddr { 192.168.8.10, 192.168.8.11, 192.168.8.12 } tcp dport 2049 accept
  }
}
```

## Kubernetes side

- Each share is a **static** `PersistentVolume` (`Retain`, `storageClassName:
  ""`) mounted by IP (`192.168.8.20`) with `nfsvers=4.1`, bound to its claim
  by `volumeName`. Deleting the claim keeps the data.
- The `nfs.csi.k8s.io` CSIDriver has `fsGroupPolicy: None`, so kubelet never
  walks a share to chown it; only the node plugin DaemonSet runs (static PVs
  need no controller).
- Pods mounting a share run as its owner (`runAsUser`/`runAsGroup` = the
  share ID) and keep `hostUsers: true`: NFS has no idmapped mounts.
- SELinux: NFS files keep their `nfs_t` label (the CSI driver drops
  `context=` mount options); confined containers reach them through the
  `virt_use_nfs` boolean, which apply.sh keeps on.
- Velero skips every `nfs.csi.k8s.io` volume through its volume policy
  ([docs/velero.md](velero.md)).
