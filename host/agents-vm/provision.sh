#!/usr/bin/env bash
# Agents VM provisioning (docs/openchamber.md), run once by cloud-init as
# root on every freshly rebuilt root disk. Installs the Fedora toolset, the
# pinned agent tools into /usr/local (read-only to `agent`, so nothing can
# self-update), the secrets loader and the OpenChamber, Paseo and ThinkRail
# user services.
set -euxo pipefail

. /usr/local/share/agents/versions.env
. /etc/os-release
arch=$(uname -m)
case "$arch" in
  x86_64) npm_arch=x64 deb_arch=amd64 go_arch=amd64 ;;
  aarch64) npm_arch=arm64 deb_arch=arm64 go_arch=arm64 ;;
  *) echo "unsupported architecture: $arch" >&2; exit 1 ;;
esac
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# --- repositories ---------------------------------------------------------
# HashiCorp and Adoptium publish a new Fedora release some time after GA:
# use the newest release they serve, at most ours.
newest_release() { # URL-TEMPLATE (with @R@)
  local r
  for r in "$VERSION_ID" $((VERSION_ID - 1)) $((VERSION_ID - 2)); do
    if curl -fsSIo /dev/null "${1//@R@/$r}"; then
      echo "$r"
      return
    fi
  done
  echo "no repository for Fedora $VERSION_ID or the two previous releases: $1" >&2
  return 1
}
hashicorp=$(newest_release "https://rpm.releases.hashicorp.com/fedora/@R@/$arch/stable/repodata/repomd.xml")
cat >/etc/yum.repos.d/hashicorp.repo <<EOF
[hashicorp]
name=HashiCorp Stable - Fedora $hashicorp
baseurl=https://rpm.releases.hashicorp.com/fedora/$hashicorp/\$basearch/stable
enabled=1
gpgcheck=1
gpgkey=https://rpm.releases.hashicorp.com/gpg
EOF
adoptium=$(newest_release "https://packages.adoptium.net/artifactory/rpm/fedora/@R@/$arch/repodata/repomd.xml")
cat >/etc/yum.repos.d/adoptium.repo <<EOF
[adoptium]
name=Adoptium - Fedora $adoptium
baseurl=https://packages.adoptium.net/artifactory/rpm/fedora/$adoptium/\$basearch
enabled=1
gpgcheck=1
gpgkey=https://packages.adoptium.net/artifactory/api/gpg/key/public
EOF
cat >/etc/yum.repos.d/google-chrome.repo <<'EOF'
[google-chrome]
name=google-chrome
baseurl=https://dl.google.com/linux/chrome/rpm/stable/$basearch
enabled=1
gpgcheck=1
gpgkey=https://dl.google.com/linux/linux_signing_key.pub
EOF

# --- packages -------------------------------------------------------------
dnf -y install \
  bash bat bats bind-utils bzip2 ca-certificates cargo clang clang-tools-extra \
  cmake coreutils curl diffutils fd-find file findutils fzf gawk gcc gcc-c++ \
  gdb gettext-envsubst gh git git-lfs glab golang gopls grep gzip iproute \
  iputils jq just less lld lldb llvm lsof make meson mold ninja-build \
  nmap-ncat nodejs26 nodejs26-bin nodejs26-npm nodejs26-npm-bin \
  openssh-clients openssl patch pkgconf-pkg-config procps-ng python3 \
  python3-devel python3-pytest-xdist ripgrep rsync rust rust-analyzer \
  rustfmt python3-scons sed ShellCheck sqlite strace tar time tree \
  tree-sitter-cli unzip util-linux uv wget2-wget which xxd xz yq zip zstd \
  pnpm vim-enhanced podman buildah skopeo dnf-plugins-core rpm-build \
  rpmdevtools redhat-rpm-config autoconf automake libtool m4 ccache \
  valgrind perf psmisc sysstat socat tcpdump traceroute acl attr entr \
  inotify-tools python3-pip pipx direnv tmux moreutils parallel gnupg2 \
  man-db man-pages kubernetes1.37-client helm kustomize opentofu kind \
  terraform temurin-25-jdk google-chrome-stable \
  qemu-guest-agent dnf5-plugin-automatic
systemctl enable --now qemu-guest-agent

# Updates between rebuilds; never reboot on its own.
printf '[commands]\napply_updates = yes\nreboot = never\n' >/etc/dnf/automatic.conf
systemctl enable --now dnf5-automatic.timer

# --- pinned tools in /usr/local ---------------------------------------------
export npm_config_prefix=/usr/local
# OpenChamber and Paseo run their install scripts (native modules).
npm install -g "@openchamber/web@$OPENCHAMBER_VERSION" "@getpaseo/cli@$PASEO_VERSION"
npm install -g --ignore-scripts \
  "@earendil-works/pi-coding-agent@$PI_AGENT_VERSION" \
  "@playwright/test@$PLAYWRIGHT_TEST_VERSION" \
  "@playwright/cli@$PLAYWRIGHT_CLI_VERSION" \
  "chrome-devtools-mcp@$CHROME_DEVTOOLS_MCP_VERSION" \
  "skills@$SKILLS_VERSION"

# Playwright's Chromium, outside HOME.
export PLAYWRIGHT_BROWSERS_PATH=/opt/ms-playwright
playwright install chromium
playwright-cli install-browser chromium

# OpenCode, through the official OpenCode 2 installer with the version
# pinned (the unversioned /install path is OpenCode 1's and refuses 2.x).
mkdir "$work/opencode"
curl -fsSL https://opencode.ai/v2/install |
  HOME="$work/opencode" bash -s -- --version "$OPENCODE_VERSION" --no-modify-path
install -m 0755 "$work/opencode/.opencode/bin/opencode" /usr/local/bin/opencode

# Codex CLI: the installer links into HOME, so copy the standalone binary.
mkdir "$work/codex"
curl -fsSL https://chatgpt.com/codex/install.sh |
  env CODEX_RELEASE="$CODEX_VERSION" CODEX_INSTALL_DIR="$work/codex/bin" HOME="$work/codex" sh -
install -m 0755 "$work/codex/.codex/packages/standalone/current/bin/codex" /usr/local/bin/codex

# Claude Code: the release manifest is verified against Anthropic's release
# signing key (fingerprint pinned) and the binary against the manifest.
release_url=https://downloads.claude.ai/claude-code-releases/$CLAUDE_CODE_VERSION
export GNUPGHOME=$work/gnupg
install -d -m 0700 "$GNUPGHOME"
curl -fsSL https://downloads.claude.ai/keys/claude-code.asc -o "$work/claude-code.asc"
test "$(gpg --show-keys --with-colons "$work/claude-code.asc" | awk -F: '$1 == "fpr" && !done {print $10; done = 1}')" = \
  31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE
gpg --batch --import "$work/claude-code.asc"
curl -fsSL -o "$work/manifest.json" "$release_url/manifest.json"
curl -fsSL -o "$work/manifest.json.sig" "$release_url/manifest.json.sig"
gpg --batch --verify "$work/manifest.json.sig" "$work/manifest.json"
test "$(jq -r .version "$work/manifest.json")" = "$CLAUDE_CODE_VERSION"
curl -fsSL -o "$work/claude" "$release_url/linux-$npm_arch/claude"
echo "$(jq -r --arg p "linux-$npm_arch" '.platforms[$p].checksum' "$work/manifest.json")  $work/claude" | sha256sum -c -
install -m 0755 "$work/claude" /usr/local/bin/claude
unset GNUPGHOME

# Antigravity CLI: the per-arch manifest supplies the artifact and its
# SHA-512; the manifest version must equal the pin.
manifest=$(curl -fsSL "https://antigravity-cli-auto-updater-974169037036.us-central1.run.app/manifests/linux_$deb_arch.json")
test "$(jq -r .version <<<"$manifest")" = "$ANTIGRAVITY_VERSION"
curl -fsSL -o "$work/agy.tar.gz" "$(jq -r .url <<<"$manifest")"
echo "$(jq -r .sha512 <<<"$manifest")  $work/agy.tar.gz" | sha512sum -c -
tar -xzf "$work/agy.tar.gz" -C "$work" antigravity
install -m 0755 "$work/antigravity" /usr/local/bin/agy

# GitHub Copilot CLI, SHA-256-verified release tarball.
mkdir "$work/copilot"
(
  cd "$work/copilot"
  curl -fsSLO "https://github.com/github/copilot-cli/releases/download/v$COPILOT_VERSION/copilot-linux-$npm_arch.tar.gz"
  curl -fsSLO "https://github.com/github/copilot-cli/releases/download/v$COPILOT_VERSION/SHA256SUMS.txt"
  sha256sum -c --ignore-missing SHA256SUMS.txt
  tar -xzf "copilot-linux-$npm_arch.tar.gz"
  install -m 0755 copilot /usr/local/bin/copilot
)

# ThinkRail, SHA-256-verified release binary. Outside a bin/ directory its
# background release check stays off (it only runs in the installer's
# <prefix>/bin layout); the wrapper puts it on PATH.
mkdir "$work/thinkrail"
(
  cd "$work/thinkrail"
  curl -fsSLO "https://github.com/JetBrains/thinkrail/releases/download/v$THINKRAIL_VERSION/thinkrail-linux-$npm_arch"
  curl -fsSLO "https://github.com/JetBrains/thinkrail/releases/download/v$THINKRAIL_VERSION/SHA256SUMS"
  sha256sum -c --ignore-missing SHA256SUMS
  install -D -m 0755 "thinkrail-linux-$npm_arch" /usr/local/libexec/thinkrail/thinkrail
)
printf '#!/bin/sh\nexec /usr/local/libexec/thinkrail/thinkrail "$@"\n' >/usr/local/bin/thinkrail
chmod 0755 /usr/local/bin/thinkrail

# Infisical CLI (secrets loader below), SHA-256-verified release tarball.
mkdir "$work/infisical"
(
  cd "$work/infisical"
  tarball=cli_${INFISICAL_VERSION}_linux_$go_arch.tar.gz
  curl -fsSLO "https://github.com/Infisical/cli/releases/download/v$INFISICAL_VERSION/$tarball"
  curl -fsSLO "https://github.com/Infisical/cli/releases/download/v$INFISICAL_VERSION/cli_${INFISICAL_VERSION}_checksums.txt"
  sha256sum -c --ignore-missing "cli_${INFISICAL_VERSION}_checksums.txt"
  tar -xzf "$tarball" infisical
  install -m 0755 infisical /usr/local/bin/infisical
)

# shfmt (not packaged for this Fedora release), verified by the Go checksum
# database.
GOBIN=/usr/local/bin GOPATH=$work/go GOCACHE=$work/gocache GOFLAGS=-modcacherw \
  go install "mvdan.cc/sh/v3/cmd/shfmt@$SHFMT_VERSION"

for tool in openchamber pi paseo playwright playwright-cli chrome-devtools-mcp skills \
  opencode codex claude agy copilot thinkrail infisical shfmt node kubectl kind terraform tofu google-chrome-stable; do
  command -v "$tool"
done

# --- environment ----------------------------------------------------------
# Self-update and telemetry switches (docs/openchamber.md). OpenChamber has
# no switch for its update check, and ThinkRail none for its basic usage
# events, so both point at an unreachable port.
cat >/etc/profile.d/agents.sh <<'EOF'
export PLAYWRIGHT_BROWSERS_PATH=/opt/ms-playwright
export PI_SKIP_VERSION_CHECK=1
export OPENCHAMBER_UPDATE_API_URL=http://127.0.0.1:9/
export THINKRAIL_NO_ANALYTICS=1
export THINKRAIL_POSTHOG_HOST=http://127.0.0.1:9
export DISABLE_UPDATES=1
export DISABLE_TELEMETRY=1
export INFISICAL_DISABLE_TELEMETRY=1
export INFISICAL_DISABLE_UPDATE_CHECK=1
export NPM_CONFIG_PREFIX=$HOME/.local
case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) PATH=$HOME/.local/bin:$PATH ;; esac
export PATH
EOF
install -d -m 0755 /etc/systemd/user.conf.d
cat >/etc/systemd/user.conf.d/agents.conf <<'EOF'
[Manager]
DefaultEnvironment=PLAYWRIGHT_BROWSERS_PATH=/opt/ms-playwright PI_SKIP_VERSION_CHECK=1 OPENCHAMBER_UPDATE_API_URL=http://127.0.0.1:9/ THINKRAIL_NO_ANALYTICS=1 THINKRAIL_POSTHOG_HOST=http://127.0.0.1:9 DISABLE_UPDATES=1 DISABLE_TELEMETRY=1 INFISICAL_DISABLE_TELEMETRY=1 INFISICAL_DISABLE_UPDATE_CHECK=1 "PATH=/home/agent/.local/bin:/usr/local/bin:/usr/bin"
EOF

# --- secrets: Infisical /agents/* into tmpfs ---------------------------------
cat >/usr/local/libexec/agents-secrets <<'EOF'
#!/bin/sh
# Fetch the agents VM's secrets (Infisical path /agents, read-only machine
# identity) into /run/agents/secrets.env, readable by `agent` only.
set -eu
. /etc/agents/infisical.env
export INFISICAL_DISABLE_TELEMETRY=1 INFISICAL_DISABLE_UPDATE_CHECK=1
domain=https://eu.infisical.com
token=$(infisical login --domain "$domain" --method=universal-auth \
  --client-id "$AGENTS_INFISICAL_CLIENT_ID" \
  --client-secret "$AGENTS_INFISICAL_CLIENT_SECRET" --plain --silent)
install -d -m 0750 -o root -g agent /run/agents
umask 0137
infisical export --domain "$domain" --token "$token" \
  --projectId "$AGENTS_INFISICAL_PROJECT_ID" --env prod --path /agents \
  --format dotenv >/run/agents/secrets.env.tmp
chgrp agent /run/agents/secrets.env.tmp
mv /run/agents/secrets.env.tmp /run/agents/secrets.env
EOF
chmod 0755 /usr/local/libexec/agents-secrets
cat >/etc/systemd/system/agents-secrets.service <<'EOF'
[Unit]
Description=Load the agents VM secrets from Infisical
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/libexec/agents-secrets
Restart=on-failure
RestartSec=30

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now agents-secrets.service

# --- agent user services ------------------------------------------------------
units=/etc/systemd/user
cat >$units/agents-config.service <<'EOF'
[Unit]
Description=Managed coding-agent configuration

[Service]
Type=oneshot
ExecStart=/usr/local/libexec/agents-config

[Install]
WantedBy=default.target
EOF
cat >$units/openchamber.service <<'EOF'
[Unit]
Description=OpenChamber web server
After=agents-config.service

[Service]
EnvironmentFile=/run/agents/secrets.env
Environment=OPENCHAMBER_HOST=0.0.0.0
WorkingDirectory=%h
ExecStart=/usr/local/bin/openchamber serve --foreground --port 3000
Restart=on-failure

[Install]
WantedBy=default.target
EOF
cat >$units/paseo.service <<'EOF'
[Unit]
Description=Paseo daemon
After=agents-config.service

[Service]
EnvironmentFile=/run/agents/secrets.env
Environment=PASEO_LISTEN=0.0.0.0:6767
Environment=PASEO_RELAY_ENABLED=false
Environment=PASEO_HOSTNAMES=paseo.base-domain.invalid
Environment=PASEO_WEB_UI_ENABLED=true
WorkingDirectory=%h
ExecStart=/usr/local/bin/paseo daemon run
Restart=on-failure

[Install]
WantedBy=default.target
EOF
# ThinkRail has no login of its own: Envoy Gateway's Authelia sign-in
# fronts thinkrail.base-domain.invalid, and the VM host's firewall keeps
# LAN and WireGuard clients off this port (docs/openchamber.md).
cat >$units/thinkrail.service <<'EOF'
[Unit]
Description=ThinkRail web server
After=agents-config.service

[Service]
EnvironmentFile=/run/agents/secrets.env
WorkingDirectory=%h
ExecStart=/usr/local/libexec/thinkrail/thinkrail --host 0.0.0.0 --port 24242 --no-open
Restart=on-failure

[Install]
WantedBy=default.target
EOF
cat >$units/claude-remote-control.service <<'EOF'
[Unit]
Description=Claude Code Remote Control (optional; needs a claude.ai login)

[Service]
WorkingDirectory=%h/projects
ExecStart=/usr/local/bin/claude remote-control
Restart=on-failure

[Install]
WantedBy=default.target
EOF
systemctl --global enable agents-config.service openchamber.service paseo.service thinkrail.service
loginctl enable-linger agent
