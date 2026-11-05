# Agents VM (OpenChamber, Paseo and ThinkRail)

The AI agent workspace is a libvirt/KVM virtual machine on the Ryzen node,
outside Kubernetes. It runs [OpenChamber](https://github.com/openchamber/openchamber)
the [Paseo](https://paseo.sh/) daemon and
[ThinkRail](https://github.com/JetBrains/thinkrail) as `agent` (UID 1000)
user services, with pinned coding agents: OpenCode, Claude Code, Codex CLI, the
Pi agent, the Antigravity CLI and the GitHub Copilot CLI, plus Node.js,
pnpm, uv, Google Chrome with Playwright and chrome-devtools-mcp, the skills
CLI, kind, kubectl and rootless Podman on Fedora.

| | |
| :--- | :--- |
| Host | The `ryzen` profile (`AGENTS_VM=1` in `host/nodes/ryzen.env`) |
| Definition | `host/agents-vm/` (applied by `host/apply.sh` through `host.sh`) |
| Size | 8 vCPU, 16 GiB RAM, 40 GiB root and 160 GiB `/home` (thin qcow2 on the encrypted root, or on a data disk chosen with `host/disks.sh`, [docs/fedora.md](fedora.md#data-disks)) |
| Address | `10.20.0.10` on the routed network `10.20.0.0/24` (`virbr-agents`) |
| Domains | `openchamber.base-domain.invalid` (port `3000`), `paseo.base-domain.invalid` (port `6767`), `thinkrail.base-domain.invalid` (port `24242`) |
| Cluster side | `apps/openchamber`: HTTPRoutes, ThinkRail's gateway sign-in and selectorless Services with EndpointSlices to `10.20.0.10` |

The Ryzen's kubelet reserves the VM's 16 GiB (`system-reserved`), the VM runs
with a lower CPU weight than the host's own services, and `libvirt-guests`
shuts it down cleanly and starts it again with the host. The VM is not backed
up: everything worth keeping lives in git remotes or on `/home`.

## Rebuildable root, persistent home

The root disk is rebuilt from scratch, `/home` never is:

1. `host.sh` hashes its inputs (every file in `host/agents-vm/` plus
   `FEDORA_RELEASE`). When they change, it stages a rebuild.
2. `agents-vm-rebuild.timer` runs it in the 02:00–02:30 Europe/Lisbon window
   (before kured's reboot window). When no VM exists yet, `host.sh` builds it
   right away.
3. `rebuild.sh` downloads the Fedora Cloud Base image for `FEDORA_RELEASE`,
   verifies its `CHECKSUM` file against the Fedora release key and the image
   against it, creates a new root disk and a cloud-init seed (the agents'
   SSH keys, the Infisical identity, and `provision.sh` and the agents'
   instructions with the cluster domain filled in from the `homeworld-domain`
   Secret), and redefines the libvirt domain.
4. cloud-init creates the `/home` filesystem once (XFS, label `agents-home`)
   and never formats it again; then `provision.sh` installs everything.

Between rebuilds, `dnf5-automatic` updates the Fedora packages inside the VM.
The agent tools are pinned in `host/agents-vm/versions.env` and installed
into `/usr/local`, which `agent` cannot write, so no tool updates itself;
Renovate groups their bumps into one PR, and a merge rebuilds the root that
night. Third-party repositories without the new Fedora release yet
(HashiCorp, Adoptium) fall back to the previous release until they publish
it.

## Network

The routed network has no NAT: the router routes `10.20.0.0/24` to the
Ryzen ([docs/openwrt.md](openwrt.md) section 17) and every other node gets
the same static route from apply.sh. firewalld on the Ryzen decides what
crosses `virbr-agents`:

| Direction | Allowed |
| --- | --- |
| VM → Ryzen | DHCP and DNS (libvirt's dnsmasq, forwarding to the router, so `*.base-domain.invalid` resolves) |
| VM → internet | Everything |
| VM → Gateway VIP `192.168.8.50` | TCP `443` and `22` (Forgejo, its registry, every web app) |
| VM → anything else private | Rejected: RFC 1918, CGNAT, link-local, multicast and their IPv6 counterparts, so no node, pod, Service, NAS or LAN host |
| LAN and WireGuard clients → VM | Every port (SSH, OpenChamber, Paseo, dev servers) except ThinkRail's `24242`, which has no login of its own |
| Nodes and pods → VM | `3000`, `6767` and `24242` only (Envoy Gateway's backends) |
| Ryzen → VM | `3000`, `6767`, `24242`, DHCP replies and ICMP |

The Gateway VIP is never announced from the Ryzen ([docs/cilium.md](cilium.md)),
so the VM's HTTPS and SSH traffic to it leaves through the LAN like any
other client's. The Ryzen uses kernel (legacy) host routing for the same
reason Envoy on it can reach the VM.

## Access

- **Browser**: `https://openchamber.base-domain.invalid` and
  `https://paseo.base-domain.invalid` through Envoy Gateway (the
  wildcard Let's Encrypt certificate). Both apps authenticate on their own: the
  OpenChamber UI password and Paseo's bearer password ([docs/oidc.md](oidc.md)).
- **ThinkRail**: `https://thinkrail.base-domain.invalid`, behind Envoy
  Gateway's Authelia sign-in (the `platform` group): ThinkRail has no
  accounts of its own, so the VM's port is closed to LAN and WireGuard
  clients and the Gateway is the only way in. It runs the Pi agent
  in-process and shares Pi's logins (`/login` inside `pi`) or signs in
  to JetBrains AI from its own settings; app state lives in
  `~/.thinkrail`.
- **Paseo apps**: pair the desktop or mobile app with the daemon, directly at
  `10.20.0.10:6767` or through `paseo.base-domain.invalid`. The relay is
  disabled (`PASEO_RELAY_ENABLED=false`), and `PASEO_HOSTNAMES` allows the
  Gateway hostname besides the IP addresses Paseo accepts by default.
- **SSH and editors**: `ssh agent@10.20.0.10` (the keys entered at bootstrap)
  for a shell or VS Code Remote-SSH, from the LAN or over WireGuard.
- **Claude Code Remote Control**: an optional user service,
  `systemctl --user enable --now claude-remote-control`, after `claude` is
  logged in to a claude.ai account.

## Secrets

The VM has its own read-only Infisical machine identity, scoped to the
`/agents` folder ([docs/secrets.md](secrets.md)). bootstrap.sh stores its
client ID and secret root-only on the Ryzen (`/etc/homeworld/agents-vm.env`),
the cloud-init seed carries them into the VM, and `agents-secrets.service`
exports `/agents/*` into `/run/agents/secrets.env` (tmpfs, readable by
`agent`) at every boot. The OpenChamber and Paseo services load that file,
so agents they start see `OPENAI_API_KEY` and `GITHUB_TOKEN`; in an SSH
session, `set -a; . /run/agents/secrets.env; set +a` does the same.

## Agent logins

Log in to each agent once over SSH; the credentials live under `/home/agent`
and survive rebuilds: `opencode auth login`, `codex login`, `claude`, `/login`
inside `pi`, `agy`, `copilot login`. Copilot CLI prefers `GITHUB_TOKEN` over
its stored login, so that token needs the Copilot Requests permission.

## Managed configuration

`agents-config.service` (a user service, every boot) rewrites only its own
keys in each agent's configuration and a marked block in each agent's global
instructions file (from `host/agents-vm/agents-instructions.md`), and keeps
everything else the agents or you add:

- Codex, OpenCode, Pi and the Antigravity CLI run without approval prompts;
  the VM itself is the sandbox.
- Self-update and update checks are off for every agent (and inert anyway,
  `/usr/local` being read-only): Codex `check_for_update_on_startup`,
  OpenCode `update: "disable"`, Pi `PI_SKIP_VERSION_CHECK`, Copilot `autoUpdate`,
  Claude Code `DISABLE_UPDATES`, Infisical CLI `INFISICAL_DISABLE_UPDATE_CHECK`,
  Playwright CLI `NO_UPDATE_NOTIFIER`, Antigravity CLI `AGY_CLI_DISABLE_AUTO_UPDATE`.
  OpenChamber has no switch for its update
  check, so `OPENCHAMBER_UPDATE_API_URL` points at an unreachable local port.
  ThinkRail's release check only runs from an installer layout
  (`<prefix>/bin/thinkrail`), so the binary lives in
  `/usr/local/libexec/thinkrail` behind a wrapper.
- Telemetry is off where the vendor allows it: Codex analytics and feedback,
  OpenCode sharing, Pi install telemetry, Claude Code
  `DISABLE_TELEMETRY` and `DISABLE_ERROR_REPORTING`, Infisical CLI
  `INFISICAL_DISABLE_TELEMETRY` (also set in the secrets loader). Copilot CLI has no telemetry switch short of offline mode, which
  also disables GitHub sign-in; that is an accepted upstream limitation.
  Antigravity saves its telemetry choice with the account, not in
  `settings.json`, so it stays a manual step: turn off Enable Telemetry in
  `/config` after the first login; only the feedback survey is managed.
  ThinkRail's additional analytics are off (`THINKRAIL_NO_ANALYTICS`), and
  its basic usage events, error reports and surveys have no switch outside
  CI, so `THINKRAIL_POSTHOG_HOST` points them at an unreachable local port.
