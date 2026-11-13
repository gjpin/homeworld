# Application Upgrades & Migrations

This document details upgrade automation, database migration procedures, and version-stepping requirements across the cluster.

---

## 1. Automated Major Database Upgrades (CloudNativePG)

All PostgreSQL databases (`affine`, `authelia`, `coder`, `forgejo`,
`homeassistant`, `immich`, `vaultwarden`, `woodpecker`) run on **CloudNativePG** (CNPG). Each
`apps/<app>/0_postgres.yaml` pins `spec.imageName`, which Renovate tracks:

* `ghcr.io/cloudnative-pg/postgresql:<major>.<minor>-system-<debian>` (every
  cluster except Immich). Two Renovate managers read this one line. The
  docker manager treats `-system-<debian>` as a fixed compatibility suffix
  and proposes PostgreSQL updates on the same Debian release. A second
  manager (`cloudnative-pg-debian-release`) proposes Debian release moves
  (see [Debian Release Moves](#debian-release-moves)). A PR never changes both
  at once.
* `ghcr.io/tensorchord/cloudnative-vectorchord:<major>.<minor>-<vectorchord>`
  (Immich). A dedicated `regex:` versioning rule in `renovate.json` parses
  the VectorChord suffix as part of the version. The tags do not name the
  Debian release, so upstream's Debian moves arrive inside ordinary updates.

### Minor Version Updates (e.g. 18.1 → 18.2)
* **Execution:** Rolling update.
* **Process:** The CNPG operator restarts the instance pod on the new image. With `instances: 1`, the database is briefly unavailable while the pod restarts.

### Major Version Upgrades (e.g. 18 → 19)
* **Execution:** Declarative offline in-place `pg_upgrade` managed entirely by the CNPG operator.
* **Automation Workflow:**
  1. Renovate opens a dedicated major version PR for `imageName` in `0_postgres.yaml` (`separateMultipleMajor` keeps each major in its own PR; the PR is never automerged).
  2. Merging the PR commits the new major version tag into Git, which Argo CD syncs to the cluster.
  3. The CNPG operator compares the new image with the major version recorded in `.status.pgDataImageInfo` and shuts down every instance pod.
  4. The operator runs a `<cluster>-major-upgrade` Job that executes `pg_upgrade --link` against the existing `PGDATA` volume.
  5. Upon success, the operator restarts the cluster on the new major version. Replicas (if configured) are re-cloned from the upgraded primary.
* **Downtime:** The upgrade is *offline*: the whole cluster is unavailable to the application until the Job finishes.

### Before Merging a Major Upgrade

1. **Take an on-demand backup.** CNPG recommends a full backup immediately
   before the upgrade. The nightly Velero copy may be up to a day old and is
   only crash-consistent.
   Create a CNPG volume-snapshot `Backup` and wait for it to complete:

   ```bash
   kubectl apply -f - <<YAML
   apiVersion: postgresql.cnpg.io/v1
   kind: Backup
   metadata:
     name: <cluster>-pre-major-upgrade
     namespace: <namespace>
   spec:
     cluster:
       name: <cluster>
     method: volumeSnapshot
   YAML
   kubectl -n <namespace> wait backup/<cluster>-pre-major-upgrade \
     --for=jsonpath='{.status.phase}'=completed --timeout=15m
   ```

   Point-in-time recovery does not cross major versions. This backup is the
   only way back once the upgrade Job has succeeded.
2. **Check the Debian release.** CNPG only supports major upgrades between
   images on the same operating system release (e.g. no `bookworm` →
   `trixie` during `pg_upgrade`). The `-system-<debian>` suffix guarantees this
   for the `cloudnative-pg/postgresql` images. For Immich, compare the
   `org.opencontainers.image.base.name` label of the current and target
   `cloudnative-vectorchord` images. If they differ, do not merge:
   `pg_upgrade` would fail. Wait until Immich is on a current-major tag built
   on the target's Debian release.
3. **Check extensions.** CNPG is not responsible for extensions: each one
   must be available in the target image for the new major version. For
   Immich, the target `cloudnative-vectorchord` image must ship VectorChord
   in a version within Immich's supported range.

### If the Upgrade Job Fails

No data is modified until `pg_upgrade` succeeds. Revert the Renovate PR's
commit: Argo CD syncs the previous `imageName`, and the operator deletes the
failed Job and restarts the cluster on the original version. Inspect the
Job's logs (`kubectl -n <namespace> logs job/<cluster>-major-upgrade`)
before retrying.

### After a Successful Major Upgrade

1. **Refresh optimizer statistics.** `pg_upgrade` carries over most planner
   statistics from PostgreSQL 18 onward, but not extended statistics. Fill in
   the gaps:

   ```bash
   kubectl -n <namespace> exec -c postgres \
     "$(kubectl -n <namespace> get pod -o name \
       -l cnpg.io/cluster=<cluster>,cnpg.io/instanceRole=primary)" -- \
     vacuumdb --all --analyze-in-stages --missing-stats-only
   ```

2. **Update extensions.** `pg_upgrade` keeps each extension at its installed
   version. List lagging extensions with
   `SELECT name, installed_version, default_version FROM pg_available_extensions WHERE installed_version <> default_version;`
   and run `ALTER EXTENSION <name> UPDATE;` in the affected database.
3. **Take a new backup.** Create another on-demand `Backup` (as above, with a
   `-post-major-upgrade` name) so a restore point exists on the new major
   version, then prune the pre-upgrade `Backup` once the application is
   healthy.

### Debian Release Moves

Debian release moves are automated for the `cloudnative-pg/postgresql`
images. The `cloudnative-pg-debian-release` custom manager in `renovate.json`
reads the `-system-<debian>` suffix with Renovate's `debian` versioning and
looks up tags for the *pinned* PostgreSQL version only
(`<major>.<minor>-system-<debian>`). When CNPG publishes that version on a
newer Debian stable release, Renovate opens one PR moving every matching
cluster to it. Debian testing is never proposed: Renovate only considers a
release stable once Debian has released it.

* **No `pg_upgrade`.** The PostgreSQL version is unchanged, so the operator
  rolls each instance pod onto the new image. Because the lookup is pinned to
  the current version, a Debian move can never be combined with a major
  upgrade. If CNPG stops building a new major for the old Debian release, the
  major PR only appears after the Debian move is merged.
* **No reindex.** A new Debian release can ship a glibc whose collation
  ordering differs, which corrupts text indexes built with glibc collations.
  Every cluster here is initialized with CNPG's default `C` locale, and no
  database or `Database` resource overrides it. `C` compares bytes without
  calling glibc, so the move does not affect indexes. If a cluster ever adopts
  a glibc locale, check after each move:

  ```sql
  SELECT datname, datcollversion,
         pg_database_collation_actual_version(oid) AS actual
  FROM pg_database WHERE datcollversion IS DISTINCT FROM
         pg_database_collation_actual_version(oid);
  ```

  For each listed database, run `REINDEX DATABASE <db>;` and then
  `ALTER DATABASE <db> REFRESH COLLATION VERSION;`.

Immich's `cloudnative-vectorchord` tags carry no Debian marker, so upstream's
Debian moves arrive inside ordinary Renovate updates. On a minor update this
is safe for the same reasons. On a major upgrade it is not (see
[Before Merging a Major Upgrade](#before-merging-a-major-upgrade)).

---

## 2. Automated Storage Engine Upgrades (Longhorn)

Longhorn upgrades consist of two components:
1. **Longhorn Manager & Drivers:** Handled declaratively via the Helm chart under `apps/longhorn/`. The chart's pre-upgrade checker is disabled (its online version check is a phone-home, and CRDs arrive declaratively through the render); the post-upgrade cleanup runs as an Argo CD PostSync hook that re-runs with the fresh image on every sync and self-deletes on success.
2. **Volume Engines:** Longhorn manages separate engine instances for each active persistent volume.
   * **Automation:** Configured with `defaultSettings.concurrentAutomaticEngineUpgradePerNodeLimit: 2` in `apps/longhorn/helm/values.yaml`.
   * **Behavior:** After the Longhorn Manager upgrades, Longhorn automatically rolls and upgrades volume engines across nodes concurrently, removing the need for manual engine upgrades in the Longhorn UI.

Before merging a Longhorn bump, check the pre-upgrade conditions from the [upstream upgrade guide](https://longhorn.io/docs/latest/deploy/upgrade/): no volume is `Faulted` (unusable replicas may be deleted during the upgrade) and no BackingImage is in a failed state. Upstream also recommends a Longhorn system backup, which needs a Longhorn backup target this cluster does not configure; confirm the latest [Velero backup](velero.md) succeeded instead. Longhorn cannot be downgraded.

---

## 3. Automated Post-Upgrade Tasks (OpenCloud)

As documented in [docs/opencloud.md](opencloud.md), OpenCloud automatically handles post-update configuration patches (`opencloud init --diff`) and search engine re-indexing (`opencloud search index --all-spaces --force-rescan --insecure`) asynchronously on container startup via `entrypoint.sh`.

---

## 4. Applications Requiring Sequential Version Stepping

Certain upstream applications require (or recommend) sequential version progression instead of skipping releases:

| Application | Upgrade Constraint | Upstream Rationale |
| :--- | :--- | :--- |
| **Cilium** | Sequential minor versions, each from the latest patch of the previous minor | The only tested upgrade and rollback path is between consecutive minor releases. |
| **Longhorn** | Sequential minor versions | Upstream does not support jumping minor versions and rejects the upgrade automatically. Downgrades are blocked. |
| **cert-manager** | Sequential minor versions (recommended), each on its latest patch | Upstream recommends one minor at a time; larger jumps are only covered by a reinstall. |
| **External Secrets** | Sequential minor versions (recommended) | Upstream's stability policy recommends upgrading version by version. |
| **Velero** | From the previous minor only | Each upgrade guide assumes the previous minor is running; older installations step through the earlier guides. The chart version does not follow Velero's, so Renovate cannot enforce this: check the release a chart bump ships. |

Forgejo, Immich, and the other applications have no stepping constraint; their upstream procedures are in [§9](#9-upstream-upgrade-procedures).

---

## 5. Renovate Guardrails

To prevent breaking jumps while keeping standard application updates streamlined, `renovate.json` implements targeted `packageRules`:

* **Global Defaults:** `separateMajorMinor: false`, `separateMinorPatch: false`, and `separateMultipleMajor: false` (standard applications receive direct updates to the latest release in a single PR).
* **Kubernetes version pin:** the `kubernetes-version` group carries every place a
  Kubernetes minor is pinned — the k3s version (`host/versions.env` and the
  system-upgrade-controller Plans), the e2e suite's `kubeVersion`, the
  pod-security docs, e2e hook comments, and every
  `managedNamespaceMetadata` PSA `*-version` label across `apps/` — in one PR
  (`scripts/check-k8s-version.sh` fails the build if any of them drift).
* **Strict Components:** Cilium, Longhorn, cert-manager, and External Secrets set `separateMultipleMinor: true`, so Renovate opens one PR per minor increment instead of jumping to the highest version ([§4](#4-applications-requiring-sequential-version-stepping)). Forgejo, Immich, MariaDB, and the CloudNativePG operand images set `separateMajorMinor: true` and `separateMultipleMajor: true`, so each major arrives in its own PR.
* **PR notices:** the components with an upstream procedure ([§9](#9-upstream-upgrade-procedures)) carry `prBodyNotes` that summarize it and link the upstream release notes or upgrade guide.
* **Grouped platform pins:** the system-upgrade-controller CRD tag, remote base and image move in one PR; the VictoriaMetrics single-node and vmalert charts move together; the agents VM tool pins (`host/agents-vm/versions.env`) arrive as one PR, so a merge rebuilds the VM once.
* **Kubernetes version pins:** every reference to the cluster's Kubernetes minor — the k3s version in `host/versions.env` and `apps/system-upgrade-controller/2_plans.yaml`, the `managedNamespaceMetadata` Pod Security Admission labels in `apps/app-of-apps.yaml` and `apps/otel-collector/1_helm_node.yaml`, the e2e suite's `kubeVersion` (kind node image) and its README, the user-namespaces documentation in `AGENTS.md` and `docs/pod-security.md`, and the e2e staging hook comments — is tracked by `customManagers` in `renovate.json` and grouped into a single `kubernetes-version` PR. The kind-side references are sourced from `kindest/node` Docker Hub tags, so Renovate can never propose a node image kind cannot pull, and the k3s references from k3s releases. Merge a minor bump only once the PR carries the matching k3s minor as well (k3s publishes a new minor after upstream Kubernetes), so the PSA labels never reference a minor newer than the API server once the Plans have run, and only when the local kind CLI is new enough to pull the new node image. `scripts/check-k8s-version.sh` (run by the [validate workflow](../.github/workflows/validate.yaml)) fails CI when any reference drifts from the rest.
* **`ignorePaths` override:** `config:recommended` defaults `ignorePaths` to `**/examples/**`, `**/tests/**`, and similar patterns, which silently excludes `e2e/examples/` from every manager (the suite pin, the e2e README tag, and the staging hook comments). The explicit `ignorePaths` in `renovate.json` keeps only `**/node_modules/**` and `**/bower_components/**`; do not remove it or the Kubernetes version automation stops seeing the e2e suite.

---

## 6. Platform Upgrades (k3s, Fedora, Host Components, Agents VM)

Nothing on the nodes updates outside these windows (Europe/Lisbon):

| Window | What |
| --- | --- |
| 01:00–02:00 | k3s upgrades (system-upgrade-controller) |
| 02:00–02:30 | Agents VM root rebuild, only when its pins changed |
| 02:30–06:30 | kured reboots: package updates, host configuration changes k3s reads at start, Fedora release upgrades |

* **k3s:** the `kubernetes-version` PR bumps `K3S_VERSION` in `host/versions.env` (what `host/bootstrap.sh` installs on a new node) and `version` in the `k3s-server` and `k3s-agent` Plans (`apps/system-upgrade-controller/2_plans.yaml`). After the merge, the controller upgrades one server at a time in the window with `docker.io/rancher/k3s-upgrade`: it cordons the node (no drain), replaces `/usr/local/bin/k3s`, restarts k3s and uncordons. The cordon blocks kured through its `NodeCordoned` gate, so upgrades and reboots never overlap. k3s upgrades also move the Gateway API CRDs (k3s's `gateway-api-crd` addon). Upgrade one minor at a time, per the [k3s upgrade docs](https://docs.k3s.io/upgrades).
* **Fedora packages:** `dnf5-automatic` installs updates daily and never reboots; kured reboots each node that needs it ([fedora.md](fedora.md#updates-and-reboots)).
* **Fedora releases:** Renovate opens a PR bumping `FEDORA_RELEASE` in `host/versions.env`. After the merge, every node downloads the upgrade on its next hourly pull and kured reboots the nodes into the offline upgrade one at a time; a node that fails its post-boot check halts the rollout ([fedora.md](fedora.md#fedora-release-upgrades)). The agents VM is rebuilt on the new release in the next window.
* **gVisor, kube-vip, helm:** Renovate bumps `GVISOR_VERSION`, `KUBE_VIP_VERSION` and `HELM_VERSION` in `host/versions.env`. apply.sh installs a new gVisor on the next pull (new pods use it; running sandboxes keep theirs until they restart), rewrites the kube-vip static pod (kubelet restarts it), and uses helm only during bootstrap.
* **Agents VM tools:** Renovate bumps `host/agents-vm/versions.env` in one grouped PR; the merge rebuilds the VM root in the next window ([agents-vm.md](agents-vm.md#rebuildable-root-persistent-home)).

---

## 7. DocumentDB Engine Upgrades

Notesnook's document database runs on the DocumentDB Kubernetes Operator
(`apps/notesnook/0_documentdb.yaml`), which layers a MongoDB-compatible gateway
over a generated CloudNativePG `Cluster`.

### Version Pins (three places, two tracks)

* **Operator track** (controller, sidecar injector, WAL replica images):
  `apps/documentdb-operator/helm/local-charts/documentdb-operator/Chart.yaml`
  `version`. Upgrades are fully automated: Renovate bumps
  the version and runs `scripts/vendor-documentdb-operator.sh` on the PR
  branch (a `postUpgradeTasks` command allowed via `RENOVATE_ALLOWED_COMMANDS`
  in the Renovate workflow), so the PR contains the complete re-vendored tree
  with the homeworld patches re-applied (subchart strip, `cloudnative-pg`
  plugin namespace) — approve and merge. The operator, sidecar injector, and
  WAL replica images default to the chart's `appVersion` in the vendored
  templates, so the single chart-version PR moves all three together (the
  re-vendored tree pins what actually renders; no separate image pins are
  tracked). The script fails closed if upstream
  renames templates or namespaces, surfacing the needed script fix as an
  artifact error on the Renovate PR; it can also be run locally at any time
  (no arguments re-vendor the currently pinned version).
* **Database track** (extension + gateway images): `documentDbVersion` in
  `apps/documentdb-operator/helm/values.yaml` sets the operator-wide default,
  and `documentDBVersion` in `apps/notesnook/0_documentdb.yaml` pins the
  cluster explicitly so an operator chart bump cannot silently change the
  engine version. Engine `X.Y.0` ↔ upstream tag `vX.Y-0` at
  [documentdb/documentdb releases](https://github.com/documentdb/documentdb/releases).

Renovate tracks all four fields via `customManagers` in `renovate.json`.
The engine managers use the docker datasource against
`ghcr.io/documentdb/documentdb-kubernetes-operator/documentdb`, the extension
image the operator mounts (the gateway image shares its tags), with `semver`
versioning: the bare `X.Y.Z` tags are the releases, while the
`-build-...` and release-candidate tags are never proposed. Release-candidate
engines are not upgradable in place, so never pin one on a cluster that holds
data. (The `vX.Y-0` form above is the GitHub *release* tag — a human-facing
alias of the same version; Renovate tracks the image tags, not the releases.)

### Schema Upgrades Are Two-Phase

Binary (image) upgrades do **not** run `ALTER EXTENSION` automatically. After
the new images roll, finalize the schema explicitly:

1. Ensure a recent [Velero backup](velero.md) exists.
2. Merge the Renovate engine PR and wait for the cluster to report Ready.
3. Set `spec.schemaVersion` to the new version (or `"auto"` to track the
   binary; `"auto"` skips the rollback safety window and is not recommended).
4. Once the schema is updated, the operator blocks image rollback below the
   installed schema version — verify application health before committing.

### PostgreSQL Base Image

`spec.image.postgres`, pinned to a
`ghcr.io/cloudnative-pg/postgresql:<major>.<minor>-system-trixie` tag, is
tracked by the CloudNativePG package rule: minor bumps roll with zero
downtime, major bumps trigger CNPG's automated offline `pg_upgrade`. The image
must stay trixie-based to match the extension's GLIBC requirements.

This pin takes effect only because `imageMode: imageVolume` in
`apps/documentdb-operator/helm/values.yaml` mounts the extension into that image
through an image volume. The chart's `auto` default could instead select the
combined PostgreSQL + DocumentDB image, which ignores `spec.image.postgres` and
is fixed for the life of the cluster; with the pin, the webhook rejects the
`DocumentDB` when the API server does not accept image volumes.

---

## 8. MariaDB Engine Upgrades (MariaDB Operator)

Supernote's database runs on the MariaDB Operator
(`apps/supernote/0_mariadb.yaml`), the cluster's only MariaDB consumer. The
operand image is pinned twice: `spec.image` on the `MariaDB` CR and the
operator's `config.mariadbImage` default in
`apps/mariadb-operator/helm/values.yaml`. Renovate tracks both; merge them in
the same change. Any MariaDB version can be upgraded to any later one in a
single step, so no sequential stepping is required.

### Automated Upgrade Steps

MariaDB's upgrade guides (minor and major) and the operator's update
documentation recommend the steps below; each is automated, so merging the
Renovate PR is the whole procedure:

| Recommended step | Automation |
| :--- | :--- |
| Back up the database before upgrading | Argo CD PreSync hook `apps/supernote/0_pre_sync_backup.yaml`: a one-shot `PhysicalBackup` cuts a consistent volume snapshot (the operator holds `FLUSH TABLES WITH READ LOCK` while it is taken) before every sync of the application, and the sync waits for it (Argo CD health check `k8s.mariadb.com_PhysicalBackup` in `apps/argocd/helm/values.yaml`). A failed snapshot fails the sync, so the image never rolls without its backup. |
| Back up the `mysql` system database | The official image's entrypoint dumps it into the data directory (`system_mysql_backup_<old version>.sql.zst`) before upgrading. |
| Clean shutdown with `innodb_fast_shutdown` not `2` | `innodb_fast_shutdown=1` is pinned in `myCnf`, and `terminationGracePeriodSeconds: 120` leaves room to flush before the kubelet's `SIGKILL`. |
| Run `mariadb-upgrade` | `updateStrategy.mariadbAutoUpgradeEnabled` makes the operator set `MARIADB_AUTO_UPGRADE`; the entrypoint runs `mariadb-upgrade` whenever the major or minor version changes and is a no-op otherwise. |

Reviewing the release notes stays a human step; the Renovate PR for
`docker.io/library/mariadb` carries a reminder. Operator chart bumps can
change the generated StatefulSet or pod template and roll the instance the
same way, behind the same pre-sync snapshot.

### Rolling Back

MariaDB cannot be downgraded in place. To return to the previous version,
restore the pre-upgrade snapshot (the newest `mariadb-pre-sync-*`
`VolumeSnapshot` in the `supernote` namespace) into a fresh instance: revert
the image change, then delete the `MariaDB` CR and its `storage-mariadb-0`
PVC and recreate the CR with `spec.bootstrapFrom.volumeSnapshotRef.name` set
to that snapshot (remove the field once the instance is running).

### Supernote Database Script

Upstream's installer re-runs its `supernotedb.sql` on every update as both
seed and migration. Here it is embedded in the `supernotedb-seed` SqlJob
(`apps/supernote/1_sql_job.yaml`), which the operator runs once and never
re-runs. The `check-supernotedb-sql` workflow fetches the script
(`https://supernote-private-cloud.supernote.com/cloud/supernotedb.sql`) daily
and, when it changes, opens a PR that re-vendors it into the SqlJob with
`scripts/refresh-supernotedb-sql.sh` (also runnable locally); the PR is never
automerged. The script refuses a download that no longer creates every table
the vendored script does (a truncated file or an error page), and a failed
run (including the script moving or disappearing upstream) opens a
"Supernote database script check is failing" issue that the next successful
run closes. To apply it:

1. Merge the PR, alongside the Supernote image bump that needs it when one is
   open.
2. After the change syncs, delete the SqlJob together with its completed Job
   (`kubectl -n supernote delete sqljob supernotedb-seed --cascade=foreground`;
   the Job shares the SqlJob's name, and a leftover one would be reused
   instead of re-run). Argo CD recreates the SqlJob and the operator runs the
   new Job.

The script's schema statements are idempotent, but like upstream's installer
it also empties the recycle-bin and file-conversion tables on every run.

---

## 9. Upstream Upgrade Procedures

Merging a Renovate PR is only safe once the upstream release notes for every
version it crosses have been read: majors routinely carry required manual
actions, and minors of the operators below do too. For each application,
check the notes for removed or renamed configuration keys, new prerequisites
(CRD or dependency versions), and one-time manual steps, and apply them in the
same PR when they are declarative.

Then check that this repository's own inputs still fit the target version:

* **Helm values:** every key in `apps/<component>/helm/values.yaml` still
  exists in the new chart's `values.yaml` (and `values.schema.json`, when the
  chart ships one) with the same meaning. Helm ignores unknown keys, so a
  renamed key silently falls back to the chart default.
* **Kustomize patches:** each patch still matches its target resource, and
  the fields it sets or deletes still exist in the new render.
* **Application configuration:** config templates, ConfigMaps, environment
  variables, command-line flags, and custom resource fields use no removed,
  renamed, or deprecated option; switch deprecated ones to the documented
  replacement in the same PR instead of waiting for their removal.
* **Rendered output:** render the component before and after the bump
  (`kubectl kustomize --enable-helm`) and diff the two, confirming the
  security contexts, `runtimeClassName`/`hostUsers`, resources,
  ServiceMonitors, and ports are still emitted. After the sync, check the
  application's logs for deprecation warnings.

### Upgrade Tooling

`scripts/upgrade-report.sh` does the mechanical half of this review for a
git range (by default a branch against `origin/main`). Per touched component
it renders both sides and diffs them per resource, diffs the chart's default
values and values schema, lists the values keys the new chart no longer
reads, keys no chart version knows, values that equal the new default, new
chart options, and defaults that changed under keys left unset. It also
reports the latest stable chart and image tags upstream, the convention
findings on the new render (gVisor or user namespaces, Restricted security
contexts, requests and limits, fully qualified images, 60s monitors), with
those introduced by the change called out, whether the component holds
state, and the release notes of every chart and application release in the
range, with lines mentioning breaking changes, deprecations, or removals
extracted. With `--all` and `--base` equal to `--head`, it audits the
current state of every component instead.

The `upgrade` agent skill (`.agents/skills/upgrade/SKILL.md`, in the
[Agent Skills](https://agentskills.io/specification) format; `.claude/skills`
links to it for Claude Code) works
open Renovate PRs end to end on top of the report: one reviewer per PR reads
the release notes and the target version's configuration reference, adapts
values, patches, and application configuration, fixes convention
regressions, and pushes to the PR branch. The skill then merges the PRs one
at a time once CI passes. Before merging an upgrade of a stateful component
it runs `scripts/pre-upgrade-backup.sh`, which takes a Velero backup of the
component's namespaces unless one completed within the last hour
([velero.md](velero.md#pre-upgrade-backups)). Before a Cilium minor it runs
`scripts/cilium-preflight.sh` ([below](#cilium-pre-flight-check)). It stops
instead of merging when a release needs a decision or a step outside git:
an Immich major, a Gateway API or Kubernetes minimum the cluster does not
meet, a failed backup or pre-flight, or a stepping constraint from
[§4](#4-applications-requiring-sequential-version-stepping).

The [upgrade-agent workflow](../.github/workflows/upgrade-agent.yaml)
reviews every Renovate PR as it opens with the pi coding agent and DeepSeek V4.1 Flash through the DeepSeek API (thinking `high`). The
agent works in the skill's result mode: it reviews and commits on a runner
holding only a read-only token and the `DEEPSEEK_API_KEY` Actions secret, and
returns a decision. DeepSeek bills off-peak hours at half price, so reviews
run only off-peak ([`scripts/deepseek-off-peak.sh`](../scripts/deepseek-off-peak.sh)):
a review starts an hour or more into an off-peak period with at least 30
minutes of it left, and stops five minutes before the next peak window.
Renovate runs at 11:00 UTC, an hour after the weekday peak ends. A PR opened,
or a `/upgrade` reply posted, outside that time is labelled `upgrade-deferred`
and reviewed again at the next 05:00 or 11:00 UTC on a weekday, an hour after
a peak window ends. A second job pushes its commit as the `renovate-homeworld`
app and posts the review as a PR comment and as the "Upgrade agent review"
check on the PR head. A PR the agent passes with nothing for the owner
to see is labelled `upgrade-ready` and merged by the app once every other
check on its head passes. A PR that passes but brings a new feature useful
here, a notable user-facing feature (a new capability, not a rework of an
existing view), or a post-merge step that needs the owner to act, is
labelled `upgrade-review` and left open for the owner to merge. Checks that
an automatic startup task succeeded (OpenCloud's configuration patch and
re-index) do not hold a PR: its comment lists them with their commands. A blocker, failing CI, or a run that ended without a
result is labelled `upgrade-blocked`. A PR waiting for an earlier PR of the same package is
labelled `upgrade-waiting` and reviewed again when that one merges. The agent
may not change `.github/`; such fixes come back as a diff in the comment.
Renovate's own version bumps under `.github/` are reviewed and merged like
any other PR.
Replying `/upgrade <decision>` on the PR (repository owner only) runs the
review again ([upgrade-agent-request](../.github/workflows/upgrade-agent-request.yaml));
the agent reads the reply as the answer to its blocker or to the features it listed. Hosted runners cannot reach the cluster, so the
workflow passes `--no-cluster` until the cluster is live; after that,
stateful upgrades block for a local run that can take the pre-merge backup.

The applications below document procedures beyond that review.

| Application | Upstream procedure | Here |
| :--- | :--- | :--- |
| **Cilium** | [Upgrade guide](https://docs.cilium.io/en/stable/operations/upgrade/) plus the per-minor upgrade notes: run the pre-flight check, keep `upgradeCompatibility` at the originally installed version, and apply each minor's required actions (removed APIs, Gateway API CRD minimums). | Manual pre-flight before merging a minor bump (below). Gateway API CRDs come from k3s, so a Gateway API minimum can require a k3s upgrade first. |
| **Envoy Gateway** | [Upgrade notes](https://gateway.envoyproxy.io/docs/install/install-helm/): CRDs before the controller; releases can require a minimum Gateway API CRD version. | CRDs sync with the render. Check the release's Gateway API requirement against the k3s-bundled CRDs ([k3s.md](k3s.md)). |
| **CloudNativePG operator** | [Operator upgrade](https://cloudnative-pg.io/docs/current/installation_upgrade): read the release notes (some versions need extra steps or are not directly upgradable), avoid skipping versions. | Every operator bump rolls every PostgreSQL cluster; with `instances: 1` each database restarts once. |
| **MariaDB Operator** | Per-release `UPGRADE_<version>.md` [guides](https://github.com/mariadb-operator/mariadb-operator/tree/main/docs/releases): CRDs first, sometimes prerequisites on the `MariaDB` CR (e.g. `updateStrategy` fields) before the operator moves. | CRDs sync with the render. Apply any CR prerequisite in an earlier commit than the chart bump. |
| **Velero** | Per-version guide (`velero.io/docs/main/upgrade-to-<minor>/`): CRDs first, from the previous minor only, plugin images matching the [compatibility matrix](https://github.com/vmware-tanzu/velero-plugin-for-aws). | CRDs sync with the render (`upgradeCRDs: false`). Bump `velero-plugin-for-aws` together with Velero when the matrix requires it. |
| **Argo CD** | [Upgrade overview](https://argo-cd.readthedocs.io/en/stable/operator-manual/upgrading/overview/): read the `upgrading/<from>-<to>` notes of every minor crossed; majors carry incompatible changes. | Chart majors also list value changes in the chart README. |
| **Forgejo** | [Upgrade guide](https://forgejo.org/docs/latest/admin/upgrade/): versions may be skipped. Back up before a major, flush queues before upgrading, run the doctor afterwards. | Before a major: a CNPG on-demand `Backup` ([§1](#before-merging-a-major-upgrade)) and `forgejo manager flush-queues`. After: `forgejo doctor check --all`. Chart majors list breaking value changes in the chart README. The image tag is pinned in `apps/forgejo/helm/values.yaml` rather than taken from the chart's `appVersion`, so application and chart majors arrive as separate PRs. |
| **Woodpecker** | [Migrations](https://woodpecker-ci.org/migrations): per-major breaking changes, some requiring admin actions (repairing repository webhooks, plugin privileges, file ownership). | Apply the listed actions after the sync. |
| **Immich** | [Upgrading](https://docs.immich.app/install/upgrading): read the breaking changes; downgrades are unsupported, even within a minor. Mobile apps move before the server on a major. | The chart does not follow Immich releases, so `apps/immich/helm/values.yaml` pins the tag for both images and chart bumps do not move Immich: check the chart still templates the new version. The VectorChord range constrains the CNPG image ([§1](#before-merging-a-major-upgrade)). |
| **Authelia** | [Storage migrations](https://www.authelia.com/configuration/storage/migrations/) run automatically on start; going back requires a manual schema downgrade. | Take a CNPG on-demand `Backup` ([§1](#before-merging-a-major-upgrade)) before a bump and roll back by restoring it (or the latest [Velero backup](velero.md)), not by reverting the image alone. |
| **Coder** | [Upgrade](https://coder.com/docs/install/operate/upgrade) and [best practices](https://coder.com/docs/install/operate/upgrade/best-practices): rollbacks are unsupported, so snapshot the database first; migrations run at startup and take longer the more minors are crossed. Read the [release notes](https://github.com/coder/coder/releases) of every minor crossed — Coder Agents settings and APIs can change between releases. | Take a CNPG on-demand `Backup` ([§1](#before-merging-a-major-upgrade)) before a minor bump and roll back by restoring it, not by reverting the image. The chart and image move together in one Renovate PR. When the bump raises a Terraform or provider minimum, push the repository template again ([coder.md](coder.md#workspace-template)). The `coder-workspace-image` PR (Debian base, mise, rustup, Rust, and the image's toolset) rebuilds the workspace image on merge; push the template after Renovate's follow-up tag bump ([coder.md](coder.md#workspace-image)). |
| **AFFiNE** | [Upgrade](https://docs.affine.pro/self-host-affine/install/upgrade) and the [release notes](https://github.com/toeverything/AFFiNE/releases) of every minor crossed: schema and data migrations run before the server starts and cannot be rolled back; `config.json` keys can be renamed and the BYOK provider list can change between releases. | Take a CNPG on-demand `Backup` ([§1](#before-merging-a-major-upgrade)) before a minor bump and roll back by restoring it, not by reverting the image. Diff the release's `config.schema.json` against the `config.json` template in `apps/affine/-1_secrets.yaml` and apply renamed keys in the same PR; the `migrate` init container runs the migrations on the first new pod. The Manticore chart (search index) arrives in its own Renovate PR. |
| **Home Assistant** | [Updating](https://www.home-assistant.io/common-tasks/container/#updating): back up first and read the backward-incompatible changes of every release crossed; check repairs and logs afterwards. The bootstrap init container seeds `.storage/http` in the HTTP store's format: when `homeassistant/components/http/config.py` changes its storage version or schema, update the seed to the new format in the same PR. | Confirm the latest [Velero backup](velero.md) and take a CNPG on-demand `Backup` ([§1](#before-merging-a-major-upgrade)) before a bump. |
| **RustFS** | [Upgrade runbook](https://docs.rustfs.com/upgrade-scale/upgrade): never upgrade with offline nodes or degraded erasure sets; the on-disk format never changes. The operator chart needs its CRDs first. | CRDs sync with the render. |
| **Grafana VictoriaMetrics datasource plugins** | Read the plugin release notes ([metrics](https://github.com/VictoriaMetrics/victoriametrics-datasource/blob/main/CHANGELOG.md), [logs](https://github.com/VictoriaMetrics/victorialogs-datasource/blob/main/CHANGELOG.md)) and check the `grafanaDependency` in the release's `plugin.json` against the Grafana image. | The plugin-loader init container in `apps/grafana/0_grafana.yaml` verifies each tarball's sha256. Renovate moves the tag and tarball name but not the checksum: copy the new digest from the release assets page into the same PR. |
| **OpenCode and OpenChamber (agents VM)** | OpenChamber runs only on the OpenCode major it targets, from the minimum in its `packages/web/server/lib/opencode/compatibility.js` (`MINIMUM_OPENCODE_VERSION`); a newer OpenCode major is unsupported until an OpenChamber release adopts it. OpenCode majors can move the installer URL and deprecate `opencode.json` keys ([V1 migration guide](https://opencode.ai/v2/docs/migrate-v1/)). | Before merging an `agents-vm-tools` PR that moves either pin, check that the pinned OpenChamber accepts the pinned OpenCode version. On an OpenCode major, check the installer URL in `host/agents-vm/provision.sh` and the managed keys in `host/agents-vm/agents-config.sh` ([agents-vm.md](agents-vm.md#managed-configuration)). |
| **Longhorn** | See [§2](#2-automated-storage-engine-upgrades-longhorn). | |
| **OpenCloud** | Each major has an upgrade page (`docs.opencloud.eu/docs/next/admin/maintenance/upgrade/upgrade-<major>.x.x`) linked from the release's *Action required* note: renamed or deprecated environment variables, moved `opencloud.yaml` keys, new opt-in services, and one-time cleanups. | Rename the variables and keys `apps/opencloud` sets in the same PR. The configuration patch (`opencloud init --diff`) and the search re-index run on startup ([§3](#3-automated-post-upgrade-tasks-opencloud)). Once Argo CD has synced the new image, run `kubectl -n opencloud logs deploy/opencloud -c opencloud \| grep -E '^\[(init\|upgrade\|reindex)\]'`: expect `[init] Configuration is up to date.` or `[init] Configuration patch applied successfully.`, then `[reindex] Search re-indexing completed successfully.` (it can take minutes). On `[init] WARNING: Patch dry-run failed`, apply the change shown by `kubectl -n opencloud exec deploy/opencloud -c opencloud -- cat /etc/opencloud/opencloud.config.patch` to `/etc/opencloud/opencloud.yaml` by hand; a `[reindex] ERROR` retries on the next pod start (`kubectl -n opencloud rollout restart deploy/opencloud`). |
| **DocumentDB, MariaDB, CloudNativePG operands** | See [§7](#7-documentdb-engine-upgrades), [§8](#8-mariadb-engine-upgrades-mariadb-operator), [§1](#1-automated-major-database-upgrades-cloudnativepg). | |

Charts that ship their CRDs in `crds/` (Grafana Operator, OpenTelemetry
Operator, RustFS Operator, Envoy Gateway, Velero) tell Helm users to apply
the CRDs by hand before `helm upgrade`. Here the render includes them and
Argo CD server-side applies them in the same sync ([argocd.md](argocd.md)),
so no manual step is needed.

### Cilium Pre-Flight Check

`scripts/cilium-preflight.sh <target>` runs the whole check below and
deletes the pre-flight resources afterwards.

Before merging a Cilium minor bump, render the pre-flight DaemonSet from the
target chart, apply it, and wait until it is ready on every node (it pre-pulls
the new image) and its `cnp-validator` reports every `CiliumNetworkPolicy`
valid. Pass only these flags, not `apps/cilium/helm/values.yaml`: the full
values also render Hubble and a freshly generated `cilium-ca` Secret, which
would overwrite the live ones.

```bash
helm template cilium-preflight cilium --repo https://helm.cilium.io \
  --version <target> --namespace cilium \
  --set preflight.enabled=true --set agent=false --set operator.enabled=false \
  --set k8sServiceHost=127.0.0.1 --set k8sServicePort=6444 \
  > cilium-preflight.yaml
kubectl apply -f cilium-preflight.yaml
kubectl -n cilium get daemonset cilium-pre-flight-check
kubectl -n cilium get deployment cilium-pre-flight-check
```

The DaemonSet's ready count must match the `cilium` DaemonSet's, and the
Deployment must report `1/1`; a Deployment stuck at `0/1` names the invalid
policy in its `cnp-validator` logs. Fix it, then delete the pre-flight
resources (`kubectl delete -f cilium-preflight.yaml`) and merge.
