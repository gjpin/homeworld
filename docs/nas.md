# NAS (OpenMediaVault NFS)

The NAS (`192.168.8.20`, a Raspberry Pi running Raspberry Pi OS and
OpenMediaVault on a btrfs RAID10 filesystem) is the cluster's only bulk
storage. Node disks hold Longhorn's small application volumes; the photo
library, the OpenCloud users' files and the torrent downloads live on the NAS
over NFSv4.1 through [csi-driver-nfs](https://github.com/kubernetes-csi/csi-driver-nfs).

## Shares

One shared folder and one NFS export per app, each owned by a dedicated
numeric ID:

| Share | Owner (UID:GID) | Snapshots | Claim |
| --- | --- | --- | --- |
| `homeworld-immich` | `20001:20001` | yes | `immich/photos` |
| `homeworld-opencloud` | `20002:20002` | yes | `opencloud/opencloud-users` |
| `homeworld-qbittorrent` | `20003:20003` | no | `qbittorrent/qbittorrent-downloads` |

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
copies. The downloads share is not snapshotted.

## Off-site backups

The btrfs snapshots share the NAS's disks; restic copies the Immich and
OpenCloud shares nightly to Backblaze B2, encrypted on the NAS before upload
(restic encrypts every repository with AES-256 under its password). The NAS
backs itself up rather than going through the cluster, so a restore needs
neither a running cluster nor Velero. The downloads share is not backed up.

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
for share in homeworld-immich homeworld-opencloud; do
  snap="$STAGE/$share"
  # A run that failed midway leaves its snapshot behind.
  if [ -d "$snap" ]; then btrfs subvolume delete "$snap"; fi
  btrfs subvolume snapshot -r "$POOL/$share" "$snap"
  restic backup --host nas --tag "$share" --exclude-file /etc/restic/excludes "$snap"
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
