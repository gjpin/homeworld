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
      chartVersion: "1.17.2"
      namespace: kube-system
      values:
        image.pullPolicy: IfNotPresent
        ipam.mode: kubernetes
      waitTimeout: 10m
  prepare:
    nodeLabels:
      - node-role.kubernetes.io/homelab=homelab
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
2. kind (Kubernetes `v1.36.1` to match PSA labels and kind 0.32's node image) with kindnet on a **single control-plane node** and `networking.kubeProxyMode: nftables` (iptables-restore hits `sendmsg EMSGSIZE` once this suite's Service count is installed, and kube-proxy then leaves stale ClusterIP DNATs after Recreate). A second kind worker doubles kubelet/containerd inotify usage. Raise `fs.inotify.max_user_instances` to 1024 on the Linux Docker VM (Lima); rootless Docker cannot write that sysctl from inside the kind node. Docker Desktop / Lima rootless cannot mount `bpffs` or idmap overlayfs, so the Cilium agent is not started and staging rewrites `hostUsers: false` to `true` and strips `runtimeClassName: gvisor` (kind nodes have no `runsc` runtime; production keeps both). The Cilium 1.17 helm chart does not ship CRDs; `kind.go` and `apply-cilium-crds.sh` apply `CiliumNetworkPolicy` CRDs from the pinned Git tag. Staging Applications also get `SkipDryRunOnMissingResource=true` and `ServerSideApply=true` so directory apps that mix CRDs and CRs can sync on an empty cluster, and large CRDs/dashboard ConfigMaps do not hit the 256Ki last-applied annotation limit. Gateway `from: all` is rewritten to `All` for Gateway API v1. Staging also sets ExternalSecret `decodingStrategy: None` (Auto base64-decodes plaintext Infisical values such as `authelia`), flips Dragonfly `runAsNonRoot` (image USER is root), drops invalid StatefulSet `spec.strategy` and Grafana PVC `metadata.name` (SSA schema), points OpenCloud web-extension 2.x copies at `/usr/share/nginx/html/apps/` (importer-1.0.0 stays on `/usr/share/nginx/html/importer/`), disables CrowdSec `store*CredentialsInSecret` so LAPI does not deadlock on register-job secrets, pads the CrowdSec registration token to 32+ characters, disables CrowdSec console enroll, removes the duplicate RustFS `tenants.rustfs.com` CRD, disables Collabora bind-mount jails (`mount_jail_tree=false`, child roots under `/tmp`), points Immich at the `photos` RWO PVC and raises server/ML limits to 4Gi, sets the DocumentDB webhook `failurePolicy: Ignore` and relaxes its probes, shrinks the OpenChamber PVC to 10Gi and relaxes its resources, and disables Argo Dex/ApplicationSet/notifications plus the repo-server GPG fsnotify watcher.
3. Seed Infisical, apply ESO credentials, create a `longhorn-crypto` StorageClass on kind's local-path provisioner, raise inotify limits, apply Cilium and Envoy Gateway CRDs, and strip stuck Argo hook-finalizers
4. Envsubst + rewrite `apps/` (including nested Application `repoURL`s) into `/tmp/homeworld-e2e-git`, serve it with `git daemon` on `:9418`
5. Helm-install Argo CD chart **9.5.9** with `kustomize.buildOptions: --enable-helm`. `skipIfPresent: true` skips the upgrade when `--keep-cluster` reuses a cluster that already has the release (including `failed` / `pending-upgrade`).
6. Apply generated Applications (`e2e/examples/.generated/app-of-apps.yaml`) pointing at `git://host.docker.internal:9418/homeworld.git`
7. Wait until those Applications are `status.sync.status=Synced` and `status.health.status=Healthy`
8. Assert pods, in-scope workloads, ExternalSecrets, CNPG, Dragonfly, and the Envoy Gateway

```bash
# From repo root (after building):
/tmp/e2e validate -f e2e/examples/homeworld.suite.yaml
/tmp/e2e run -f e2e/examples/homeworld.suite.yaml
```

Host extra tools for the homeworld suite: `rsync`, `envsubst` (gettext), `python3`, `git`, `openssl`, `jq`, `curl`.

### Local Infisical

`examples/infisical/` adapts Infisical’s `docker-compose.prod.yml`:

| Upstream | E2E adaptation |
| --- | --- |
| `infisical/infisical:latest` + `pull_policy: always` | Pin `v0.162.12` |
| Host `80:8080` | `8080:8080` |
| `.env` | `.env.e2e` with local-only encryption/JWT/DB defaults |

Images are pinned (`postgres:14.17-alpine`, `redis:7.4.2-alpine`) — never `latest`.

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
   CrowdSec `auto_registration` token to ≥32 characters, leaves OpenCloud
   `importer-1.0.0` on `/usr/share/nginx/html/importer/`, drops the duplicate
   RustFS `tenants.rustfs.com` CRD, disables Collabora jails and the Argo
   repo-server GPG watcher, and disables Argo Dex/ApplicationSet/
   notifications plus scales CoreDNS to 1 replica. A deploy hook stubs
   `*.e2e.local` in CoreDNS to the Envoy Gateway ClusterIP (there is no
   external-dns) and staging sets OpenCloud `COLLABORATION_*_INSECURE=true`
   so WOPI discovery accepts the self-signed Gateway cert. CrowdSec LAPI's
   start script downloads hub dest_file data (GeoLite2, CDN/crawler lists)
   that the image does not ship. Raise inotify on the Docker VM (Lima
   `sysctl.d`) to 1024 so Grafana/Victoria/Collabora/OpenCloud/
   Radicale/CrowdSec/Forgejo/Immich fit.

6. **Cilium world egress:** homeworld’s External Secrets path is an intentional
   internet exception. Prefer reusing that exception and pointing `hostAPI` at
   the host-mapped URL rather than special-casing Infisical in the Go CLI.

### Seed and staging hooks

| Hook | Role |
| --- | --- |
| `hooks/seed-infisical.sh` | Wait for API, bootstrap admin/org/project, UA identity, upsert every ExternalSecret key (fails the run if login, project, identity, or a secret upsert fails) |
| `hooks/apply-eso-credentials.sh` | Apply `universal-auth-credentials` Secret for ESO |
| `hooks/apply-operator-crds.sh` | Apply prometheus-operator, cert-manager, CNPG, Grafana Operator, Dragonfly, and RustFS CRDs (Argo excludes CRDs) |
| `hooks/apply-storageclass.sh` | Create `StorageClass/longhorn-crypto` using `rancher.io/local-path` |
| `hooks/stage-local-repo.sh` | Envsubst tracked placeholders, omit kind-incompatible Applications, patch Infisical/git CNPs, replace ClusterIssuers with self-signed, commit and serve `git://127.0.0.1:9418/homeworld.git` |
| `hooks/patch-coredns-e2e-domain.sh` | After Envoy exists, stub `*.e2e.local` in CoreDNS to the Gateway ClusterIP and restart CoreDNS |

Staging copies live under `/tmp/homeworld-e2e-git`. The kubectl-applied Application list is `e2e/examples/.generated/app-of-apps.yaml` (gitignored).

### Kind-incompatible apps (omitted from e2e Applications)

| Application | Reason |
| --- | --- |
| `longhorn-app` | Longhorn needs host disks; PVCs use a local-path class of the same name instead |
| `velero-app`, `velero-ui-app` | Real Backblaze B2 |
| `homeassistant-app` | Zigbee / host devices |
| `external-dns-app` | Cloudflare API |
| `openchamber-app` | Workspace image `ghcr.io/gjpin/openchamber` is private; kind cannot pull it without credentials |

`otel-collector-app` is **included** in e2e: the victoria-metrics/…-logs `serviceProbe`
assertions require OTel-exported series and log lines, which only the pod
collector self-scrape and the node collector `filelog` receiver produce.

TLS uses self-signed ClusterIssuers still named `letsencrypt-prod` / `letsencrypt-staging` so Gateway annotations keep working. There is no public DNS and no HTTP login/WOPI coverage.

### Out of scope

- Longhorn, Cloudflare ACME, B2, Zigbee
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
