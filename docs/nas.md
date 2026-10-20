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
these snapshots are their only point-in-time copies. The downloads share is
not snapshotted.

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
