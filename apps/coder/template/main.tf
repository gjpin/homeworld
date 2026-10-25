# Kubernetes workspace template for the homeworld cluster, adapted from
# upstream's examples/templates/kubernetes. Pushed by hand with
# `coder templates push` (docs/coder.md); Argo CD does not read this
# directory.
#
# Workspaces land in the coder-workspaces namespace, which enforces the
# Restricted Pod Security Standard and the network policies in
# apps/coder/workspaces/: no ingress, egress to coder.homeworld.internal,
# Forgejo, and the internet on 22/80/443.

terraform {
  required_providers {
    coder = {
      source  = "coder/coder"
      version = "2.19.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "3.4.0"
    }
  }
}

provider "coder" {}

# coderd runs in-cluster: the provider authenticates with the coder service
# account, whose Role covers Pods, PVCs, and Deployments in
# coder-workspaces only.
provider "kubernetes" {}

locals {
  namespace = "coder-workspaces"
  image     = "docker.io/codercom/example-base:ubuntu-20261019"
  home      = "/home/coder"
  # Public roots plus the Homeworld CA, assembled at container start; see
  # the dev container's command.
  ca_bundle = "/tmp/ca-certificates.crt"
  # Language toolchains come from mise in the home volume, so one image
  # serves every project (docs/coder.md). Renovate bumps the version and
  # scripts/refresh-mise-sha.sh the matching linux-x64 binary hash.
  mise_version = "2026.10.19"
  mise_sha256  = "3162760f40b6b5f706c60641e4ef5ee7322bc6c54f72fc26a7111b337aa18d9d"

  labels = {
    "app.kubernetes.io/name"     = "coder-workspace"
    "app.kubernetes.io/instance" = "coder-workspace-${data.coder_workspace.me.id}"
    "app.kubernetes.io/part-of"  = "coder"
    "com.coder.resource"         = "true"
    "com.coder.workspace.id"     = data.coder_workspace.me.id
    "com.coder.workspace.name"   = data.coder_workspace.me.name
    "com.coder.user.id"          = data.coder_workspace_owner.me.id
    "com.coder.user.username"    = data.coder_workspace_owner.me.name
  }
}

data "coder_parameter" "cpu" {
  name         = "cpu"
  display_name = "CPU"
  description  = "CPU limit in cores"
  default      = "2"
  icon         = "/icon/memory.svg"
  mutable      = true
  option {
    name  = "2 Cores"
    value = "2"
  }
  option {
    name  = "4 Cores"
    value = "4"
  }
}

data "coder_parameter" "memory" {
  name         = "memory"
  display_name = "Memory"
  description  = "Memory limit in GB"
  default      = "4"
  icon         = "/icon/memory.svg"
  mutable      = true
  option {
    name  = "2 GB"
    value = "2"
  }
  option {
    name  = "4 GB"
    value = "4"
  }
  option {
    name  = "8 GB"
    value = "8"
  }
}

data "coder_parameter" "home_disk_size" {
  name         = "home_disk_size"
  display_name = "Home disk size"
  description  = "Size of the persistent /home/coder volume in GB"
  default      = "10"
  type         = "number"
  icon         = "/emojis/1f4be.png"
  mutable      = false
  validation {
    min = 1
    max = 50
  }
}

data "coder_workspace" "me" {}
data "coder_workspace_owner" "me" {}

resource "coder_agent" "main" {
  os   = "linux"
  arch = "amd64"

  env = {
    GIT_AUTHOR_NAME     = coalesce(data.coder_workspace_owner.me.full_name, data.coder_workspace_owner.me.name)
    GIT_AUTHOR_EMAIL    = data.coder_workspace_owner.me.email
    GIT_COMMITTER_NAME  = coalesce(data.coder_workspace_owner.me.full_name, data.coder_workspace_owner.me.name)
    GIT_COMMITTER_EMAIL = data.coder_workspace_owner.me.email
  }

  metadata {
    display_name = "CPU Usage"
    key          = "0_cpu_usage"
    script       = "coder stat cpu"
    interval     = 10
    timeout      = 1
  }

  metadata {
    display_name = "RAM Usage"
    key          = "1_ram_usage"
    script       = "coder stat mem"
    interval     = 10
    timeout      = 1
  }

  metadata {
    display_name = "Home Disk"
    key          = "2_home_disk"
    script       = "coder stat disk --path $${HOME}"
    interval     = 60
    timeout      = 1
  }
}

# Seeds the home volume on first start and installs the pinned mise binary.
# Project toolchains come from each repository's mise.toml or
# .tool-versions; the shims directory is on the container PATH, so
# terminals, code-server extensions, and Coder Agents tool calls all resolve
# the project's versions.
resource "coder_script" "mise" {
  agent_id           = coder_agent.main.id
  display_name       = "mise"
  icon               = "/icon/terminal.svg"
  run_on_start       = true
  start_blocks_login = true
  script             = <<-EOT
    #!/usr/bin/env bash
    set -euo pipefail

    # The home volume hides the image's /home/coder: copy the skeleton
    # dotfiles once.
    if [ ! -f ~/.init_done ]; then
      cp -rT /etc/skel ~
      touch ~/.init_done
    fi

    mise=~/.local/bin/mise
    if ! "$mise" --version 2>/dev/null | grep -q '^${local.mise_version} '; then
      echo "Installing mise ${local.mise_version}"
      mkdir -p ~/.local/bin
      tmp="$(mktemp)"
      curl -fsSL -o "$tmp" \
        https://github.com/jdx/mise/releases/download/v${local.mise_version}/mise-v${local.mise_version}-linux-x64
      echo "${local.mise_sha256}  $tmp" | sha256sum -c -
      install -m 0755 "$tmp" "$mise"
      rm -f "$tmp"
    fi

    # Interactive shells also load each project's [env] and tasks.
    if ! grep -qF 'mise activate bash' ~/.bashrc; then
      echo 'eval "$(~/.local/bin/mise activate bash)"' >>~/.bashrc
    fi

    # Tools pinned in the global config (~/.config/mise/config.toml).
    cd ~
    "$mise" install --yes || echo "mise install failed; run it again from a terminal"
    "$mise" reshim
  EOT
}

# https://registry.coder.com/modules/coder/code-server
module "code-server" {
  count    = data.coder_workspace.me.start_count
  source   = "registry.coder.com/coder/code-server/coder"
  version  = "1.6.0"
  agent_id = coder_agent.main.id
  folder   = local.home
  # Served on its own origin under *.coder.homeworld.internal.
  subdomain = true
  # code-server's usage telemetry and its update check against GitHub.
  additional_args = "--disable-telemetry --disable-update-check"
  # Installed from Open VSX. hverlin.mise-vscode points the
  # language extensions at the project's mise toolchains.
  extensions = [
    "hverlin.mise-vscode",
    "golang.go",
    "ms-python.python",
    "dbaeumer.vscode-eslint",
    "esbenp.prettier-vscode",
  ]
  # Extension telemetry; extension update checks and auto-updates stay on.
  machine_settings = {
    "telemetry.telemetryLevel" = "off"
  }
}

resource "kubernetes_persistent_volume_claim_v1" "home" {
  metadata {
    name      = "coder-${data.coder_workspace.me.id}-home"
    namespace = local.namespace
    labels = merge(local.labels, {
      "app.kubernetes.io/name"     = "coder-pvc"
      "app.kubernetes.io/instance" = "coder-pvc-${data.coder_workspace.me.id}"
    })
    annotations = {
      "com.coder.user.email" = data.coder_workspace_owner.me.email
    }
  }
  wait_until_bound = false
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "longhorn-crypto"
    resources {
      requests = {
        storage = "${data.coder_parameter.home_disk_size.value}Gi"
      }
    }
  }
}

resource "kubernetes_deployment_v1" "main" {
  count = data.coder_workspace.me.start_count
  depends_on = [
    kubernetes_persistent_volume_claim_v1.home
  ]
  wait_for_rollout = false
  metadata {
    # Named after the owner and workspace (the home PVC keeps the id) so the
    # upstream Grafana dashboards' pod=~"$workspace_name" panels resolve.
    name      = "coder-${lower(data.coder_workspace_owner.me.name)}-${lower(data.coder_workspace.me.name)}"
    namespace = local.namespace
    labels    = local.labels
    annotations = {
      "com.coder.user.email" = data.coder_workspace_owner.me.email
    }
  }

  spec {
    replicas = 1
    selector {
      match_labels = local.labels
    }
    strategy {
      type = "Recreate"
    }

    template {
      metadata {
        labels = local.labels
      }
      spec {
        # gVisor Pods keep the host user namespace (gVisor cannot join a pod
        # user namespace); the sandbox kernel is their isolation boundary.
        runtime_class_name              = "gvisor"
        automount_service_account_token = false
        # The agent binary matches coder_agent.main.arch; the cluster also
        # has an aarch64 node.
        node_selector = {
          "kubernetes.io/arch" = "amd64"
        }

        security_context {
          run_as_user            = 1000
          run_as_group           = 1000
          run_as_non_root        = true
          fs_group               = 1000
          fs_group_change_policy = "OnRootMismatch"
          seccomp_profile {
            type = "RuntimeDefault"
          }
        }

        container {
          name              = "dev"
          image             = local.image
          image_pull_policy = "IfNotPresent"
          # The agent init script downloads the agent binary from
          # https://coder.homeworld.internal with curl, so the Homeworld CA
          # has to be in the bundle before it runs. The bundle is rebuilt
          # from the mounted ConfigMap on every start.
          command = ["sh", "-c", <<-EOT
            cat /etc/ssl/certs/ca-certificates.crt /etc/homeworld-ca/ca.crt > ${local.ca_bundle}
            ${coder_agent.main.init_script}
          EOT
          ]
          security_context {
            allow_privilege_escalation = false
            run_as_non_root            = true
            capabilities {
              drop = ["ALL"]
            }
          }
          env {
            name  = "CODER_AGENT_TOKEN"
            value = coder_agent.main.token
          }
          # curl (the init script), git (Forgejo over HTTPS), and OpenSSL
          # clients read the combined bundle; the Go agent adds the CA
          # directory to its system roots; Node.js appends the CA.
          env {
            name  = "CURL_CA_BUNDLE"
            value = local.ca_bundle
          }
          env {
            name  = "GIT_SSL_CAINFO"
            value = local.ca_bundle
          }
          env {
            name  = "SSL_CERT_FILE"
            value = local.ca_bundle
          }
          env {
            name  = "SSL_CERT_DIR"
            value = "/etc/homeworld-ca"
          }
          env {
            name  = "NODE_EXTRA_CA_CERTS"
            value = "/etc/homeworld-ca/ca.crt"
          }
          # mise and its shims ahead of the image's default PATH, for every
          # process the agent starts.
          env {
            name  = "PATH"
            value = "${local.home}/.local/bin:${local.home}/.local/share/mise/shims:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
          }
          # Download statistics sent to mise-versions after each install,
          # and the release check behind `mise version`.
          env {
            name  = "MISE_USE_VERSIONS_HOST_TRACK"
            value = "false"
          }
          env {
            name  = "MISE_DISABLE_UPDATE_WARNING"
            value = "true"
          }
          resources {
            requests = {
              "cpu"               = "250m"
              "memory"            = "512Mi"
              "ephemeral-storage" = "256Mi"
            }
            limits = {
              "cpu"               = data.coder_parameter.cpu.value
              "memory"            = "${data.coder_parameter.memory.value}Gi"
              "ephemeral-storage" = "8Gi"
            }
          }
          volume_mount {
            mount_path = local.home
            name       = "home"
            read_only  = false
          }
          volume_mount {
            mount_path = "/etc/homeworld-ca"
            name       = "homeworld-ca"
            read_only  = true
          }
        }

        volume {
          name = "home"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim_v1.home.metadata[0].name
            read_only  = false
          }
        }

        volume {
          name = "homeworld-ca"
          config_map {
            name = "homeworld-ca"
          }
        }

        affinity {
          pod_anti_affinity {
            preferred_during_scheduling_ignored_during_execution {
              weight = 1
              pod_affinity_term {
                topology_key = "kubernetes.io/hostname"
                label_selector {
                  match_expressions {
                    key      = "app.kubernetes.io/name"
                    operator = "In"
                    values   = ["coder-workspace"]
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}
