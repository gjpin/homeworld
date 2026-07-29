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
      # also: workloadsReady, serviceProbe, resourceCondition,
      #       gatewayReady, networkProbe
```

**Portability:** the CLI only understands generic `dockerCompose` deps. Suites
that need Infisical (or any other control plane) ship compose + seed hooks.

Validate a fixture without a cluster:

```bash
go run ./cmd/e2e validate -f testdata/suite.minimal.yaml
```

## Homeworld example

```bash
# From repo root (after building):
/tmp/e2e validate -f e2e/examples/homeworld.suite.yaml
/tmp/e2e run -f e2e/examples/homeworld.suite.yaml
```

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

5. **Cilium world egress:** homeworld’s External Secrets path is an intentional
   internet exception. Prefer reusing that exception and pointing `hostAPI` at
   the host-mapped URL rather than special-casing Infisical in the Go CLI.

### Seed hooks

| Hook | Role |
| --- | --- |
| `hooks/seed-infisical.sh` | Wait for API, bootstrap admin/org/project, UA identity, placeholder secrets |
| `hooks/apply-eso-credentials.sh` | Apply `universal-auth-credentials` Secret for ESO |

Infisical first-run APIs vary by version; the seed hook is best-effort and may
fall back to placeholders. Prefer pinning Infisical CLI **0.41.90** (or newer
compatible) if you automate bootstrap via CLI instead of curl.

### Out of scope (v1)

- Longhorn on kind (omit or substitute in asserts)
- Real Cloudflare ACME / B2 / Zigbee
- Embedding Infisical control-plane logic in Go
- GitHub Actions wiring

## Using from another repo

Point `-f` at any suite YAML. Optional Compose deps and hooks travel with the
suite. The module path is `github.com/gjpin/homeworld/e2e` and can be extracted
later without changing the portable contract.

## Tests

```bash
cd e2e
go test ./...
go build -o /tmp/e2e ./cmd/e2e
go run ./cmd/e2e validate -f testdata/suite.minimal.yaml
```
