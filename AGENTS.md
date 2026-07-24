# AGENTS.md

## Repository purpose

This repository manages a Kubernetes homelab through Argo CD. Most changes are
declarative Kubernetes resources or Argo CD `Application` resources that install
version-pinned Helm charts. It also contains Grafana dashboard exports and a host
bootstrap script.

## Scope

- Treat `todo/`, `secrets/`, `incubator/`, and `configs/` as out of scope.
- Do not inspect, search, edit, validate, or derive conventions from those
  directories unless the user explicitly asks for work in one of them.
- The exclusion applies to those directories, not to Kubernetes resources such
  as `apps/*/*_secrets.yaml`.
- Preserve unrelated working-tree changes.

## Layout

- `apps/app-of-apps.yaml`: root Argo CD applications and dependency sync waves.
- `apps/<component>/`: manifests for one component. Numbered filenames express
  the intended apply/read order.
- `grafana-dashboards/`: imported Grafana dashboard JSON.
- `setup.sh`: Fedora/k3s host bootstrap and initial Argo CD installation.
- `README.md`: required environment variables, bootstrap notes, sync-wave
  documentation, and the new-component checklist.

## Manifest conventions

- Match the style and resource structure of the nearest component; avoid broad
  reformatting or cleanup in focused changes.
- Use two-space YAML indentation and `---` between multiple documents.
- Set `metadata.namespace` explicitly when the resource is namespaced.
- Pin container images, chart versions, and remote revisions. Do not introduce
  floating tags such as `latest`.
- Helm installations are represented as Argo CD `Application` resources with
  inline `spec.source.helm.valuesObject`. Preserve the existing automated sync
  policy and sync options unless the change specifically requires otherwise.
- Keep service names, selectors, labels, PVC references, route backends, and
  namespaces consistent across all resources in a component.
- Workloads should target homelab nodes using
  `node-role.kubernetes.io/homelab: homelab` where the chart or manifest supports
  a node selector.
- Enable metrics and a `ServiceMonitor` when the component supports them.
- Public HTTP/gRPC endpoints use Gateway API resources plus the
  `external-dns.alpha.kubernetes.io/hostname` annotation. Keep Gateway listeners,
  route hostnames, TLS hostnames, and backend ports aligned.
- Preserve `${VARIABLE}` placeholders in tracked files. They are intended for
  `envsubst` during deployment.
- Never place real credentials, tokens, passwords, private keys, or substituted
  secret values in the repository. Prefer the existing External Secrets /
  Infisical pattern for new secret material.

## Adding or changing a component

- Check the upstream chart/image documentation before changing a version or
  values schema.
- For a new component, create `apps/<component>/` and order manifests with
  numeric filename prefixes when dependencies exist.
- Add the component to `apps/app-of-apps.yaml` with the correct destination
  namespace and dependency sync wave. Keep the sync-wave explanation in
  `README.md` accurate.
- Apply the README checklist as applicable: stable name override, homelab node
  selector, Gateway/HTTPRoute listener, and ServiceMonitor. Resource
  requests/limits and autoscaling are intentionally disabled unless the user
  requests a policy change.
- Treat CRDs and operators as dependencies: they must be installed in an earlier
  sync wave than resources that use them.
- Do not run `kubectl apply`, `helm install/upgrade`, Argo CD sync, or `setup.sh`
  unless the user explicitly asks to change a live system.

## Validation

Run checks relevant to the files changed:

```bash
# Parse every in-scope Kubernetes YAML file.
find apps -type f -name '*.yaml' -print0 |
  xargs -0 -n1 yq eval '.' >/dev/null

# Parse every Grafana dashboard.
find grafana-dashboards -type f -name '*.json' -print0 |
  xargs -0 -n1 jq empty

# Check the bootstrap script after shell changes.
shellcheck setup.sh
```

Also inspect the diff for accidental secret substitution and verify cross-file
references manually. Cluster-side schema validation is useful only when the
required CRDs are installed; report when validation could not cover custom
resources rather than claiming full cluster compatibility.

## Change discipline

- Keep commits and patches narrowly scoped.
- Do not edit generated/imported dashboard JSON unless the task concerns that
  dashboard; avoid formatting an entire export for a small semantic change.
- Do not rename or reorganize existing resources merely for consistency.
- Update documentation when environment variables, public domains, bootstrap
  steps, component inventory, or sync ordering change.
