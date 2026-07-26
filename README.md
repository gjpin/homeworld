# Apps

| App | Domain(s) | Description |
| --- | --- | --- |
| Argo CD | `argocd.${BASE_DOMAIN}`<br>`grpc.argocd.${BASE_DOMAIN}` | GitOps continuous delivery and its gRPC API. |
| Authentik | `auth.${BASE_DOMAIN}` | Identity provider. |
| cert-manager | — | TLS certificate management. |
| CloudNativePG | — | PostgreSQL operator. |
| Dragonfly Operator | — | Dragonfly, a Redis-compatible datastore, operator. |
| Envoy Gateway | `envoy.${BASE_DOMAIN}` | Gateway API implementation and control-plane metrics. |
| ExternalDNS | — | DNS record management. |
| External Secrets | — | Infisical-backed secret synchronization. |
| Forgejo | `git.${BASE_DOMAIN}` | Git forge. |
| Grafana | `grafana.${BASE_DOMAIN}` | Dashboards and observability visualization. |
| Grafana Operator | — | Grafana instance, dashboard, and datasource operator. |
| Home Assistant | `home.${BASE_DOMAIN}` | Home automation. |
| Immich | `photos.${BASE_DOMAIN}` | Photo and video management. |
| Longhorn | `longhorn.${BASE_DOMAIN}` | Distributed block-storage management. |
| OpenObserve | `openobserve.${BASE_DOMAIN}` | Logs, metrics, and traces backend. |
| OpenTelemetry Collector | — | Telemetry collection and export. |
| Prometheus Operator CRDs | — | Custom resource definitions required for monitoring resources. |
| Radicale | `contacts.${BASE_DOMAIN}` | CalDAV and CardDAV server. |
| Syncthing | `sync.${BASE_DOMAIN}` | Peer-to-peer file synchronization. |

# Variables
```bash
# public HTTP routes
export BASE_DOMAIN=domain.com

# external-dns, cert-manager
export CLOUDFLARE_API_TOKEN= # API token with DNS edit permissions for the zone

# cert-manager
export ACME_EMAIL=

# external-dns
export EXTERNAL_IP=10.0.0.1

# external-secrets
export INFISICAL_CLIENT_ID=
export INFISICAL_CLIENT_SECRET=
export INFISICAL_HOST=https://app.infisical.com
export INFISICAL_PROJECT_SLUG=
export INFISICAL_ENVIRONMENT_SLUG=dev

```

# Secrets
* Create secrets in cluster:
```bash
envsubst < secrets.yaml | kubectl apply -f -
```

# Helm repos
```bash
# argo
helm repo add argo https://argoproj.github.io/argo-helm

# cert-manager
helm repo add cert-manager https://charts.jetstack.io

# clickhouse
helm repo add altinity-clickhouse-operator https://docs.altinity.com/clickhouse-operator/

# cloudnative-pg
helm repo add cloudnative-pg https://cloudnative-pg.io/charts

# external-dns
helm repo add external-dns https://kubernetes-sigs.github.io/external-dns/


# kube-prometheus-stack
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts

# longhorn
helm repo add longhorn https://charts.longhorn.io

# metrics-server
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/

# otel-collector
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts

# openobserve
helm repo add openobserve https://charts.openobserve.ai

```

# Network egress
Cilium and its `CiliumNetworkPolicy` CRD must be installed before Argo CD syncs
this repository. Each protected application includes a namespaced policy that
blocks egress to the Cilium `world` entity. `world` includes both LAN and
Internet destinations.

Internet-capable exceptions: Argo CD (Git), cert-manager (ACME), external-dns (DNS provider), and external-secrets (Infisical).

# Grafana admin credentials
Create the following values in Infisical before syncing Grafana:

* `/grafana/GF_SECURITY_ADMIN_USER`
* `/grafana/GF_SECURITY_ADMIN_PASSWORD`

# OpenObserve credentials
Create the following values in Infisical before syncing OpenObserve, the OTel
Collector, and Grafana:

* `/openobserve/ZO_ROOT_USER_EMAIL`
* `/openobserve/ZO_ROOT_USER_PASSWORD`
* `/openobserve/OTLP_AUTHORIZATION` (the complete `Basic <base64(email:password)>` header)

# Longhorn encryption credential
Create the following value in Infisical before syncing Longhorn:

* `/longhorn/CRYPTO_KEY_VALUE`

# PostgreSQL application credentials
Create the following values in Infisical before syncing CloudNativePG and its
database consumers:

* `/authentik/POSTGRES_USERNAME`
* `/authentik/POSTGRES_PASSWORD`
* `/forgejo/POSTGRES_USERNAME`
* `/forgejo/POSTGRES_PASSWORD`
* `/immich/POSTGRES_USERNAME`
* `/immich/POSTGRES_PASSWORD`

Set each `POSTGRES_USERNAME` value to its matching application role:
`authentik`, `forgejo`, or `immich`.

# Authentik and Dragonfly credentials
Create the following values in Infisical before syncing Authentik and Immich:

* `/authentik/AUTHENTIK_SECRET_KEY`
* `/authentik/DRAGONFLY_PASSWORD`
* `/immich/DRAGONFLY_PASSWORD`

# ArgoCD
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
   * argocd
   * cloudnative-pg: postgresql operator
   * dragonfly-operator: dragonfly (redis-compatible) operator
   * grafana-operator: Grafana instance, dashboard, and datasource operator
   * TBD (rustfs / garage): s3-compatible storage operator
* **Sync wave 5**
   * openobserve: standalone logs, metrics, and traces backend
* **Sync wave 6**
   * authentik
   * homeassistant
   * immich
   * otel-collector
   * forgejo
   * grafana
   * radicale
   * syncthing

# Testing
* Add 'homelab' role to all nodes:
```bash
kubectl label nodes --all node-role.kubernetes.io/homelab=homelab
```

# Dependency updates
Renovate runs daily at 04:17 UTC and can also be started from the **Run
workflow** button for the `Renovate` GitHub Actions workflow. It opens review
PRs only: updates, including major releases, are never auto-merged. Merging a
reviewed Renovate PR is the only way an update reaches Argo CD; the workflows
do not run `kubectl`, Helm, or Argo CD commands.

Create a GitHub App, install it on this repository, and save its app ID and
private key as these repository Actions secrets:

* `RENOVATE_APP_ID`
* `RENOVATE_APP_PRIVATE_KEY`

Configure the GitHub App permissions as documented for
[self-hosted Renovate](https://docs.renovatebot.com/modules/platform/github/#running-as-a-github-app):

| Permission | Scope |
| --- | --- |
| Checks | `read` + `write` |
| Commit statuses | `read` + `write` |
| Contents | `read` + `write` |
| Issues | `read` + `write` |
| Pull requests | `read` + `write` |
| Workflows | `read` + `write` |
| Administration | `read` |
| Dependabot alerts | `read` |
| Members | `read` |
| Metadata | `read` |

The installation token is generated per workflow run and is not stored in the
repository. Renovate updates Argo CD Helm and Git-tag revisions, explicit
container images, and the CloudNativePG, Grafana, and OpenObserve image fields.
`apps/app-of-apps.yaml` intentionally remains on `HEAD`; Helm image repository
overrides without an explicit tag continue to inherit their chart's image tag.

* Enable minikube's metrics-server addon
```bash
minikube addons enable metrics-server
```

* Bootstrap Argo
```bash
# Add ArgoCD helm repo
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update

# Install ArgoCD
helm install argocd argo/argo-cd \
  --version 8.2.2 \
  --namespace argocd \
  --create-namespace \
  -f configs/argocd/helm_values.yaml
```

* Access ArgoCD UI:
```bash
# Get default secret
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d && echo

# Port forward UI
kubectl port-forward -n argocd svc/argocd-server 8080:80

# Access: admin:$password
```
