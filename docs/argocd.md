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
   * syncthing
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