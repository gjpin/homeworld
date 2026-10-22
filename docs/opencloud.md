# OpenCloud

OpenCloud provides file sync, sharing, web office integration, and collaborative document editing.

## Storage Architecture

* `opencloud-config` (128 MiB, `longhorn-crypto`, RWO): Mounted at `/etc/opencloud` for generated configuration (`opencloud.yaml`) and backups.
* `opencloud-data` (2 GiB, `longhorn-crypto`, RWO): Mounted at `/var/lib/opencloud` for the service state (NATS, the search index, IDM, thumbnails) and upgrade markers.
* `opencloud-users` (the NAS share `homeworld-opencloud`, NFS, [nas.md](nas.md)): Mounted at `/var/lib/opencloud/storage/users`, the users storage root of the POSIX `decomposed` driver (`STORAGE_USERS_DRIVER=decomposed`, `STORAGE_USERS_DECOMPOSED_ROOT`). The server pod runs as the share's owner, UID/GID `20002`, and Velero skips the share; the NAS snapshots it.

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

## Identity & integrations

* **OIDC sign-in:** OpenCloud authenticates through Authelia as the four clients `web`, `OpenCloudDesktop`, `OpenCloudAndroid`, `OpenCloudIOS`; access requires membership in one of the `opencloud-admin`, `opencloud-spaceadmin`, `opencloud-user`, or `opencloud-user-light` groups (the `opencloud` authorization policy; see [oidc.md](oidc.md) and the inline deviation notes in `apps/authelia/helm/configuration.yaml.tmpl`).
* **WOPI office editing:** Collabora (office.`homeworld.internal`) serves document editing through OpenCloud's WOPI callbacks; the Collabora WOPI allow-list is the `aliasgroups` host `https://cloud.homeworld.internal:443`.
* **CalDAV/CardDAV:** OpenCloud's authenticated DAV proxy forwards calendar and contact requests to the internal Radicale server (`radicale:5232`) — clients never reach Radicale directly.
* **Full-text search:** the `opencloud-tika` sidecar (Apache Tika on `:9998`) extracts text from documents for search indexing.
* **Collaborative editing (yjs):** the `yjs` sidecar (WebSocket relay on `127.0.0.1:1234`) serves the `/yjs` route through the internal proxy, scoped to the pod.
* **Web extensions:** the web-extension init containers fetch and install OpenCloud's web assets (`apps/opencloud/1_deployments.yaml` web-extensions path) into the served tree at startup.

## Not configured

- **Outbound email:** no SMTP environment is set, so share-invitation emails are not sent — invitations surface in-app instead. Add SMTP settings to the OpenCloud deployment if email delivery is ever needed.
