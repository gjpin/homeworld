# AGENTS.md

## Repository purpose

This repository manages a Kubernetes homelab through Argo CD. Most changes are
declarative Kubernetes resources or Argo CD `Application` resources that install
version-pinned Helm charts. It also contains Grafana dashboard exports.

## Scope

- Treat `incubator/` as out of scope, unless explicitly asked to work on it.
- Do not inspect, search, edit, validate, or derive conventions from that
  directory unless the user explicitly asks for work in one of them.
- Preserve unrelated working-tree changes.

## Layout

- `apps/app-of-apps.yaml`: root Argo CD applications and dependency sync waves.
- `apps/<component>/`: manifests for one component. Numbered filenames express
  the intended apply/read order.
- `apps/grafana/dashboards/`: imported Grafana dashboard JSON.
- `README.md`: required environment variables, bootstrap notes, and sync-wave documentation.

## Manifest conventions

- Match the style and resource structure of the nearest component; avoid broad
  reformatting or cleanup in focused changes.
- Use two-space YAML indentation and `---` between multiple documents.
- Set `metadata.namespace` explicitly when the resource is namespaced.
- Pin container images, chart versions, and remote revisions. Do not introduce
  floating tags such as `latest`.
- Helm installations are rendered from pinned upstream charts under
  `apps/<component>/helm/` (or `apps/otel-collector/helm/{<helm>}/`
  when multiple releases exist). Argo CD `Application` resources and CI
  point directly to these directories.
  Preserve the existing automated sync policy and sync options unless the
  change specifically requires otherwise.
- Keep service names, selectors, labels, PVC references, route backends, and
  namespaces consistent across all resources in a component.
- Workloads should target homelab nodes using
  `node-role.kubernetes.io/homelab: homelab` where the chart or manifest supports
  a node selector.
- Enable metrics and a `ServiceMonitor` when the component supports them; always set the ServiceMonitor interval to `60s`.
- Public HTTP/gRPC endpoints use Gateway API resources plus the
  `external-dns.alpha.kubernetes.io/hostname` annotation. Keep Gateway listeners,
  route hostnames, TLS hostnames, and backend ports aligned.
- Preserve `${VARIABLE}` placeholders in tracked files. They are intended for
  `envsubst` during deployment.
- Never place real credentials, tokens, passwords, private keys, or substituted
  secret values in the repository. Prefer the existing External Secrets /
  Infisical pattern for new secret material.
- Every PostgreSQL database must be provisioned as a CloudNativePG `Cluster`
  instance; do not deploy application-bundled PostgreSQL.
- Every Redis or Redis-compatible datastore must be provisioned as Dragonfly;
  do not deploy application-bundled Redis.
- Every Argo CD `Application` resource (root in `apps/app-of-apps.yaml` and child
  manifests under `apps/<component>/`) must declare `ServerSideApply=true` under
  `spec.syncPolicy.syncOptions` by default to prevent client-side apply
  annotation size limit errors (e.g. 256 KB `kubectl.kubernetes.io/last-applied-configuration`)
  on large custom resources and CRD updates.
- Intra-component manifests must follow the standard 5-phase sync wave sequence
  when ordering dependencies exist:
  - Wave `-2`: `CiliumNetworkPolicy` (and `-3` for early bootstrap policies)
  - Wave `-1`: `ExternalSecret`
  - Wave `0`: Datastores (CNPG `Cluster`, Dragonfly, Tenant), foundational Gateway listeners, PVCs
  - Wave `1`: Workload child `Application`s, Deployments, StatefulSets
  - Wave `2`: `HTTPRoute`, `GRPCRoute`, and `SecurityPolicy`
  Omit `sync-wave` on resources that do not have ordering dependencies (defaulting to wave 0). Do not keep redundant `sync-wave: "0"` annotations on standalone resources like `ReferenceGrant` or `PodMonitor`.
- CRDs must always precede custom resources: when CRDs and custom resources
  coexist in the same directory, use sync waves to apply CRDs first and retain
  `SkipDryRunOnMissingResource=true` under sync options or annotations to avoid
  pre-sync OpenAPI validation failures.

## Pod security conventions

- Every workload must satisfy Kubernetes Restricted Pod Security Standards, or
  be as close to Restricted as the workload's documented function permits. This
  includes Deployments, StatefulSets, DaemonSets, Jobs, hooks, init containers,
  sidecars, ephemeral containers, and operator-generated pods.
- Use these defaults wherever the image and chart support them:

  ```yaml
  podSecurityContext:
    runAsNonRoot: true
    seccompProfile:
      type: RuntimeDefault
  securityContext:
    allowPrivilegeEscalation: false
    capabilities:
      drop:
        - ALL
  ```

  Use the chart's exact value keys and apply equivalent fields to handwritten
  resources. Set `runAsUser` and `runAsGroup` only after verifying the image's
  supported UID/GID and writable paths; do not enable
  `readOnlyRootFilesystem` blindly.
- Review rendered resources, not only Helm values. Verify every pod-producing
  object in `homelab`, including init containers, hooks, and operands
  generated by CNPG, Dragonfly, Grafana, RustFS, and other operators.
- The Argo CD Application that creates a namespace owns its Pod Security
  Admission labels through `syncPolicy.managedNamespaceMetadata`. Stage
  changes with Restricted `audit` and `warn` labels, then enable Restricted
  enforcement only after rendered and live admission results are clean. Pin
  label versions to the cluster's Kubernetes minor version.
- Host integration, hostPath, host ports, device access, or unavoidable root
  execution may use a broader profile only when required for documented
  functionality. Isolate such workloads in a dedicated namespace, retain
  Restricted audit/warn labels, and document the reason in namespace metadata
  and resource-specific scanner exceptions. Do not hide mixed workloads behind
  wildcard or namespace-wide scanner exclusions.
- A close-to-Restricted exception must still use non-root execution where
  possible, `RuntimeDefault` seccomp, no privilege escalation, and dropped
  capabilities. Prefer splitting node-level or host-integrated workloads from
  ordinary Restricted workloads rather than weakening an entire namespace.

## Kubernetes 1.36 user namespaces

- Opt every compatible Pod into user namespaces with `spec.hostUsers: false`.
  For Helm workloads, use the chart's exact value key (prefered) or a rendered Kustomize
  patch. For operator-generated Pods, use a supported operator pod-template or
  patch mechanism; do not add unknown fields to a custom resource.
- Review rendered resources in `homelab`, including Deployments, StatefulSets,
  DaemonSets, Jobs, hooks, init containers, sidecars, ephemeral containers, and
  operator-generated operands. Verify the final Pod specs contain
  `hostUsers: false`, not only the input values.
- A Pod with `hostUsers: false` must not use `hostNetwork`, `hostIPC`, or
  `hostPID`, and must not use `volumeDevices` or NFS volumes. Preserve
  `hostUsers: true` or the default only for documented host integration,
  unsupported operator-generated Pods, or incompatible filesystems, and add a
  resource-scoped exception explaining the reason.
- Recheck existing Pods after changing admission policies or generated Pod
  templates; user-namespace mutations apply when Pods are created or recreated.

## New component checklist

- `fullnameOverride`
- `nodeSelector`
- Gateway listener and `HTTPRoute` (if applicable)
- `ServiceMonitor`
- `ServerSideApply=true` in `spec.syncPolicy.syncOptions` for all `Application` resources
- Standard intra-component sync waves (-2 network policy, -1 secrets, 0 datastore/gateway, 1 workload, 2 routes)
- Add the destination namespace to the world-egress policy selector, or explicitly justify an egress exception.
- Set requests and limits on all regular, init, and sidecar containers. Preserve
  higher upstream values; use the documented profile fallbacks when absent.
- Autoscaling (HPA/KEDA) is intentionally disabled unless the user requests a policy change.

## Adding or changing a component

- Check the upstream chart/image documentation before changing a version or
  values schema.
- Before modifying an existing Helm installation or adding a new one, render
  the exact pinned chart with the proposed values and inspect the generated
  resources. Ground chart versions, value keys, resource names, selectors,
  ports, generated secrets, CRDs, and other integration details in that render
  rather than assumptions from defaults or documentation alone.
- For a new component, create `apps/<component>/` and order manifests with
  numeric filename prefixes when dependencies exist.
- Add the component to `apps/app-of-apps.yaml` with the correct destination
  namespace and dependency sync wave. Keep the sync-wave explanation in
  `README.md` accurate.
- Check whether the component's pinned chart, image, or remote revision is
  covered by `renovate.json`; update Renovate configuration when its existing
  managers and matchers do not support the new dependency field.
- Apply the new-component checklist as applicable.
- Treat CRDs and operators as dependencies: they must be installed in an earlier
  sync wave than resources that use them.
- Do not run `kubectl apply`, `helm install/upgrade` or Argo CD sync
  unless the user explicitly asks to change a live system.

## Validation

Run checks relevant to the files changed:

```bash
# Parse every in-scope Kubernetes YAML file.
find apps -type f -name '*.yaml' -not -path '*/charts/*' -print0 |
  xargs -0 -n1 yq eval '.' >/dev/null

# Parse every Grafana dashboard.
find apps/grafana/dashboards -type f -name '*.json' -print0 |
  xargs -0 -n1 jq empty
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
- Update documentation in `docs/` whenever architectural changes, operational
  workflows, sync ordering, or manifest conventions affect, invalidate, or alter
  the descriptions there.
