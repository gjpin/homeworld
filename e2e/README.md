# Portable E2E CLI (`e2e`)

Config-driven Go CLI that bootstraps **kind + Cilium**, brings up suite-defined
**Docker Compose** dependencies, runs a portable deploy pipeline, and asserts
cluster health. Project-specific apps (including Infisical seeding) live in
suite YAML and hook scripts — not in Go.

## Build

```bash
cd e2e
go build -o /tmp/e2e ./cmd/e2e
```

## Host prerequisites

Required on `PATH` for `run` / `cluster` / `deps`:

| Tool | Notes |
| --- | --- |
| `docker` | Engine running |
| `docker compose` | Compose v2 plugin (`docker compose version`) |
| `kind` | Cluster create/delete |
| `kubectl` | Apply / wait / labels |
| `helm` | Cilium (and suite helm steps) |

`e2e validate` checks the suite schema and reports missing tools as warnings.

## Commands

| Command | Behavior |
| --- | --- |
| `e2e run -f suite.yaml` | deps → cluster up → prepare → deploy → assert |
| `e2e deps up -f suite.yaml` | Start Compose projects |
| `e2e deps down -f suite.yaml` | Stop Compose projects (`down -v`) |
| `e2e cluster up -f suite.yaml` | kind + Cilium only |
| `e2e cluster down -f suite.yaml` | Delete kind (+ deps unless `--keep-deps`) |
| `e2e deploy -f suite.yaml` | Prepare + deploy (current kubecontext) |
| `e2e assert -f suite.yaml` | Checks only |
| `e2e validate -f suite.yaml` | Schema (+ prereq warnings), no cluster |

Global flags: `--kubeconfig`, `--context`, `--timeout`, `--fail-fast`,
`--output text|json`. On `run`: `--keep-cluster` / `--keep-deps` retain
resources after failure.

Exit codes: `0` ok, `1` assert failed, `2` pipeline error, `3` usage/schema.

## Suite schema (v1alpha1)

```yaml
apiVersion: e2e.testing.dev/v1alpha1
kind: Suite
metadata:
  name: example
spec:
  workdir: .   # optional; default = suite file directory
  deps:
    dockerCompose:
      - name: infisical
        file: examples/infisical/docker-compose.yml
        envFile: examples/infisical/.env.e2e
        projectName: e2e-infisical
        wait:
          - url: http://127.0.0.1:8080/api/status
            timeout: 5m
  cluster:
    name: e2e
    kindConfig: |
      kind: Cluster
      apiVersion: kind.x-k8s.io/v1alpha4
      networking:
        disableDefaultCNI: true
      nodes:
      - role: control-plane
      - role: worker
    cilium:
      chartVersion: "<match the pinned chart in apps/cilium/helm/kustomization.yaml>"
      namespace: kube-system
      values:
        image.pullPolicy: IfNotPresent
        ipam.mode: kubernetes
      waitTimeout: 10m
  prepare:
    hooks:
      - name: seed
        command: ["./hooks/seed.sh"]
  deploy:
    timeout: 45m
    steps:
      - name: apply-root
        apply:
          paths: ["apps/app-of-apps.yaml"]
      # also: kustomize, helm, wait, hook
  assert:
    timeout: 20m
    checks:
      - name: pods
        podsReady:
          excludeNamespaces: ["kube-system"]
          ignoreCompletedJobs: true
      # also: workloadsReady, serviceProbe, resourceCondition
      #       (name or cluster-wide list; condition and/or fields),
      #       gatewayReady, networkProbe
```

**Portability:** the CLI only understands generic `dockerCompose` deps. Suites
that need Infisical (or any other control plane) ship compose + seed hooks.

Validate a fixture without a cluster:

```bash
go run ./cmd/e2e validate -f testdata/suite.minimal.yaml
```

## Homeworld example

`examples/homeworld.suite.yaml` boots **this checkout** on kind:

1. Infisical via Compose
2. kind (Kubernetes `v1.37.0` to match PSA labels and the kind node image) with kindnet on a **single control-plane node** and `networking.kubeProxyMode: nftables` (iptables-restore hits `sendmsg EMSGSIZE` once this suite's Service count is installed, and kube-proxy then leaves stale ClusterIP DNATs after Recreate). A second kind worker doubles kubelet/containerd inotify usage. Raise `fs.inotify.max_user_instances` to 1024 on the Linux Docker VM (Lima); rootless Docker cannot write that sysctl from inside the kind node. Docker Desktop / Lima rootless cannot mount `bpffs` or idmap overlayfs, so the Cilium agent is not started and staging rewrites `hostUsers: false` to `true` and strips `runtimeClassName: gvisor` (kind nodes have no `runsc` runtime; production keeps both). The Cilium helm chart does not ship CRDs; `kind.go` and `apply-cilium-crds.sh` apply `CiliumNetworkPolicy` CRDs from the pinned Git tag. Staging Applications also get `SkipDryRunOnMissingResource=true` and `ServerSideApply=true` so directory apps that mix CRDs and CRs can sync on an empty cluster, and large CRDs/dashboard ConfigMaps do not hit the 256Ki last-applied annotation limit. Gateway `from: all` is rewritten to `All` for Gateway API v1. Staging also sets ExternalSecret `decodingStrategy: None` (Auto base64-decodes plaintext Infisical values such as `authelia`), adds `--kubelet-insecure-tls` to metrics-server (kind kubelet serving certificates carry no IP SANs for the docker-network node address), drops the Grafana PVC `metadata.name` (SSA schema), points OpenCloud web-extension copies at `/usr/share/nginx/html/apps/` (the importer extension stays on `/usr/share/nginx/html/importer/`), disables CrowdSec `store*CredentialsInSecret` so LAPI does not deadlock on register-job secrets, pads the CrowdSec registration token to 32+ characters, disables CrowdSec console enroll, removes the duplicate RustFS `tenants.rustfs.com` CRD, disables Collabora bind-mount jails (`mount_jail_tree=false`, child roots under `/tmp`), points Immich at the `photos` RWO PVC and raises server/ML limits to 4Gi, sets the DocumentDB webhook `failurePolicy: Ignore` and relaxes its probes, and disables Argo Dex/ApplicationSet/notifications plus the repo-server GPG fsnotify watcher.
3. Seed Infisical, apply ESO credentials, create a `longhorn-crypto` StorageClass on kind's local-path provisioner, raise inotify limits, apply Cilium and Envoy Gateway CRDs, and strip stuck Argo hook-finalizers
4. Copy `apps/` into `/tmp/homeworld-e2e-git`, swap the committed production coordinates kind cannot use (the `192.168.8.50` Gateway VIP for the kind node IP, the Infisical Cloud endpoint for the Compose instance; the `base-domain.invalid` placeholder stays for the homeworld plugin to fill in with `homeworld.test`), rewrite it (including nested Application `repoURL`s), and serve it with `git daemon` on `:9418`
5. Helm-install the Argo CD chart (matching `apps/argocd/helm/kustomization.yaml`) with `kustomize.buildOptions: --enable-helm`. `skipIfPresent: true` skips the upgrade when `--keep-cluster` reuses a cluster that already has the release (including `failed` / `pending-upgrade`).
6. Apply generated Applications (`e2e/examples/.generated/app-of-apps.yaml`) pointing at `git://host.docker.internal:9418/homeworld.git`
7. Wait until those Applications are `status.sync.status=Synced` and `status.health.status=Healthy`
8. Assert pods, in-scope workloads, ExternalSecrets, CNPG, Dragonfly, and the Envoy Gateway

```bash
# From repo root (after building):
/tmp/e2e validate -f e2e/examples/homeworld.suite.yaml
/tmp/e2e run -f e2e/examples/homeworld.suite.yaml
```

Host extra tools for the homeworld suite: `rsync`, `python3`, `git`, `openssl`, `jq`, `curl`.

Size the Docker VM for the single kind node: the suite's pod CPU requests add up to more than 4 CPUs (the scheduler leaves database pods Pending on a 4-CPU Lima VM), so give it at least 6 CPUs and 16 GiB, and raise `fs.inotify.max_user_instances` to 1024 as described above (`limactl shell <vm> sudo sysctl -w fs.inotify.max_user_instances=1024 fs.inotify.max_user_watches=524288`, or a `sysctl.d` drop-in to persist it).

### Local Infisical

`examples/infisical/` adapts Infisical’s `docker-compose.prod.yml`:

| Upstream | E2E adaptation |
| --- | --- |
| `infisical/infisical:latest` + `pull_policy: always` | Pinned tag (see `examples/infisical/docker-compose.yml`) |
| Host `80:8080` | `8080:8080` |
| `.env` | `.env.e2e` with local-only encryption/JWT/DB defaults |

Images are pinned (see `examples/infisical/docker-compose.yml`) — never `latest`.

### Kind → Infisical reachability

1. Infisical publishes on the host at `127.0.0.1:8080`.
2. Suite hooks set `INFISICAL_HOST=http://host.docker.internal:8080` so pods
   (External Secrets) can dial the host-mapped API.
3. **Docker Desktop / macOS:** `host.docker.internal` works out of the box.
4. **Linux:** map the host into kind nodes, for example:

   ```yaml
   # in kindConfig nodes[].extraHosts (kind v0.20+)
   extraHosts:
   - "host.docker.internal:10.0.2.2"   # or docker bridge gateway IP
   ```

   Discover the gateway: `docker network inspect bridge -f '{{(index .IPAM.Config 0).Gateway}}'`.

5. The staging hook rewrites `allow-infisical` to port **8080** and adds
   `host.docker.internal:9418` on `allow-argocd-repository-sources` so ESO and
   Argo can reach the host-mapped Infisical API and git daemon. The same
   `extraHosts` mapping is required on Linux for both. Staging also pads the
   CrowdSec `auto_registration` token to ≥32 characters, leaves the OpenCloud
   importer extension on `/usr/share/nginx/html/importer/`, drops the duplicate
   RustFS `tenants.rustfs.com` CRD, disables Collabora jails and the Argo
   repo-server GPG watcher, and disables Argo Dex/ApplicationSet/
   notifications plus scales CoreDNS to 1 replica. A deploy hook stubs
   `*.homeworld.test` in CoreDNS to the Envoy Gateway ClusterIP (the
   public wildcard record does this in production) and staging sets
   OpenCloud `COLLABORATION_*_INSECURE=true` for WOPI discovery. CrowdSec LAPI's
   start script downloads hub dest_file data (GeoLite2, CDN/crawler lists)
   that the image does not ship. Raise inotify on the Docker VM (Lima
   `sysctl.d`) to 1024 so Grafana/Victoria/Collabora/OpenCloud/
   Radicale/CrowdSec/Forgejo/Immich fit.

6. **Cilium world egress:** homeworld’s External Secrets path is an intentional
   internet exception. Prefer reusing that exception and pointing `hostAPI` at
   the host-mapped URL rather than special-casing Infisical in the Go CLI.

### First-boot sync rescues

Argo CD gives up on an application after five failed sync attempts, and self-heal never re-fires after a failed sync. A first-boot transient (for example the grafana operator pinging its instance before the pod is ready) can therefore leave an application stuck OutOfSync forever even though the underlying condition cleared minutes later. The suite's `wait-argo` step re-triggers the sync on stuck OutOfSync homeworld applications every three minutes (`resyncInterval`) to recover from those transients.

### Deploy ordering

`patch-coredns` runs before `wait-argo` on purpose: the forgejo `configure-gitea` init resolves `auth.homeworld.test` through the patched CoreDNS stub, and the wave-6 pods start while `wait-argo` polls. The envoy LoadBalancer Service it waits for comes from wave 2 plus the certificate chain (wave 3), which completes before wave 6 — the 600s deadline covers the cold-node case.

### Seed and staging hooks

| Hook | Role |
| --- | --- |
| `hooks/seed-infisical.sh` | Wait for API, bootstrap admin/org/project, UA identity, upsert every Infisical key (including the `homeworld.test` cluster domain as `/argocd/BASE_DOMAIN`) the suite's installed apps consume (fails the run if login, project, identity, or a secret upsert fails) |
| `hooks/apply-eso-credentials.sh` | Apply `universal-auth-credentials` Secret for ESO |
| `hooks/apply-argocd-domain.sh` | Seed `argocd/homeworld-domain` (`homeworld.test`) before the bootstrap Argo CD starts, as `host/bootstrap.sh` does in production |
| `hooks/apply-operator-crds.sh` | Apply prometheus-operator, cert-manager, CNPG, Grafana Operator, Dragonfly, MariaDB Operator, RustFS, OpenTelemetry Operator, and DocumentDB CRDs, plus the external-snapshotter `VolumeSnapshotClass` CRDs from the tag pinned in `apps/snapshot-controller` (snapshot-controller-app is omitted, but CNPG, MariaDB Operator, and Velero ship snapshot classes) (Argo excludes CRDs; the OTel chart ships its CRDs as rendered templates that kustomize includeCRDs never captures) |
| `hooks/apply-storageclass.sh` | Create `StorageClass/longhorn-crypto` using `rancher.io/local-path` |
| `hooks/stage-local-repo.sh` | Swap the Gateway VIP and Infisical endpoint literals for kind, replace the Let's Encrypt issuers with self-signed ones, omit kind-incompatible Applications, patch Infisical/git CNPs, write the homeworld plugin values for the bootstrap Argo CD, commit and serve `git://127.0.0.1:9418/homeworld.git` |
| `hooks/patch-coredns-e2e-domain.sh` | After Envoy exists, stub `*.homeworld.test` in CoreDNS to the Gateway ClusterIP and restart CoreDNS |

Staging copies live under `/tmp/homeworld-e2e-git`. The kubectl-applied Application list is `e2e/examples/.generated/app-of-apps.yaml` (gitignored).

### Kind-incompatible apps (omitted from e2e Applications)

| Application | Reason |
| --- | --- |
| `longhorn-app` | Longhorn needs host disks; PVCs use a local-path class of the same name instead |
| `velero-app`, `velero-ui-app` | Real Backblaze B2 |
| `homeassistant-app` | Zigbee / host devices |
| `external-dns-app` | Publishes the production wildcard record through the Cloudflare API; the CoreDNS stub resolves the e2e domain instead |
| `cilium-app` | Rootless Docker (Lima or Desktop) cannot mount bpffs, so the Cilium datapath cannot start on kind; the suite installs its own CRD-only Cilium in kube-system |
| `snapshot-controller-app` | kind's local-path provisioner has no CSI driver, so there is nothing for the snapshot controller to act on |
| `qbittorrent-app` | The gluetun VPN sidecar needs real ProtonVPN WireGuard credentials, which the suite does not have |
| `kured-app`, `system-upgrade-controller-app` | Host lifecycle: kured reads the node's reboot sentinel through the host PID namespace and reboots nodes, and the upgrade Plans replace the k3s binary; kind nodes are neither Fedora nor k3s |
| `csi-driver-nfs-app` | No NAS: the static NFS volumes (Immich, OpenCloud) are rewritten to local-path claims of the `longhorn-crypto` substitute class |
| `supernote-app` | Upstream publishes amd64-only images, and the kind node follows the host architecture (arm64 on Apple-silicon hosts) |

`otel-collector-app` is **included** in e2e: the victoria-metrics/…-logs `serviceProbe`
assertions require OTel-exported series and log lines, which only the pod
collector self-scrape and the node collector `filelog` receiver produce.

Argo CD renders through the production homeworld plugin with the reserved `homeworld.test` domain. Kind cannot answer Let's Encrypt DNS-01 challenges, so self-signed `letsencrypt-prod`/`letsencrypt-staging` issuers stand in, and no workload trusts the resulting certificate: in-cluster HTTPS calls to the domain (OIDC discovery and token calls, WOPI, webhooks) fail with x509 errors. Coder and Actual Budget, which gate startup on Authelia's OIDC discovery, are excluded from the readiness checks. The public wildcard record is replaced by the CoreDNS stub; HTTP coverage targets ClusterIP services through in-cluster probes (including Collabora's WOPI discovery endpoint) rather than the public Gateway, and no OIDC login flow is exercised.

### Out of scope

- Longhorn, B2, Zigbee, Cilium L2 announcements of the Gateway VIP
- Browser / OIDC / Collabora WOPI flows
- Embedding Infisical control-plane logic in Go
- Full kind e2e on GitHub Actions (CI runs `go test` and `e2e validate` only)

## Using from another repo

Point `-f` at any suite YAML. Optional Compose deps and hooks travel with the
suite. The module path is `github.com/gjpin/homeworld/e2e` and can be extracted
later without changing the portable contract.

## Tests

```bash
cd e2e
go test ./...
python3 testdata/rewrite/rewrite_test.py
go build -o /tmp/e2e ./cmd/e2e
go run ./cmd/e2e validate -f testdata/suite.minimal.yaml
go run ./cmd/e2e validate -f examples/homeworld.suite.yaml
```
