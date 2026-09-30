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
- `apps/<component>/`: manifests for one component. Filenames are prefixed with
  their exact Argo CD sync wave (e.g. `-2_network_policy.yaml`, `-1_secrets.yaml`,
  `0_gateway.yaml`, `1_helm.yaml`, `2_http_route.yaml`).
- `apps/grafana/dashboards/`: imported Grafana dashboard JSON.
- `README.md`: required environment variables, bootstrap notes, and sync-wave documentation.

## Manifest conventions

- Match the style and resource structure of the nearest component; avoid broad
  reformatting or cleanup in focused changes.
- Use two-space YAML indentation and `---` between multiple documents.
- Set `metadata.namespace` explicitly when the resource is namespaced.
- Pin container images, chart versions, and remote revisions. Do not introduce
  floating tags such as `latest`.
- Container image references must always be fully qualified with an explicit
  registry (e.g. `docker.io/library/alpine:3.24.2`, `ghcr.io/immich-app/immich-server`);
  never use bare short names like `alpine:3.24.2`. Docker Hub images carry the
  `docker.io/` prefix (with `library/` for official images). This applies to
  handwritten manifests, Helm values, Dockerfiles, and e2e tooling. When a
  chart's default image would render short-form, override
  `image.repository`/`image.registry` in values so the rendered Pod specs stay
  fully qualified, and keep the custom regex managers in `renovate.json` aligned
  with the new image strings.
- Helm installations are rendered from pinned upstream charts under
  `apps/<component>/helm/` (or `apps/otel-collector/helm/{<helm>}/`
  when multiple releases exist). Argo CD `Application` resources and CI
  point directly to these directories.
  Preserve the existing automated sync policy and sync options unless the
  change specifically requires otherwise.
  Always render the chart with proposed values and patches to inspect the
  actual generated manifests rather than relying on input values alone.
  Confirm that all required resources and configurations are actually emitted,
  including `ServiceMonitor` definitions (with the standard `60s` interval),
  Pod Security Standards contexts, user namespaces (`hostUsers: false`), node
  selectors, container requests and limits, services, and port mappings.
- Helm installations must use official upstream charts. When no official
  chart exists, do not adopt an unofficial or community chart: review how
  several unofficial charts package the application (deployment structure,
  config mounts, probes, RBAC, upgrade flow) and implement the component as
  handwritten manifests in this repository's conventions instead. Never
  pin or deploy an unofficial chart directly.
- Keep service names, selectors, labels, PVC references, route backends, and
  namespaces consistent across all resources in a component.
- Workloads should target homelab nodes using
  `node-role.kubernetes.io/homelab: homelab` where the chart or manifest supports
  a node selector.
- Enable metrics and a `ServiceMonitor` when the component supports them; always set the ServiceMonitor interval to `60s`.
  The monitor only works if the application actually serves the scraped endpoint: enable it in application
  config (e.g. Home Assistant's `prometheus:` block with `requires_auth: false`, Woodpecker's
  `server.metrics.enabled`), confirm the scraped port really renders, allow the otel-collector scrape
  path in both components' network policies, and ship a `PodMonitor` (60s) per CNPG `Cluster`.
- Application telemetry, anonymous usage statistics, upgrade checkers, and
  external phone-home mechanisms must be completely disabled across all
  manifests and Helm values unless explicitly requested and documented.
  Applications must not phone home in the background. However, core application
  features and functionality must NOT be disabled or broken in the process;
  when in doubt whether a mechanism is pure telemetry or required for features,
  ask the user.
- Public HTTP/gRPC endpoints use Gateway API resources plus the
  `external-dns.alpha.kubernetes.io/hostname` annotation. Keep Gateway listeners,
  route hostnames, TLS hostnames, and backend ports aligned. Every route backend also
  needs a matching per-service `allow-envoy-backend-<service>` egress CiliumNetworkPolicy
  in `apps/envoy-gateway` (one port per rule — Cilium applies `toPorts` to every
  `toServices` entry) plus an ingress rule on the app side, and a `docs/network-policies.md` row.
- Under default-deny ingress, kubelet readiness/liveness probes are denied too: every
  workload with probes needs a CiliumNetworkPolicy allowing `fromEntities: host` to the
  probe port.
- Preserve `${VARIABLE}` placeholders in tracked files. They are intended for
  `envsubst` during deployment.
- Never place real credentials, tokens, passwords, private keys, or substituted
  secret values in the repository. Prefer the existing External Secrets /
  Infisical pattern for new secret material. Every container env `secretKeyRef`
  must have a matching `data` entry in the component's wave-`-1` ExternalSecret
  and a `docs/secrets.md` row — a missing key fails the pod with
  `CreateContainerConfigError`.
- Charts rendered through `kustomize` keep their `helm.sh/hook` Jobs in the Argo
  sync path, where hook annotations are inert and the immutable Job spec breaks
  every chart bump (the completed Job from the first sync rejects the new image
  tag). Disable such jobs via chart values or patch-delete them from the render
  (Longhorn's `preUpgradeChecker`/uninstall jobs are the canonical example). A
  hook job whose work is genuinely wanted (Longhorn's post-upgrade cleanup) is
  instead converted to an Argo CD sync hook: patch its annotations to
  `argocd.argoproj.io/hook: PostSync` (or `PreSync`) plus
  `argocd.argoproj.io/hook-delete-policy: HookSucceeded` so it runs at the right
  phase with the fresh image and self-deletes instead of blocking upgrades.
  Never let an upgrade-checker or uninstall job run from a synced manifest.
- Every PostgreSQL database must be provisioned as a CloudNativePG `Cluster`
  instance; do not deploy application-bundled PostgreSQL.
- Every Redis or Redis-compatible datastore (including Valkey) must be provisioned
  using the Dragonfly Operator (`Dragonfly` resource); do not deploy
  application-bundled Redis or Valkey.
- Every MongoDB or document database must be provisioned using the DocumentDB
  Kubernetes Operator (`DocumentDB` resource); do not deploy application-bundled
  MongoDB, standalone `mongod` StatefulSets, or unmanaged document datastores.
- Every S3 or object storage requirement must be satisfied by the cluster's
  RustFS Operator or existing shared RustFS `Tenant` store; do not deploy
  application-bundled object storage engines (e.g. MinIO).
- Every `StorageClass` provisioning filesystem volumes must declare the Talos
  SELinux mount option:

  ```yaml
  mountOptions:
    - context=system_u:object_r:ephemeral_t:s0
  ```

  This ensures the CSI driver mounts filesystems with the `ephemeral_t` label
  required for unprivileged and Restricted pod access under Talos SELinux.
  Volumes requested as `volumeMode: Block` contain no filesystem, so they need
  no label.
- Every Argo CD `Application` resource (root in `apps/app-of-apps.yaml` and child
  manifests under `apps/<component>/`) must declare `ServerSideApply=true` under
  `spec.syncPolicy.syncOptions` by default to prevent client-side apply
  annotation size limit errors (e.g. 256 KB `kubectl.kubernetes.io/last-applied-configuration`)
  on large custom resources and CRD updates.
- Intra-component manifests must follow the standard 5-phase sync wave sequence
  when ordering dependencies exist:
  - Wave `-2`: `CiliumNetworkPolicy` (and `-3` for early bootstrap policies)
  - Wave `-1`: `ExternalSecret`
  - Wave `0`: Datastores (CNPG `Cluster`, Dragonfly, DocumentDB, Tenant), foundational Gateway listeners, PVCs
  - Wave `1`: Workload child `Application`s, Deployments, StatefulSets
  - Wave `2`: `HTTPRoute`, `GRPCRoute`, and `SecurityPolicy`
  Omit `sync-wave` on resources that do not have ordering dependencies (defaulting to wave 0). Do not keep redundant `sync-wave: "0"` annotations on standalone resources like `ReferenceGrant` or `PodMonitor`.
- Manifest filenames must be prefixed with their exact Argo CD sync wave:
  `<wave>_<descriptor>.yaml` (e.g. `-2_network_policy.yaml`, `-1_secrets.yaml`,
  `0_postgres.yaml`, `1_helm.yaml`, `2_http_route.yaml`).
  - Manifests must not combine resources from multiple sync waves in a single file;
    split them when distinct waves are required (e.g. `0_postgres.yaml` for CNPG
    `Cluster` and `1_database.yaml` for CNPG `Database`).
  - Resources sharing the same sync wave within a component share the same wave
    prefix and are disambiguated by their descriptive suffix (e.g. `0_pvc.yaml`,
    `0_postgres.yaml`, `0_dragonfly.yaml`, `0_documentdb.yaml`, `0_gateway.yaml`).
  - Resources with omitted sync waves default to wave 0 and must use the `0_` prefix.
- CRDs must always precede custom resources: when CRDs and custom resources
  coexist in the same directory, use sync waves to apply CRDs first and retain
  `SkipDryRunOnMissingResource=true` under sync options or annotations to avoid
  pre-sync OpenAPI validation failures. Newly added apps with CRDs must ensure
  CRDs are installed and upgraded before the application or dependent workloads
  (via earlier sync waves and `ServerSideApply=true`), and `docs/argocd.md`
  must be updated within the existing text to reflect the new CRD provider or consumer.

### Authelia OIDC clients

- Configure every OIDC integration from the official Authelia client guide for
  that application under
  https://www.authelia.com/integration/openid-connect/clients/; follow its
  client definition (scopes, PKCE, redirect URIs, grant types, token endpoint
  auth method). Document any required deviation inline in the Authelia client
  list and in `docs/oidc.md`.
- Confidential clients use `token_endpoint_auth_method: client_secret_basic`.
  Use `client_secret_post` only when the client library cannot send Basic auth
  headers (e.g. the Home Assistant `hass-oidc-auth` plugin, the RustFS console,
  velero-ui) and comment the reason inline.
- Every client sets `require_pkce: true` with `pkce_challenge_method: S256`,
  `consent_mode: pre-configured` with `pre_configured_consent_duration: 1 week`,
  and `access_token_signed_response_alg: RS256`. Exception: the shared Envoy
  Gateway client (`envoy`) sets `require_pkce: false` and
  `access_token_signed_response_alg: none` — Envoy Gateway's OIDC filter sends
  no PKCE, and its access token never leaves Envoy's encrypted session cookie
  (`forwardAccessToken: false`), so no claims can be read from it (official
  Envoy Gateway client guide). The `velero-ui` client also sets
  `require_pkce: false`: velero-ui's passport-oauth2 flow sends no PKCE
  (no official Authelia client guide exists for it).
- CLI or localhost-redirect flows get their own public client
  (`token_endpoint_auth_method: none`, `offline_access` scope,
  `refresh_token` grant); never merge the localhost redirect into the
  confidential client.
- Add a `claims_policy` only when the client cannot hydrate claims from the
  UserInfo endpoint (e.g. Grafana's claims-hydration bug) or when it reads
  claims from the token itself (Authelia 4.39 removed `groups`, `email`,
  `name`, and `preferred_username` from ID tokens by default; clients such as
  Argo CD, which runs without `enableUserInfoGroups`, need a policy restoring
  them — see the `apps` policy in `apps/authelia/helm/configuration.yaml.tmpl`
  and docs/oidc.md). Role mapping follows the custom-claim pattern:
  `definitions.user_attributes` expression + a `claims_policies` entry with
  `custom_claims` + a matching custom scope (see `immich_role`).
- Authelia group names are singular and app-prefixed (`<app>-admin`,
  `<app>-user`) and must exist in the Infisical users database. Exception: the
  cross-app `platform` group gates the gateway-OIDC routes and deliberately
  carries no app prefix.
- Client secrets are stored in Infisical as `/authelia/OIDC_CLIENT_SECRET_<APP>`,
  pulled into the `authelia-files` ExternalSecret as
  `oidc_client_secret_<app>`, and delivered to the app through its own
  ExternalSecret when consumed in-cluster (Grafana/Vaultwarden pattern).
  Home Assistant reads the injected environment variable through the
  `!env_var` tag so the secret never lands on the PVC.
- List every OIDC app origin explicitly in the provider's `cors.allowed_origins`.
- Apps doing server-side token exchange get an `allow-<app>-authelia`
  CiliumNetworkPolicy egress (`toFQDNs: auth.${BASE_DOMAIN}:443`) and a
  matching `docs/network-policies.md` egress entry.
- Public browser-UI routes for workloads with no usable app-native OIDC or
  login must be authenticated by Envoy Gateway itself as the shared `envoy`
  client: one HTTPRoute-scoped `SecurityPolicy` per hostname with
  `mergeType: StrategicMerge` (a route-level policy silently overrides the
  Gateway-level CrowdSec extAuth without it), a
  `https://<host>/oauth2/callback` redirect URI with a matching
  `cookieDomain`, and the `platform` authorization policy; the client secret
  is delivered to each protected app's namespace as the
  `envoy-oidc-client-secret` ExternalSecret (key `client-secret`). Never
  apply this pattern to routes used by non-browser clients
  (CalDAV/CardDAV, WOPI, device pairing, API or CLI endpoints): the OIDC
  redirect cannot complete without a browser. Remove headless consumers of a
  protected route (e.g. Homepage siteMonitors) instead of exempting them.
  Apps that cannot delegate their login at all (Collabora's WOPI route, the
  RustFS operator console, OpenChamber pairing, the Notesnook stack) keep
  app-native access control, with the reason documented in `docs/oidc.md`.
- Apps without native OIDC support may use a pinned community integration
  delivered by a sha256-verified init container (hass-oidc-auth pattern,
  Renovate-tracked). PVC-resident bootstrap configuration (e.g.
  `configuration.yaml`) may be seeded by a rootless init container with
  create-if-missing guards; grant the non-root group PVC write access via the
  pod's `fsGroup` (`fsGroupChangePolicy: OnRootMismatch`), and note that later
  git changes to the seed must be applied by editing the file directly.

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

  Apply security context settings via Helm values when supported, via Kustomize
  patches if not exposed by the chart, or directly in handwritten Deployments,
  StatefulSets, DaemonSets, and Jobs. For operator-managed workloads, use supported
  operator pod-templates, patch mechanisms (e.g. CNPG `podPatch`), or admission
  policies. Set `runAsUser` and `runAsGroup` only after verifying the image's
  supported UID/GID and writable paths; do not enable
  `readOnlyRootFilesystem` blindly.
- If it is a Helm workload, render the chart with proposed values and patches to
  verify that the generated manifests actually contain the required security
  context fields (`runAsNonRoot`, `seccompProfile`, `allowPrivilegeEscalation`,
  `capabilities.drop: [ALL]`). Do not rely on input values alone. Verify every
  pod-producing object in `homelab`, including init containers, hooks, and
  operands generated by CNPG, DocumentDB, Dragonfly, Grafana, RustFS, and other operators.
- Update `docs/pod-security.md` (the Pod Security Standards table) whenever a
  workload's security profile or exception status changes, or when adding a new
  application.
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

## Kubernetes 1.37 user namespaces

- Opt every compatible Pod into user namespaces with `spec.hostUsers: false`.
  For Helm workloads, use the chart's exact value key (preferred) or a Kustomize
  patch if not exposed. For handwritten manifests, declare `hostUsers: false`
  directly in the Pod template spec. For operator-generated Pods, use a supported
  operator pod-template or patch mechanism (e.g. CNPG `podPatch` or
  MutatingAdmissionPolicy); do not add unknown fields to a custom resource.
- For Helm workloads, render the chart with proposed values or patches to
  verify the final Pod specs actually contain `hostUsers: false`, not only the
  input values. Also verify every operator-generated operand and handwritten
  resource.
- Update `docs/pod-security.md` (the User Namespaces table) whenever user
  namespace adoption or exception status changes, or when adding a new
  application.
- A Pod with `hostUsers: false` must not use `hostNetwork`, `hostIPC`, or
  `hostPID`, and must not use `volumeDevices` or NFS volumes. Preserve
  `hostUsers: true` or the default only for documented host integration,
  unsupported operator-generated Pods, or incompatible filesystems, and add a
  resource-scoped exception explaining the reason.
- Recheck existing Pods after changing admission policies or generated Pod
  templates; user-namespace mutations apply when Pods are created or recreated.

## gVisor runtime sandboxing

- Opt every compatible Pod into gVisor runtime sandboxing with `spec.runtimeClassName: gvisor`.
- For Helm workloads, use the chart's exact value key or a Kustomize patch if not exposed. For handwritten manifests, declare `runtimeClassName: gvisor` directly in the Pod template spec. For operator-generated Pods, use a supported operator pod-template or patch mechanism.
- A Pod with `runtimeClassName: gvisor` must not use `hostNetwork`, host block devices, or direct node filesystem integration. Preserve standard runtimes only for the documented exceptions (`cilium-agent`, `cilium-envoy`, `cilium-operator`, `crowdsec-agent`, `generic-device-plugin`, `longhorn-manager`, `otel-collector-node`, `velero-node-agent`, the gluetun-based qBittorrent pod, `zigbee2mqtt`, and operator-generated operands whose pod templates the CRD cannot set — CNPG, Dragonfly, DocumentDB, and RustFS Tenant operands). Keep the gVisor table in `docs/pod-security.md` as the source of truth for the exact list. Operator-spawned pods that accept a runtime class per-instance (e.g. Woodpecker pipeline pods) opt in through the operator's allow-from-step flag plus per-pipeline backend options, never a repo-level manifest.

## New component checklist

- `fullnameOverride`
- `runtimeClassName: gvisor` (where supported)
- `nodeSelector`
- Gateway listener and `HTTPRoute` (if applicable)
- `ServiceMonitor`
- `ServerSideApply=true` in `spec.syncPolicy.syncOptions` for all `Application` resources
- Standard intra-component sync waves (-2 network policy, -1 secrets, 0 datastore/gateway, 1 workload, 2 routes)
  with manifest filenames strictly matching `<wave>_<descriptor>.yaml`.
- StorageClass SELinux mount options (`context=system_u:object_r:ephemeral_t:s0`) for CSI filesystem volumes
- CRD ordering: newly added apps with CRDs must install CRDs before workloads (and support declarative upgrades via `ServerSideApply=true`), with `docs/argocd.md` updated within the existing text.
- Document Pod Security Standards compliance and User Namespaces status in `docs/pod-security.md`.
- Document Authelia OIDC integration status or sign-in behavior in `docs/oidc.md`.
- Authelia OIDC client per the Authelia OIDC client conventions (if the app has user login).
- Scope the component's internet egress with dedicated, per-app CiliumNetworkPolicies
  (FQDN- or port-scoped — there is no shared world-egress selector) and add a matching
  `docs/network-policies.md` row.
- Set requests and limits on all regular, init, and sidecar containers. Preserve
  higher upstream values; use the documented profile fallbacks when absent.
- Application telemetry, anonymous usage metrics, and upgrade checkers disabled
  (without breaking functionality)
- Autoscaling (HPA/KEDA) is intentionally disabled unless the user requests a policy change.

## Adding or changing a component

- Check the upstream chart/image documentation before changing a version or
  values schema.
- Before modifying an existing Helm installation or adding a new one, render
  the exact pinned chart with the proposed values and patches, and inspect all
  generated resources. Ground chart versions, value keys, resource names,
  selectors, ports, generated secrets, CRDs, and other integration details in
  that render rather than assumptions from defaults or documentation alone.
  Specifically inspect the rendered output to confirm all required resources
  and fields are actually emitted (e.g. `ServiceMonitor` with `60s` interval,
  Pod Security Standards contexts, `hostUsers: false`, node selectors, and
  container resource requests/limits).
- For a new component, create `apps/<component>/` and prefix every manifest with
  its exact Argo CD sync wave number (`<wave>_<descriptor>.yaml`).
- Add the component to `apps/app-of-apps.yaml` with the correct destination
  namespace and dependency sync wave. Keep the sync-wave explanation in
  `README.md` accurate.
- Check whether the component's pinned chart, image, or remote revision is
  covered by `renovate.json`; update Renovate configuration when its existing
  managers and matchers do not support the new dependency field. This includes
  e2e hooks, compose files, `go.mod`, and any other version-bearing field: add
  a custom regex manager when no built-in manager can see it.
- Apply the new-component checklist as applicable.
- Keep `docs/pod-security.md` updated with any changes or additions to Pod Security
  Standards compliance and User Namespaces status.
- Authelia integrations must always use
  https://www.authelia.com/integration/openid-connect/clients/ as the
  reference for OpenID Connect client configuration.
- Keep `docs/oidc.md` updated with any changes or additions to Authelia OIDC
  integration status or sign-in behavior when onboarding or modifying an app.
- Treat CRDs and operators as dependencies: they must be installed in an earlier
  sync wave than resources that use them. Newly added apps with CRDs must follow
  this rule both on initial deployment and during upgrades (ensuring CRDs precede
  applications and support declarative upgrades via `ServerSideApply=true`), and
  `docs/argocd.md` must be updated within the existing text.
- Do not run `kubectl apply`, `helm install/upgrade` or Argo CD sync
  unless the user explicitly asks to change a live system.

## Validation

Run checks relevant to the files changed:

```bash
# Parse every in-scope Kubernetes YAML file (vendored Helm templates under
# local-charts/ contain Go directives and are validated via helm render instead).
find apps -type f -name '*.yaml' -not -path '*/charts/*' -not -path '*/local-charts/*' -print0 |
  xargs -0 -n1 yq eval '.' >/dev/null

# Parse every Grafana dashboard.
find apps/grafana/dashboards -type f -name '*.json' -print0 |
  xargs -0 -n1 jq empty

# Fail if any pinned Kubernetes version reference (PSA labels, e2e kind node
# image, documentation, hook comments) drifts from the rest.
scripts/check-k8s-version.sh
```

Helm inflation requires an explicit flag in every local render: use
`kubectl kustomize --enable-helm <dir>` (or `kustomize build --enable-helm`);
the bare `kustomize build` command fails on every `helmCharts` directory.
Production Argo CD already sets this globally via `kustomize.buildOptions`
in `argocd-cm` (see docs/argocd.md).

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
- Update documentation in `docs/` (including `docs/pod-security.md` for Pod
  Security Standards and User Namespaces changes, `docs/oidc.md` for Authelia
  OIDC integration status and sign-in behavior, and `docs/argocd.md` within
  its existing text for sync waves and CRD lifecycle updates) whenever
  architectural changes, operational workflows, sync ordering, or manifest
  conventions affect, invalidate, or alter the descriptions there.
- Do not cite application version numbers in documentation; they drift with
  Renovate bumps. Required Kubernetes version pins (PSA labels, kind node
  images) and the upgrade procedures in `docs/upgrades.md` are the only
  exceptions. Describe the current state only; no before/after or migration
  notes.
