# Domains
```
- argocd.${BASE_DOMAIN}
- grpc.argocd.${BASE_DOMAIN}
- grafana.${BASE_DOMAIN}
- immich.${BASE_DOMAIN}
- longhorn.${BASE_DOMAIN}
- nextcloud.${BASE_DOMAIN}
```

# Variables
```bash
# argocd, grafana, immich, longhorn, nextcloud
export BASE_DOMAIN=domain.com

# external-dns, cert-manager
export CLOUDFLARE_API_TOKEN=

# cert-manager
export ACME_EMAIL=

# external-dns
export EXTERNAL_IP=10.0.0.1

# longhorn
export LONGHORN_ENCRYPTION_PASSPHRASE=

# nextcloud
export NEXTCLOUD_USERNAME=
export NEXTCLOUD_PASSWORD=

# grafana
export GRAFANA_USERNAME=
export GRAFANA_PASSWORD=

# gigapipe
export GIGAPIPE_CLICKHOUSE_PASSWORD=
```

# Helm repos
```bash
# argo
helm repo add argo https://argoproj.github.io/argo-helm

# cert-manager
helm repo add cert-manager https://charts.jetstack.io

# cloudnative-pg
helm repo add cloudnative-pg https://cloudnative-pg.io/charts

# external-dns
helm repo add external-dns https://kubernetes-sigs.github.io/external-dns/

# longhorn
helm repo add longhorn https://charts.longhorn.io

# metrics-server
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/

# nextcloud
helm repo add nextcloud https://nextcloud.github.io/helm

# otel-collector
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts

# clickhouse
helm repo add altinity-clickhouse-operator https://docs.altinity.com/clickhouse-operator/
```

# New component checklist
- fullnameOverride
- requests/limits
- autoscaling (hpa)
- nodeselector
- httproute + gateway listener (if applicable)
- serviceMonitor