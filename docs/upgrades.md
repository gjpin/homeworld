# Application Upgrades & Migrations

This document details upgrade automation, database migration procedures, and version-stepping requirements across the cluster.

---

## 1. Automated Major Database Upgrades (CloudNativePG)

All PostgreSQL databases (`authelia`, `crowdsec`, `forgejo`, `immich`) run on **CloudNativePG** (CNPG).

### Minor Version Updates (e.g. 18.1 → 18.2)
* **Execution:** Rolling update.
* **Process:** The CNPG operator restarts instance pods sequentially with zero application downtime.

### Major Version Upgrades (e.g. 18 → 19)
* **Execution:** Declarative offline in-place `pg_upgrade` managed entirely by the CNPG operator.
* **Automation Workflow:**
  1. Renovate opens a dedicated major version PR for `imageName` in `0_postgres.yaml`.
  2. Merging the PR commits the new major version tag into Git, which Argo CD syncs to the cluster.
  3. The CNPG operator detects the major PostgreSQL version difference between the running `PGDATA` volume and the new image.
  4. The operator automatically stops the database pod to guarantee data consistency.
  5. The operator launches an automated upgrade Kubernetes Job that runs PostgreSQL's native `pg_upgrade` against the existing `PGDATA` volume.
  6. Upon completion, the operator restarts the pod running the new major PostgreSQL version. Replicas (if configured) are automatically re-created from the upgraded primary.
* **Safety & Prerequisites:**
  * **Downtime:** The upgrade is *offline*; the affected application will experience temporary database unavailability while `pg_upgrade` executes (typically 1–3 minutes).
  * **Extensions (Immich / VectorChord):** For Immich, ensure the target `cloudnative-vectorchord` image includes VectorChord compiled for the new PostgreSQL major version before merging.
  * **Backups:** Ensure a recent [Velero backup](velero.md) exists before merging major database upgrades.

---

## 2. Automated Storage Engine Upgrades (Longhorn)

Longhorn upgrades consist of two components:
1. **Longhorn Manager & Drivers:** Handled declaratively via the Helm chart under `apps/longhorn/`. The chart's pre-upgrade checker is disabled (its online version check is a phone-home, and CRDs arrive declaratively through the render); the post-upgrade cleanup runs as an Argo CD PostSync hook that re-runs with the fresh image on every sync and self-deletes on success.
2. **Volume Engines:** Longhorn manages separate engine instances for each active persistent volume.
   * **Automation:** Configured with `defaultSettings.concurrentAutomaticEngineUpgradePerNodeLimit: 2` in `apps/longhorn/helm/values.yaml`.
   * **Behavior:** After the Longhorn Manager upgrades, Longhorn automatically rolls and upgrades volume engines across nodes concurrently, removing the need for manual engine upgrades in the Longhorn UI.

---

## 3. Automated Post-Upgrade Tasks (OpenCloud)

As documented in [docs/opencloud.md](opencloud.md), OpenCloud automatically handles post-update configuration patches (`opencloud init --diff`) and search engine re-indexing (`opencloud search index --all-spaces --force-rescan --insecure`) asynchronously on container startup via `entrypoint.sh`.

---

## 4. Applications Requiring Sequential Version Stepping

Certain upstream applications require sequential version progression and prohibit skipping releases:

| Application | Upgrade Constraint | Upstream Rationale |
| :--- | :--- | :--- |
| **Forgejo** | Sequential major versions (`v7.x` → `v8.x` → `v9.x`) | Database schema migrations must run in sequence. Skipping major versions can cause irrecoverable database corruption. |
| **Immich** | Step through checkpoint releases | Breaking changes, database migrations, and machine-learning model updates must be applied incrementally. Background queues must be cleared before the next upgrade. |
| **Longhorn** | Sequential minor versions (`1.10.x` → `1.11.x` → `1.12.x`) | Upstream explicitly does not support jumping minor versions. Manager and CSI plugin schemas evolve sequentially. |
| **cert-manager** | Sequential minor versions (`1.15.x` → `1.16.x` → `1.17.x`) | CRD schemas and conversion webhooks require minor-by-minor progression. |

---

## 5. Renovate Guardrails

To prevent breaking jumps while keeping standard application updates streamlined, `renovate.json` implements targeted `packageRules`:

* **Global Defaults:** `separateMajorMinor: false`, `separateMinorPatch: false`, and `separateMultipleMajor: false` (standard applications receive direct updates to the latest release in a single PR).
* **Strict Components:** Forgejo, Immich, Longhorn, cert-manager, and CloudNativePG operand images have `separateMajorMinor: true`, `separateMultipleMajor: true`, or `separateMinorPatch: true` enabled. This guarantees:
  * Renovate opens individual PRs for each major or minor increment rather than jumping to the highest version.
  * PR bodies include automated notices linking to upstream release notes, breaking change checklists, and backup reminders.
* **OpenChamber Workspace Image:** Node.js major bumps are separated (`separateMajorMinor: true`) because OpenChamber requires a minimum Node.js version; the PR body reminds you to verify it before merging.
* **Kubernetes version pins:** every reference to the cluster's Kubernetes minor — the `managedNamespaceMetadata` Pod Security Admission labels in `apps/app-of-apps.yaml` and `apps/otel-collector/1_helm_node.yaml`, the e2e suite's `kubeVersion` (kind node image) and its README, the user-namespaces documentation in `README.md`, `AGENTS.md`, and `docs/pod-security.md`, and the e2e staging hook comments — is tracked by `customManagers` in `renovate.json` and grouped into a single `kubernetes-version` PR. Updates are sourced from `kindest/node` Docker Hub tags, so Renovate can never propose a node image kind cannot pull (patch bumps roll the e2e suite pin forward on their own; minor bumps move every reference together). Merge the PR only after the Talos nodes run the new minor and the local kind CLI is new enough to pull the new node image. `scripts/check-k8s-version.sh` (run by the [validate workflow](../.github/workflows/validate.yaml)) fails CI when any reference drifts from the rest.
* **`ignorePaths` override:** `config:recommended` defaults `ignorePaths` to `**/examples/**`, `**/tests/**`, and similar patterns, which silently excludes `e2e/examples/` from every manager (the suite pin, the e2e README tag, and the staging hook comments). The explicit `ignorePaths` in `renovate.json` keeps only `**/node_modules/**` and `**/bower_components/**`; do not remove it or the Kubernetes version automation stops seeing the e2e suite.

---

## 6. OpenChamber Agent Workspace Image Refreshes

The persistent AI agent workspace (`apps/openchamber`) runs a custom image built from `images/openchamber/Dockerfile`. The running pod never updates itself: every change to the workspace arrives as a PR you approve, and merging rolls the pod at a moment you choose (merge when the agents are idle; session state, worktrees, and credentials persist on the `openchamber-agent-home` PVC).

* **Pinned tool versions** (base image digest, Node.js, pnpm, uv, OpenChamber, OpenCode, Codex CLI, Pi agent, Grok Build, Antigravity CLI, Copilot CLI, Playwright packages, chrome-devtools-mcp, skills): Renovate opens one PR per updated dependency via `customManagers` in `renovate.json`.
* **Debian packages and Google Chrome** (not visible to Renovate): the daily [package refresh check](../.github/workflows/check-openchamber-apt-updates.yaml) runs `apt-get --simulate full-upgrade` inside the published image and opens a PR bumping `ARG APT_REFRESH` whenever packages are outdated.
* **Image builds** ([Build OpenChamber workspace image](../.github/workflows/build-openchamber.yaml)): merging a PR that touches `images/openchamber/**` builds `linux/amd64` + `linux/arm64`, pushes `ghcr.io/gjpin/openchamber:main-<shortsha>`, and commits the new tag into `apps/openchamber/1_deployment.yaml`. Argo CD then rolls the agent pod.

---

## 7. DocumentDB Engine Upgrades

Notesnook's document database runs on the DocumentDB Kubernetes Operator
(`apps/notesnook/0_documentdb.yaml`), which layers a MongoDB-compatible gateway
over a generated CloudNativePG `Cluster`.

### Version Pins (three places, two tracks)

* **Operator track** (controller, sidecar injector, WAL replica images):
  `apps/documentdb-operator/helm/local-charts/documentdb-operator/Chart.yaml`
  `version` (currently `0.3.0`). Upgrades are fully automated: Renovate bumps
  the version and runs `scripts/vendor-documentdb-operator.sh` on the PR
  branch (a `postUpgradeTasks` command allowed via `RENOVATE_ALLOWED_COMMANDS`
  in the Renovate workflow), so the PR contains the complete re-vendored tree
  with the homeworld patches re-applied (subchart strip, `cloudnative-pg`
  plugin namespace) — approve and merge. The script fails closed if upstream
  renames templates or namespaces, surfacing the needed script fix as an
  artifact error on the Renovate PR; it can also be run locally at any time
  (no arguments re-vendor the currently pinned version).
* **Database track** (extension + gateway images): `documentDbVersion` in
  `apps/documentdb-operator/helm/values.yaml` sets the operator-wide default,
  and `documentDBVersion` in `apps/notesnook/0_documentdb.yaml` pins the
  cluster explicitly so an operator chart bump cannot silently change the
  engine version. Engine `X.Y.0` ↔ upstream tag `vX.Y-0` at
  [documentdb/documentdb releases](https://github.com/documentdb/documentdb/releases).

Renovate tracks all four fields via `customManagers` in `renovate.json`
(the engine managers follow `pg18-*` tags on
`ghcr.io/documentdb/documentdb/documentdb-local`, matching the pinned
PostgreSQL 18 base image).

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

`spec.image.postgres` (`ghcr.io/cloudnative-pg/postgresql:18.6-system-trixie`)
is tracked by the CloudNativePG package rule: minor bumps roll with zero
downtime, major bumps trigger CNPG's automated offline `pg_upgrade`. The image
must stay trixie-based to match the extension's GLIBC requirements.
