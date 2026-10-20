# Velero B2 backups
Velero creates a whole-cluster backup every day at 22:00 Europe/Lisbon, clear
of the database snapshots and the nightly k3s-upgrade and reboot windows
([upgrades.md](upgrades.md#6-platform-upgrades-k3s-fedora-host-components-agents-vm)). The B2
backup location is `https://s3.eu-central-003.backblazeb2.com`, storing data in
`homeworld-velero` under the `velero` prefix. Backups expire after 30 days, retaining
30 daily restore points. The `velero` namespace itself is excluded from the
schedule — the Velero/B2 configuration is fully declarative and restores from
git plus Infisical, so backing up the backup operator adds nothing.

Volume data moves through **CSI snapshot data movement**: the CSI plugin
(`features: EnableCSI`, `defaultSnapshotMoveData`) creates a `VolumeSnapshot`
per backed-up PVC using the `longhorn` VolumeSnapshotClass
(`apps/velero/0_snapshot_class.yaml`, labeled `velero.io/csi-volumesnapshot-class:
"true"`); the snapshot-controller (`apps/snapshot-controller`, wave 3 ahead of
Velero, with the CSI snapshot CRDs applied from the pinned upstream Git tag)
drives the Longhorn CSI driver to realize the snapshot; the node-agent then
uploads the snapshot contents to the B2 backup location through data-mover
pods (one per DataUpload/DataDownload, labeled `velero.io/data-upload`/
`velero.io/data-download`), which carry their own kube-apiserver and B2 egress
policies, and the transient CSI snapshot is deleted afterwards
(`deletionPolicy: Delete`). Kopia remains the uploader format for the backup
repository. The class pins `parameters.type: snap` — the Longhorn CSI driver
treats an empty type as `bak` (a Longhorn backup needing a backup target this
cluster does not have), which would fail every Velero snapshot.

The data mover reads each snapshot through a temporary clone volume. The
node-agent configuration (`velero-node-agent-config`) puts those clones on the
encrypted single-replica `longhorn-scratch` class instead of the three-replica
`longhorn-crypto`, so a backup costs one extra copy of each volume while it
runs, not three.

NFS volumes (the NAS shares, [nas.md](nas.md)) are skipped: the `velero-volume-policy`
ConfigMap, referenced by the schedule's `resourcePolicy`, skips every
`nfs.csi.k8s.io` volume. No NFS VolumeSnapshotClass exists, so the CSI plugin
would otherwise fail those claims; the NAS snapshots its own shares. Their
Kubernetes objects (PersistentVolumes and claims) are still backed up.

## Database-native volume-snapshot backups

Every CloudNativePG cluster also takes a **daily 23:30 UTC volume-snapshot
backup** (a `ScheduledBackup` with `method: volumeSnapshot` in each
component's `1_scheduled_backup.yaml`; CloudNativePG schedules take six
fields with seconds first and run in UTC only, so the schedule is
`0 30 23 * * *`) against the dedicated
`cnpg-longhorn` VolumeSnapshotClass (`apps/cloudnative-pg/0_snapshot_class.yaml`,
`deletionPolicy: Delete`, `parameters.type: snap`). Volume-snapshot backups
give the databases a same-day in-cluster restore point independent of Velero
and B2. A volume snapshot lives inside the same Longhorn volume (on each of
its three replicas): it is a point-in-time rollback, not an independent copy,
and Velero/B2 remains the disaster-recovery path. CloudNativePG keeps no
retention for volume-snapshot backups, so the `backup-pruner` CronJob
(`apps/cloudnative-pg/1_backup_pruner.yaml`, daily at 12:00 Europe/Lisbon)
deletes scheduled `Backup` objects older than seven days; their
`VolumeSnapshots` and the Longhorn snapshot contents are garbage-collected
with them (`snapshotOwnerReference: backup` on each Cluster). Backups taken
by hand are never pruned.

The MariaDB instance (Supernote) mirrors this with the MariaDB Operator's
`PhysicalBackup`: a **daily 00:00 Europe/Lisbon volume snapshot**
(`apps/supernote/1_physical_backup.yaml`) against the dedicated
`mariadb-longhorn` VolumeSnapshotClass (`apps/mariadb-operator/0_snapshot_class.yaml`,
`deletionPolicy: Delete`, `parameters.type: snap`), consistent because the
operator holds `FLUSH TABLES WITH READ LOCK` while the snapshot is cut, plus a
pre-upgrade snapshot taken by a PreSync hook before every sync of the
application (see [upgrades.md](upgrades.md#8-mariadb-engine-upgrades-mariadb-operator)).
Unlike CNPG, retention is built in: `maxRetention: 168h` makes the operator
delete each schedule's snapshots older than seven days after every successful
one. The same in-volume caveat applies.

Before syncing Velero, create a dedicated Backblaze B2 application key limited
to the backup bucket with list, read, write, and delete permissions. Enable
bucket-default SSE-B2, and configure the bucket lifecycle to permanently delete
hidden object versions one day after Velero deletes them. B2 versions objects by
default, so this prevents expired backups from accumulating indefinitely.

Create the following Infisical values before the first Velero backup:

* `/velero/B2_APPLICATION_KEY_ID`
* `/velero/B2_APPLICATION_KEY`
* `/velero/KOPIA_REPOSITORY_PASSWORD`

`KOPIA_REPOSITORY_PASSWORD` encrypts the Kopia repository and must remain
recoverable for restores. Do not rotate it after the repository is initialized
without a coordinated repository migration. A restore requires B2 access using the same application key and repository
password, plus a target cluster with Velero, the AWS plugin, the CSI snapshot
APIs and snapshot-controller, and the Longhorn CSI driver installed.