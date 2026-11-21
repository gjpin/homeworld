# Kubernetes (homeworld)

General-purpose Linux development workspace for any language, with
code-server in the browser and a persistent `/home/coder` volume. The image
carries Node.js, Go, Python, Rust, Java, and C/C++ toolchains, Kubernetes and
infrastructure CLIs (kubectl, helm, kustomize, terraform, opentofu), gh and
glab, the Claude Code, Codex, OpenCode, Copilot, Pi, Antigravity, and Mistral
Vibe coding agents, and Playwright with Chromium. Projects pin other versions with
[mise](https://mise.jdx.dev): run `mise install` in a repository with a
`mise.toml` or `.tool-versions`. Use it for coding tasks in repositories on
the homeworld Forgejo (`git.` on the cluster domain) or public forges.

- Runs in the `coder-workspaces` namespace under gVisor, as UID 1000 with
  the Restricted Pod Security Standard: no root, no `sudo`, no Docker or
  Podman. Install extra tools with mise, `pipx`, or `npm -g`, never `apt`.
- Internet egress on ports 22, 80, and 443 only; no inbound connections.
- Stopping the workspace keeps the home volume, including tools you
  installed; everything outside `/home/coder` resets on every start.
