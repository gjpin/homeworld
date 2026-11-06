# Security Scanners

All Helm-rendered manifests are scanned by two security tools in CI. **Kubescape** checks the offline render of every pinned Helm chart against the `AllControls` framework, and **kube-linter** evaluates the same render for manifest best practices.

Every intentionally accepted finding is registered as an explicit, resource-scoped exception with a written reason. There are no blanket, namespace-wide, or cluster-wide suppressions: an exception names the exact rendered resource and the exact check it waives, and CI fails if the exception registry and the scanner inputs drift apart. The one exception to this rule is Kubescape control `C-0236` (verify image signature), excluded from the scan with `--exclude-controls`: it accepts only static cosign public keys, while most pinned images are signed keyless (Sigstore certificates tied to a CI identity) or not signed at all, so it would fail or need waiving on nearly every workload. Image provenance is reviewed when a pinned dependency is updated.

---

## Scanning pipeline

The `validate` job in `.github/workflows/validate.yaml` runs `scripts/scan-security.sh`, which:

1. Validates the exception registry and its parity with the scanner input (`scripts/validate-security-exceptions.sh`).
2. Renders every pinned Helm chart under `apps/` through its kustomization, and the upstream releases kustomized directly (the system-upgrade-controller and the Intel GPU device plugin), into an offline manifest tree (`scripts/render-helm-profiles.sh`). kubescape scans that tree with an empty kubeconfig, so it never contacts a cluster.
3. Validates the kube-linter exceptions: annotations naming an unknown check, and annotations whose finding has disappeared from an annotation-stripped copy of the render, both fail the job.
4. Runs kube-linter (default checks) over the render; any diagnostic not ignored on the specific resource fails the job.
5. Runs Kubescape with the `AllControls` framework minus `C-0236` and with `--fail-on-degraded-config`; the job fails if the report contains any failed control that is not covered by an exception.

Scanner tool versions are pinned in `.github/workflows/validate.yaml` and updated by Renovate. The offline render covers only the Helm installations; handwritten manifests under `apps/<component>/` are deployed through Argo CD and governed by the Pod Security conventions in [pod-security.md](pod-security.md) and live cluster admission instead.

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

For Helm workloads the annotation is applied either as a kustomize patch in `apps/<component>/helm/kustomization.yaml` or through the chart's own annotation values (`deploymentAnnotations` / `annotations`) in `apps/<component>/helm/values.yaml`.

kube-linter silently ignores annotations that name a check it does not know, and an annotation whose finding has disappeared is a stale exception. `scripts/scan-security.sh` therefore fails when an annotation names anything other than a built-in check of the pinned kube-linter version, and fails when an annotation does not suppress at least one finding in an annotation-stripped copy of the render.

### Pod Security Standards exceptions

The privileged and baseline namespaces required by host-integration workloads (Cilium, Home Assistant, Longhorn, the OTel node collector, qBittorrent, RustFS, Velero) are Pod Security exceptions documented in [pod-security.md](pod-security.md). They are enforced by Pod Security Admission at deploy time and are not scanner suppressions. The same underlying facts (hostPath volumes, host networking, privileged containers, root images) are what many of the Kubescape controls below flag; the two exception systems are kept separate on purpose.

---

## Adding or reviewing an exception

1. Run the scan locally (`scripts/scan-security.sh homelab`) and confirm the finding. Fixing the manifest — through Helm values, a kustomize patch, or a values override — always wins over an exception.
2. For a Kubescape finding: add the control to `security/exceptions.yaml` with a reason specific to the component and behavior, and add the matching `postureExceptionPolicy` entry to `security/kubescape-exceptions.json`, scoped to the exact resources that fail the control.
3. For a kube-linter finding: add `ignore-check.kube-linter.io/<check-name>` on the exact rendered resource, with the reason as the annotation value, through a kustomize patch or the chart's annotation values.
4. Run `scripts/validate-security-exceptions.sh` and re-run the scan to confirm the report is clean.

Registry reasons should name the concrete behavior and component ("the velero node-agent requires hostPath mounts to `/var/lib/kubelet/pods` for CSI volume snapshots"), not generic boilerplate — the registry and this document are the audit trail for every waiver.

---

## Kubescape exception inventory

`security/exceptions.yaml` is the authoritative inventory. The controls currently registered group into these categories:

| Category | Controls | Scope | Why required |
| :--- | :--- | :--- | :--- |
| **Bare rendered `cilium-secrets` Namespace** | C-0049, C-0054, C-0189, C-0192, C-0193, C-0194, C-0195, C-0196, C-0197, C-0198, C-0199, C-0200, C-0201, C-0202, C-0203, C-0204, C-0206 *(17)* | `Namespace/cilium-secrets` only | The Cilium chart renders this Namespace bare: no Pod Security Admission labels, no pods, no network policy. The entire offline render contains exactly one Namespace object, and every namespace-level Kubescape control (admission labels, default service account, network policy, label usage) fails against it. The namespace only stores operator-synced TLS interception secrets; its cluster-side protection (admission labels, Cilium policy) is applied outside the Helm renders. |
| **Controller RBAC and service accounts** | C-0002, C-0007, C-0015, C-0031, C-0034, C-0035, C-0037, C-0053, C-0063, C-0065, C-0186, C-0187, C-0188, C-0190, C-0191, C-0255, C-0258, C-0259, C-0261, C-0267, C-0272, C-0278, C-0279, C-0280, C-0281, C-0282 *(26)* | the exact ClusterRoleBindings, RoleBindings, and controller workloads of Argo CD, cert-manager, Cilium, CloudNativePG, Coder, the DocumentDB/Grafana/MariaDB/RustFS operators, Envoy Gateway, ExternalDNS, External Secrets, Kube State Metrics, Longhorn, the Manticore search worker (AFFiNE; namespaced pod-list Role), Velero, Velero UI, and Woodpecker | These controls flag the RBAC that upstream controllers ship for their reconciliation: administrative and wildcard permissions, secret and event access, escalation and bind rights, and automounted service-account tokens on workloads that talk to the Kubernetes API. The bindings are pinned by the upstream charts; waiving them per exact resource is the alternative to not running the controllers. Kube State Metrics is the same pattern in read-only form: its chart's ClusterRole lists cluster state — including secrets, which feed the `kube_secret_*` metrics — through an automounted token. The Woodpecker agent creates its CI pipeline pods through its namespace-scoped Role, coderd's Terraform provisioners create workspace Pods, PVCs, and Deployments through the chart's Role in `coder-workspaces` (bound across namespaces to its automounted token), and the Velero UI manages cluster-scoped `velero.io` resources through the wildcard ClusterRole its chart ships and mounts its access-policy file from a ConfigMap. |
| **Host integration** | C-0041, C-0044, C-0045, C-0046, C-0048, C-0057 *(6)* | Cilium agent/Envoy/operator, `longhorn-manager`, Velero node-agent, OTel node collector, Longhorn upgrade jobs | These controls flag `hostNetwork`, host ports, hostPath mounts, added capabilities, and privileged containers. They are the scanner-side view of the documented host-integration exceptions in [pod-security.md](pod-security.md): the kube-proxy replacement datapath, distributed storage, node volume backups, and node log collection. |
| **Preserved upstream security contexts** | C-0013, C-0016, C-0017, C-0055, C-0210, C-0211 *(6)* | upstream workloads whose pinned images or charts do not emit full Restricted contexts (Argo CD, Cilium, Coder, Longhorn, Velero, Victoria components, Woodpecker, Immich, Forgejo, Collabora, Manticore, Jellyfin, Seerr, Houndarr, AudioMuse-AI, the operators, and chart Jobs) | These controls flag missing `runAsNonRoot`, `allowPrivilegeEscalation`, immutable root filesystems, seccomp, and hardening fields where the pinned upstream image or chart does not provide them. Overriding the image's UID, filesystem, or context generically breaks runtime access, so the upstream context is preserved; every workload that *can* be hardened is already patched to Restricted per [pod-security.md](pod-security.md). |
| **Cilium network-policy blind spot** | C-0030, C-0260 *(2)* | all workload resources in the render | The enforced network boundary is `CiliumNetworkPolicy`, which Kubescape cannot evaluate; it only understands `NetworkPolicy` and therefore reports every namespace in the offline render as unisolated. The actual per-component boundaries are listed in [network-policies.md](network-policies.md). |
| **Missing probes** | C-0018, C-0056 *(2)* | chart Jobs and components whose charts expose no safe health endpoint (the AudioMuse-AI queue worker serves no port; the Argo CD repo-server's `homeworld-plugin` sidecar serves only the Config Management Plugin unix socket) | About half the flagged resources are one-shot Jobs (upgrade jobs, cert-gen, registration jobs). For the remaining controllers the upstream chart exposes no probe value; adding synthetic probes could trigger unsafe restarts. |
| **Labels and housekeeping** | C-0076, C-0077, C-0293 *(3)* | upstream-generated resources | Recommended-label controls (`C-0076`, `C-0077`) flag chart-generated resources that omit parts of the `app.kubernetes.io` label set, and `C-0293` flags the selector-less Longhorn admission webhook and recovery backend Services that the chart intentionally ships without a pod selector. |
| **Secrets handling** | C-0012, C-0207, C-0237 *(3)* | `argocd-cm`, the Authelia and Cilium ConfigMaps, `velero-ui`, and the workloads consuming External Secrets values | `C-0012` and `C-0207` flag secret values referenced through rendered ConfigMaps and environment variables — the delivery pattern for applications that only support env-var configuration (values populated by External Secrets from Infisical, see [secrets.md](secrets.md)). `C-0237` (image signature verification) cannot be proven from static manifests; provenance is reviewed when a pinned dependency is updated. |

---

## kube-linter ignore inventory

kube-linter checks currently accepted through `ignore-check.kube-linter.io` annotations (counts are per rendered resource; each annotation carries its own reason inline), and why each is accepted:

| Check | Resources | Why accepted |
| :--- | :--- | :--- |
| `no-read-only-root-fs` (31) | upstream workloads and chart Jobs whose images write to their root filesystems | The pinned upstream image writes to its root filesystem (startup configuration staging, rendering caches); a read-only root would break the documented function. |
| `run-as-non-root` (12) | Cilium agent, cilium-envoy and cilium-operator, the csi-driver-nfs node plugin, the Intel GPU device plugin, kured, Longhorn (manager, driver deployer, global manager, post-upgrade hook), the otel node collector, and the Velero node-agent | The pinned upstream image's preserved root context is required for host datapath access or has no non-root USER; overriding it would break runtime file access. |
| `liveness-port` / `readiness-port` / `startup-port` (8 / 7 / 3) | cilium-envoy, hubble-relay, envoy-gateway, the otel collectors, and the grafana/opentelemetry operators | The upstream chart probes an undeclared health port (9878, 4222, 8081, or 13133) instead of a declared containerPort. |
| `job-ttl-seconds-after-finished` (1) | Longhorn's post-upgrade Job (an Argo CD PostSync hook) | The upstream chart leaves `ttlSecondsAfterFinished` unset; the hook's `HookSucceeded` delete policy removes it instead. |
| `privileged-container` / `privilege-escalation-container` (3 / 4) | csi-driver-nfs node plugin, kured, longhorn-manager, plus the cilium agent for privilege escalation | Host-integration workloads documented in [pod-security.md](pod-security.md): the kube-proxy replacement datapath, NFS mounts on the node, node reboots and distributed storage require privileged contexts. (The longhorn pre-upgrade job no longer renders; the post-upgrade cleanup runs as an Argo PostSync hook.) |
| `host-network` (4) | cilium agent, cilium-envoy, cilium-operator, csi-driver-nfs node plugin | Kube-proxy replacement and the Envoy datapath require the host network namespace, and the NFS node plugin mounts the NAS from the node. |
| `host-pid` (1) | kured | kured enters the host PID namespace to run the reboot sentinel and reboot the node ([pod-security.md](pod-security.md)). |
| `sensitive-host-mounts` (2) | cilium agent (host `/proc` for the chart's sysctl overwrites), otel node collector (host filesystem root for node telemetry and log collection) | Host integration documented in [pod-security.md](pod-security.md). |
| `dangling-service` (2) | longhorn-admission-webhook, longhorn-recovery-backend | The chart's Services select labels that longhorn-manager pods only carry at runtime; no matching pod exists in the offline render. |
| `env-var-secret` (1) | authelia | The `_FILE`-suffixed environment variables carry paths to mounted Infisical-provided secret files, not inline secret values. |
| `drop-net-raw-capability` (1) | cilium agent | The kube-proxy replacement datapath requires the added NET_RAW capability. |
