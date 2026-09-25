# OpenChamber

Persistent AI agent workspace: a single non-root, gVisor-sandboxed pod that runs the [OpenChamber](https://github.com/openchamber/openchamber) web server and a pinned toolchain of coding agents ([OpenCode](https://opencode.ai), Codex CLI, and the Pi agent) on Debian 13, with a PVC-backed home directory so sessions, worktrees, and credentials survive pod restarts.

## Overview

| | |
| :--- | :--- |
| Component | `apps/openchamber` |
| Image | `ghcr.io/gjpin/openchamber:main-<shortsha>`, built from [`images/openchamber/Dockerfile`](../images/openchamber/Dockerfile) |
| Domain | `openchamber.${BASE_DOMAIN}` |
| Data | `openchamber-agent-home` PVC (100Gi, Longhorn) mounted at `/home/agent` |

The pod runs `openchamber serve --foreground` as the non-root `agent` user (UID 1000) under gVisor (`runtimeClassName: gvisor`) with user namespaces (`hostUsers: false`). OpenChamber manages its own OpenCode server on loopback inside the pod and drives coding-agent sessions in projects under `/home/agent`. An entrypoint script seeds a fresh PVC from an image-staged skills skeleton and re-applies the managed no-approval agent configuration idempotently on every boot, preserving agent-created settings.

The image replicates the Debian provisioning of [gjpin/agent-os](https://github.com/gjpin/agent-os): the full trixie package baseline, third-party apt repositories (Buildkite helm, OpenTofu, HashiCorp, Adoptium Temurin 25, Google Chrome), pnpm, uv, and Google Chrome, plus Playwright Chromium browsers and skills.

## Access

The web UI is reachable only over WireGuard at `openchamber.${BASE_DOMAIN}` through Envoy Gateway (TLS via cert-manager, protected by the CrowdSec Envoy bouncer). Authentication is OpenChamber's own `OPENCHAMBER_UI_PASSWORD`; there is no OIDC (see [oidc.md](oidc.md)). Desktop and mobile apps pair directly against the same URL via QR-code pairing — no tunnels required.

### Relay decision: not deployed

[openchamber-relay](https://github.com/openchamber/openchamber-relay) is **not** hosted in the cluster. The relay is a stateless broker for *indirect* connections: it exists so devices that cannot reach an OpenChamber instance directly (NAT, no open ports) can connect by dialing outbound to it. Since every device reaches `openchamber.${BASE_DOMAIN}` directly over WireGuard, the relay would add nothing, and hosting it would require a public `wss://` route that contradicts the WireGuard-only access model. Revisit only if agents should ever be reachable from devices that are not on the VPN.

## Updates: everything is PR-gated

The running pod never updates itself; every change to the workspace arrives as a PR you approve. Merging a PR rebuilds the image and rolls the pod at a moment you choose — merge when the agents are idle. Session state, worktrees, and credentials persist on the PVC across restarts.

**Pinned tool versions** — Renovate opens one PR per updated dependency (daily run) via `customManagers` in `renovate.json`, covering the base image digest, Node.js 26, pnpm, uv, **OpenChamber itself**, OpenCode, Codex CLI, the Pi agent, the Playwright packages, chrome-devtools-mcp, and the skills CLI.

- OpenChamber, for example, is pinned as `ARG OPENCHAMBER_VERSION=2.0.1` in the Dockerfile and installed as `@openchamber/web@2.0.1`. When [openchamber/openchamber](https://github.com/openchamber/openchamber/releases) publishes a new release, Renovate opens a PR bumping the `ARG`; merging rebuilds the image with the new version. In-app self-update is inert by design (`/usr/local` is not writable by the agent user, and updates only ever come from image rebuilds).

**Debian packages and Google Chrome** — Renovate cannot see apt repositories, so the daily [package refresh check](../.github/workflows/check-openchamber-apt-updates.yaml) runs `apt-get --simulate full-upgrade` inside the published image and opens a PR bumping `APT_REFRESH` whenever packages are outdated.

**Image builds** — merging a PR that touches `images/openchamber/**` triggers the [build workflow](../.github/workflows/build-openchamber.yaml), which builds `linux/amd64` and `linux/arm64` on native runners, pushes `ghcr.io/gjpin/openchamber:main-<shortsha>`, and commits the new tag into `apps/openchamber/1_deployment.yaml`. Argo CD then rolls the agent pod.

## Bootstrap

1. Add the three `/openchamber/*` Infisical secrets (see [secrets.md](secrets.md)).
2. On first deployment the manifest references the `main-bootstrap` placeholder tag, so the pod reports `ImagePullBackOff` until the first build finishes and commits a real tag. This is expected.
3. After the first build, make the `gjpin/openchamber` GHCR package public so the cluster can pull it without credentials.
4. Argo CD rolls the pod once the build workflow commits the real image tag.

## Agent credentials

Provider credentials come from two places:

- **Infisical** — `OPENAI_API_KEY` (Codex CLI and OpenCode) and `GITHUB_TOKEN` (git operations) are injected as environment variables from the `openchamber-credentials` secret. Add further provider keys the same way by extending the ExternalSecret and the Infisical paths in [secrets.md](secrets.md).
- **Interactive logins** — `kubectl exec` into the pod and run `opencode auth login`, `codex login`, or `/login` inside a Pi session; the artifacts persist under `/home/agent` on the PVC and survive restarts and updates.