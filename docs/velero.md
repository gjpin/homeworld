# Velero B2 backups
Velero creates a whole-cluster backup every day at 22:00 Europe/Lisbon, clear
of the nightly k3s-upgrade and reboot windows
([upgrades.md](upgrades.md#6-platform-upgrades-k3s-fedora-host-components-agents-vm)). The B2
backup location is `https://s3.eu-central-003.backblazeb2.com`, storing data in
`homeworld-velero` under the `velero` prefix, with `checksumAlgorithm: ""` as the
AWS plugin's README requires for B2. Backups expire after 30 days, retaining
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
would otherwise fail those claims; the NAS snapshots its own shares and
backs them up to B2 with restic ([nas.md](nas.md#off-site-backups)). Their
Kubernetes objects (PersistentVolumes and claims) are still backed up.

## Pre-upgrade backups

Before an upgrade of a stateful component is merged,
`scripts/pre-upgrade-backup.sh <namespace>...` checks for a `Completed`
backup covering each namespace that finished within the last hour. When
there is none, it creates a `Backup` named `pre-upgrade-<namespace>-<UTC
timestamp>` (label `homeworld/pre-upgrade: "true"`) whose spec is the
`velero-daily` schedule's template narrowed to those namespaces: the same
volume policy, snapshot data movement to B2, and 30-day expiry. It waits for
the backup to complete and fails on any other outcome, so the upgrade is not
merged without it. Restore it like a nightly backup.

## Database-native volume-snapshot backups

Velero is the only scheduled backup of the databases: its nightly copy of
each CloudNativePG and MariaDB volume is crash-consistent, which both engines
recover from on start. The databases additionally take **pre-upgrade volume
snapshots**, which are rollback points rather than independent copies (they
live inside the same Longhorn volume, on each of its three replicas):

* CloudNativePG: an on-demand `Backup` with `method: volumeSnapshot`, taken
  by hand before a major upgrade
  ([upgrades.md](upgrades.md#before-merging-a-major-upgrade)), against the
  dedicated `cnpg-longhorn` VolumeSnapshotClass
  (`apps/cloudnative-pg/0_snapshot_class.yaml`, `deletionPolicy: Delete`,
  `parameters.type: snap`). Each Cluster sets `snapshotOwnerReference:
  backup`, so deleting the `Backup` deletes its `VolumeSnapshot` and the
  Longhorn snapshot.
* MariaDB (Supernote): a `PhysicalBackup` taken by an Argo CD PreSync hook
  before every sync of the application (`apps/supernote/0_pre_sync_backup.yaml`,
  [upgrades.md](upgrades.md#8-mariadb-engine-upgrades-mariadb-operator)),
  against the dedicated `mariadb-longhorn` VolumeSnapshotClass
  (`apps/mariadb-operator/0_snapshot_class.yaml`, `deletionPolicy: Delete`,
  `parameters.type: snap`), consistent because the operator holds
  `FLUSH TABLES WITH READ LOCK` while the snapshot is cut. The operator
  prunes only scheduled backups, and an unscheduled one snapshots only while
  no snapshot carries its name label, so a rotation Job runs first in the
  same phase (`apps/supernote/-1_pre_sync_snapshot_rotation.yaml`): it
  deletes the previous hook CR, moves the existing `mariadb-pre-sync-*`
  VolumeSnapshots off the operator's label, and keeps the newest seven.

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