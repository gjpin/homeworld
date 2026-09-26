# OpenChamber

Persistent AI agent workspace: a single non-root, gVisor-sandboxed pod that runs the [OpenChamber](https://github.com/openchamber/openchamber) web server and a pinned toolchain of coding agents ([OpenCode](https://opencode.ai), Codex CLI, the Pi agent, [Grok Build](https://x.ai/cli), [Antigravity CLI](https://antigravity.google/product/antigravity-cli/), and [GitHub Copilot CLI](https://github.com/features/copilot/cli)) on Debian 13, with a PVC-backed home directory so sessions, worktrees, and credentials survive pod restarts.

## Overview

| | |
| :--- | :--- |
| Component | `apps/openchamber` |
| Image | `ghcr.io/gjpin/openchamber:main-<shortsha>`, built from [`images/openchamber/Dockerfile`](../images/openchamber/Dockerfile) |
| Domain | `openchamber.${BASE_DOMAIN}` |
| Data | `openchamber-agent-home` PVC (100Gi, Longhorn) mounted at `/home/agent` |

The pod runs `openchamber serve --foreground` as the non-root `agent` user (UID 1000) under gVisor (`runtimeClassName: gvisor`) with user namespaces (`hostUsers: false`). OpenChamber manages its own OpenCode server on loopback inside the pod and drives coding-agent sessions in projects under `/home/agent`. An entrypoint script seeds a fresh PVC from an image-staged skills skeleton and re-applies the managed no-approval agent configuration idempotently on every boot, preserving agent-created settings.

Full trixie package baseline, third-party apt repositories (Buildkite helm, OpenTofu, HashiCorp, Adoptium Temurin 25, Google Chrome), pnpm, uv, and Google Chrome, plus Playwright Chromium browsers and skills. Grok Build, Antigravity CLI, and Copilot CLI ship as pinned standalone binaries in `/usr/local/bin` (not writable by the agent user, so in-place self-update is inert by design, matching the OpenChamber treatment).

## Access

The web UI is reachable only over WireGuard at `openchamber.${BASE_DOMAIN}` through Envoy Gateway (TLS via cert-manager, protected by the CrowdSec Envoy bouncer). Authentication is OpenChamber's own `OPENCHAMBER_UI_PASSWORD`; there is no OIDC (see [oidc.md](oidc.md)). Desktop and mobile apps pair directly against the same URL via QR-code pairing — no tunnels required.

### Relay decision: not deployed

[openchamber-relay](https://github.com/openchamber/openchamber-relay) is **not** hosted in the cluster. The relay is a stateless broker for *indirect* connections: it exists so devices that cannot reach an OpenChamber instance directly (NAT, no open ports) can connect by dialing outbound to it. Since every device reaches `openchamber.${BASE_DOMAIN}` directly over WireGuard, the relay would add nothing, and hosting it would require a public `wss://` route that contradicts the WireGuard-only access model. Revisit only if agents should ever be reachable from devices that are not on the VPN.

## Updates: grouped PRs with a build-gated automerge

The running pod never updates itself; every change to the workspace arrives as a PR. PRs are merged automatically once a PR-side build of the image succeeds, so the published image always contains every pending update — the grouped binary updates and the apt refreshes land together with the next build. Session state, worktrees, and credentials persist on the PVC across restarts.

**Pinned tool versions** — Renovate's daily run groups every workspace-image update (the base image digest, Node.js, pnpm, uv, **OpenChamber itself**, OpenCode, Codex CLI, the Pi agent, Grok Build, the Antigravity CLI, the Copilot CLI, the Playwright packages, chrome-devtools-mcp, and the skills CLI, majors included) into a single `openchamber-workspace-image` PR via the `customManagers` and group rule in `renovate.json`.

- OpenChamber, for example, is pinned as `ARG OPENCHAMBER_VERSION=2.0.2` in the Dockerfile and installed as `@openchamber/web@2.0.2`. When [openchamber/openchamber](https://github.com/openchamber/openchamber/releases) publishes a new release, the grouped PR picks up the bumped `ARG`. In-app self-update is inert by design (`/usr/local` is not writable by the agent user, and updates only ever come from image rebuilds).

**Debian packages and Google Chrome** — Renovate cannot see apt repositories, so the daily [package refresh check](../.github/workflows/check-openchamber-apt-updates.yaml) runs `apt-get --simulate full-upgrade` inside the published image and opens a PR bumping `APT_REFRESH` whenever packages are outdated.

**Build-gated automerge** — GitHub's native auto-merge is unavailable for private repositories, so the [automerge workflow](../.github/workflows/automerge-openchamber.yaml) merges these PRs itself: whenever a PR's checks finish, it merges the PR if it was opened by the Renovate app, only touches `images/openchamber/Dockerfile`, is mergeable, and every check is green. The [PR smoke build](../.github/workflows/smoke-openchamber.yaml) is what makes unattended merges safe — it builds the image for `linux/amd64` without pushing, so a broken release fails its checks and the PR stays open for manual recovery.

**Image builds** — merging a PR that touches `images/openchamber/**` triggers the [build workflow](../.github/workflows/build-openchamber.yaml), which builds `linux/amd64` and `linux/arm64` on native runners, pushes `ghcr.io/gjpin/openchamber:main-<shortsha>`, and commits the new tag into `apps/openchamber/1_deployment.yaml`. Argo CD then rolls the agent pod.

## Bootstrap

1. Add the three `/openchamber/*` Infisical secrets (see [secrets.md](secrets.md)).
2. On first deployment the manifest references the `main-bootstrap` placeholder tag, so the pod reports `ImagePullBackOff` until the first build finishes and commits a real tag. This is expected.
3. After the first build, make the `gjpin/openchamber` GHCR package public so the cluster can pull it without credentials.
4. Argo CD rolls the pod once the build workflow commits the real image tag.

## Agent credentials

Provider credentials come from two places:

- **Infisical** — `OPENAI_API_KEY` (Codex CLI and OpenCode) and `GITHUB_TOKEN` (git operations) are injected as environment variables from the `openchamber-credentials` secret. Add further provider keys the same way by extending the ExternalSecret and the Infisical paths in [secrets.md](secrets.md).
- **Interactive logins** — `kubectl exec` into the pod and run `opencode auth login`, `codex login`, `/login` inside a Pi session, `grok login --device-auth` (device-code flow; works with a SuperGrok subscription), `agy` (prints an auth URL + code on first launch), or `copilot login` (device-code flow); the artifacts persist under `/home/agent` on the PVC and survive restarts and updates. Copilot CLI prefers `COPILOT_GITHUB_TOKEN`/`GH_TOKEN`/`GITHUB_TOKEN` env vars over its stored login, so the injected `GITHUB_TOKEN` must carry the Copilot Requests permission or it shadows `copilot login`.

## Telemetry and self-update policy

Self-update is disabled for every agent (OpenCode `autoupdate: false`, Copilot `autoUpdate: false`, Grok `cli.auto_update = false`) and inert by design (`/usr/local` is not writable by the agent user; updates only ever come from image rebuilds). Telemetry is disabled where the vendor supports it (Grok `features.telemetry = false` + `telemetry.trace_upload = false`, Antigravity `enableTelemetry = false`).

Exception: Copilot CLI has no documented telemetry off-switch short of `COPILOT_OFFLINE=true`, which also disables GitHub auth and GitHub-hosted features and is therefore not used. Its GitHub-side telemetry is an accepted upstream limitation.