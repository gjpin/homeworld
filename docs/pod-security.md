# Pod Security & User Namespaces

Workloads in this cluster are secured according to the [Kubernetes Pod Security Standards (PSS)](https://kubernetes.io/docs/concepts/security/pod-security-standards/) and opted into [Kubernetes 1.37 User Namespaces](https://kubernetes.io/docs/concepts/workloads/pods/user-namespaces/) (`hostUsers: false`) wherever supported.

Namespace-level Pod Security Admission (PSA) labels are managed declaratively in `apps/app-of-apps.yaml` through `syncPolicy.managedNamespaceMetadata`. Changes stage with Restricted `audit` and `warn` labels, with Restricted enforcement enabled once rendered and live admission results are verified clean.

Workloads requiring host integration, raw block devices, hostPath mounts, or root execution are isolated in dedicated namespaces with resource-scoped exceptions documented via `security.homeworld/exception-reason` annotations.

---

## Pod Security Standards

The table below outlines the Pod Security Standard compliance level for every component in the cluster.

| Application | Namespace | PSA Level | Compliance | Details & Rationale |
| :--- | :--- | :---: | :---: | :--- |
| **Argo CD** | `argocd` | Restricted | **Restricted** | All components (`server`, `repo-server`, `application-controller`, `applicationset-controller`, `notifications-controller`) run as non-root with dropped capabilities (`ALL`) and `RuntimeDefault` seccomp. The attached Dragonfly instance (the chart's bundled Redis is disabled) runs as the image's `dfly` user (UID/GID `999`) with dropped capabilities and `RuntimeDefault` seccomp. Dex and the bundled Redis are disabled in values. |
| **Authelia** | `authelia` | Restricted | **Restricted** | Application container runs as UID `1000` with read-only root filesystem, dropped capabilities (`ALL`), and `RuntimeDefault` seccomp. Attached PostgreSQL and Dragonfly instances also conform to Restricted. |
| **cert-manager** | `cert-manager` | Restricted | **Restricted** | Controller, cainjector, webhook, and startup check run non-root with dropped capabilities (`ALL`) and `RuntimeDefault` seccomp. |
| **Cilium** | `cilium` | Privileged | **Exception** | **Why not Restricted:** `cilium-agent` and `cilium-envoy` (DaemonSets) provide the kube-proxy replacement datapath and require BPF access, bpffs/cgroup host mounts, `hostNetwork`, and hostPath CNI state; `cilium-operator` runs `hostNetwork` by upstream chart default. PSS `baseline` forbids hostPath volumes and host networking, so the namespace enforces `privileged` (Restricted `audit`/`warn` retained).<br><br>*Mitigations:* `SYS_MODULE` and `SYSLOG` are dropped from the agent capability set (Talos forbids workloads loading kernel modules), `allowPrivilegeEscalation: false`, and the pod-network `hubble-relay` and `hubble-ui` run under gVisor with user namespaces. |
| **CloudNativePG** | `cloudnative-pg` | Restricted | **Restricted** | Operator controller runs as non-root with dropped capabilities (`ALL`) and `RuntimeDefault` seccomp. |
| **Collabora** | `collabora` | Restricted | **Restricted** | Runs as non-root (UID `1000`) with dropped capabilities (`ALL`) and `RuntimeDefault` seccomp. Writable root filesystem is accepted for office document rendering caches. |
| **CrowdSec** | `crowdsec` | Privileged | **Exception** | **Why not Restricted:** The pinned upstream CrowdSec image requires container UID `0` to write staged configuration files during startup. Additionally, `crowdsec-agent` (DaemonSet) requires a read-only hostPath mount (`/var/log`) to read container engine and node logs for intrusion detection — PSS `baseline` forbids hostPath volumes, so the namespace enforces `privileged` (Restricted `audit`/`warn` retained).<br><br>*Mitigations:* `crowdsec-lapi` and `crowdsec-appsec` maintain dropped capabilities (`ALL`), `allowPrivilegeEscalation: false`, and `RuntimeDefault` seccomp. |
| **CrowdSec Envoy Bouncer** | `envoy-gateway` | Restricted | **Restricted** | Runs as non-root with dropped capabilities (`ALL`), `allowPrivilegeEscalation: false`, and `RuntimeDefault` seccomp. |
| **Dragonfly Operator** | `dragonfly-operator` | Restricted | **Restricted** | Operator manager runs non-root with dropped capabilities (`ALL`), `allowPrivilegeEscalation: false`, and `RuntimeDefault` seccomp (the optional `kube-rbac-proxy` sidecar is disabled in values). |
| **DocumentDB Operator** | `documentdb-operator` / `cloudnative-pg` | Restricted | **Restricted** | Operator controller (UID `100`, GID `101`) and CNPG-I sidecar injector (UID `10001`, GID `10001`) run non-root with dropped capabilities (`ALL`), `allowPrivilegeEscalation: false`, and `RuntimeDefault` seccomp. |
| **Envoy Gateway** | `envoy-gateway` | Restricted | **Restricted** | Gateway control-plane controller and Envoy proxy data-plane pods run non-root with dropped capabilities (`ALL`) and `RuntimeDefault` seccomp. |
| **ExternalDNS** | `external-dns` | Restricted | **Restricted** | Controller runs as non-root with dropped capabilities (`ALL`), `allowPrivilegeEscalation: false`, and `RuntimeDefault` seccomp. |
| **External Secrets** | `external-secrets` | Restricted | **Restricted** | Controller, webhook, and cert-controller run as non-root with dropped capabilities (`ALL`) and `RuntimeDefault` seccomp. |
| **Forgejo** | `forgejo` | Restricted | **Restricted** | Application and init containers run non-root (UID `1000`, GID `1000`) with dropped capabilities (`ALL`) and `RuntimeDefault` seccomp. Attached PostgreSQL instance also conforms to Restricted. |
| **Generic Device Plugin** | `kube-system` | Privileged | **Exception** | **Why not Restricted:** the Kubernetes device plugin API requires a privileged container that enumerates host `/dev` and registers its socket under the kubelet's `/var/lib/kubelet/device-plugins` — both hostPath volumes PSS baseline forbids. `kube-system` deliberately carries no Argo-managed PSA labels: it is shared with the kind control-plane's own infra (kube-dns, kube-proxy), so the DevicePlugin DaemonSet's `security.homeworld/exception-reason` annotation is the scoping mechanism instead of namespace labels.<br><br>*Mitigations:* scoped to homelab-labeled nodes, runs without an API token and with zero network egress, and exists so workloads like gluetun can access the TUN device without privileged mode or hostPath device mounts. |
| **Grafana** | `grafana` | Restricted | **Restricted** | Grafana instance and the plugin-loader init container run non-root (UID `1000`) with dropped capabilities (`ALL`) and `RuntimeDefault` seccomp. |
| **Grafana Operator** | `grafana-operator` | Restricted | **Restricted** | Operator controller runs as non-root with dropped capabilities (`ALL`) and `RuntimeDefault` seccomp. |
| **Home Assistant** | `homeassistant` | Privileged | **Exception** | **Why not Restricted:** The `homeassistant` Core container requires UID `0` (`runAsNonRoot: false`) because the upstream image uses `s6-overlay` for process supervision. `zigbee2mqtt` accesses the physical Zigbee USB adapter via a hostPath mount (`/dev/serial/by-id`) on nodes labeled `environment=zigbee` — PSS `baseline` forbids hostPath volumes, so the namespace enforces `privileged` (Restricted `audit`/`warn` retained).<br><br>*Mitigations:* Workloads are isolated in unprivileged user namespaces (`hostUsers: false`). `mosquitto` and `zigbee2mqtt` run non-root (`runAsUser: 1883` and `1000`) with dropped capabilities (`ALL`) and `RuntimeDefault` seccomp under Restricted; `zigbee2mqtt` accesses the serial device via host `dialout` group (GID `20`). The `hass-oidc-auth-loader` and `homeassistant-config-bootstrap` init containers are fully rootless (UID/GID `1000`, dropped capabilities, `runAsNonRoot: true`): the loader writes only to an `emptyDir` overlaid at `/config/custom_components/auth_oidc`, and the config bootstrap seeds Home Assistant's first-boot configuration files into the `/config` PVC through the pod's `fsGroup` (`fsGroupChangePolicy: OnRootMismatch` limits the kubelet's recursive chown to the first mount; Longhorn supports kubelet-side fsGroup handling for RWO filesystem volumes). |
| **Homepage** | `homepage` | Restricted | **Restricted** | Dashboard runs non-root (UID `1000`) with dropped capabilities (`ALL`), read-only root filesystem (writable `/tmp` and `/app/config/logs` emptyDirs), and `RuntimeDefault` seccomp. |
| **Immich** | `immich` | Restricted | **Restricted** | Server and machine-learning pods run non-root with dropped capabilities (`ALL`) and `RuntimeDefault` seccomp. Attached PostgreSQL and Dragonfly instances also conform to Restricted. |
| **Kubelet Serving Cert Approver** | `kubelet-serving-cert-approver` | Restricted | **Restricted** | Controller runs as non-root (UID/GID `65534`) with dropped capabilities (`ALL`), read-only root filesystem, and `RuntimeDefault` seccomp. |
| **Kube State Metrics** | `kube-state-metrics` | Restricted | **Restricted** | Read-only API watcher running as the chart's non-root 65534 user with dropped capabilities, `RuntimeDefault` seccomp, and a read-only root filesystem (chart defaults). |
| **Longhorn** | `longhorn-system` | Privileged | **Exception** | **Why not Restricted:** `longhorn-manager` (DaemonSet), CSI plugins (`longhorn-csi-plugin`), and engine/replica instance managers require privileged containers, hostPath volume mounts (`/var/lib/longhorn`, `/dev`, `/sys`, `/proc`), bidirectionally shared mounts, and raw host block-device access to manage distributed storage, kernel block devices, and iscsi/spdk engines.<br><br>*Mitigations:* Isolated in dedicated `longhorn-system` namespace. `longhorn-ui` is fully hardened (non-root with dropped capabilities, no privilege escalation, user namespaces, gVisor); `longhorn-driver-deployer`, `longhorn-global-manager` (the leader-elected cluster-wide controllers), and the post-upgrade cleanup job run gVisor with user namespaces, no privilege escalation, and all capabilities dropped under the upstream image's root user. The chart's other helm-hook Jobs never reach the sync path: the `preUpgradeChecker` is disabled (its online version check is the manager phone-home this repo refuses) and the uninstall Job is patch-deleted. The post-upgrade cleanup runs as an Argo CD PostSync hook — after every longhorn sync, with the fresh image, self-deleting on success so its immutable spec never blocks a chart bump. |
| **Metrics Server** | `metrics-server` | Restricted | **Restricted** | Scraper runs as non-root (UID `1000`) with dropped capabilities (`ALL`), read-only root filesystem, and `RuntimeDefault` seccomp. |
| **Notesnook** | `notesnook` | Restricted | **Restricted** | All components (`sync`, `identity`, `sse`, `monograph`) run non-root (UID `1000`) with dropped capabilities (`ALL`) and `RuntimeDefault` seccomp. DocumentDB operand pods (managed by CloudNativePG) run non-root (PostgreSQL UID `105`, gateway UID `1000`) with dropped capabilities (`ALL`), `allowPrivilegeEscalation: false`, and `RuntimeDefault` seccomp via CNPG hardened defaults and the injector's hardened sidecar context. |
| **OpenChamber** | `openchamber` | Restricted | **Restricted** | Agent workspace pod runs non-root (UID `1000`) with dropped capabilities (`ALL`), `RuntimeDefault` seccomp, and a writable PVC-backed HOME that agent work requires. |
| **OpenCloud** | `opencloud` | Restricted | **Restricted** | OpenCloud server, all eleven web extension init containers (`external-sites`, `json-viewer`, `progress-bars`, `unzip`, `draw-io`, `calculator`, `pastebin`, `bpmn`, `maps`, `arcade`, `cast`), and OpenCloud Tika search run non-root (UID `1000`) with dropped capabilities (`ALL`) and `RuntimeDefault` seccomp. |
| **VictoriaMetrics** | `victoria-metrics` | Restricted | **Restricted** | VictoriaMetrics, VictoriaLogs, and VictoriaTraces StatefulSets run non-root (UID `1000`, GID `1000`, fsGroup `2000`) with dropped capabilities (`ALL`), `RuntimeDefault` seccomp, and `readOnlyRootFilesystem`. |
| **OpenTelemetry Collector** | `otel-collector` / `otel-collector-node` | Mixed | **Mixed** | **Restricted:** the `otel-collector-cluster` Deployment and the operator-managed `otel-collector-pod` StatefulSet (plus its Target Allocator) run non-root with dropped capabilities (`ALL`) and `RuntimeDefault` seccomp, declared through the Helm chart values and the `OpenTelemetryCollector` CR's `podSecurityContext`/`securityContext`.<br><br>**Exception (Privileged):** `otel-collector-node-agent` (DaemonSet in `otel-collector-node`) requires hostPath volume mounts (`/var/log`, `/var/lib/docker/containers`, `/proc`, `/sys`) and host metrics/log collection permissions to collect host and node telemetry; PSS `baseline` forbids hostPath volumes, so the namespace enforces `privileged` (Restricted `audit`/`warn` retained) following the Longhorn node-integration exception. |
| **OpenTelemetry Operator** | `opentelemetry-operator` | Restricted | **Restricted** | Operator manager runs non-root (UID/GID `65532`) with dropped capabilities (`ALL`), `allowPrivilegeEscalation: false`, and `RuntimeDefault` seccomp from the chart defaults. |
| **Prometheus Operator CRDs** | `prometheus-operator-crd` | Restricted | **Restricted** | CRD definitions only; no workload pods deployed. |
| **qBittorrent** | `qbittorrent` | Privileged | **Exception** | **Why not Restricted:** the gluetun VPN sidecar requires the `NET_ADMIN`/`NET_RAW` capabilities and the `/dev/net/tun` device to tunnel all BitTorrent traffic; PSS baseline forbids added capabilities.<br><br>*Mitigations:* the pod runs in an unprivileged user namespace (`hostUsers: false`), gluetun is non-privileged and receives the TUN device through the generic-device-plugin (`devic.es/tun`, no hostPath), qBittorrent, the config-seed init container, and the metrics exporter are fully rootless with dropped capabilities, Cilium egress is default-deny (VPN tunnel endpoints and the DoT bootstrap only), and the qbittorrent container's readiness probe is gated on the gluetun health server so a down tunnel drops the pod from its Service. |
| **Radicale** | `radicale` | Restricted | **Restricted** | Internal CalDAV/CardDAV backend runs non-root (UID `1000`) with dropped capabilities (`ALL`) and `RuntimeDefault` seccomp. |
| **RustFS** | `rustfs` | Baseline | **Exception** | **Why not Restricted:** The pinned RustFS Operator does not inject all Restricted container security fields (`allowPrivilegeEscalation: false`, `capabilities.drop: [ALL]`, explicit `seccompProfile`) into operator-generated Tenant StatefulSet pods.<br><br>*Mitigations:* Non-root execution (`runAsUser: 10001`, `runAsGroup: 10001`, `fsGroup: 10001`) is enforced, and user namespaces (`hostUsers: false`) are injected via `MutatingAdmissionPolicy`. |
| **RustFS Operator** | `rustfs-operator` | Restricted | **Restricted** | Storage operator runs non-root with dropped capabilities (`ALL`), `allowPrivilegeEscalation: false`, and `RuntimeDefault` seccomp. |
| **Snapshot Controller** | `snapshot-controller` | Restricted | **Restricted** | CSI snapshot controller (handwritten manifests; upstream ships no official chart) runs as non-root (UID/GID `65532` on the distroless image) with dropped capabilities (`ALL`) and `RuntimeDefault` seccomp.
| **Velero** | `velero` | Privileged | **Mixed** | **Restricted:** `velero` controller Deployment runs non-root with dropped capabilities (`ALL`) and `RuntimeDefault` seccomp.<br><br>**Exception (Privileged):** `velero-node-agent` (DaemonSet) requires hostPath mounts to `/var/lib/kubelet/pods` to mount and upload the CSI snapshots that volume backups move through (Kopia remains the uploader format) — PSS `baseline` forbids hostPath volumes, so the namespace enforces `privileged` (Restricted `audit`/`warn` retained). |
| **Velero UI** | `velero-ui` | Restricted | **Restricted** | Web management interface runs non-root with dropped capabilities (`ALL`) and `RuntimeDefault` seccomp. |
| **Vaultwarden** | `vaultwarden` | Restricted | **Restricted** | Password manager runs as non-root (UID `1000`) on unprivileged port `8080` with dropped capabilities (`ALL`), read-only root filesystem, and `RuntimeDefault` seccomp. Attached PostgreSQL instance also conforms to Restricted. |
| **Woodpecker CI** | `woodpecker` | Restricted | **Restricted** | Server and agent StatefulSets run as non-root (UID `1000`, GID `1000`) with dropped capabilities (`ALL`), `allowPrivilegeEscalation: false`, and `RuntimeDefault` seccomp. Attached PostgreSQL instance also conforms to Restricted. |

---

## User Namespaces

Kubernetes 1.37 User Namespaces (`spec.hostUsers: false`) map container UIDs/GIDs to unprivileged ranges on the host node. This ensures that even if a container process runs as UID `0` internally, it operates without root privileges on the underlying host node.

The table below details user namespace implementation across all cluster workloads:

| Workload | Namespace | User Namespaces | Implementation Mechanism | Details & Rationale |
| :--- | :--- | :---: | :--- | :--- |
| **Argo CD** | `argocd` | **Enabled** (`false`) | Kustomize patch | Applied to `server`, `repo-server`, `application-controller`, `applicationset-controller`, and `notifications-controller`. The Dragonfly operand runs in standard host namespaces (CRD lacks a `hostUsers` field). |
| **Authelia** | `authelia` | **Enabled** (`false`) | Kustomize patch | Applied to the Authelia Deployment. The attached CNPG cluster uses the `cnpg.io/podPatch` annotation; Dragonfly operand pods run in standard host namespaces (CRD lacks a `hostUsers` field). |
| **cert-manager** | `cert-manager` | **Enabled** (`false`) | Helm `values.yaml` | `global.hostUsers: false` applied across controller, cainjector, and webhook. |
| **Cilium (Hubble Relay / UI)** | `cilium` | **Enabled** (`false`) | Helm `values.yaml` | `hubble.hostUsers: false` applied to the `hubble-relay` and `hubble-ui` Deployments. |
| **Cilium (Agent / Envoy / Operator)** | `cilium` | **Disabled** (`true`) | *None (Host integration)* | **Why not enabled:** `cilium-agent`, `cilium-envoy`, and `cilium-operator` run `hostNetwork` (upstream default), which prohibits `hostUsers: false`; the kube-proxy replacement datapath requires direct node networking. |
| **CloudNativePG Operator** | `cloudnative-pg` | **Enabled** (`false`) | Kustomize patch | Applied to operator Deployment. |
| **CloudNativePG Clusters** | `authelia`, `crowdsec`, `forgejo`, `homeassistant`, `immich`, `vaultwarden`, `woodpecker` | **Enabled** (`false`) | CNPG `podPatch` annotation | `cnpg.io/podPatch` injects `hostUsers: false` into PostgreSQL instance pods. |
| **Collabora** | `collabora` | **Enabled** (`false`) | Kustomize patch | Applied to Collabora Deployment. |
| **CrowdSec** | `crowdsec` | **Enabled** (`false`) | Kustomize patch | Applied to LAPI, AppSec, and the registration jobs. **Disabled** on the Agent DaemonSet: the agent's read-only `/var/log` hostPath is incompatible with user namespaces (see the PSS exception row). |
| **CrowdSec Envoy Bouncer** | `envoy-gateway` | **Enabled** (`false`) | Kustomize patch | Applied to bouncer Deployment. |
| **Dragonfly Operator** | `dragonfly-operator` | **Enabled** (`false`) | Kustomize patch | Applied to operator Deployment. Operator-generated Dragonfly CR instances run in standard host namespaces (CRD lacks `hostUsers` field). |
| **DocumentDB Operator** | `documentdb-operator` / `cloudnative-pg` | **Enabled** (`false`) | Kustomize patch | Applied to operator and sidecar-injector Deployments. Operator-generated DocumentDB operand pods (CNPG Clusters) run in standard host namespaces (DocumentDB CRD does not propagate `hostUsers`). |
| **Envoy Gateway** | `envoy-gateway` | **Enabled** (`false`) | Kustomize patch / Manifest | Applied to gateway controller and `EnvoyProxy` data-plane pods. |
| **ExternalDNS** | `external-dns` | **Enabled** (`false`) | Kustomize patch | Applied to ExternalDNS Deployment. |
| **External Secrets** | `external-secrets` | **Enabled** (`false`) | Helm `values.yaml` | `hostUsers: false` configured for controller, webhook, and cert-controller. |
| **Forgejo** | `forgejo` | **Enabled** (`false`) | Kustomize patch | Applied to Forgejo Deployment. |
| **Grafana** | `grafana` | **Enabled** (`false`) | Grafana CR manifest | Declared in `spec.deployment.spec.template.spec.hostUsers`. |
| **Grafana Operator** | `grafana-operator` | **Enabled** (`false`) | Helm `values.yaml` | `hostUsers: false` configured for operator Deployment. |
| **Generic Device Plugin** | `kube-system` | **Disabled** (`true`) | *None (Host integration)* | **Why not enabled:** the privileged device plugin registers its socket through the kubelet's hostPath `/var/lib/kubelet/device-plugins` and enumerates host `/dev`; a user namespace adds no isolation value for the node-level device enumeration it performs. |
| **Home Assistant** | `homeassistant` | **Enabled** (`false`) | Manifest | Declared in Deployments for `homeassistant` Core, `mosquitto`, and `zigbee2mqtt`. Isolates container UID `0` within an unprivileged host user namespace. |
| **Homepage** | `homepage` | **Enabled** (`false`) | Manifest | Declared in the Homepage dashboard Deployment. |
| **Immich** | `immich` | **Enabled** (`false`) | Helm `values.yaml` | `defaultPodOptions.hostUsers: false` configured for server and machine-learning Deployments. |
| **Kubelet Serving Cert Approver** | `kubelet-serving-cert-approver` | **Enabled** (`false`) | Manifest | Declared in the approver Deployment. |
| **Longhorn (Auxiliary)** | `longhorn-system` | **Enabled** (`false`) | Kustomize patch | Applied to `longhorn-ui`, `longhorn-driver-deployer`, `longhorn-global-manager`, and the post-upgrade cleanup job; the pre-upgrade and uninstall Jobs never render (pre-upgrade disabled with the preUpgradeChecker, uninstall patch-deleted). |
| **Kube State Metrics** | `kube-state-metrics` | **Enabled** (`gvisor`) | Kustomize patch | The chart exposes no runtimeClassName key; the patch pins it on the Deployment. |
| **Kube State Metrics** | `kube-state-metrics` | **Enabled** (`false`) | Kustomize patch | The chart's `hostUsers` default is a chart-computed nil, so the patch pins it. |
| **Longhorn (Storage Node)** | `longhorn-system` | **Disabled** (`true`) | *None (Host integration)* | **Why not enabled:** Kubernetes user namespaces prohibit `hostUsers: false` on pods utilizing `hostNetwork`, `hostPID`, `hostIPC`, or raw block-volume devices. Longhorn storage manager requires direct node device and kernel integration. |
| **Metrics Server** | `metrics-server` | **Enabled** (`false`) | Kustomize patch | Applied to the metrics-server Deployment; the chart's `hostUsers` value is gated on the kube version assumed by the rendering helm binary, so the field is pinned by a patch to stay deterministic. |
| **Notesnook** | `notesnook` | **Enabled** (`false`) | Manifest | Declared in Pod templates across all microservice Deployments (`sync`, `identity`, `sse`, `monograph`). DocumentDB operand pods (CNPG Clusters) run in standard host namespaces. |
| **OpenChamber** | `openchamber` | **Enabled** (`false`) | Manifest | Declared in the agent workspace Deployment. |
| **OpenCloud** | `opencloud` | **Enabled** (`false`) | Manifest | Declared in Deployments for `opencloud` server and `opencloud-tika`. |
| **VictoriaMetrics** | `victoria-metrics` | **Enabled** (`false`) | Kustomize patch | Applied to VictoriaMetrics, VictoriaLogs, and VictoriaTraces StatefulSets. |
| **OTel Collector (Cluster)** | `otel-collector` | **Enabled** (`false`) | Helm values | The chart's top-level `hostUsers: false` value applies to the cluster collector Deployment. |
| **OTel Collector (Pod)** | `otel-collector` | **Enabled** (`false`) | `OpenTelemetryCollector` CR | Declared in the collector CR's `spec.hostUsers`. |
| **OTel Target Allocator** | `otel-collector` | **Enabled** (`false`) | `MutatingAdmissionPolicy` | The operator's embedded Target Allocator CR does not inherit the collector's `hostUsers`, so the `opentelemetry-gvisor` MutatingAdmissionPolicy injects `hostUsers: false` alongside the runtime class. |
| **OpenTelemetry Operator** | `opentelemetry-operator` | **Enabled** (`false`) | Helm values | The chart's top-level `hostUsers: false` value applies to the operator manager Deployment. |
| **OTel Collector (Node)** | `otel-collector-node` | **Disabled** (`true`) | *None (Host integration)* | **Why not enabled:** Node agent requires hostPath mounts, `HostToContainer` mount propagation, and host telemetry access that conflict with user namespaces. Receiver host ports are disabled (`ports.*.hostPort: 0`) to satisfy PSS; nothing sends telemetry to node IPs. |
| **Radicale** | `radicale` | **Enabled** (`false`) | Manifest | Declared in Radicale Deployment. |
| **RustFS Tenant** | `rustfs` | **Enabled** (`false`) | `MutatingAdmissionPolicy` | RustFS Operator does not support a pod template patch field for `hostUsers`. A CEL-based Kubernetes `MutatingAdmissionPolicy` mutates Tenant pods at admission to inject `hostUsers: false`. |
| **RustFS Operator** | `rustfs-operator` | **Enabled** (`false`) | Kustomize patch | Applied to the storage operator and console Deployments. |
| **qBittorrent** | `qbittorrent` | **Enabled** (`false`) | Manifest | Declared in the qBittorrent Deployment (isolating gluetun's container-root in an unprivileged host user namespace) and in the port-forward sync CronJob pod template. |
| **Snapshot Controller** | `snapshot-controller` | **Enabled** (`false`) | Manifest | Declared in the handwritten Deployment. |
| **Velero (Server)** | `velero` | **Enabled** (`false`) | Kustomize patch | Applied to `velero` controller Deployment. |
| **Velero (Node Agent)** | `velero` | **Disabled** (`true`) | *None (Host integration)* | **Why not enabled:** Node agent requires hostPath mounts to `/var/lib/kubelet/pods` for CSI snapshot data movement (`defaultVolumesToFsBackup: false`, `features: EnableCSI`). |
| **Velero UI** | `velero-ui` | **Enabled** (`false`) | Kustomize patch | Applied to `velero-ui` Deployment. |
| **Vaultwarden** | `vaultwarden` | **Enabled** (`false`) | Manifest | Declared in the Vaultwarden Deployment. |
| **Woodpecker CI** | `woodpecker` | **Enabled** (`false`) | Kustomize patch | Applied to Woodpecker server and agent StatefulSets. Attached CNPG cluster uses `podPatch`. |

---

## SELinux & CSI Storage Classes

On Talos Linux, CSI drivers mount the volumes they provision directly, preventing the OS from automatically labelling those volumes. Without an explicit SELinux context, pods cannot access the volume contents.

To enable unprivileged and Restricted workloads to access mounted volumes, all `StorageClass` resources provisioning filesystems declare the `ephemeral_t` SELinux context in `mountOptions`:

```yaml
mountOptions:
  - context=system_u:object_r:ephemeral_t:s0
```

Volumes requested as `volumeMode: Block` contain no filesystem, so they need no label.

---

## gVisor Runtime Sandboxing

To provide kernel-level defense-in-depth against container breakout vulnerabilities, the cluster utilizes [gVisor](https://gvisor.dev/) (`runsc`) via the `RuntimeClass/gvisor` definition, which is not managed by GitOps and is created manually during Talos bootstrap (see [docs/talos.md](talos.md)). Compatible workloads across every application namespace declare `spec.runtimeClassName: gvisor`. Operator-generated operands whose pod templates the CRD cannot set — CloudNativePG instance pods, Dragonfly instances, DocumentDB clusters, and RustFS Tenant pods — run on the standard runtime as documented exceptions: their `hostUsers` field is injected through the operators' supported mechanisms (`cnpg.io/podPatch`, MutatingAdmissionPolicy), but the CRDs expose no runtime class field. Workloads spawned per-pipeline by the Woodpecker Kubernetes backend opt into gVisor per-step through backend options (`WOODPECKER_BACKEND_K8S_RUNTIME_CLASS_ALLOW_FROM_STEP` gates it at the agent).

Only workloads requiring direct host device access, raw block devices, or kernel filesystem hooks retain the standard container runtime.

| Workload | Namespace | gVisor Sandboxing | Implementation Mechanism | Details & Rationale |
| :--- | :--- | :---: | :--- | :--- |
| **Argo CD** | `argocd` | **Enabled** (`gvisor`) | Kustomize patch | Applied to `server`, `repo-server`, `application-controller`, `applicationset-controller`, and `notifications-controller`. The Dragonfly operand is a documented standard-runtime exception (CRD lacks a `runtimeClassName` field). |
| **Authelia** | `authelia` | **Enabled** (`gvisor`) | Kustomize patch | Applied to Authelia Deployment. |
| **cert-manager** | `cert-manager` | **Enabled** (`gvisor`) | Kustomize patch | Applied across `controller`, `cainjector`, and `webhook` Deployments (the `startupapicheck` Job is disabled in values: it is an inert Helm-hook upgrade checker under Argo). |
| **Cilium (Hubble Relay / UI)** | `cilium` | **Enabled** (`gvisor`) | Kustomize patch | Applied to the `hubble-relay` and `hubble-ui` Deployments; the chart has no `runtimeClassName` value. |
| **Cilium (Agent / Envoy / Operator)** | `cilium` | **Disabled** | *None (Host integration)* | **Exception:** `cilium-agent` and `cilium-envoy` require BPF datapath, bpffs mounts, and `hostNetwork`; `cilium-operator` runs `hostNetwork` by upstream chart default. |
| **CloudNativePG Operator** | `cloudnative-pg` | **Enabled** (`gvisor`) | Kustomize patch | Applied to operator Deployment. |
| **Collabora** | `collabora` | **Enabled** (`gvisor`) | Kustomize patch | Applied to Collabora Deployment. |
| **CrowdSec (LAPI / AppSec)** | `crowdsec` | **Enabled** (`gvisor`) | Kustomize patch | Applied to `crowdsec-lapi` and `crowdsec-appsec` Deployments and the registration jobs. |
| **CrowdSec (Agent)** | `crowdsec` | **Disabled** | *None (Host integration)* | **Exception:** Agent DaemonSet requires hostPath volume mounts (`/var/log`) to read node and container engine logs. |
| **CrowdSec Envoy Bouncer** | `envoy-gateway` | **Enabled** (`gvisor`) | Kustomize patch | Applied to bouncer Deployment. |
| **Dragonfly Operator** | `dragonfly-operator` | **Enabled** (`gvisor`) | Kustomize patch | Applied to operator Deployment. |
| **DocumentDB Operator** | `documentdb-operator` / `cloudnative-pg` | **Enabled** (`gvisor`) | Kustomize patch | Applied to operator and sidecar-injector Deployments. DocumentDB operand pods inherit the CNPG default runtime. |
| **Envoy Gateway** | `envoy-gateway` | **Enabled** (`gvisor`) | Kustomize patch / `EnvoyProxy` | Applied to the gateway controller Deployment, `EnvoyProxy` data-plane pods, and the certgen Job. |
| **ExternalDNS** | `external-dns` | **Enabled** (`gvisor`) | Kustomize patch | Applied to ExternalDNS Deployment. |
| **External Secrets** | `external-secrets` | **Enabled** (`gvisor`) | Helm `values.yaml` | Applied across `controller`, `webhook`, and `cert-controller` Deployments. |
| **Forgejo** | `forgejo` | **Enabled** (`gvisor`) | Kustomize patch | Applied to Forgejo Deployment. |
| **Grafana** | `grafana` | **Enabled** (`gvisor`) | Grafana CR manifest | Declared in `spec.deployment.spec.template.spec.runtimeClassName`. |
| **Grafana Operator** | `grafana-operator` | **Enabled** (`gvisor`) | Kustomize patch | Applied to operator Deployment. |
| **Generic Device Plugin** | `kube-system` | **Disabled** | *None (Host integration)* | **Exception:** the privileged device plugin enumerates host `/dev` and registers its socket under the kubelet's hostPath `/var/lib/kubelet/device-plugins`. |
| **Home Assistant (Core / Mosquitto)** | `homeassistant` | **Enabled** (`gvisor`) | Manifest | Declared in `homeassistant` Core and `mosquitto` Deployments. |
| **Home Assistant (Zigbee2MQTT)** | `homeassistant` | **Disabled** | *None (Host integration)* | **Exception:** Zigbee2MQTT requires direct hostPath access to physical USB serial adapter (`/dev/serial/by-id`). |
| **Homepage** | `homepage` | **Enabled** (`gvisor`) | Manifest | Declared in the Homepage dashboard Deployment. |
| **Immich** | `immich` | **Enabled** (`gvisor`) | Kustomize patch | Applied to `immich-server` and `immich-machine-learning` Deployments. |
| **Kubelet Serving Cert Approver** | `kubelet-serving-cert-approver` | **Enabled** (`gvisor`) | Manifest | Declared in the approver Deployment. |
| **Longhorn (Auxiliary)** | `longhorn-system` | **Enabled** (`gvisor`) | Kustomize patch | Applied to `longhorn-manager` auxiliary containers where the chart allows it, plus the `longhorn-ui`, `longhorn-driver-deployer`, and `longhorn-global-manager` Deployments and the post-upgrade cleanup job; the pre-upgrade and uninstall Jobs never render. `longhorn-manager`'s own DaemonSet containers stay on the standard runtime with the privileged PSS exception above (the chart exposes no runtime-class key for them). |
| **Longhorn (Storage Node)** | `longhorn-system` | **Disabled** | *None (Host integration)* | **Exception:** Storage engine, CSI node plugin, and instance managers require raw host block devices, iscsi/spdk engines, and bidirectional mount propagation. |
| **Metrics Server** | `metrics-server` | **Enabled** (`gvisor`) | Kustomize patch | Applied to the metrics-server Deployment; the chart has no `runtimeClassName` value. |
| **Notesnook** | `notesnook` | **Enabled** (`gvisor`) | Manifest | Declared across all microservice Deployments. DocumentDB operand pods inherit the CNPG default runtime. |
| **OpenChamber** | `openchamber` | **Enabled** (`gvisor`) | Manifest | Declared in the agent workspace Deployment; gVisor isolates arbitrary model-generated code executed by the coding agents. |
| **OpenCloud** | `opencloud` | **Enabled** (`gvisor`) | Manifest | Declared in `opencloud` server and `opencloud-tika` Deployments. |
| **VictoriaMetrics** | `victoria-metrics` | **Enabled** (`gvisor`) | Helm values | `server.runtimeClassName: gvisor` on VictoriaMetrics, VictoriaLogs, and VictoriaTraces. |
| **OTel Collector (Cluster)** | `otel-collector` | **Enabled** (`gvisor`) | Helm values | The chart's `runtimeClassName: gvisor` value applies to the cluster collector Deployment. |
| **OTel Collector (Pod/Target Allocator)** | `otel-collector` | **Enabled** (`gvisor`) | MutatingAdmissionPolicy | The `OpenTelemetryCollector` and `TargetAllocator` CRDs expose no `runtimeClassName` field, so the `opentelemetry-gvisor` MutatingAdmissionPolicy injects it into operator-generated pods at admission. |
| **OpenTelemetry Operator** | `opentelemetry-operator` | **Enabled** (`gvisor`) | Kustomize patch | Applied to the operator manager Deployment; the chart has no `runtimeClassName` value. |
| **OTel Collector (Node)** | `otel-collector-node` | **Disabled** | *None (Host integration)* | **Exception:** Node collector DaemonSet requires hostPath mounts (`/proc`, `/sys`, `/var/log`) and host metrics access. |
| **qBittorrent (qBittorrent / gluetun / exporter)** | `qbittorrent` | **Disabled** | *None (Host integration)* | **Exception:** the gluetun sidecar requires the `/dev/net/tun` device to establish the VPN tunnel, which gVisor does not implement. |
| **qBittorrent (port-forward sync job)** | `qbittorrent` | **Enabled** (`gvisor`) | Manifest | Declared in the sync CronJob pod template; the job only calls in-cluster HTTP endpoints. |
| **Radicale** | `radicale` | **Enabled** (`gvisor`) | Manifest | Declared in Radicale Deployment. |
| **RustFS Operator** | `rustfs-operator` | **Enabled** (`gvisor`) | Kustomize patch | Applied to the storage operator and console Deployments. |
| **Snapshot Controller** | `snapshot-controller` | **Enabled** (`gvisor`) | Manifest | Declared in the handwritten Deployment. |
| **Velero (Server)** | `velero` | **Enabled** (`gvisor`) | Kustomize patch | Applied to `velero` controller Deployment. |
| **Velero (Node Agent)** | `velero` | **Disabled** | *None (Host integration)* | **Exception:** Node agent requires hostPath mounts to `/var/lib/kubelet/pods` for CSI snapshot data movement (`defaultVolumesToFsBackup: false`, `features: EnableCSI`). |
| **RustFS Tenant** | `rustfs` | **Disabled** | *None (Operator limitation)* | **Exception:** the RustFS Operator's `Tenant` CRD exposes no `runtimeClassName` field, so operator-generated Tenant pods run the standard runtime (documented alongside the `baseline` PSS exception). |
| **Velero UI** | `velero-ui` | **Enabled** (`gvisor`) | Kustomize patch | Applied to `velero-ui` Deployment. |
| **Woodpecker CI** | `woodpecker` | **Enabled** (`gvisor`) | Kustomize patch / Helm values | Applied to server and agent StatefulSets. Pipeline step pods opt into gVisor per step through `backend_options.kubernetes.runtimeClassName`, gated by `WOODPECKER_BACKEND_K8S_RUNTIME_CLASS_ALLOW_FROM_STEP`; this release has no agent-wide runtime-class flag. Steps must also carry a Restricted-compatible `backend_options.kubernetes.securityContext` (`runAsNonRoot`, `RuntimeDefault` seccomp, dropped capabilities, `allowPrivilegeEscalation: false`) and a non-root clone image, or the Restricted-enforcing namespace rejects them at admission; a full instance-wide step security context lands with the upstream default/enforced-secctx feature and is not available in the pinned release. |

---

## ServiceAccount Hygiene & Token Automounting

To minimize attack surface and prevent credential exfiltration in the event of pod compromise, workloads that do not interact with the Kubernetes API disable API token projection via `automountServiceAccountToken: false`.

Standalone applications use dedicated ServiceAccounts rather than the namespace `default` ServiceAccount:
- `opencloud`: Dedicated `opencloud` ServiceAccount with `automountServiceAccountToken: false`.
- `homeassistant`: Dedicated `homeassistant-app` ServiceAccount with `automountServiceAccountToken: false` applied to `homeassistant`, `mosquitto`, and `zigbee2mqtt` (the name avoids colliding with the CloudNativePG cluster-derived `homeassistant` ServiceAccount, which CNPG adopts as-is and needs a mounted token).
- `radicale`: Dedicated `radicale` ServiceAccount with `automountServiceAccountToken: false`.
- `homepage`: Dedicated `homepage` ServiceAccount with `automountServiceAccountToken: true` — the dashboard's Kubernetes integration reads pods, nodes, and `metrics.k8s.io` from the API server, scoped to a read-only ClusterRole.

Handwritten application ServiceAccounts:
- `vaultwarden`: Dedicated `vaultwarden-app` ServiceAccount with `automountServiceAccountToken: false` (the name avoids colliding with the CloudNativePG cluster-derived `vaultwarden` ServiceAccount, which CNPG adopts as-is and needs a mounted token).

Helm workloads with API access disabled via patches or values:
- `forgejo`: `automountServiceAccountToken: false`
- `victoria-metrics`: `automountServiceAccountToken: false`
- `longhorn-ui`: `automountServiceAccountToken: false`
- `collabora`: `automountServiceAccountToken: false`
- `crowdsec-envoy-bouncer`: `automountServiceAccountToken: false`
- `authelia`: `automountServiceAccountToken: false`


