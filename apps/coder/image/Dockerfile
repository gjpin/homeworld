# Coder workspace image: the agents VM's toolset (host/agents-vm/provision.sh)
# on Debian, for the Restricted, gVisor-sandboxed coder-workspaces namespace.
# Built for linux/amd64 (the template's agent architecture) and pushed to
# ghcr.io/gjpin/homeworld/coder-workspace by
# .github/workflows/coder-workspace-image.yaml (docs/coder.md).
#
# System packages come from apt, Rust from rustup, and the other language
# toolchains, cloud CLIs, and coding agents from mise (mise.toml). Everything
# installs as root and is read-only to the workspace user, so nothing updates
# itself.
FROM docker.io/library/debian:trixie-20261027

SHELL ["/bin/bash", "-o", "pipefail", "-c"]
ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8

RUN apt-get update \
    && apt-get install --yes --no-install-recommends \
      acl attr autoconf automake bash bash-completion bats bind9-dnsutils \
      build-essential bzip2 ca-certificates ccache clang clang-format \
      clang-tidy clangd cmake curl diffutils direnv entr file findutils fzf \
      gawk gdb gettext-base git git-lfs gnupg gzip inotify-tools iproute2 \
      iputils-ping jq just less libtool lld lldb llvm lsof m4 make man-db \
      manpages meson mold moreutils netcat-openbsd ninja-build openssh-client \
      openssl parallel patch pipx pkgconf procps psmisc python3 python3-dev \
      python3-pip python3-pytest-xdist python3-venv ripgrep rsync scons \
      shellcheck skopeo socat sqlite3 sysstat tar time tmux tree unzip \
      util-linux valgrind vim wget xxd xz-utils zip zstd \
    && rm -rf /var/lib/apt/lists/*

# Release binaries pinned by version and sha256. Renovate bumps the versions
# and scripts/refresh-coder-image-shas.sh the matching hashes. CI builds
# linux/amd64 only; the arm64 hashes keep local builds on arm64 machines
# working.
ARG TARGETARCH
ARG MISE_VERSION=2026.10.21
ARG MISE_SHA256_AMD64=ccfe12d7a62c6fb9def2a20db1f210f13a51de881f21fd8c85db4b6312405d07
ARG MISE_SHA256_ARM64=a7c96627e56c075543fe1c1aafeb289d2588d6ddfd4d705fce4ae140c57e190c
ARG RUSTUP_VERSION=1.29.2
ARG RUSTUP_SHA256_AMD64=5be191e8c70a5007074254cb74d78dbfdd25cd5a61c27de7b8e5410122ec24f4
ARG RUSTUP_SHA256_ARM64=a9c168dbea81a84671c6b7a5c1795cb0eb699020110d107ddfca427bd797e697
ARG RUST_VERSION=1.99.1

# Rust: the pinned stable toolchain under a system RUSTUP_HOME, with the
# rustup proxies (cargo, rustc, rustfmt, clippy, rust-analyzer) in
# /usr/local/share/cargo/bin. Users' CARGO_HOME (registry cache, cargo
# install) is ~/.cargo on the home volume.
ENV RUSTUP_HOME=/usr/local/share/rustup
RUN case "${TARGETARCH}" in \
      amd64) mise_arch=x64 mise_sum="${MISE_SHA256_AMD64}" \
        rust_triple=x86_64-unknown-linux-gnu rustup_sum="${RUSTUP_SHA256_AMD64}" ;; \
      arm64) mise_arch=arm64 mise_sum="${MISE_SHA256_ARM64}" \
        rust_triple=aarch64-unknown-linux-gnu rustup_sum="${RUSTUP_SHA256_ARM64}" ;; \
      *) echo "unsupported architecture: ${TARGETARCH}" >&2; exit 1 ;; \
    esac \
    && curl -fsSL -o /usr/local/bin/mise \
      "https://github.com/jdx/mise/releases/download/v${MISE_VERSION}/mise-v${MISE_VERSION}-linux-${mise_arch}" \
    && echo "${mise_sum}  /usr/local/bin/mise" | sha256sum -c - \
    && chmod 0755 /usr/local/bin/mise \
    && curl -fsSL -o /tmp/rustup-init \
      "https://static.rust-lang.org/rustup/archive/${RUSTUP_VERSION}/${rust_triple}/rustup-init" \
    && echo "${rustup_sum}  /tmp/rustup-init" | sha256sum -c - \
    && chmod 0755 /tmp/rustup-init \
    && CARGO_HOME=/usr/local/share/cargo /tmp/rustup-init -y --no-modify-path \
      --profile minimal --default-toolchain "${RUST_VERSION}" \
      --component rustfmt,clippy,rust-analyzer,rust-src \
    && rm -rf /tmp/rustup-init /usr/local/share/cargo/registry

# No install statistics to mise-versions and no mise release check; no update
# checks or telemetry from the coding agents (the same switches as the agents
# VM, docs/openchamber.md) or chrome-devtools-mcp. The init script sets the
# agents' file-based switches in the home volume.
ENV MISE_USE_VERSIONS_HOST_TRACK=false \
    MISE_DISABLE_UPDATE_WARNING=true \
    DISABLE_UPDATES=1 \
    DISABLE_TELEMETRY=1 \
    PI_SKIP_VERSION_CHECK=1 \
    CHROME_DEVTOOLS_MCP_NO_USAGE_STATISTICS=1 \
    CHROME_DEVTOOLS_MCP_NO_UPDATE_CHECKS=1 \
    PLAYWRIGHT_BROWSERS_PATH=/opt/ms-playwright

COPY mise.toml /etc/mise/config.toml
ENV PATH=/usr/local/share/mise/shims:$PATH
RUN mise install --system --yes \
    && mise reshim --system \
    && playwright install --with-deps chromium \
    && playwright-cli install-browser chromium \
    && rm -rf /var/lib/apt/lists/* /root/.cache /root/.npm /tmp/*

COPY --chmod=0755 workspace-init.sh /usr/local/bin/homeworld-workspace-init

RUN useradd coder --create-home --shell /bin/bash --uid 1000 --user-group

# User installs (mise per-project toolchains, cargo install, npm -g, pipx)
# land in the home volume and win over the image's.
ENV PATH=/home/coder/.local/bin:/home/coder/.cargo/bin:/home/coder/.local/share/mise/shims:/usr/local/share/mise/shims:/usr/local/share/cargo/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    CARGO_HOME=/home/coder/.cargo \
    NPM_CONFIG_PREFIX=/home/coder/.local

USER 1000:1000
WORKDIR /home/coder
