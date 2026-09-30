# Velero B2 backups
Velero creates a whole-cluster backup every day at 03:00 Europe/Lisbon. The B2
backup location is `https://s3.${B2_REGION}.backblazeb2.com`, storing data in
`${B2_BUCKET}` under the `velero` prefix. Backups expire after 30 days, retaining
30 daily restore points. The `velero` namespace itself is excluded from the
schedule — the Velero/B2 configuration is fully declarative and restores from
git plus Infisical, so backing up the backup operator adds nothing. Volume data
moves through CSI snapshot data-mover pods (one per DataUpload/DataDownload,
labeled `velero.io/data-upload`/`velero.io/data-download`), which carry their
own kube-apiserver and B2 egress policies.

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
without a coordinated repository migration. A restore requires B2 access using
the same application key and repository password, plus a target cluster with
Velero, the AWS plugin, CSI snapshot APIs, and the Longhorn CSI driver installed.