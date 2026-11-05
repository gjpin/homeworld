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
| Workspace image | `apps/coder/image/`, built by `.github/workflows/coder-workspace-image.yaml` into `ghcr.io/gjpin/homeworld/coder-workspace` (see [below](#workspace-image)) |

`https://coder.base-domain.invalid` serves the dashboard, the API, and the
agents' WebSockets. Workspace apps (code-server, forwarded ports) get their
own origins under `*.coder.base-domain.invalid` (`CODER_WILDCARD_ACCESS_URL`).

## Sign-in

Authelia is the only sign-in method ([oidc.md](oidc.md)). The `coder`
authorization policy admits members of `coder-user` only. Coder's group and
role sync is a Premium feature, so groups only gate access. The first user to
sign in becomes the deployment **Owner**, and later users join as members.
Roles are assigned under **Admin settings → Users**.

Password sign-in and resets are disabled for every user, Owners included. If
no Owner can sign in through Authelia, set `CODER_DISABLE_PASSWORD_AUTH` to
`false` in `apps/coder/helm/values.yaml` and let the Pod restart, create an
admin in the database, sign in with its password, and then restore the
setting:

```bash
kubectl -n coder exec -it deploy/coder -- /opt/coder server create-admin-user
```

Sessions renew through Authelia refresh tokens (`offline_access`). After
changing OIDC scopes, every user has to sign out and back in once to store a
refresh token.

## Workspace template

Templates live in Coder's database. Argo CD does not manage them. The
repository template is a general-purpose workspace with code-server and a
persistent home volume (Longhorn `longhorn-crypto`), running the homeworld
workspace image ([below](#workspace-image)), which carries the agents VM's
toolset. One template serves every language. Its pod spec meets
the `coder-workspaces` namespace rules: Restricted security context, gVisor,
UID/GID `1000`, and resources from workspace parameters. Push it with the
Coder CLI:

```bash
coder login https://coder.base-domain.invalid
coder templates push kubernetes -d apps/coder/template --yes
coder templates edit kubernetes \
  --display-name "Kubernetes (homeworld)" \
  --description "General-purpose development workspace for any language: Node.js, Go, Python, Rust, Java, and C/C++ toolchains, Kubernetes and infrastructure CLIs, coding-agent CLIs, Playwright, per-project versions via mise, and code-server; persistent home directory."
```

Push again after changing `apps/coder/template/` (Renovate bumps the
providers with their `.terraform.lock.hcl` hashes, the code-server module,
and the workspace image tag there). The lockfile covers `linux_amd64` and
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

### Workspace image

`apps/coder/image/Dockerfile` builds the agents VM's toolset
([openchamber.md](openchamber.md)) on Debian:

- **apt**: the C/C++ toolchain (gcc, clang, llvm, lld, lldb, clangd, gdb,
  valgrind), Python 3 with headers,
  pip, pipx, and venv, autotools, cmake, meson, ninja, mold, ccache, just,
  git and git-lfs, skopeo, and the VM's shell utilities (ripgrep, fzf, jq,
  shellcheck, tmux, direnv, sqlite3, and more), with man pages.
- **rustup**: the pinned stable Rust toolchain with rustfmt, clippy,
  rust-analyzer, and rust-src, under a read-only `RUSTUP_HOME`
  (`/usr/local/share/rustup`). `CARGO_HOME` is `~/.cargo` on the home volume
  (registry cache, `cargo install`). A project that needs another toolchain
  (`rust-toolchain.toml`) sets `RUSTUP_HOME = "{{env.HOME}}/.rustup"` in its
  mise `[env]` and runs `rustup toolchain install`.
- **mise** (`apps/coder/image/mise.toml`): Node.js, pnpm, Go and gopls,
  Java (Temurin), uv, fd, bat, yq, tree-sitter, shfmt, gh, glab, kubectl,
  helm, kustomize, terraform, opentofu, infisical, the coding agents (Claude
  Code, Codex, OpenCode, Copilot CLI, Pi, Antigravity), and Playwright with
  its CLI, Chromium, chrome-devtools-mcp, and skills. They install with
  `mise install --system` into `/usr/local/share/mise` and are selected by
  `/etc/mise/config.toml`, the lowest-precedence config.

The VM tools that cannot run in a Restricted gVisor Pod are left out: Podman,
Buildah, kind, strace, perf, tcpdump, and traceroute. OpenChamber and Paseo
have no role next to Coder.

`.github/workflows/coder-workspace-image.yaml` builds `linux/amd64` on
changes to `apps/coder/image/` and weekly (Debian security updates), and
pushes `ghcr.io/gjpin/homeworld/coder-workspace:<UTC date>.<run number>`.
Pull requests build without pushing. The package is public, so nodes pull it
without credentials; after its first push, set **Package settings → Change
visibility → Public** on GitHub once. Renovate groups the image inputs
(Debian base, mise and rustup with their binary hashes, the Rust toolchain,
every `mise.toml` pin) into one
`coder-workspace-image` PR, then bumps the new tag in the template; push the
template after merging that bump.

Everything in the image is root-owned and read-only to the workspace user,
so no tool updates itself. The image switches off the same telemetry and
update checks as the agents VM (Claude Code `DISABLE_TELEMETRY`,
`DISABLE_ERROR_REPORTING` and `DISABLE_UPDATES`, `PI_SKIP_VERSION_CHECK`) and chrome-devtools-mcp's usage
statistics and update check (`CHROME_DEVTOOLS_MCP_NO_USAGE_STATISTICS`,
`CHROME_DEVTOOLS_MCP_NO_UPDATE_CHECKS`), glab's usage data and release
check (`GLAB_SEND_TELEMETRY`, `GLAB_CHECK_UPDATE`, which also gates its
remote skill-update check), and the Infisical CLI's telemetry and release
check (`INFISICAL_DISABLE_TELEMETRY`, `INFISICAL_DISABLE_UPDATE_CHECK`),
the Playwright CLI's npm release check (`NO_UPDATE_NOTIFIER`), and the template's startup
script, `homeworld-workspace-init`, sets the file-based ones in the home
volume on every start: Codex `check_for_update_on_startup` and analytics and
feedback, OpenCode `autoupdate` and sharing, Pi install telemetry,
Antigravity telemetry and feedback survey, and Copilot `autoUpdate`. It also copies the skeleton dotfiles on first start
and seeds the Playwright agent skills. Agent permission and approval
settings are left at each CLI's defaults.

### Toolchains

The image's mise versions apply wherever a project sets none. A repository
pins its own in `mise.toml` or `.tool-versions`:

```toml
[tools]
node = "lts"
go = "latest"
python = "3"
```

Run `mise install` once in the repository (or `mise use node@lts` to add a
tool and write the file). Versions the image lacks install under
`~/.local/share/mise` on the home volume, so they survive restarts and need
no root. mise's shim directories (the user's ahead of the image's) are on the
container `PATH`, so every process resolves the versions of its working
directory: terminals, code-server extensions (the `hverlin.mise-vscode`
extension points the Go, Python, and ESLint extensions at them), and Coder
Agents tool calls. Interactive bash shells also run `mise activate`, which
loads a project's `[env]` section. Personal defaults go in
`~/.config/mise/config.toml` (`mise use --global <tool>@<version>`); the
startup script installs them on every start. `npm install -g` and `pipx`
install into `~/.local`.

code-server installs the Go, Python, ESLint, Prettier, and mise extensions
from Open VSX and keeps them updated. Add more in the code-server module's
`extensions` list.

## Networking

Workspaces accept no inbound connections. The workspace agent dials
`coder.base-domain.invalid`, and every session rides back over that
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
| Coding-agent switches in the image and `homeworld-workspace-init` | No agent telemetry or self-updates ([above](#workspace-image)) |
| `GLAB_SEND_TELEMETRY=false`, `GLAB_CHECK_UPDATE=false` | No glab usage data to the GitLab instance, no glab release or skill-update check |
| `INFISICAL_DISABLE_TELEMETRY=1`, `INFISICAL_DISABLE_UPDATE_CHECK=true` | No Infisical CLI telemetry to PostHog, no release check |
| `NO_UPDATE_NOTIFIER=1` | No Playwright CLI release check against the npm registry |

## Observability

coderd serves Prometheus metrics on port `2112`
(`CODER_PROMETHEUS_ENABLE`, including per-agent stats), scraped every 60s by
the `coder` PodMonitor. The upstream dashboards are in the Grafana **Coder**
folder ([grafana-dashboards.md](grafana-dashboards.md)). Logs go to stderr in
Coder's human-readable format and reach VictoriaLogs through the OTel node
collector. The dashboards' log panels query them by `k8s.namespace.name`.
