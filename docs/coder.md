# Coder

[Coder](https://coder.com/docs) runs cloud development workspaces as Pods in
the cluster and, with Coder Agents, AI coding agents whose agent loop runs in
the control plane. The deployment uses the official Helm chart
(`apps/coder/helm/`) and the Community license.

| Piece | Where |
| --- | --- |
| Control plane (`coderd`: dashboard, API, built-in Terraform provisioners, embedded DERP relay, Coder Agents) | `coder` namespace, `apps/coder/` |
| Database | CloudNativePG `Cluster` `coder` (`apps/coder/0_postgres.yaml`) |
| Workspaces | `coder-workspaces` namespace, `apps/coder/workspaces/` (network policies, LimitRange), created by the wave-0 `coder-workspaces` Application |
| Workspace template | `apps/coder/template/` (pushed by hand, see [below](#workspace-template)) |

`https://coder.homeworld.internal` serves the dashboard, the API, and the
agents' WebSockets. Workspace apps (code-server, forwarded ports) get their
own origins under `*.coder.homeworld.internal` (`CODER_WILDCARD_ACCESS_URL`).

## Sign-in

Authelia is the only sign-in method ([oidc.md](oidc.md)). The `coder`
authorization policy admits members of `coder-user` only. Coder's group and
role sync is a Premium feature, so groups only gate access. The first user to
sign in becomes the deployment **Owner**, and later users join as members.
Roles are assigned under **Admin settings → Users**.

Password sign-in is disabled. Coder still accepts an Owner's password so the
deployment cannot be locked out. A lost Owner account is recovered directly
in the database:

```bash
kubectl -n coder exec -it deploy/coder -- /opt/coder server create-admin-user
```

Sessions renew through Authelia refresh tokens (`offline_access`). After
changing OIDC scopes, every user has to sign out and back in once to store a
refresh token.

## Workspace template

Templates live in Coder's database. Argo CD does not manage them. The
repository template is a general-purpose Ubuntu workspace with code-server
and a persistent home volume (Longhorn `longhorn-crypto`). One template serves
every language: toolchains come from mise per project ([below](#toolchains)). Its pod spec meets
the `coder-workspaces` namespace rules: Restricted security context, gVisor,
UID/GID `1000`, resources from workspace parameters, and the Homeworld CA in
the trust bundle for curl, git, OpenSSL, Go, and Node.js. Push it from a
machine that trusts the Homeworld CA (README step 9):

```bash
coder login https://coder.homeworld.internal
coder templates push kubernetes -d apps/coder/template --yes
coder templates edit kubernetes \
  --display-name "Kubernetes (homeworld)" \
  --description "General-purpose development workspace for any language: per-project toolchains via mise, git, and code-server; persistent home directory."
```

Push again after changing `apps/coder/template/` (Renovate bumps the
providers with their `.terraform.lock.hcl` hashes, the code-server module,
the base image, and mise with its binary hash there). The lockfile covers `linux_amd64` and
`linux_arm64`, the platforms coderd can be scheduled on, so the provisioners
cache providers instead of downloading them on every build. Workspace Pods
are pinned to amd64 nodes to match the agent binary. Pushing creates a new
template version, and running workspaces pick it up when they are updated or
restarted.

Templates of your own must satisfy the same constraints. The namespace
enforces the Restricted Pod Security Standard, so a template that needs root,
`sudo`, or Docker-in-Docker is rejected at admission. gVisor
(`runtime_class_name = "gvisor"`) is a template convention, not an
admission rule. The coder service account can create only Pods, PVCs, and
Deployments, and only in `coder-workspaces`.

### Toolchains

The image carries only the OS layer: git, `build-essential`, curl, jq,
Python 3, and pipx. Language runtimes come from [mise](https://mise.jdx.dev),
which the template's `mise` startup script installs as a checksum-verified,
pinned binary in `~/.local/bin`. Toolchains install under
`~/.local/share/mise` on the home volume, so they survive restarts and need
no root.

Each repository declares its versions in `mise.toml` or `.tool-versions`:

```toml
[tools]
node = "lts"
go = "latest"
python = "3"
```

Run `mise install` once in the repository (or `mise use node@lts` to add a
tool and write the file). mise's shims directory is on the container `PATH`,
so every process resolves the versions of its working directory: terminals,
code-server extensions (the `hverlin.mise-vscode` extension points the Go,
Python, and ESLint extensions at them), and Coder Agents tool calls.
Interactive bash shells also run `mise activate`, which loads a project's
`[env]` section. Defaults for directories without a config go in
`~/.config/mise/config.toml` (`mise use --global node@lts`); the startup
script installs them on every start.

code-server installs the Go, Python, ESLint, Prettier, and mise extensions
from Open VSX and keeps them updated. Add more in the code-server module's
`extensions` list.

## Networking

Workspaces accept no inbound connections. The workspace agent dials
`coder.homeworld.internal`, and every session rides back over that
connection through the embedded DERP relay: the web terminal, SSH,
IDEs, workspace apps, and Coder Agents tool calls. STUN is disabled (the
default servers are Google's) and direct connections are blocked, because
pod IPs are unreachable from client devices anyway.

Workspaces may reach Forgejo and the internet on ports 22, 80, and 443.
coderd reaches Authelia, the Terraform and Coder registries (provider and
module downloads during template imports and builds), and the Coder Agents
LLM providers. [network-policies.md](network-policies.md) lists the exact
destinations.

## Coder Agents

Coder Agents runs the agent loop inside coderd: prompts go from the control
plane to the LLM provider, and tool calls reach the workspace over the same
tunnel the IDE uses. Workspaces hold no API keys and need no agent software.
The Community license runs up to five agents at once; further chats queue.

1. Under **Admin settings → AI → Providers**, add a provider and its API
   key. coderd's egress allows `api.anthropic.com` and `api.openai.com`; any
   other provider or base URL also needs an `allow-coder-llm-providers`
   entry in `apps/coder/-2_network_policy.yaml`.
2. Under **Admin settings → AI → Models**, add at least one model.
3. Open **Agents** in the dashboard. The agent picks a template by its name,
   description, and README, so keep the repository template's description
   accurate.

Terminal agents such as Claude Code or Codex can instead be installed into a
template from a [registry module](https://registry.coder.com). They then run
inside the workspace with their own credentials, which workspace egress
already permits.

## Disabled phone-home

| Setting | Effect |
| --- | --- |
| `CODER_TELEMETRY_ENABLE=false` | No deployment telemetry to Coder |
| `CODER_UPDATE_CHECK=false` | No release check |
| `CODER_OAUTH2_GITHUB_DEFAULT_PROVIDER_ENABLE=false`, `CODER_EXTERNAL_AUTH_GITHUB_DEFAULT_PROVIDER_ENABLE=false` | No Coder-managed GitHub login or external-auth app |
| `CODER_DERP_SERVER_STUN_ADDRESSES=disable` | No STUN requests to Google |
| code-server `--disable-telemetry --disable-update-check` | Set in the repository template |
| code-server machine setting `telemetry.telemetryLevel: off` | No extension telemetry (extension updates stay on) |
| `MISE_USE_VERSIONS_HOST_TRACK=false` | No install statistics to mise-versions |
| `MISE_DISABLE_UPDATE_WARNING=true` | No mise release check |

## Observability

coderd serves Prometheus metrics on port `2112`
(`CODER_PROMETHEUS_ENABLE`, including per-agent stats), scraped every 60s by
the `coder` PodMonitor. The upstream dashboards are in the Grafana **Coder**
folder ([grafana-dashboards.md](grafana-dashboards.md)). Logs go to stderr in
Coder's human-readable format and reach VictoriaLogs through the OTel node
collector. The dashboards' log panels query them by `k8s.namespace.name`.
