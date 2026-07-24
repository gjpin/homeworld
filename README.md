# Apps
| App | Domains | Description | Link | Notes |
| --- | --- | --- | --- | --- |

# Domains
* argocd.${BASE_DOMAIN}
* authentik.${BASE_DOMAIN}
* envoy.${BASE_DOMAIN}
* git.${BASE_DOMAIN}
* grpc.argocd.${BASE_DOMAIN}
* grafana.${BASE_DOMAIN}
* home.${BASE_DOMAIN}
* longhorn.${BASE_DOMAIN}
* openobserve.${BASE_DOMAIN}
* photos.${BASE_DOMAIN}
* syncthing.${BASE_DOMAIN}

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

# s3 operator
helm repo add inseefrlab-s3operator https://inseefrlab.github.io/s3-operator
```

# Network egress
Cilium and its `CiliumClusterwideNetworkPolicy` CRD must be installed before
Argo CD syncs this repository. The sync wave 0 network policy blocks egress to
the Cilium `world` entity from application namespaces. `world` includes both
LAN and Internet destinations.

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

# ArgoCD
* **Sync wave 0**
   * network-policies: Cilium cluster-wide world-egress restriction
* **Sync wave 1**
   * prometheus-operator-crd: CRDs required by service monitors
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
   * s3-operator: minio bucket/policies operator
   * openobserve: standalone logs, metrics, and traces backend
* **Sync wave 6**
   * immich
   * otel-collector
   * forgejo
   * grafana

# Testing
* Add 'homelab' role to all nodes:
```bash
kubectl label nodes --all node-role.kubernetes.io/homelab=homelab
```

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
