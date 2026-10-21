# Kubernetes (homeworld)

General-purpose Linux development workspace for any language: an Ubuntu
container with git, build tools, and common CLI tools, code-server in the
browser, and a persistent `/home/coder` volume. Language toolchains (Node.js,
Go, Python, Rust, Java, and more) come from [mise](https://mise.jdx.dev) per
project: run `mise install` in a repository with a `mise.toml` or
`.tool-versions`, or `mise use <tool>@<version>` to add one. Use it for
coding tasks in repositories on Forgejo (`git.homeworld.internal`) or public
forges.

- Runs in the `coder-workspaces` namespace under gVisor, as UID 1000 with
  the Restricted Pod Security Standard: no root, no `sudo`, no Docker.
  Install tools with mise, `pipx`, or `npm`, never `apt`.
- Internet egress on ports 22, 80, and 443 only; no inbound connections.
- The Homeworld CA is trusted by curl, git, OpenSSL, Go, and Node.js.
- Stopping the workspace keeps the home volume, including installed
  toolchains; everything outside `/home/coder` resets on every start.
