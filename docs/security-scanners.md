# Security Scanners

Everything Argo CD deploys from this repository, handwritten manifests and pinned Helm charts alike, is scanned by two security tools in CI. **Kubescape** checks that offline render against the `AllControls` framework, and **kube-linter** evaluates the same render for manifest best practices.

Every intentionally accepted finding is registered as an explicit, resource-scoped exception with a written reason. There are no blanket, namespace-wide, or cluster-wide suppressions: an exception names the exact rendered resource and the exact check it waives, and CI fails if the exception registry and the scanner inputs drift apart. The one exception to this rule is Kubescape control `C-0236` (verify image signature), excluded from the scan with `--exclude-controls`: it accepts only static cosign public keys, while most pinned images are signed keyless (Sigstore certificates tied to a CI identity) or not signed at all, so it would fail or need waiving on nearly every workload. Image provenance is reviewed when a pinned dependency is updated.

---

## Scanning pipeline

The `validate` job in `.github/workflows/validate.yaml` runs `scripts/scan-security.sh` whenever a change touches its inputs (`apps/`, `scripts/`, `security/`, or the workflow's scanner pins). The job runs on pull requests and on direct pushes to `main`; a merged pull request is not validated again on `main`. The script:

1. Validates the exception registry and its parity with the scanner input (`scripts/validate-security-exceptions.sh`).
2. Renders the source path of every Argo CD `Application` in the repository, root and child, the way the homeworld Config Management Plugin does ([argocd.md](argocd.md#homeworld-plugin)): kustomize with Helm where the directory holds a `kustomization.yaml` (the charts and the upstream releases kustomized directly), its plain manifest files otherwise (`scripts/render-manifests.sh`). kubescape scans that tree with an empty kubeconfig, so it never contacts a cluster.
3. Validates the kube-linter exceptions: annotations naming an unknown check, and annotations whose finding has disappeared from an annotation-stripped copy of the render, both fail the job.
4. Runs kube-linter (default checks) over the render; any diagnostic not ignored on the specific resource fails the job.
5. Runs Kubescape with the `AllControls` framework minus `C-0236` and with `--fail-on-degraded-config`; the job fails if the report contains any failed control that is not covered by an exception.

Scanner tool versions are pinned in `.github/workflows/validate.yaml` and updated by Renovate.

Coverage follows the Applications, so a new component is scanned as soon as an Application deploys it. The render fails instead of skipping anything:

- a directory under `apps/` holding manifests that no Application deploys (neither an Application's own path nor below one that kustomize renders) fails the job, because the scan would never see it and Argo CD would never apply it;
- an Application whose source is not a path in this repository fails the job, unless it is an upstream CRD bundle named `*-crd` or `*-crds`: those carry no workloads, and they cannot be rendered offline;
- an Application path that does not exist fails the job.

---

## Exception mechanisms

### Kubescape

Kubescape exceptions live in two files that must stay in sync:

- `security/exceptions.yaml` — the human-maintained registry. Each entry records the Kubescape control ID (`check`), the control name, the scanner, the target profile, an owner, and the reason the finding is accepted.
- `security/kubescape-exceptions.json` — the same exceptions in Kubescape's `postureExceptionPolicy` format, which `scan-security.sh` passes to the scanner. Every policy uses the `alertOnly` action: matching resources still appear in the report but no longer count as control failures. Policies select by `controlID` only and set no `frameworkName`: Kubescape evaluates the JSON report's exception status without a framework filter, so a framework-scoped policy matches the resource but never marks its failure `w/exceptions`.

`scripts/validate-security-exceptions.sh` enforces the contract between the two files and the shape of every entry:

- each registry entry declares `check`, `control`, `scanner`, `profiles`, `owner`, and a `reason` of at least 20 characters, and targets the `homelab` profile;
- each policy is a `postureExceptionPolicy` with `alertOnly` actions;
- resource designators match exact kinds and names as anchored regexes (`^Kind$`, `^name$`) — wildcards such as `.*` are rejected;
- the set of control IDs in the registry equals the set of control IDs in the policy file.

Each policy lists the exact rendered resources (kind and name, plus namespace where the render distinguishes namespaces) that the control is waived for. When a chart update removes a finding, the exception entry is removed together with the registry entry, and the parity check keeps the two files honest.

### kube-linter

kube-linter runs its built-in default checks and has no central exception file. Suppression is per rendered resource through the `ignore-check.kube-linter.io/<check-name>` annotation, which waives exactly that check for that resource; the annotation value is the written reason the finding is accepted, so every ignore carries its own justification. The annotation must sit on the workload object's metadata (not the pod template) — kube-linter only reads the top-level object's annotations.

Handwritten manifests carry the annotation directly in the object's `metadata.annotations`. For Helm workloads it is applied either as a kustomize patch in `apps/<component>/helm/kustomization.yaml` or through the chart's own annotation values (`deploymentAnnotations` / `annotations`) in `apps/<component>/helm/values.yaml`.

kube-linter silently ignores annotations that name a check it does not know, and an annotation whose finding has disappeared is a stale exception. `scripts/scan-security.sh` therefore fails when an annotation names anything other than a built-in check of the pinned kube-linter version, and fails when an annotation does not suppress at least one finding in an annotation-stripped copy of the render.

### Pod Security Standards exceptions

The privileged and baseline namespaces required by host-integration workloads (Cilium, Home Assistant, Longhorn, the OTel node collector, qBittorrent, RustFS, Velero) are Pod Security exceptions documented in [pod-security.md](pod-security.md). They are enforced by Pod Security Admission at deploy time and are not scanner suppressions. The same underlying facts (hostPath volumes, host networking, privileged containers, root images) are what many of the Kubescape controls below flag; the two exception systems are kept separate on purpose.

---

## Adding or reviewing an exception

1. Run the scan locally (`scripts/scan-security.sh homelab`) and confirm the finding. Fixing the manifest — directly in a handwritten manifest, or through Helm values, a kustomize patch, or a values override — always wins over an exception.
2. For a Kubescape finding: add the control to `security/exceptions.yaml` with a reason specific to the component and behavior, and add the matching `postureExceptionPolicy` entry to `security/kubescape-exceptions.json`, scoped to the exact resources that fail the control.
3. For a kube-linter finding: add `ignore-check.kube-linter.io/<check-name>` on the exact rendered resource, with the reason as the annotation value: in a handwritten manifest's metadata, or through a kustomize patch or the chart's annotation values.
4. Run `scripts/validate-security-exceptions.sh` and re-run the scan to confirm the report is clean.

Registry reasons should name the concrete behavior and component ("the velero node-agent requires hostPath mounts to `/var/lib/kubelet/pods` for CSI volume snapshots"), not generic boilerplate — the registry and this document are the audit trail for every waiver.

---

## Kubescape exception inventory

`security/exceptions.yaml` is the authoritative inventory. The controls currently registered group into these categories:

| Category | Controls | Scope | Why required |
| :--- | :--- | :--- | :--- |
| **Bare rendered `cilium-secrets` Namespace** | C-0049, C-0054, C-0189, C-0192, C-0193, C-0194, C-0195, C-0196, C-0197, C-0198, C-0199, C-0200, C-0201, C-0202, C-0203, C-0204, C-0206 *(17)* | `Namespace/cilium-secrets` only | The Cilium chart renders this Namespace bare: no Pod Security Admission labels, no pods, no network policy. The entire offline render contains exactly one Namespace object, and every namespace-level Kubescape control (admission labels, default service account, network policy, label usage) fails against it. The namespace only stores operator-synced TLS interception secrets; its cluster-side protection (admission labels, Cilium policy) is applied outside the Helm renders. |
| **Controller RBAC and service accounts** | C-0002, C-0007, C-0015, C-0031, C-0034, C-0035, C-0037, C-0053, C-0063, C-0065, C-0186, C-0187, C-0188, C-0190, C-0191, C-0255, C-0258, C-0259, C-0261, C-0267, C-0272, C-0278, C-0279, C-0280, C-0281, C-0282 *(26)* | the exact ClusterRoleBindings, RoleBindings, and controller workloads of Argo CD, cert-manager, Cilium, CloudNativePG, Coder, the DocumentDB/Grafana/MariaDB/RustFS operators, Envoy Gateway, ExternalDNS, External Secrets, Kube State Metrics, Longhorn, the Manticore search worker (AFFiNE; namespaced pod-list Role), Velero, Velero UI, and Woodpecker, plus the handwritten Homepage (cluster read access for its Kubernetes widgets), kubelet-serving-cert-approver, snapshot-controller, the control-plane metrics reader, the OTel target allocator's per-namespace scrape-credential Roles, and Supernote's PreSync snapshot-rotation hook | These controls flag the RBAC that upstream controllers ship for their reconciliation: administrative and wildcard permissions, secret and event access, escalation and bind rights, and automounted service-account tokens on workloads that talk to the Kubernetes API. The bindings are pinned by the upstream charts; waiving them per exact resource is the alternative to not running the controllers. Kube State Metrics is the same pattern in read-only form: its chart's ClusterRole lists cluster state — including secrets, which feed the `kube_secret_*` metrics — through an automounted token. The Woodpecker agent creates its CI pipeline pods through its namespace-scoped Role, coderd's Terraform provisioners create workspace Pods, PVCs, and Deployments through the chart's Role in `coder-workspaces` (bound across namespaces to its automounted token), and the Velero UI manages cluster-scoped `velero.io` resources through the wildcard ClusterRole its chart ships and mounts its access-policy file from a ConfigMap. |
| **Host integration** | C-0038, C-0041, C-0044, C-0045, C-0046, C-0048, C-0057, C-0275 *(8)* | Cilium agent/Envoy/operator, `longhorn-manager`, Velero node-agent, OTel node collector, Longhorn upgrade jobs, kured, Zigbee2MQTT, and qBittorrent's gluetun sidecar | These controls flag `hostNetwork`, the host PID namespace, host ports, hostPath mounts, added capabilities, and privileged containers. They are the scanner-side view of the documented host-integration exceptions in [pod-security.md](pod-security.md): the kube-proxy replacement datapath, distributed storage, node volume backups, node log collection, node reboots, the Zigbee USB coordinator under `/dev/serial/by-id`, and the VPN tunnel and kill switch in the qBittorrent pod's own network namespace. |
| **Preserved security contexts** | C-0013, C-0016, C-0017, C-0055, C-0210, C-0211 *(6)* | upstream workloads whose pinned images or charts do not emit full Restricted contexts (Argo CD, Cilium, Coder, Longhorn, Velero, Victoria components, Woodpecker, Immich, Forgejo, Collabora, Manticore, Jellyfin, Seerr, Houndarr, AudioMuse-AI, the operators, and chart Jobs), and the handwritten workloads (Home Assistant and its Mosquitto and Zigbee2MQTT, AFFiNE, Audiobookshelf, Cleanuparr, FlareSolverr, Maintainerr, Notesnook, OpenCloud and Tika, qBittorrent) | These controls flag missing `runAsNonRoot`, `allowPrivilegeEscalation`, immutable root filesystems, seccomp, and hardening fields where the pinned upstream image or chart does not provide them. Overriding the image's UID, filesystem, or context generically breaks runtime access, so the upstream context is preserved; every workload that *can* be hardened is already patched to Restricted per [pod-security.md](pod-security.md). A handwritten workload keeps a writable root filesystem until its image's writable paths are mapped to volumes, with the reason in its kube-linter annotation. `C-0211` also asks for per-container `seLinuxOptions`, which this cluster leaves to the runtime (`container_t`, [pod-security.md](pod-security.md)). |
| **Cilium network-policy blind spot** | C-0030, C-0260 *(2)* | all workload resources in the render | The enforced network boundary is `CiliumNetworkPolicy`, which Kubescape cannot evaluate; it only understands `NetworkPolicy` and therefore reports every namespace in the offline render as unisolated. The actual per-component boundaries are listed in [network-policies.md](network-policies.md). |
| **Missing probes** | C-0018, C-0056 *(2)* | chart Jobs, the handwritten CronJobs and Supernote's PreSync hook Job, and components that expose no safe health endpoint (the AudioMuse-AI queue worker serves no port; the Argo CD repo-server's `homeworld-plugin` sidecar serves only the Config Management Plugin unix socket; qBittorrent's gluetun sidecar is checked through the qbittorrent container's readiness probe; snapshot-controller serves only its metrics port) | Most flagged resources are one-shot Jobs and CronJobs (upgrade jobs, cert-gen, registration jobs, the media-stack syncs). For the remaining controllers the upstream chart or image exposes no probe value; adding synthetic probes could trigger unsafe restarts. |
| **Labels** | C-0076, C-0077 *(2)* | chart-generated and handwritten resources | Recommended-label controls flag resources that omit parts of the recommended label set; they stay identified by exact kind, name, and namespace. |
| **Targets that exist only at runtime** | C-0293, C-0299, C-0302 *(3)* | the Longhorn admission webhook and recovery-backend Services and internal NetworkPolicies, `envoy-node-access`, the selectorless OpenChamber/Paseo/ThinkRail Services, and the Grafana and RustFS HTTPRoutes | The selected pods or backend Services are created at runtime by a controller (longhorn-manager, Envoy Gateway's proxies, the Grafana operator's `grafana-service`, the RustFS Tenant's Services), or the Service is selectorless by design with an EndpointSlice to the agents VM ([agents-vm.md](agents-vm.md)), so the offline render has no match. |
| **Recreate strategy** | C-0305 *(1)* | single-replica Deployments | A controller without leader election, or a pod holding an RWO volume, must never run two copies at once: a rolling update would wait on the volume attachment. |
| **Secrets handling** | C-0012, C-0207, C-0237 *(3)* | `argocd-cm`, the Authelia and Cilium ConfigMaps, `velero-ui`, the Homepage, Vaultwarden and Actual Budget configuration, and the workloads consuming External Secrets values | `C-0012` and `C-0207` flag secret values referenced through rendered ConfigMaps and environment variables — the delivery pattern for applications that only support env-var configuration (values populated by External Secrets from Infisical, see [secrets.md](secrets.md)). The matched keys name credentials, but no value in git is one: they are settings, `$(VAR)` expansions, or `{{HOMEPAGE_VAR_*}}` placeholders. `C-0237` (image signature verification) cannot be proven from static manifests; provenance is reviewed when a pinned dependency is updated. |

---

## kube-linter ignore inventory

kube-linter checks currently accepted through `ignore-check.kube-linter.io` annotations (counts are per rendered resource; each annotation carries its own reason inline), and why each is accepted:

| Check | Resources | Why accepted |
| :--- | :--- | :--- |
| `no-read-only-root-fs` (46) | upstream workloads and chart Jobs whose images write to their root filesystems, and the handwritten workloads whose images' writable paths are not mapped yet (Home Assistant, Mosquitto, Zigbee2MQTT, AFFiNE, Audiobookshelf, Cleanuparr, FlareSolverr, Maintainerr, the Notesnook services, OpenCloud and Tika, qBittorrent) | The pinned upstream image writes to its root filesystem (startup configuration staging, rendering caches); a read-only root would break the documented function. A handwritten workload keeps a writable root until its writable paths are mapped to volumes. |
| `run-as-non-root` (14) | Cilium agent, cilium-envoy and cilium-operator, the csi-driver-nfs node plugin, the Intel GPU device plugin, kured, Longhorn (manager, driver deployer, global manager, post-upgrade hook), the otel node collector, the Velero node-agent, Home Assistant, and qBittorrent's gluetun sidecar | The pinned upstream image's preserved root context is required for host datapath access or has no non-root USER; overriding it would break runtime file access. Home Assistant's s6-overlay runs as root under gVisor, and gluetun configures the tunnel in the pod's network namespace. |
| `liveness-port` / `readiness-port` / `startup-port` (8 / 8 / 3) | cilium-envoy, hubble-relay, envoy-gateway, the otel collectors, the grafana/opentelemetry operators, and qBittorrent | The upstream chart probes an undeclared health port (9878, 4222, 8081, or 13133) instead of a declared containerPort; the qbittorrent container probes gluetun's health server on 9999 in the shared network namespace, so a down tunnel takes the WebUI out of the Service. |
| `job-ttl-seconds-after-finished` (2) | Longhorn's post-upgrade Job (an Argo CD PostSync hook) and Supernote's snapshot-rotation Job (a PreSync hook) | `ttlSecondsAfterFinished` is unset; the hook's `HookSucceeded` delete policy removes it instead. |
| `privileged-container` / `privilege-escalation-container` (3 / 4) | csi-driver-nfs node plugin, kured, longhorn-manager, plus the cilium agent for privilege escalation | Host-integration workloads documented in [pod-security.md](pod-security.md): the kube-proxy replacement datapath, NFS mounts on the node, node reboots and distributed storage require privileged contexts. (The longhorn pre-upgrade job no longer renders; the post-upgrade cleanup runs as an Argo PostSync hook.) |
| `host-network` (4) | cilium agent, cilium-envoy, cilium-operator, csi-driver-nfs node plugin | Kube-proxy replacement and the Envoy datapath require the host network namespace, and the NFS node plugin mounts the NAS from the node. |
| `host-pid` (1) | kured | kured enters the host PID namespace to run the reboot sentinel and reboot the node ([pod-security.md](pod-security.md)). |
| `sensitive-host-mounts` (2) | cilium agent (host `/proc` for the chart's sysctl overwrites), otel node collector (host filesystem root for node telemetry and log collection) | Host integration documented in [pod-security.md](pod-security.md). |
| `dangling-service` (6) | longhorn-admission-webhook, longhorn-recovery-backend, envoy-node-access, and the OpenChamber, Paseo and ThinkRail Services | The Longhorn Services select labels that longhorn-manager pods only carry at runtime, and `envoy-node-access` selects the Envoy proxies Envoy Gateway creates; no matching pod exists in the offline render. The agents-VM Services are selectorless, with EndpointSlices pointing at the VM. |
| `env-var-secret` (1) | authelia | The `_FILE`-suffixed environment variables carry paths to mounted Infisical-provided secret files, not inline secret values. |
| `drop-net-raw-capability` (2) | cilium agent, qBittorrent's gluetun sidecar | The kube-proxy replacement datapath requires the added NET_RAW capability, and so do gluetun's tunnel and kill-switch firewall in the pod's own network namespace. |
