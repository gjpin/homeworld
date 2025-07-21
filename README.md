# Domains
```
- argocd.${BASE_DOMAIN}
- grpc.argocd.${BASE_DOMAIN}
- longhorn.${BASE_DOMAIN}
- nextcloud.${BASE_DOMAIN}
```

# Variables
```bash
# argocd, nextcloud, longhorn
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
```

# Helm repos
```bash
# argo
helm repo add argo https://argoproj.github.io/argo-helm

# cert-manager
helm repo add cert-manager https://charts.jetstack.io

# external-dns
helm repo add external-dns https://kubernetes-sigs.github.io/external-dns/

# metrics-server
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/

# longhorn
helm repo add longhorn https://charts.longhorn.io

# opentelemetry
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts

# sealed-secrets
helm repo add sealed-secrets https://bitnami-labs.github.io/sealed-secrets
```

# Documentation
[external-dns annotations](https://github.com/kubernetes-sigs/external-dns/blob/master/docs/annotations/annotations.md)

# New component checklist
- fullnameOverride
- requests/limits
- autoscaling
- nodeselector
- httproute + gateway listener (if applicable)