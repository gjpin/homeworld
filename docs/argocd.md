# ArgoCD

## Sync waves
* **Sync wave 0**
   * argocd: enables Helm inflation for the Kustomize-rendered chart profiles
* **Sync wave 1**
   * prometheus-operator-crd: CRDs required by service monitors
   * external-secrets: External Secrets Operator and Infisical ClusterSecretStore
* **Sync wave 2**
   * envoy-gateway: Gateway API and provides CRDs required by HTTP/GRPC routes
* **Sync wave 3**
   * cert-manager: TLS certificates management
   * external-dns: manages DNS records
   * longhorn: block storage
* **Sync wave 4**
   * cloudnative-pg: postgresql operator
   * dragonfly-operator: dragonfly (redis-compatible) operator
   * grafana-operator: Grafana instance, dashboard, and datasource operator
   * rustfs-operator: RustFS storage operator, console, and STS endpoint
   * velero: whole-cluster backups after External Secrets and Longhorn
* **Sync wave 5**
   * crowdsec: PostgreSQL-backed CrowdSec LAPI, Envoy log agent, and AppSec WAF,
     after CloudNativePG and External Secrets
   * openobserve: standalone logs, metrics, and traces backend
   * rustfs: shared S3-compatible storage Tenant, after the RustFS Operator,
     External Secrets, and Longhorn
   * velero-ui: web interface for Velero, after the Velero server
* **Sync wave 6**
   * crowdsec-envoy-bouncer: pinned community Envoy external-auth bouncer,
     after CrowdSec and Envoy Gateway; the Gateway policies remain owned by
     their respective application directories and are fail-closed
   * authelia: OpenCloud identity provider, after CloudNativePG, Dragonfly,
     External Secrets, and Prometheus Operator CRDs
   * homeassistant
   * immich
   * otel-collector
   * forgejo
   * grafana
   * radicale: internal CalDAV and CardDAV backend, before OpenCloud's
     authenticated DAV proxy
* **Sync wave 7**
   * collabora: standalone Collabora chart and WOPI endpoint
* **Sync wave 8**
   * opencloud: OpenCloud, Tika, RustFS storage integration, authenticated DAV
     proxy, and routes

## Application Health Checks

Argo CD does not evaluate the health of `argoproj.io/Application` CRDs by default; custom resources without a defined health check are treated as immediately `Healthy` upon creation. In an App-of-Apps pattern, this default causes the parent application to advance through sync waves immediately without waiting for child applications or their underlying workloads to reconcile.

To enforce strict sync-wave gating, `apps/argocd/helm/values.yaml` configures a custom Lua health check (`resource.customizations.health.argoproj.io_Application`) in `argocd-cm`:

```yaml
resource.customizations.health.argoproj.io_Application: |
  hs = {}
  hs.status = "Progressing"
  hs.message = ""
  if obj.status ~= nil then
    if obj.status.health ~= nil then
      hs.status = obj.status.health.status
      if obj.status.health.message ~= nil then
        hs.message = obj.status.health.message
      end
    end
  end
  return hs
```

### Behavior
- **Default State:** A newly declared or reconciling child application reports `Progressing`.
- **Status Rollup:** Once the child application and all its managed resources reconcile, its health status (`Healthy`, `Progressing`, `Degraded`) is bubbled up to the parent application.
- **Wave Gating:** Sync waves in `apps/app-of-apps.yaml` pause at wave $N$ until every application in that wave reaches `Healthy` before proceeding to wave $N+1$.

## Universal Server-Side Apply

Every Argo CD `Application` resource in this repository—both root applications in `apps/app-of-apps.yaml` and child applications in `apps/<component>/`—enables Server-Side Apply by default:

```yaml
syncPolicy:
  syncOptions:
    - ServerSideApply=true
```

### Rationale & CRD Upgrades
- **256 KB Annotation Limit:** Standard client-side apply serializes the full resource configuration into the `kubectl.kubernetes.io/last-applied-configuration` annotation. Modern Custom Resource Definitions (CRDs)—such as Prometheus Operator, Gateway API, Cert-Manager, and CloudNativePG—regularly exceed the 256 KB annotation size ceiling, causing client-side apply sync operations to fail.
- **CRD and Schema Evolution:** Server-Side Apply offloads merge calculation and field ownership to the Kubernetes API server (`fieldManager: argocd`). This enables declarative CRD upgrades and schema changes without requiring manual kubectl intervention.
- **Universal Uniformity:** Enforcing SSA globally prevents future CRD additions from failing silently or encountering annotation overflow.

## CRD Lifecycle and Upgrade Management

CRD lifecycles are orchestrated through a combination of sync waves, health checks, and Server-Side Apply to guarantee that Custom Resource Definitions are established and upgraded before the workloads that depend on them:

### Consumer Workload Sequencing (App-of-Apps Waves)
In `apps/app-of-apps.yaml`, CRD-providing infrastructure and operators are sequenced strictly ahead of consuming applications:
- **Wave 1:** `prometheus-operator-crd` (ServiceMonitors) and `external-secrets`
- **Wave 2:** `envoy-gateway` (Gateway API and Envoy Gateway CRDs)
- **Wave 3:** `cert-manager` (Certificates and ClusterIssuers)
- **Wave 4:** Datastore operators (`cloudnative-pg`, `dragonfly-operator`, `rustfs-operator`, `grafana-operator`)
- **Waves 5–8:** Applications and workloads consuming those CRDs (`authelia`, `immich`, `forgejo`, `grafana`, `opencloud`, etc.)

Argo CD's custom Lua Application health check pauses wave advancement until all applications in Wave $N$ report `Healthy`, preventing downstream workloads from encountering missing CRD errors during initial deployment or cluster-wide upgrades.

### Declarative CRD Upgrades via Server-Side Apply
Standard Helm (`helm upgrade`) intentionally ignores the `crds/` directory, preventing declarative CRD upgrades. In this repository:
- Operator charts are rendered via Kustomize with `includeCRDs: true`.
- Every `Application` enforces `ServerSideApply=true`.
- On chart version bumps, Argo CD detects CRD schema changes and applies them directly to the Kubernetes API server using Server-Side Apply (`fieldManager: argocd`), avoiding the 256 KB `kubectl.kubernetes.io/last-applied-configuration` annotation limit.

### Resource Ordering Within Sync Waves
Within an individual sync wave, Argo CD sorts manifests by Kubernetes `Kind` priority, applying `CustomResourceDefinition` resources before controller workloads (`Deployment`, `StatefulSet`, `DaemonSet`).

### Dedicated CRD Applications vs. Bundled Helm Releases
- **Standalone CRDs:** Shared ecosystem CRD suites without local controller dependencies (`prometheus-operator-crd` and `gateway-api-crd`) are separated into dedicated Argo CD applications and sync waves.
- **Bundled Operator CRDs:** Operators (`cloudnative-pg`, `cert-manager`, `external-secrets`, `dragonfly-operator`, etc.) bundle their upstream CRDs within their Helm charts, relying on Server-Side Apply and Kind-based sorting for in-place schema upgrades.

## Intra-Component Sync Wave Architecture

While `apps/app-of-apps.yaml` coordinates dependencies across broad system waves (0 through 8), individual component directories use a standardized 5-tier intra-component wave model to sequence dependencies within that component's namespace:

| Tier | Wave | Resource Types | Purpose |
| :--- | :--- | :--- | :--- |
| **Network Isolation** | `-2` (or `-3`) | `CiliumNetworkPolicy` | Enforce egress/ingress firewalling before secrets or pods materialize. |
| **Secret Material** | `-1` | `ExternalSecret` | Fetch and reconcile credentials from Infisical before datastores start. |
| **Datastores & Base** | `0` | CNPG `Cluster`, Dragonfly, RustFS `Tenant`, `Gateway`, `PVC` | Provision databases, caches, listeners, and storage. |
| **Workloads** | `1` | Child `Application`s, `Deployment`, `StatefulSet` | Deploy application workloads, pods, and backend Services. |
| **Routing & Auth** | `2` | `HTTPRoute`, `GRPCRoute`, `SecurityPolicy` | Bind ingress routes and CrowdSec external authentication after Services exist. |

### CRDs and OpenAPI Validation (`SkipDryRunOnMissingResource=true`)
When an application directory deploys both a CRD and custom resources of that kind (e.g. `apps/envoy-gateway` and `apps/cert-manager`), Argo CD runs client dry-run validation during initial sync before any wave begins. Because CRDs are not yet registered on the API server during dry-run, `SkipDryRunOnMissingResource=true` is retained to bypass dry-run validation failures on uninstalled CRDs. Intra-component sync waves then apply CRDs at wave 0 and downstream custom resources at subsequent waves.