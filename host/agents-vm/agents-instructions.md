## Agents VM: environment

You are running in the homeworld agents VM: Fedora, user `agent`, home on a
persistent disk. The root filesystem is rebuilt from scratch whenever its
pinned tools change, so anything outside `/home/agent` can disappear.

- There is no `sudo`. Install extra tools under `~/.local` or run them in a
  container.
- Use rootless `podman` for containers. Always pass `--rm`, and use fully
  qualified image names (`docker.io/library/postgres:18`, never
  `postgres:18`).
- The coding-agent CLIs, OpenChamber and Paseo are pinned in `/usr/local` and
  never self-update.
- Network: the internet is reachable. The home network, the cluster and the
  NAS are not, except `git.base-domain.invalid` (HTTPS and SSH) through the
  cluster gateway.
- Never put secrets in files you commit or in container images.
