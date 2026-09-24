# OpenCloud

OpenCloud provides file sync, sharing, web office integration, and collaborative document editing.

## Storage Architecture

* `opencloud-config` (5 GiB, `longhorn-crypto`, RWO): Mounted at `/etc/opencloud` for generated configuration (`opencloud.yaml`) and backups.
* `opencloud-data` (100 GiB, `longhorn-crypto`, RWO): Mounted at `/var/lib/opencloud` for persistent user state, local metadata, and upgrade markers.
* Workload storage uses the `decomposeds3` driver backed by RustFS S3 (`rustfs-io.rustfs.svc.cluster.local:9000`).

## Upgrades & Maintenance Automation

OpenCloud upgrades require two post-update steps:
1. Verifying and applying configuration changes (`opencloud init --diff` and `patch`).
2. Re-indexing all spaces in the search engine (`opencloud search index --all-spaces --force-rescan --insecure`).

Both steps are automated through `entrypoint.sh` (provided via the `opencloud-config-files` ConfigMap):

* **Config verification & migration:** Runs on container boot before `opencloud server` starts. If new configuration keys are required by the updated version, `opencloud init --diff` generates a patch, validates it with a dry-run, backs up `/etc/opencloud/opencloud.yaml` with a timestamp, and applies the patch cleanly.
* **Persistent version tracking:** The binary version or checksum is stored in `/var/lib/opencloud/.installed_version`. If a version bump or config change occurs, an upgrade flag is set.
* **Asynchronous search re-indexing:** When an upgrade is detected (or if `/var/lib/opencloud/.reindex_in_progress` is present from an interrupted run), a background task waits until `http://127.0.0.1:9200/health` returns healthy, allows 15s for internal microservices to register, and executes `opencloud search index --all-spaces --force-rescan --insecure`. On success, the marker is cleared and `.installed_version` is updated. Routine restarts without version changes skip re-indexing.

## Manual Commands & Recovery

If manual intervention or maintenance is required:

* **View re-indexing progress:**
  ```bash
  kubectl logs -n opencloud deploy/opencloud -c opencloud -f | grep -E '\[reindex\]|\[upgrade\]|\[init\]'
  ```
* **Trigger manual re-indexing:**
  ```bash
  kubectl exec -n opencloud deploy/opencloud -c opencloud -- opencloud search index --all-spaces --force-rescan --insecure
  ```
* **Restore previous configuration backup:**
  Timestamped backups are stored under `/etc/opencloud/opencloud.yaml.<timestamp>.bak`.
