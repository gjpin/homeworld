# Grafana dashboards

Grafana organizes every application's dashboards in its own folder. Folders are
declared as `GrafanaFolder` CRs in `apps/grafana/0_folders.yaml`; each
`GrafanaDashboard` CR references its folder via `spec.folderRef` and loads the
dashboard JSON from a kustomize-generated ConfigMap. The repository mirrors the
Grafana folder layout: dashboard JSON lives in
`apps/grafana/dashboards/<app>/<dashboard>.json`, and the `GrafanaDashboard` CRs
for one app live in `apps/grafana/1_dashboards_<app>.yaml`. The `GrafanaDashboard` CRs
carry `argocd.argoproj.io/sync-wave: "1"` and the folder CRs stay on wave 0:
the dashboards POST to the instance with the folderRef's uid, so applying
them in the same wave as the folders races the operator's folder seeding on
a fresh instance ("folder not found") and leaves the losers in the
operator's exponential reconcile backoff.

`scripts/check-dashboards.sh` (wired into CI) fails when dashboard JSON files,
the kustomize `configMapGenerator`, `GrafanaDashboard` CRs, `GrafanaFolder` CRs,
or the provisioned datasource uids drift apart.

## Datasource conventions

Metrics arrive in VictoriaMetrics via the OpenTelemetry Collector. There are
three series populations, and dashboards must scope with the labels the
population actually carries:

* Target-Allocator-discovered ServiceMonitor/PodMonitor scrapes carry
  `namespace`, `pod`, `job` (`<namespace>/<monitor-name>`), and `instance`
  labels — custom dashboards scope these with `namespace="<app-ns>"`.
* Target-Allocator-discovered ScrapeConfig scrapes (the k3s-embedded etcd,
  kube-scheduler and kube-controller-manager, apps/kube-control-plane) have
  no Kubernetes object behind them and carry
  only `job` (`scrapeConfig/<namespace>/<name>`) and `instance` (relabelled to
  the node name).
* OTLP-exported series (the node collector's kubeletstats families, RustFS's
  push) carry VictoriaMetrics' promoted OTel resource attributes as labels
  with dots preserved (`k8s.namespace.name`, `k8s.pod.name`,
  `k8s.persistentvolumeclaim.name`, ...; no `-opentelemetry.usePrometheusNaming`).
* The collectors' own self-scrape targets are static configs and carry only
  `job` (`otel-collector-pod`/`-cluster`/`-node`) and `instance` — the
  OpenTelemetry Collector dashboard scopes by the job prefix precisely
  because those series have no `namespace` label.

The Grafana datasources used by dashboards:

- `victoriametrics` (default, MetricsQL): custom dashboards hardcode this uid on
  every panel.
- `prometheus` (PromQL compatibility): imported upstream dashboards that use
  `${DS_*}` datasource variables of type `prometheus` resolve to it
  automatically; upstream `{service=~"..."}`-style matchers are rewritten to the
  guaranteed `namespace` label, and the grafana.com `__inputs` convention is
  converted into a real datasource template variable.
- `victorialogs` (LogsQL) and `loki` (LogQL compatibility): log panels.
- `victoriatraces-jaeger` / `victoriatraces-tempo`: tracing.

## RustFS OTLP metrics push

RustFS exposes no Prometheus scrape endpoint: it pushes metrics via OTLP. The
Tenant (`apps/rustfs/0_tenant.yaml`) sets `RUSTFS_OBS_ENDPOINT` to the cluster
collector's OTLP/HTTP receiver with trace and log export disabled, and the
`rustfs` / `otel-collector` CiliumNetworkPolicies carry the matching egress and
ingress rules on port `4318` (see [network-policies.md](network-policies.md)).

## Dashboard inventory

Every imported dashboard below is verified against the publishing project's
own GitHub repository or official documentation (chart-bundled files, repo
directories, docs-referenced grafana.com dashboards); third-party grafana.com
dashboards are not used. Custom dashboards reference only metric families
verified against the app's upstream source or official documentation, and every
dashboard's JSON `description` cites its provenance.

| Folder | Dashboard | Source |
| --- | --- | --- |
| AFFiNE | AFFiNE, Manticore Search (Prometheus) | AFFiNE: custom (AFFiNE publishes no dashboard; business metric scopes from `base/metrics/metrics.ts` and Prisma client and pool metrics, as rendered by `@opentelemetry/exporter-prometheus` and checked against the live exporter; the server emits no HTTP request histogram). Manticore Search: official manticoresoftware/grafana-dashboard repo `grafana/dashboards/manticore-dashboard.json` (linked from the Manticore manual's Grafana integration page); matchers scoped to `namespace="affine"`, the `job` variable limited to the Manticore scrape job there, and the datasource variable defaulted to `prometheus` |
| Argo CD | ArgoCD | official: argoproj/argo-cd repo `examples/dashboard.json` (linked from the docs monitoring page) |
| Authelia | Authelia | custom (authelia telemetry metrics, authelia.com reference; no official dashboard) |
| Bazarr | Bazarr | official: the exportarr project's bundled dashboard (onedr0p/exportarr `examples/grafana/dashboard2.json`, the Bazarr row), split per app like the qBittorrent exporter's; `__inputs` converted to a datasource variable, instance matchers scoped to the `bazarr` namespace, cAdvisor `container_*` panels dropped (not collected here) |
| Bindery | Bindery | custom (bindery `internal/metrics/metrics.go`: `bindery_http_*`, `bindery_scheduler_*`, `bindery_build_info`, plus go_/process_; the project publishes no dashboard) |
| cert-manager | cert-manager | custom (pkg/metrics/metrics.go plus certificate metrics corroborated by the docs-referenced monitoring mixin; the project publishes no dashboard) |
| Cilium | Cilium Metrics, Cilium Operator, Hubble | official: cilium repo prometheus addon example; datasource uids and `k8s_app`/`io_cilium_app` target-label scoping adapted to the guaranteed `namespace` label |
| CloudNativePG | CloudNativePG | official: cloudnative-pg/grafana-dashboards repo |
| Coder | Coder Control Plane, Coder Provisioners, Coder Workspaces, Coder Workspace Detail, DERP | official: coder/observability repo `coder-observability/templates/dashboards/`, rendered with this deployment's namespaces (`coder`, `coder-workspaces`); metric panels unchanged (its cAdvisor `container_*` panels stay empty — the cluster collects container usage via kubeletstats), LogQL panels rewritten to LogsQL on the `victorialogs` datasource because the OTLP log pipeline carries `k8s.*` attributes instead of Alloy's `namespace`/`pod`/`logger` labels. Its Prebuilds and Agent Boundaries dashboards cover Premium features, and Status monitors the observability chart's own stack, so they are not imported |
| Collabora | Collabora Online / HA - Allocation, Collabora-Online / Overview | official: chart-bundled `grafana_dashboards/`; three stale upstream target datasource uids normalized |
| CrowdSec | Crowdsec Overview, LAPI Metrics | official: crowdsecurity/grafana-dashboards (`dashboards_v5`); `__inputs` converted to a datasource variable |
| CrowdSec Envoy Bouncer | Envoy CrowdSec Bouncer | official: chart-bundled `dashboards/bouncer.json` |
| Dragonfly Operator | Dragonfly Dashboard | official: dragonflydb/dragonfly-operator repo `monitoring/grafana-dashboard.json` (linked from dragonflydb.io docs); `__inputs` converted to a datasource variable |
| Envoy Gateway | Envoy Gateway Global, Envoy Clusters, Envoy Global, Global Ratelimit, Resources Monitor | official: envoyproxy/gateway repo `charts/gateway-addons-helm/dashboards/`; upstream's stale target-level datasource uids normalized to the panels' `$datasource` variable |
| ExternalDNS | ExternalDNS | custom (official Available Metrics docs; the project publishes no dashboard) |
| External Secrets | External Secrets Operator | official: chart-bundled monitoring dashboard; `service=~` matchers rewritten to `namespace` |
| FlareSolverr | FlareSolverr | custom (flaresolverr `src/metrics.py`: `flaresolverr_request_total`, the `flaresolverr_request_duration` histogram, plus the Python process collector; no official dashboard) |
| Forgejo | Forgejo | custom (forgejo `modules/metrics/collector.go`; the project publishes no dashboard — the gitea-monitoring mixin is a third-party fork) |
| Grafana | Grafana Overview | official: grafana/grafana repo `grafana-mixin/dashboards/grafana-overview.json` |
| Grafana Operator | Grafana Operator | custom (grafana-operator `controllers/metrics/metrics.go` plus controller-runtime metrics; no official dashboard) |
| Home Assistant | Home Assistant | custom (HA prometheus integration, `components/prometheus`; no official dashboard) |
| Immich | Immich | custom (OTel `http_server_duration` metrics and `immich_queues_*` gauges verified in the immich source; the project publishes no dashboard) |
| Jellyfin | Jellyfin | custom (Jellyfin `EnableMetrics`: prometheus-net.AspNetCore `http_*` and prometheus-net `process_*`/`dotnet_*` families; Jellyfin publishes no dashboard and no media-level metrics) |
| Kubelet Serving Cert Approver | Kubelet Serving Cert Approver | custom (alex1989hu/kubelet-serving-cert-approver metrics table; no official dashboard) |
| Kubernetes Control Plane | Kubernetes API Server, Kubernetes Scheduler, Kubernetes Controller Manager | custom (Kubernetes source metric families — `apiserver_*`, `scheduler_*`, `workqueue_*`, and kube-state-metrics' `kube_lease_owner` for the leader panels, since k3s serves no `leader_election_master_status`; the Kubernetes project publishes no dashboards) |
| Kubernetes Control Plane | etcd | official: etcd-io/website `op-guide/grafana.json` for the etcd minor k3s embeds, linked from the etcd Monitoring guide; datasource variable defaulted to `prometheus`; its `cluster` variable selects the etcd ScrapeConfig job |
| kured | kured | custom (kured's `kured_reboot_required` gauge and Go process collector from its `cmd/kured` source, plus vmalert's `ALERTS` series that gate reboots; the project publishes no dashboard) |
| Kube State Metrics | Kube State Metrics | custom (kube-state-metrics standard `kube_*` families from its own docs; the project ships no dashboard); panels match the scrape job because `kube_*` series carry the target's namespace, not the exporter's |
| Lidarr | Lidarr | official: the exportarr project's bundled dashboard (onedr0p/exportarr `examples/grafana/dashboard2.json`, the Lidarr row), split per app like the qBittorrent exporter's; `__inputs` converted to a datasource variable, instance matchers scoped to the `lidarr` namespace, cAdvisor `container_*` panels dropped (not collected here) |
| Longhorn | Longhorn Example v1.1.0 | official: grafana.com 13032, the dashboard referenced by the longhorn.io monitoring docs; `__inputs` converted to a datasource variable |
| MariaDB Operator | MySQL | official: prometheus/mysqld_exporter repo `mysqld-mixin/dashboards/mysql-overview.json` at the exporter version MariaDB CRs pin (the mariadb-operator project publishes no dashboard); unmodified, its prometheus-type datasource variable resolves to the compatibility datasource |
| metrics-server | Metrics Server | custom (metrics-server `metrics_server_manager_tick_duration_seconds` plus component-base apiserver metrics; no official dashboard) |
| Navidrome | Navidrome | custom (navidrome `core/metrics/prometheus.go`: `db_model_totals`, `navidrome_info`, `media_scan_last`, `media_scans`, `http_request_count`, `http_request_latency`, plus go_/process_; the grafana.com Navidrome dashboards are third-party) |
| Notesnook | Notesnook | custom (notesnook sync `SyncEventCounterSource` meter; DocumentDB `documentdb_postgres_up` per the operator monitoring contract) |
| OpenCloud | OpenCloud | custom (docs.opencloud.eu proxy metrics, `opencloud_proxy_*`; no official dashboard) |
| OpenTelemetry Collector | OpenTelemetry Collector | custom (otelcol self-observability metrics verified against the opentelemetry-collector source; the project publishes no production dashboard — the demo repo's dashboard is demo-tailored and the helm-charts port is unmerged); scoped by the self-scrape job label, since static targets carry no namespace label |
| Prowlarr | Prowlarr | official: the exportarr project's bundled dashboard (onedr0p/exportarr `examples/grafana/dashboard2.json`, the Prowlarr row), split per app like the qBittorrent exporter's; `__inputs` converted to a datasource variable, instance matchers scoped to the `prowlarr` namespace, cAdvisor `container_*` panels dropped (not collected here) |
| qBittorrent | qBittorrent | official: martabal/qbittorrent-exporter bundled dashboard; `__inputs` converted to a datasource variable |
| Radarr | Radarr | official: the exportarr project's bundled dashboard (onedr0p/exportarr `examples/grafana/dashboard2.json`, the Radarr row), split per app like the qBittorrent exporter's; `__inputs` converted to a datasource variable, instance matchers scoped to the `radarr` namespace, cAdvisor `container_*` panels dropped (not collected here) |
| RustFS | RustFS | custom (docs.rustfs.com observability metrics reference; OTLP-pushed `rustfs_*`; the grafana.com RustFS dashboards are third-party) |
| RustFS Operator | RustFS Operator | custom (rustfs/operator `src/metrics.rs`; duration metrics are summaries, so averages come from `_sum`/`_count`) |
| Snapshot Controller | Snapshot Controller | custom (kubernetes-csi external-snapshotter; controller-runtime `workqueue_*`/`rest_client_*`/`go_*`/`process_*` families; upstream ships no dashboard) |
| Sonarr | Sonarr | official: the exportarr project's bundled dashboard (onedr0p/exportarr `examples/grafana/dashboard2.json`, the Sonarr row), split per app like the qBittorrent exporter's; `__inputs` converted to a datasource variable, instance matchers scoped to the `sonarr` namespace, cAdvisor `container_*` panels dropped (not collected here) |
| Unpackerr | Unpackerr | custom (unpackerr `pkg/unpackerr/metrics.go`: `unpackerr_gauges`, `unpackerr_counters`, `unpackerr_app_queue_*`, `unpackerr_bytes_written_total`, `unpackerr_files_extracted_total`, `unpackerr_archives_read_total`, `unpackerr_extract_time_seconds`, plus go_/process_; the project publishes no dashboard) |
| Velero | Velero Backups | custom (velero `pkg/metrics/metrics.go`; the project publishes no dashboard — the grafana.com ones are third-party) |
| VictoriaMetrics | VictoriaMetrics - single-node (VM), VictoriaLogs - single-node (VM), VictoriaTraces - single-node, VictoriaMetrics - vmalert | official: VictoriaMetrics repo `dashboards/vm/` variants for VM and VictoriaLogs, grafana.com 24136 (VictoriaMetrics org) for VictoriaTraces; the VictoriaLogs `__inputs` convention converted to a datasource variable; vmalert from the same repo's `dashboards/vmalert.json` |
| Woodpecker | Woodpecker CI | custom (woodpecker `server/metric/metrics_server.go`; no official dashboard; step-level metrics are not enabled in this deployment) |

Apps without collectible metrics have no folder: `admission-policies` and
`prometheus-operator-crd` deploy no workloads; `csi-driver-nfs` runs only its
node plugin, whose metrics listener belongs to the omitted controller;
`system-upgrade-controller` serves no metrics endpoint; `actual-budget` serves
only a JSON `/metrics` (process memory and uptime, not Prometheus); `homepage`, `radicale`,
`openchamber`, `velero-ui`, and `opentelemetry-operator` expose no scrapeable
metrics; of the media stack, `seerr`, `maintainerr`, `cleanuparr`, `houndarr`,
`audiobookshelf`, `streamystats`, `audiomuse-ai` and `feishin` serve no
Prometheus endpoint (their PostgreSQL clusters are covered by the
CloudNativePG folder), and the `recyclarr`, `qbit-manage`, `media-config`,
`beets` and `jellyfin-auto-collections` jobs and the
`intel-gpu-plugin` expose none; the DocumentDB operator's controller-runtime metrics endpoint is
disabled upstream with no chart toggle. Apps whose only metrics are the
shared CloudNativePG instance metrics (`vaultwarden`, `homeassistant` and the
other CNPG-backed apps) are covered by the CloudNativePG folder's dashboards
and the per-cluster 60s PodMonitors rather than a folder of their own.
`supernote` exposes no application metrics either: its MariaDB instance
(operator-generated mysqld-exporter ServiceMonitor) and Dragonfly cache
(60s PodMonitor) are covered by the MariaDB Operator and Dragonfly Operator
folders.

## Adding a dashboard

1. Put the JSON at `apps/grafana/dashboards/<app>/<dashboard>.json` (unique uid).
2. Add a `configMapGenerator` entry (`grafana-dashboard-<dashboard>`) in
   `apps/grafana/kustomization.yaml`.
3. Add a `GrafanaDashboard` CR with `spec.folderRef: folder-<app>` in
   `apps/grafana/1_dashboards_<app>.yaml` (create the file and the folder CR for
   new apps).
4. Verify every referenced metric against the app's upstream source or official
   documentation, and cite the provenance in the dashboard `description`.
5. Run `scripts/check-dashboards.sh`.
