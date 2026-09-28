# Security Scanners

All Helm-rendered manifests are scanned by three security tools in CI. **Kubescape** checks the offline render of every pinned Helm chart against the `AllControls` framework, **kube-score** evaluates the same render for manifest best practices, and **Trivy** scans container images added or changed in a pull request for known vulnerabilities.

Every intentionally accepted finding is registered as an explicit, resource-scoped exception with a written reason. There are no blanket, namespace-wide, or cluster-wide suppressions: an exception names the exact rendered resource and the exact check it waives, and CI fails if the exception registry and the scanner inputs drift apart.

---

## Scanning pipeline

The `helm-security` job in `.github/workflows/validate.yaml` runs `scripts/scan-security.sh`, which:

1. Validates the exception registry and its parity with the scanner input (`scripts/validate-security-exceptions.sh`).
2. Renders every pinned Helm chart under `apps/` through its kustomization into an offline manifest tree (`scripts/render-helm-profiles.sh`).
3. Runs kube-score over the render with `--exit-one-on-warning`; any warning or critical finding not ignored on the specific resource fails the job.
4. Runs Kubescape with the `AllControls` framework and `--fail-on-degraded-config`; the job fails if the report contains any failed control that is not covered by an exception.

The separate `trivy-image-scan` job runs `scripts/scan-images.sh`, which extracts the container images added or changed in the pull request diff and fails on unpatched `CRITICAL`/`HIGH` vulnerabilities.

Scanner tool versions are pinned in `.github/workflows/validate.yaml` and updated by Renovate. The offline render covers only the Helm installations; handwritten manifests under `apps/<component>/` are deployed through Argo CD and governed by the Pod Security conventions in [pod-security.md](pod-security.md) and live cluster admission instead.

---

## Exception mechanisms

### Kubescape

Kubescape exceptions live in two files that must stay in sync:

- `security/exceptions.yaml` — the human-maintained registry. Each entry records the Kubescape control ID (`check`), the control name, the scanner, the target profile, an owner, and the reason the finding is accepted.
- `security/kubescape-exceptions.json` — the same exceptions in Kubescape's `postureExceptionPolicy` format, which `scan-security.sh` passes to the scanner. Every policy uses the `alertOnly` action: matching resources still appear in the report but no longer count as control failures.

`scripts/validate-security-exceptions.sh` enforces the contract between the two files and the shape of every entry:

- each registry entry declares `check`, `control`, `scanner`, `profiles`, `owner`, and a `reason` of at least 20 characters, and targets the `homelab` profile;
- each policy is a `postureExceptionPolicy` with `alertOnly` actions;
- resource designators match exact kinds and names as anchored regexes (`^Kind$`, `^name$`) — wildcards such as `.*` are rejected;
- the set of control IDs in the registry equals the set of control IDs in the policy file.

Each policy lists the exact rendered resources (kind and name, plus namespace where the render distinguishes namespaces) that the control is waived for. When a chart update removes a finding, the exception entry is removed together with the registry entry, and the parity check keeps the two files honest.

### kube-score

kube-score has no central exception file. Suppression is per rendered resource through the `kube-score/ignore` annotation, which lists the exact kube-score test IDs waived for that resource. Every `kube-score/ignore` annotation is paired with a `security.homeworld/exception-reason` annotation on the same resource stating why the finding is accepted.

For Helm workloads the annotation pair is applied either as a kustomize patch in `apps/<component>/helm/kustomization.yaml` or through the chart's own annotation values (`deploymentAnnotations` / `podAnnotations`) in `apps/<component>/helm/values.yaml`.

### Trivy

Trivy image scanning has no exception mechanism by design. The scan gates on unpatched `CRITICAL`/`HIGH` findings for images changed in the pull request, and the remediation path is an image bump through Renovate, not a waiver.

### Pod Security Standards exceptions

The privileged and baseline namespaces required by host-integration workloads (Cilium, CrowdSec, Home Assistant, Longhorn, the OTel node collector, RustFS, Velero) are Pod Security exceptions documented in [pod-security.md](pod-security.md). They are enforced by Pod Security Admission at deploy time and are not scanner suppressions. The same underlying facts (hostPath volumes, host networking, privileged containers, root images) are what many of the Kubescape controls below flag; the two exception systems are kept separate on purpose.

---

## Adding or reviewing an exception

1. Run the scan locally (`scripts/scan-security.sh homelab`) and confirm the finding. Fixing the manifest — through Helm values, a kustomize patch, or a values override — always wins over an exception.
2. For a Kubescape finding: add the control to `security/exceptions.yaml` with a reason specific to the component and behavior, and add the matching `postureExceptionPolicy` entry to `security/kubescape-exceptions.json`, scoped to the exact resources that fail the control.
3. For a kube-score finding: add the failed test ID to the resource's `kube-score/ignore` annotation and write the matching `security.homeworld/exception-reason` on the same resource.
4. Run `scripts/validate-security-exceptions.sh` and re-run the scan to confirm the report is clean.

Registry reasons should name the concrete behavior and component ("the velero node-agent requires hostPath mounts to `/var/lib/kubelet/pods` for file-level backups"), not generic boilerplate — the registry and this document are the audit trail for every waiver.

---

## Kubescape exception inventory

`security/exceptions.yaml` is the authoritative inventory. The controls currently registered group into these categories:

| Category | Controls | Scope | Why required |
| :--- | :--- | :--- | :--- |
| **Bare rendered `cilium-secrets` Namespace** | C-0049, C-0054, C-0189, C-0192, C-0193, C-0194, C-0195, C-0196, C-0197, C-0198, C-0199, C-0200, C-0201, C-0202, C-0203, C-0204, C-0206 *(17)* | `Namespace/cilium-secrets` only | The Cilium chart renders this Namespace bare: no Pod Security Admission labels, no pods, no network policy. The entire offline render contains exactly one Namespace object, and every namespace-level Kubescape control (admission labels, default service account, network policy, label usage) fails against it. The namespace only stores operator-synced TLS interception secrets; its cluster-side protection (admission labels, Cilium policy) is applied outside the Helm renders. |
| **Controller RBAC and service accounts** | C-0002, C-0007, C-0015, C-0031, C-0034, C-0035, C-0037, C-0053, C-0063, C-0065, C-0186, C-0187, C-0188, C-0190, C-0191, C-0255, C-0258, C-0259, C-0261, C-0267, C-0272, C-0278, C-0279, C-0280, C-0281, C-0282 *(26)* | the exact ClusterRoleBindings, RoleBindings, and controller workloads of Argo CD, cert-manager, Cilium, CloudNativePG, CrowdSec, the Dragonfly/DocumentDB/Grafana/RustFS operators, Envoy Gateway, ExternalDNS, External Secrets, Longhorn, Velero, Velero UI, and Woodpecker | These controls flag the RBAC that upstream controllers ship for their reconciliation: administrative and wildcard permissions, secret and event access, escalation and bind rights, and automounted service-account tokens on workloads that talk to the Kubernetes API. The bindings are pinned by the upstream charts; waiving them per exact resource is the alternative to not running the controllers. The Woodpecker agent creates its CI pipeline pods through its namespace-scoped Role, and the Velero UI manages cluster-scoped `velero.io` resources through the wildcard ClusterRole its chart ships. |
| **Host integration** | C-0041, C-0044, C-0045, C-0046, C-0048, C-0057 *(6)* | Cilium agent/Envoy/operator, `longhorn-manager`, Velero node-agent, `crowdsec-agent`, OTel node collector, Longhorn upgrade jobs | These controls flag `hostNetwork`, host ports, hostPath mounts, added capabilities, and privileged containers. They are the scanner-side view of the documented host-integration exceptions in [pod-security.md](pod-security.md): the kube-proxy replacement datapath, distributed storage, node volume backups, and node log collection. |
| **Preserved upstream security contexts** | C-0013, C-0016, C-0017, C-0055, C-0210, C-0211 *(6)* | upstream workloads whose pinned images or charts do not emit full Restricted contexts (Argo CD, Cilium, CrowdSec, Longhorn, Velero, Victoria components, Woodpecker, Immich, Forgejo, Collabora, the operators, and chart Jobs) | These controls flag missing `runAsNonRoot`, `allowPrivilegeEscalation`, immutable root filesystems, seccomp, and hardening fields where the pinned upstream image or chart does not provide them. Overriding the image's UID, filesystem, or context generically breaks runtime access, so the upstream context is preserved; every workload that *can* be hardened is already patched to Restricted per [pod-security.md](pod-security.md). |
| **Cilium network-policy blind spot** | C-0030, C-0260 *(2)* | all workload resources in the render | The enforced network boundary is `CiliumNetworkPolicy`, which Kubescape cannot evaluate; it only understands `NetworkPolicy` and therefore reports every namespace in the offline render as unisolated. The actual per-component boundaries are listed in [network-policies.md](network-policies.md). |
| **Missing probes** | C-0018, C-0056 *(2)* | chart Jobs and components whose charts expose no safe health endpoint | About half the flagged resources are one-shot Jobs (upgrade jobs, cert-gen, registration jobs). For the remaining controllers the upstream chart exposes no probe value; adding synthetic probes could trigger unsafe restarts. |
| **Labels and housekeeping** | C-0076, C-0077, C-0293 *(3)* | upstream-generated resources | Recommended-label controls (`C-0076`, `C-0077`) flag chart-generated resources that omit parts of the `app.kubernetes.io` label set, and `C-0293` flags the selector-less Longhorn admission webhook and recovery backend Services that the chart intentionally ships without a pod selector. |
| **Secrets handling** | C-0012, C-0207, C-0237 *(3)* | `argocd-cm`, the Authelia and Cilium ConfigMaps, `velero-ui`, and the workloads consuming External Secrets values | `C-0012` and `C-0207` flag secret values referenced through rendered ConfigMaps and environment variables — the delivery pattern for applications that only support env-var configuration (values populated by External Secrets from Infisical, see [secrets.md](secrets.md)). `C-0237` (image signature verification) cannot be proven from static manifests; provenance is reviewed when a pinned dependency is updated. |

---

## kube-score ignore inventory

kube-score test IDs currently accepted through `kube-score/ignore` annotations, and the reason each is accepted:

| Test ID | Why accepted |
| :--- | :--- |
| `pod-networkpolicy` | Same blind spot as Kubescape C-0030/C-0260: the enforced network boundary is `CiliumNetworkPolicy`, which kube-score cannot see in the offline render. |
| `container-image-pull-policy` | Pinned images are intentionally pulled `IfNotPresent` to reuse the node image cache; kube-score requires `Always` (or digest pinning) instead. |
| `container-security-context-user-group-id` | The pinned upstream image dictates its UID/GID, which sits below kube-score's numeric threshold or is unset in the chart render; overriding it would break runtime file access. |
| `container-security-context-readonlyrootfilesystem` | The upstream image writes to its root filesystem (startup configuration staging, rendering caches); a read-only root would break the documented function. |
| `deployment-replicas` | Single-replica deployments are intentional; autoscaling and replica counts are fixed by policy. |
| `pod-probes-identical` | The upstream chart deliberately shares one health endpoint between liveness and readiness probes. |
| `pod-probes` | The chart exposes no safe probe for the workload (mostly one-shot Jobs); synthetic probes could trigger unsafe restarts. |
| `deployment-strategy` | The upstream chart's default update strategy is preserved. |
| `container-security-context-privileged` | Host-integration workloads (Cilium agent, Longhorn manager) documented in [pod-security.md](pod-security.md). |
| `statefulset-has-servicename` | The upstream chart never creates the headless Service named by the StatefulSet (Woodpecker agent). |
| `deployment-has-poddisruptionbudget` | A PDB is meaningless for the intentional single-replica deployment it would protect. |
| `service-targets-pod` | Selector-less Services shipped by the chart (Longhorn admission webhook, recovery backend); matches Kubescape C-0293. |
| `networkpolicy-targets-pod` | The chart's NetworkPolicies select pods that `longhorn-manager` creates at runtime; those pods do not exist in a static render. |
