# Pod Security & User Namespaces

Workloads in this cluster are secured according to the [Kubernetes Pod Security Standards (PSS)](https://kubernetes.io/docs/concepts/security/pod-security-standards/) and opted into [Kubernetes 1.36 User Namespaces](https://kubernetes.io/docs/concepts/workloads/pods/user-namespaces/) (`hostUsers: false`) wherever supported.

Namespace-level Pod Security Admission (PSA) labels are managed declaratively in `apps/app-of-apps.yaml` through `syncPolicy.managedNamespaceMetadata`. Changes stage with Restricted `audit` and `warn` labels, with Restricted enforcement enabled once rendered and live admission results are verified clean.

Workloads requiring host integration, raw block devices, hostPath mounts, or root execution are isolated in dedicated namespaces with resource-scoped exceptions documented via `security.homeworld/exception-reason` annotations.

---

## Pod Security Standards

The table below outlines the Pod Security Standard compliance level for every component in the cluster.

| Application | Namespace | PSA Level | Compliance | Details & Rationale |
| :--- | :--- | :---: | :---: | :--- |
| **Argo CD** | `argocd` | Restricted | **Restricted** | All components (`server`, `repo-server`, `application-controller`, `redis`, `dex`) run as non-root with dropped capabilities (`ALL`) and `RuntimeDefault` seccomp. |
| **Authelia** | `authelia` | Restricted | **Restricted** | Application container runs as UID `1000` with read-only root filesystem, dropped capabilities (`ALL`), and `RuntimeDefault` seccomp. Attached PostgreSQL and Dragonfly instances also conform to Restricted. |
| **cert-manager** | `cert-manager` | Restricted | **Restricted** | Controller, cainjector, webhook, and startup check run non-root with dropped capabilities (`ALL`) and `RuntimeDefault` seccomp. |
| **CloudNativePG** | `cloudnative-pg` | Restricted | **Restricted** | Operator controller runs as non-root with dropped capabilities (`ALL`) and `RuntimeDefault` seccomp. |
| **Collabora** | `collabora` | Restricted | **Restricted** | Runs as non-root (UID `1000`) with dropped capabilities (`ALL`) and `RuntimeDefault` seccomp. Writable root filesystem is accepted for office document rendering caches. |
| **CrowdSec** | `crowdsec` | Baseline | **Exception** | **Why not Restricted:** The pinned upstream CrowdSec image requires container UID `0` to write staged configuration files during startup. Additionally, `crowdsec-agent` (DaemonSet) requires a read-only hostPath mount (`/var/log`) to read container engine and node logs for intrusion detection.<br><br>*Mitigations:* `crowdsec-lapi` and `crowdsec-appsec` maintain dropped capabilities (`ALL`), `allowPrivilegeEscalation: false`, and `RuntimeDefault` seccomp under the Baseline namespace. |
| **CrowdSec Envoy Bouncer** | `envoy-gateway` | Restricted | **Restricted** | Runs as non-root with dropped capabilities (`ALL`), `allowPrivilegeEscalation: false`, and `RuntimeDefault` seccomp. |
| **Dragonfly Operator** | `dragonfly-operator` | Restricted | **Restricted** | Operator manager and `kube-rbac-proxy` run non-root with dropped capabilities (`ALL`), `allowPrivilegeEscalation: false`, and `RuntimeDefault` seccomp. |
| **Envoy Gateway** | `envoy-gateway` | Restricted | **Restricted** | Gateway control-plane controller and Envoy proxy data-plane pods run non-root with dropped capabilities (`ALL`) and `RuntimeDefault` seccomp. |
| **ExternalDNS** | `external-dns` | Restricted | **Restricted** | Controller runs as non-root with dropped capabilities (`ALL`), `allowPrivilegeEscalation: false`, and `RuntimeDefault` seccomp. |
| **External Secrets** | `external-secrets` | Restricted | **Restricted** | Controller, webhook, and cert-controller run as non-root with dropped capabilities (`ALL`) and `RuntimeDefault` seccomp. |
| **Forgejo** | `forgejo` | Restricted | **Restricted** | Application and init containers run non-root (UID `1000`, GID `1000`) with dropped capabilities (`ALL`) and `RuntimeDefault` seccomp. Attached PostgreSQL instance also conforms to Restricted. |
| **Grafana** | `grafana` | Restricted | **Restricted** | Grafana instance and the plugin-loader init container run non-root (UID `1000`) with dropped capabilities (`ALL`) and `RuntimeDefault` seccomp. |
| **Grafana Operator** | `grafana-operator` | Restricted | **Restricted** | Operator controller runs as non-root with dropped capabilities (`ALL`) and `RuntimeDefault` seccomp. |
| **Home Assistant** | `homeassistant` | Baseline | **Exception** | **Why not Restricted:** The `homeassistant` Core container requires UID `0` (`runAsNonRoot: false`) because the upstream image uses `s6-overlay` for process supervision. `zigbee2mqtt` accesses the physical Zigbee USB adapter via a hostPath mount (`/dev/serial/by-id`) on nodes labeled `environment=zigbee`.<br><br>*Mitigations:* Workloads are isolated in unprivileged user namespaces (`hostUsers: false`). `mosquitto` and `zigbee2mqtt` run non-root (`runAsUser: 1883` and `1000`) with dropped capabilities (`ALL`) and `RuntimeDefault` seccomp under Restricted; `zigbee2mqtt` accesses the serial device via host `dialout` group (GID `20`). |
| **Immich** | `immich` | Restricted | **Restricted** | Server and machine-learning pods run non-root with dropped capabilities (`ALL`) and `RuntimeDefault` seccomp. Attached PostgreSQL and Dragonfly instances also conform to Restricted. |
| **Longhorn** | `longhorn-system` | Privileged | **Exception** | **Why not Restricted:** `longhorn-manager` (DaemonSet), CSI plugins (`longhorn-csi-plugin`), and engine/replica instance managers require privileged containers, hostPath volume mounts (`/var/lib/longhorn`, `/dev`, `/sys`, `/proc`), bidirectionally shared mounts, and raw host block-device access to manage distributed storage, kernel block devices, and iscsi/spdk engines.<br><br>*Mitigations:* Isolated in dedicated `longhorn-system` namespace. Auxiliary pods (`longhorn-ui`, `longhorn-driver-deployer`, upgrade jobs) run non-root with user namespaces enabled. |
| **OpenCloud** | `opencloud` | Restricted | **Restricted** | OpenCloud server, all web extension init containers (`external-sites`, `json-viewer`, `progress-bars`, `unzip`), and OpenCloud Tika search run non-root (UID `1000`) with dropped capabilities (`ALL`) and `RuntimeDefault` seccomp. |
| **OpenObserve** | `openobserve` | Restricted | **Restricted** | Runs non-root (UID `10000`, GID `3000`, fsGroup `2000`) with dropped capabilities (`ALL`) and `RuntimeDefault` seccomp. |
| **OpenTelemetry Collector** | `otel-collector` / `otel-collector-node` | Mixed | **Mixed** | **Restricted:** `otel-collector-cluster` and `otel-collector-pod` Deployments run non-root with dropped capabilities (`ALL`) and `RuntimeDefault` seccomp.<br><br>**Exception (Baseline):** `otel-collector-node-agent` (DaemonSet in `otel-collector-node`) requires hostPath volume mounts (`/var/log`, `/var/lib/docker/containers`, `/proc`, `/sys`) and host metrics/log collection permissions to collect host and node telemetry. |
| **Prometheus Operator CRDs** | `prometheus-operator-crd` | Restricted | **Restricted** | CRD definitions only; no workload pods deployed. |
| **Radicale** | `radicale` | Restricted | **Restricted** | Internal CalDAV/CardDAV backend runs non-root (UID `2999`) with dropped capabilities (`ALL`) and `RuntimeDefault` seccomp. |
| **RustFS** | `rustfs` | Baseline | **Exception** | **Why not Restricted:** Pinned RustFS Operator 0.0.5 does not inject all Restricted container security fields (`allowPrivilegeEscalation: false`, `capabilities.drop: [ALL]`, explicit `seccompProfile`) into operator-generated Tenant StatefulSet pods.<br><br>*Mitigations:* Non-root execution (`runAsUser: 10001`, `runAsGroup: 10001`, `fsGroup: 10001`) is enforced, and user namespaces (`hostUsers: false`) are injected via `MutatingAdmissionPolicy`. |
| **RustFS Operator** | `rustfs-operator` | Restricted | **Restricted** | Storage operator runs non-root with dropped capabilities (`ALL`), `allowPrivilegeEscalation: false`, and `RuntimeDefault` seccomp. |
| **Velero** | `velero` | Baseline | **Mixed** | **Restricted:** `velero` controller Deployment and `velero-upgrade-crds` Job run non-root with dropped capabilities (`ALL`) and `RuntimeDefault` seccomp.<br><br>**Exception (Baseline):** `velero-node-agent` (DaemonSet) requires hostPath mounts to `/var/lib/kubelet/pods` to execute file-level (Kopia) volume backups of persistent volumes. |
| **Velero UI** | `velero-ui` | Restricted | **Restricted** | Web management interface runs non-root with dropped capabilities (`ALL`) and `RuntimeDefault` seccomp. |
| **Woodpecker CI** | `woodpecker` | Restricted | **Restricted** | Server and agent StatefulSets run as non-root (UID `1000`, GID `1000`) with dropped capabilities (`ALL`), `allowPrivilegeEscalation: false`, and `RuntimeDefault` seccomp. Attached PostgreSQL instance also conforms to Restricted. |

---

## User Namespaces

Kubernetes 1.36 User Namespaces (`spec.hostUsers: false`) map container UIDs/GIDs to unprivileged ranges on the host node. This ensures that even if a container process runs as UID `0` internally, it operates without root privileges on the underlying host node.

The table below details user namespace implementation across all cluster workloads:

| Workload | Namespace | User Namespaces | Implementation Mechanism | Details & Rationale |
| :--- | :--- | :---: | :--- | :--- |
| **Argo CD** | `argocd` | **Enabled** (`false`) | Kustomize patch | Applied to `server`, `repo-server`, and `application-controller`. |
| **Authelia** | `authelia` | **Enabled** (`false`) | Kustomize patch | Applied to Authelia Deployment. Attached CNPG and Dragonfly pods use standard host namespaces. |
| **cert-manager** | `cert-manager` | **Enabled** (`false`) | Helm `values.yaml` | `global.hostUsers: false` applied across controller, cainjector, and webhook. |
| **CloudNativePG Operator** | `cloudnative-pg` | **Enabled** (`false`) | Kustomize patch | Applied to operator Deployment. |
| **CloudNativePG Clusters** | `crowdsec`, `forgejo`, `woodpecker` | **Enabled** (`false`) | CNPG `podPatch` annotation | `cnpg.io/podPatch` injects `hostUsers: false` into PostgreSQL instance pods. |
| **Collabora** | `collabora` | **Enabled** (`false`) | Kustomize patch | Applied to Collabora Deployment. |
| **CrowdSec** | `crowdsec` | **Enabled** (`false`) | Kustomize patch | Applied to LAPI, AppSec, Agent DaemonSet, and registration jobs. |
| **CrowdSec Envoy Bouncer** | `envoy-gateway` | **Enabled** (`false`) | Kustomize patch | Applied to bouncer Deployment. |
| **Dragonfly Operator** | `dragonfly-operator` | **Enabled** (`false`) | Kustomize patch | Applied to operator Deployment. Operator-generated Dragonfly CR instances run in standard host namespaces (CRD lacks `hostUsers` field). |
| **Envoy Gateway** | `envoy-gateway` | **Enabled** (`false`) | Kustomize patch / Manifest | Applied to gateway controller and `EnvoyProxy` data-plane pods. |
| **ExternalDNS** | `external-dns` | **Enabled** (`false`) | Kustomize patch | Applied to ExternalDNS Deployment. |
| **External Secrets** | `external-secrets` | **Enabled** (`false`) | Helm `values.yaml` | `hostUsers: false` configured for controller, webhook, and cert-controller. |
| **Forgejo** | `forgejo` | **Enabled** (`false`) | Kustomize patch | Applied to Forgejo Deployment. |
| **Grafana** | `grafana` | **Enabled** (`false`) | Grafana CR manifest | Declared in `spec.deployment.spec.template.spec.hostUsers`. |
| **Grafana Operator** | `grafana-operator` | **Enabled** (`false`) | Helm `values.yaml` | `hostUsers: false` configured for operator Deployment. |
| **Home Assistant** | `homeassistant` | **Enabled** (`false`) | Manifest | Declared in Deployments for `homeassistant` Core, `mosquitto`, and `zigbee2mqtt`. Isolates container UID `0` within an unprivileged host user namespace. |
| **Immich** | `immich` | **Enabled** (`false`) | Helm `values.yaml` | `defaultPodOptions.hostUsers: false` configured for server and machine-learning Deployments. |
| **Longhorn (Auxiliary)** | `longhorn-system` | **Enabled** (`false`) | Kustomize patch | Applied to `longhorn-ui`, `longhorn-driver-deployer`, and upgrade/uninstall jobs. |
| **Longhorn (Storage Node)** | `longhorn-system` | **Disabled** (`true`) | *None (Host integration)* | **Why not enabled:** Kubernetes user namespaces prohibit `hostUsers: false` on pods utilizing `hostNetwork`, `hostPID`, `hostIPC`, or raw block-volume devices. Longhorn storage manager requires direct node device and kernel integration. |
| **OpenCloud** | `opencloud` | **Enabled** (`false`) | Manifest | Declared in Deployments for `opencloud` server and `opencloud-tika`. |
| **OpenObserve** | `openobserve` | **Enabled** (`false`) | Kustomize patch | Applied to OpenObserve Deployment. |
| **OTel Collector (Cluster/Pod)** | `otel-collector` | **Enabled** (`false`) | Kustomize patch | Applied to cluster and pod collector Deployments. |
| **OTel Collector (Node)** | `otel-collector-node` | **Disabled** (`true`) | *None (Host integration)* | **Why not enabled:** Node agent requires hostPath mounts, `HostToContainer` mount propagation, host ports, and host telemetry access that conflict with user namespaces. |
| **Radicale** | `radicale` | **Enabled** (`false`) | Manifest | Declared in Radicale Deployment. |
| **RustFS Tenant** | `rustfs` | **Enabled** (`false`) | `MutatingAdmissionPolicy` | RustFS Operator does not support a pod template patch field for `hostUsers`. A CEL-based Kubernetes `MutatingAdmissionPolicy` mutates Tenant pods at admission to inject `hostUsers: false`. |
| **RustFS Operator** | `rustfs-operator` | **Enabled** (`false`) | Kustomize patch | Applied to storage operator Deployment. |
| **Velero (Server)** | `velero` | **Enabled** (`false`) | Kustomize patch | Applied to `velero` controller Deployment and `velero-upgrade-crds` Job. |
| **Velero (Node Agent)** | `velero` | **Disabled** (`true`) | *None (Host integration)* | **Why not enabled:** Node agent requires hostPath mounts to `/var/lib/kubelet/pods` to perform volume backups. |
| **Velero UI** | `velero-ui` | **Enabled** (`false`) | Kustomize patch | Applied to `velero-ui` Deployment. |
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

