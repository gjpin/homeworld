# Persistent AI agent workspace.
#
# Debian 13 (trixie) with development toolchain, the
# OpenChamber web server, OpenCode, Codex CLI, the Pi coding agent, Grok Build,
# the Antigravity CLI, and the GitHub Copilot CLI, all
# running as the non-root `agent` user with a PVC-backed HOME.
#
# Every version below is pinned. Updates arrive as PRs:
#   - Renovate groups the base image digest and every ARG update into one
#     openchamber-workspace-image PR via custom regex managers (renovate.json).
#   - The daily check-openchamber-apt-updates workflow bumps APT_REFRESH when
#     Debian publishes newer packages than the image currently contains.
# Each PR must pass the PR-side amd64 smoke build (smoke-openchamber.yaml);
# the automerge-openchamber workflow then merges it, and this image rebuilds
# from main with every pending update included.
#
# Multi-arch: linux/amd64 and linux/arm64, built per-platform on native runners.

# Base image digest is updated by Renovate ("Update the OpenChamber workspace
# base image digest" custom manager).
FROM debian:trixie-slim@sha256:a99cfc517144bc59b1978475ec53b46ecabec7e43635402ee5b77cc54cd1b20a

# Bumped by the daily check-openchamber-apt-updates workflow when the
# published image has out-of-date apt packages (including Google Chrome).
# Bumping it rebuilds the apt layer with refreshed packages.
ARG APT_REFRESH=2026-09-25

# Pinned tool versions, each tracked by its own Renovate custom manager.
ARG NODE_VERSION=26.10.0
ARG PNPM_VERSION=12.7.0
ARG UV_VERSION=0.12.19
ARG OPENCHAMBER_VERSION=2.0.2
ARG OPENCODE_VERSION=1.18.32
ARG CODEX_VERSION=0.157.1
ARG PI_AGENT_VERSION=0.87.1
ARG PLAYWRIGHT_TEST_VERSION=1.63.0
ARG PLAYWRIGHT_CLI_VERSION=0.1.21
ARG CHROME_DEVTOOLS_MCP_VERSION=1.10.1
ARG SKILLS_VERSION=1.7.0
ARG GROK_VERSION=1.0.41
ARG ANTIGRAVITY_VERSION=1.2.12
ARG COPILOT_VERSION=1.0.88

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    PLAYWRIGHT_BROWSERS_PATH=/opt/ms-playwright

# Installs the trixie package baseline plus the Buildkite (helm),
# OpenTofu (tofu), HashiCorp (terraform), and Adoptium (temurin-25-jdk)
# repositories.
RUN set -eux; \
    echo "apt refresh epoch: ${APT_REFRESH}"; \
    apt-get update; \
    apt-get install -y ca-certificates curl gnupg wget; \
    install -d -m 0755 /etc/apt/keyrings; \
    installer_dir="$(mktemp -d)"; \
    \
    curl -fsSL https://packages.buildkite.com/helm-linux/helm-debian/gpgkey -o "$installer_dir/helm.gpg"; \
    helm_fingerprint="$(gpg --show-keys --with-colons "$installer_dir/helm.gpg" | awk -F: '$1 == "fpr" {print $10; exit}')"; \
    test "$helm_fingerprint" = DDF78C3E6EBB2D2CC223C95C62BA89D07698DBC6; \
    gpg --batch --yes --dearmor -o /etc/apt/keyrings/helm.gpg "$installer_dir/helm.gpg"; \
    echo 'deb [signed-by=/etc/apt/keyrings/helm.gpg] https://packages.buildkite.com/helm-linux/helm-debian/any/ any main' > /etc/apt/sources.list.d/helm.list; \
    \
    curl -fsSL https://get.opentofu.org/opentofu.gpg -o /etc/apt/keyrings/opentofu.gpg; \
    curl -fsSL https://packages.opentofu.org/opentofu/tofu/gpgkey -o "$installer_dir/opentofu-repo.gpg"; \
    gpg --batch --yes --dearmor -o /etc/apt/keyrings/opentofu-repo.gpg "$installer_dir/opentofu-repo.gpg"; \
    echo 'deb [signed-by=/etc/apt/keyrings/opentofu.gpg,/etc/apt/keyrings/opentofu-repo.gpg] https://packages.opentofu.org/opentofu/tofu/any/ any main' > /etc/apt/sources.list.d/opentofu.list; \
    \
    curl -fsSL https://apt.releases.hashicorp.com/gpg -o "$installer_dir/hashicorp.gpg"; \
    gpg --batch --yes --dearmor -o /etc/apt/keyrings/hashicorp.gpg "$installer_dir/hashicorp.gpg"; \
    echo 'deb [signed-by=/etc/apt/keyrings/hashicorp.gpg] https://apt.releases.hashicorp.com trixie main' > /etc/apt/sources.list.d/hashicorp.list; \
    \
    curl -fsSL https://packages.adoptium.net/artifactory/api/gpg/key/public -o "$installer_dir/adoptium.gpg"; \
    gpg --batch --yes --dearmor -o /etc/apt/keyrings/adoptium.gpg "$installer_dir/adoptium.gpg"; \
    echo 'deb [signed-by=/etc/apt/keyrings/adoptium.gpg] https://packages.adoptium.net/artifactory/deb trixie main' > /etc/apt/sources.list.d/adoptium.list; \
    \
    chmod 0644 /etc/apt/keyrings/*.gpg /etc/apt/sources.list.d/*.list; \
    rm -rf "$installer_dir"; \
    apt-get update; \
    apt-get install -y \
      acl attr autoconf automake bat bats bind9-dnsutils buildah bzip2 \
      ca-certificates cargo ccache clang clang-tools cmake coreutils curl \
      dnf-plugins-core diffutils direnv entr fd-find file findutils fzf g++ \
      gawk gcc gdb gettext-base gh git git-lfs glab golang gopls gnupg2 \
      gnu-which gzip helm inotify-tools iproute2 iputils-arping \
      iputils-clockdiff iputils-ping iputils-tracepath jq just kind kubectl \
      kustomize less libtool lld lldb llvm linux-perf lsof m4 make man-db \
      manpages meson mold moreutils ncat ninja-build nodejs npm \
      openssh-client openssl parallel patch pipx pkgconf podman procps psmisc \
      python3 python3-dev python3-pip python3-pytest-xdist ripgrep rpm rsync \
      rust-analyzer rustc rustfmt scons sed shellcheck shfmt skopeo socat \
      sqlite3 strace sudo sysstat tar tcpdump temurin-25-jdk terraform time \
      tmux tofu traceroute tree tree-sitter-cli unzip util-linux valgrind vim \
      wget xxd xz-utils yq zip zstd; \
    if [ -x /usr/bin/fdfind ] && [ ! -e /usr/local/bin/fd ]; then \
      ln -s /usr/bin/fdfind /usr/local/bin/fd; \
    fi; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/*

# Google Chrome Stable from Google's native package. 
# The package configures Google's apt repository, so
# every rebuild also refreshes Chrome with the other apt packages.
RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    case "$arch" in \
      amd64) chrome_url="https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb" ;; \
      arm64) chrome_url="https://dl.google.com/linux/direct/google-chrome-stable_current_arm64.deb" ;; \
      *) echo >&2 "unsupported architecture for Google Chrome: $arch"; exit 1 ;; \
    esac; \
    curl --fail --silent --show-error --location --retry 5 --output /tmp/google-chrome.deb "$chrome_url"; \
    apt-get update; \
    apt-get install -y /tmp/google-chrome.deb; \
    rm -f /tmp/google-chrome.deb; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/*; \
    command -v google-chrome-stable

# Node.js 26 from the official tarball (the 26 release line enters Active
# LTS in late October 2026; Renovate keeps it current within the major).
# OpenChamber requires Node 22+; trixie's apt nodejs is 20.x, so /usr/local
# takes PATH precedence while the apt nodejs/npm packages remain installed.
RUN set -eux; \
    arch="$(uname -m)"; \
    case "$arch" in \
      x86_64) node_arch="x64" ;; \
      aarch64) node_arch="arm64" ;; \
      *) echo >&2 "unsupported architecture for Node.js: $arch"; exit 1 ;; \
    esac; \
    cd /tmp; \
    curl -fsSLO "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-${node_arch}.tar.xz"; \
    curl -fsSL "https://nodejs.org/dist/v${NODE_VERSION}/SHASUMS256.txt" | grep "node-v${NODE_VERSION}-linux-${node_arch}.tar.xz$" | sha256sum -c -; \
    tar -xJf "node-v${NODE_VERSION}-linux-${node_arch}.tar.xz" -C /usr/local --strip-components=1; \
    rm -f "node-v${NODE_VERSION}-linux-${node_arch}.tar.xz"; \
    hash -r; \
    node --version; \
    npm --version

# pnpm, installed via the official script; version pinned.
# pnpm v12 places binaries under $PNPM_HOME/bin.
ENV PNPM_HOME=/usr/local/pnpm
RUN set -eux; \
    curl -fsSL https://get.pnpm.io/install.sh | env PNPM_VERSION="${PNPM_VERSION}" PNPM_HOME=/usr/local/pnpm SHELL=/bin/bash sh -; \
    /usr/local/pnpm/bin/pnpm --version

# uv/uvx, installed via the official unmanaged installer.
RUN set -eux; \
    curl -fsSL "https://astral.sh/uv/${UV_VERSION}/install.sh" | env UV_UNMANAGED_INSTALL=/usr/local/bin sh -; \
    uv --version; \
    uvx --version

# Playwright Test and the Playwright Agent CLI. The Test package pins the
# Chromium revision installed by the browsers layer below.
RUN set -eux; \
    npm install -g --ignore-scripts \
      "@playwright/test@${PLAYWRIGHT_TEST_VERSION}" \
      "@playwright/cli@${PLAYWRIGHT_CLI_VERSION}"; \
    playwright --version; \
    playwright-cli --version

# Playwright Chromium browsers, baked outside HOME because /home/agent is a
# PVC mount at runtime. Kept directly after the Playwright packages (their
# only dependency) so this 1.3 GB layer only rebuilds when the Playwright
# versions change, not when the coding agents update.
RUN set -eux; \
    playwright install chromium; \
    playwright-cli install-browser chromium

# Stage the agent skills skeleton outside HOME; the entrypoint seeds a fresh
# PVC from it on first boot. playwright-cli installs skills into the
# workspace root, so run it from inside the staging directory.
RUN set -eux; \
    install -d -m 0755 /opt/agent-seed; \
    cd /opt/agent-seed; \
    env HOME=/opt/agent-seed playwright-cli install --skills; \
    env HOME=/opt/agent-seed playwright-cli install --skills=agents; \
    test -f /opt/agent-seed/.agents/skills/playwright-cli/SKILL.md; \
    test -f /opt/agent-seed/.claude/skills/playwright-cli/SKILL.md

# OpenChamber server, tracked by the openchamber/openchamber release tag.
RUN set -eux; \
    npm install -g "@openchamber/web@${OPENCHAMBER_VERSION}"; \
    openchamber --version

# chrome-devtools-mcp: MCP server exposing Chrome DevTools to agents.
RUN set -eux; \
    npm install -g --ignore-scripts "chrome-devtools-mcp@${CHROME_DEVTOOLS_MCP_VERSION}"; \
    chrome-devtools-mcp --help > /dev/null

# skills: CLI for installing and managing agent skill packages.
RUN set -eux; \
    npm install -g --ignore-scripts "skills@${SKILLS_VERSION}"; \
    command -v skills add-skill

# Pi coding agent.
RUN set -eux; \
    npm install -g --ignore-scripts "@earendil-works/pi-coding-agent@${PI_AGENT_VERSION}"; \
    pi --version

# OpenCode CLI, pinned by version through the official installer.
RUN set -eux; \
    install -d -m 0755 /tmp/opencode-install; \
    curl -fsSL https://opencode.ai/install | HOME=/tmp/opencode-install bash -s -- --version "${OPENCODE_VERSION}"; \
    install -m 0755 /tmp/opencode-install/.opencode/bin/opencode /usr/local/bin/opencode; \
    rm -rf /tmp/opencode-install; \
    opencode --version

# Codex CLI, pinned by release through the official installer. The
# installer places a symlink into CODEX_INSTALL_DIR that points into the
# installing user's ~/.codex, so the real standalone binary is copied to
# /usr/local/bin to keep it usable by the non-root agent user.
RUN set -eux; \
    install -d -m 0755 /tmp/codex-install; \
    curl -fsSL https://chatgpt.com/codex/install.sh | env CODEX_RELEASE="${CODEX_VERSION}" CODEX_INSTALL_DIR=/tmp/codex-install/bin HOME=/tmp/codex-install sh -; \
    install -m 0755 /tmp/codex-install/.codex/packages/standalone/current/bin/codex /usr/local/bin/codex; \
    rm -rf /tmp/codex-install; \
    codex --version

# Grok Build CLI, pinned by version through a direct artifact download.
# Upstream publishes no checksums; TLS plus a `--version` smoke test is the
# same verification the official installer performs.
RUN set -eux; \
    arch="$(uname -m)"; \
    case "$arch" in \
      x86_64) grok_arch="x86_64" ;; \
      aarch64) grok_arch="aarch64" ;; \
      *) echo >&2 "unsupported architecture for Grok: $arch"; exit 1 ;; \
    esac; \
    curl -fsSL "https://x.ai/cli/grok-${GROK_VERSION}-linux-${grok_arch}.zst" -o /tmp/grok.zst; \
    zstd -dc /tmp/grok.zst > /usr/local/bin/grok; \
    rm -f /tmp/grok.zst; \
    chmod 0755 /usr/local/bin/grok; \
    ln -sf grok /usr/local/bin/agent; \
    grok --version

# Antigravity CLI (`agy`), pinned by version via Google's per-arch release
# manifest for the build architecture. The manifest supplies a versioned
# artifact URL plus a SHA-512 checksum; the build asserts the manifest
# version equals the pinned ARG so a silent upstream roll never slips past
# the pin. The `agy install` shell handoff from the official installer is
# intentionally skipped: the binary is placed directly in /usr/local/bin.
RUN set -eux; \
    arch="$(uname -m)"; \
    case "$arch" in \
      x86_64) agy_arch="amd64" ;; \
      aarch64) agy_arch="arm64" ;; \
      *) echo >&2 "unsupported architecture for Antigravity: $arch"; exit 1 ;; \
    esac; \
    manifest="$(curl -fsSL "https://antigravity-cli-auto-updater-974169037036.us-central1.run.app/manifests/linux_${agy_arch}.json")"; \
    manifest_version="$(printf '%s' "$manifest" | jq -r .version)"; \
    test "$manifest_version" = "${ANTIGRAVITY_VERSION}"; \
    agy_url="$(printf '%s' "$manifest" | jq -r .url)"; \
    agy_sha512="$(printf '%s' "$manifest" | jq -r .sha512)"; \
    curl -fsSL "$agy_url" -o /tmp/agy.tar.gz; \
    printf '%s  /tmp/agy.tar.gz\n' "$agy_sha512" | sha512sum -c -; \
    tar -xzf /tmp/agy.tar.gz -C /tmp antigravity; \
    install -m 0755 /tmp/antigravity /usr/local/bin/agy; \
    rm -f /tmp/agy.tar.gz /tmp/antigravity; \
    agy --version

# GitHub Copilot CLI, pinned by release tarball with SHA-256 verification.
# The tarball and SHA256SUMS.txt keep their upstream names so
# `sha256sum -c --ignore-missing` validates the pinned artifact.
RUN set -eux; \
    arch="$(uname -m)"; \
    case "$arch" in \
      x86_64) copilot_arch="x64" ;; \
      aarch64) copilot_arch="arm64" ;; \
      *) echo >&2 "unsupported architecture for Copilot: $arch"; exit 1 ;; \
    esac; \
    install -d -m 0755 /tmp/copilot-install; \
    cd /tmp/copilot-install; \
    curl -fsSLO "https://github.com/github/copilot-cli/releases/download/v${COPILOT_VERSION}/copilot-linux-${copilot_arch}.tar.gz"; \
    curl -fsSLO "https://github.com/github/copilot-cli/releases/download/v${COPILOT_VERSION}/SHA256SUMS.txt"; \
    sha256sum -c --ignore-missing SHA256SUMS.txt; \
    tar -tzf "copilot-linux-${copilot_arch}.tar.gz"; \
    tar -xzf "copilot-linux-${copilot_arch}.tar.gz"; \
    test -f copilot; \
    install -m 0755 copilot /usr/local/bin/copilot; \
    cd /; rm -rf /tmp/copilot-install; \
    copilot --version

COPY openchamber-entrypoint.sh /usr/local/bin/openchamber-entrypoint

# Non-root agent user. HOME defaults to the PVC-mounted /home/agent at
# runtime; PATH includes the agent-user install directories plus the system
# installs. NPM_CONFIG_PREFIX routes runtime `npm install -g` into the PVC.
RUN set -eux; \
    chmod 0755 /usr/local/bin/openchamber-entrypoint; \
    useradd --uid 1000 --user-group --create-home --shell /bin/bash agent; \
    command -v openchamber; \
    command -v opencode; \
    command -v codex; \
    command -v pi; \
    command -v grok; \
    command -v agy; \
    command -v copilot; \
    command -v google-chrome-stable

ENV HOME=/home/agent \
    PATH=/home/agent/.local/bin:/home/agent/.local/share/pnpm/bin:/home/agent/.opencode/bin:/usr/local/pnpm/bin:/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin \
    PNPM_HOME=/home/agent/.local/share/pnpm \
    NPM_CONFIG_PREFIX=/home/agent/.local

USER agent
WORKDIR /home/agent
EXPOSE 3000

ENTRYPOINT ["/usr/local/bin/openchamber-entrypoint"]
