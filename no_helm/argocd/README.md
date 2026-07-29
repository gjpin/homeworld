# Argo CD rendered manifests

These manifests are generated from the `argo-cd` Helm chart version `9.5.9`
using the `valuesObject` in `apps/argocd/1_helm.yaml`.

The Prometheus Operator API version is passed explicitly because its CRDs are
installed in sync wave 1 and the chart conditionally renders ServiceMonitors
only when that API is available.

```bash
helm template argocd argo-cd \
  --repo https://argoproj.github.io/argo-helm \
  --version 9.5.9 \
  --namespace argocd \
  --include-crds \
  --api-versions monitoring.coreos.com/v1 \
  --output-dir no_helm \
  -f <(yq eval '.spec.source.helm.valuesObject' apps/argocd/1_helm.yaml)
```

Helm writes the chart directory as `no_helm/argo-cd`; rename it to
`no_helm/argocd` after rendering.
