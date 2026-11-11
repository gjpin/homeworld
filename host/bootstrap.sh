#!/bin/bash
# Variables named in ask/ask_secret calls are assigned through printf -v.
# shellcheck disable=SC2154
# One-time node bootstrap (docs/k3s.md). Run as root on a fresh Fedora Server
# install, from a checkout of this repository:
#
#   sudo host/bootstrap.sh <homeworld-ryzen|homeworld-corebox|homeworld-dragon> [--treat-as-ssd SERIAL]...
#
# It validates the profile against the hardware, records the node's local
# settings, grows the root LV, binds the LUKS root to Tang, lets you choose
# the data disks (host/disks.sh, which takes the extra options), applies the host
# configuration, installs the pinned k3s, and on the first server hands the
# cluster to Argo CD through the k3s auto-deploying manifests directory.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "$here")
profile=${1:-}
[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }
[ -f "$here/nodes/$profile.env" ] || { echo "usage: $0 <$(cd "$here/nodes" && ls | sed 's/\.env$//' | paste -sd'|')>" >&2; exit 1; }
. "$here/cluster.env"
. "$here/versions.env"
# shellcheck source=/dev/null
. "$here/nodes/$profile.env"

log() { echo; echo "== $*"; }
ask() { # ask VAR PROMPT [DEFAULT]
  local reply
  read -r -p "$2${3:+ [$3]}: " reply
  printf -v "$1" '%s' "${reply:-${3:-}}"
}
ask_secret() {
  local reply
  read -r -s -p "$2: " reply
  echo
  printf -v "$1" '%s' "$reply"
}

# --- hardware ---------------------------------------------------------------
log "Checking the $profile profile against this machine"
vendor=$(lscpu | awk -F: '/^Vendor ID/ && !done {gsub(/^[ \t]+/, "", $2); print $2; done = 1}')
mem_gib=$(awk '/^MemTotal/ {print int($2 / 1024 / 1024)}' /proc/meminfo)
[ "$(uname -m)" = "$EXPECTED_ARCH" ] || { echo "architecture $(uname -m), profile expects $EXPECTED_ARCH" >&2; exit 1; }
[ "$vendor" = "$EXPECTED_CPU_VENDOR" ] || { echo "CPU vendor $vendor, profile expects $EXPECTED_CPU_VENDOR" >&2; exit 1; }
[ "$mem_gib" -ge "$MIN_MEMORY_GIB" ] || { echo "${mem_gib} GiB RAM, profile expects at least $MIN_MEMORY_GIB" >&2; exit 1; }
. /etc/os-release
[ "$ID" = fedora ] || { echo "not Fedora" >&2; exit 1; }

# Password SSH is turned off below: make sure the admin can still log in.
admin=${SUDO_USER:-}
if [ -z "$admin" ] || [ ! -s "$(getent passwd "$admin" | cut -d: -f6)/.ssh/authorized_keys" ]; then
  echo "run through sudo as a user whose ~/.ssh/authorized_keys holds your key" >&2
  exit 1
fi

# --- node-local settings ----------------------------------------------------
mkdir -p /etc/homeworld /etc/rancher/k3s
if [ ! -f /etc/homeworld/env ]; then
  log "Node settings (kept in /etc/homeworld/env, never in git)"
  default_ip=$(ip -o -4 route get 1.1.1.1 | awk '{for (i = 1; i < NF; i++) if ($i == "src") print $(i + 1)}')
  ask node_ip "This node's LAN address (its static DHCP lease)" "$default_ip"
  ask node_ips "All three node addresses, space-separated"
  ask vm_host_ip "Address of the node running the agents VM (homeworld-ryzen profile)"
  ask role "First server of a new cluster (init) or joining one (join)" join
  case "$role" in init | join) ;; *) echo "role must be init or join" >&2; exit 1 ;; esac
  # k3s needs the domain for its first start (authentication.yaml), before
  # this script reads Infisical.
  ask base_domain "Cluster domain (Infisical /argocd/BASE_DOMAIN)"
  case "$base_domain" in
    *.*) ;;
    *) echo "$base_domain is not a domain" >&2; exit 1 ;;
  esac
  case "$base_domain" in
    *[!a-z0-9.-]* | .* | *. | *..* | base-domain.invalid) echo "$base_domain is not a domain" >&2; exit 1 ;;
  esac
  cat >/etc/homeworld/env <<EOF
NODE_IP=$node_ip
NODE_IPS="$node_ips"
AGENTS_VM_HOST_IP=$vm_host_ip
K3S_ROLE=$role
BASE_DOMAIN=$base_domain
EOF
  chmod 0644 /etc/homeworld/env
fi
echo "PROFILE=$profile" >/etc/homeworld/node.env
. /etc/homeworld/env

if [ ! -s /etc/rancher/k3s/token ]; then
  if [ "$K3S_ROLE" = init ]; then
    (umask 077 && openssl rand -hex 32 >/etc/rancher/k3s/token)
    echo "Cluster token (needed to join the other servers): $(cat /etc/rancher/k3s/token)"
  else
    ask_secret token "Cluster token (cat /etc/rancher/k3s/token on the first server)"
    (umask 077 && printf '%s\n' "$token" >/etc/rancher/k3s/token)
  fi
fi

if [ "$AGENTS_VM" = 1 ] && [ ! -f /etc/homeworld/agents-vm.env ]; then
  log "Agents VM secrets (read-only Infisical machine identity for /agents/*)"
  ask client_id "Infisical Universal Auth client ID"
  ask_secret client_secret "Infisical Universal Auth client secret"
  ask project_id "Infisical project ID (project settings)"
  echo "SSH public keys for the VM's agent user, one per line; end with an empty line:"
  keys=""
  while read -r line && [ -n "$line" ]; do keys+="$line"$'\n'; done
  (
    umask 077
    {
      echo "AGENTS_INFISICAL_CLIENT_ID=$client_id"
      echo "AGENTS_INFISICAL_CLIENT_SECRET=$client_secret"
      echo "AGENTS_INFISICAL_PROJECT_ID=$project_id"
      printf "AGENT_SSH_KEYS='%s'\n" "$keys"
    } >/etc/homeworld/agents-vm.env
  )
fi

# --- disk ---------------------------------------------------------------------
# Fedora Server's automatic partitioning leaves most of the volume group
# free; it holds the container images, etcd and, unless disks.sh below moves
# them, Longhorn (/var/lib/longhorn) and the agents VM disks.
root_dev=$(findmnt -no SOURCE /)
if lvs "$root_dev" >/dev/null 2>&1; then
  vg=$(lvs --noheadings -o vg_name "$root_dev" | tr -d ' ')
  if [ "$(vgs --noheadings --units b -o vg_free "$vg" | tr -dc 0-9)" -gt $((1024 * 1024 * 1024)) ]; then
    log "Growing $root_dev to the whole volume group"
    lvextend -r -l +100%FREE "$root_dev"
  fi
fi

log "Binding the LUKS root to Tang ($TANG_URL)"
dnf -y -q install clevis-luks clevis-dracut
# Only what root sits on: any other encrypted disk is the data disk step's, or
# not ours at all.
for dev in $(lsblk -nsrpo NAME,FSTYPE "$(findmnt -nvo SOURCE /)" | awk '$2 == "crypto_LUKS" {print $1}'); do
  if clevis luks list -d "$dev" 2>/dev/null | grep tang >/dev/null; then
    echo "$dev: already bound"
    continue
  fi
  echo "$dev: compare the key thumbprint with the router's (docs/openwrt.md), then enter the LUKS passphrase"
  clevis luks bind -d "$dev" tang "{\"url\":\"$TANG_URL\"}"
done
grubby --update-kernel=ALL --args=rd.neednet=1
dracut -f --regenerate-all

# --- data disks -------------------------------------------------------------
log "Choosing the data disks"
"$here/disks.sh" "${@:2}"

# --- host configuration and k3s ---------------------------------------------
log "Applying the host configuration"
"$here/apply.sh"

if [ ! -x /usr/local/bin/k3s ]; then
  log "Installing k3s $K3S_VERSION"
  curl -fsSL -o /tmp/k3s-install.sh "https://raw.githubusercontent.com/k3s-io/k3s/${K3S_VERSION/+/%2B}/install.sh"
  INSTALL_K3S_VERSION=$K3S_VERSION INSTALL_K3S_SKIP_SELINUX_RPM=true INSTALL_K3S_SKIP_START=true \
    INSTALL_K3S_EXEC=server sh /tmp/k3s-install.sh
  rm -f /tmp/k3s-install.sh
  # The installer skips its own chcon when the SELinux RPM step is skipped.
  restorecon -v /usr/local/bin/k3s
  rm -f /var/lib/homeworld/reboot-required
  systemctl start k3s
fi
until k3s kubectl get node "$(hostname)" >/dev/null 2>&1; do sleep 5; done
"$here/apply.sh"

[ "$K3S_ROLE" = init ] || { log "Joined. Done."; exit 0; }

# --- first server: hand the cluster to Argo CD --------------------------------
manifests=/var/lib/rancher/k3s/server/manifests
install -m 0600 "$here/files/manifests/homeworld-runtimeclasses.yaml" "$manifests/"
if k3s kubectl -n argocd get application argocd >/dev/null 2>&1; then
  log "Argo CD already runs; nothing to hand over."
  exit 0
fi

log "Rendering the bootstrap manifests"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
helm_arch=$(case "$(uname -m)" in x86_64) echo amd64 ;; aarch64) echo arm64 ;; esac)
curl -fsSL -o "$work/helm.tgz" "https://get.helm.sh/helm-$HELM_VERSION-linux-$helm_arch.tar.gz"
echo "$(curl -fsSL "https://get.helm.sh/helm-$HELM_VERSION-linux-$helm_arch.tar.gz.sha256sum" | cut -d' ' -f1)  $work/helm.tgz" | sha256sum -c --quiet -
tar -xzf "$work/helm.tgz" -C "$work" --strip-components=1 "linux-$helm_arch/helm"
render() { k3s kubectl kustomize --enable-helm --helm-command "$work/helm" "$1"; }

# Namespaces with the labels Argo CD would set when creating them itself
# (apps/app-of-apps.yaml managedNamespaceMetadata).
namespace() { # namespace NAME ROOT-APP
  yq -n ".apiVersion = \"v1\" | .kind = \"Namespace\" | .metadata.name = \"$1\"" >"$work/ns.yaml"
  yq "select(.metadata.name == \"$2\") | .spec.syncPolicy.managedNamespaceMetadata" "$repo/apps/app-of-apps.yaml" >"$work/meta.yaml"
  yq '.metadata *= load("'"$work/meta.yaml"'")' "$work/ns.yaml"
}

# Cilium CRDs from the tag matching the pinned chart.
cilium_tag=$(yq '.spec.source.targetRevision' "$repo/apps/cilium/0_crds.yaml")
cilium_crds=$(yq '.spec.source.path' "$repo/apps/cilium/0_crds.yaml")
for f in $(curl -fsSL "https://api.github.com/repos/cilium/cilium/contents/$cilium_crds?ref=$cilium_tag" | jq -r '.[].name | select(endswith(".yaml"))'); do
  echo "---"
  curl -fsSL "https://raw.githubusercontent.com/cilium/cilium/$cilium_tag/$cilium_crds/$f"
done >"$work/homeworld-cilium-crds.yaml"
namespace cilium cilium-app >"$work/homeworld-cilium-namespace.yaml"
render "$repo/apps/cilium/helm" >"$work/homeworld-cilium.yaml"

# Minimal Argo CD: the chart pinned by apps/argocd with bootstrap values,
# plus the homeworld Config Management Plugin from apps/argocd/helm, which
# renders every Application (docs/argocd.md).
mkdir "$work/argocd"
yq '.helmCharts[0] |= (.valuesFile = "values.yaml" | del(.valuesInline)) | {"apiVersion": .apiVersion, "kind": .kind, "helmCharts": [.helmCharts[0]]}' \
  "$repo/apps/argocd/helm/kustomization.yaml" >"$work/argocd/kustomization.yaml"
yq '{"configs": {"cmp": .configs.cmp}, "repoServer": {"extraContainers": .repoServer.extraContainers, "volumes": .repoServer.volumes}}' \
  "$repo/apps/argocd/helm/values.yaml" >"$work/argocd-plugin.yaml"
# shellcheck disable=SC2016 # a yq expression, not a shell one
yq eval-all '. as $item ireduce ({}; . * $item)' \
  "$repo/bootstrap/argocd-values.yaml" "$work/argocd-plugin.yaml" >"$work/argocd/values.yaml"
namespace argocd argocd-app >"$work/homeworld-argocd-namespace.yaml"
render "$work/argocd" >"$work/homeworld-argocd.yaml"
cp "$repo/apps/app-of-apps.yaml" "$work/homeworld-root.yaml"

log "External Secrets credentials (Infisical Universal Auth, docs/secrets.md)"
ask es_client_id "Client ID"
ask_secret es_client_secret "Client secret"
{
  namespace external-secrets external-secrets-app
  echo "---"
  k3s kubectl create secret generic universal-auth-credentials --namespace external-secrets \
    --from-literal=clientId="$es_client_id" --from-literal=clientSecret="$es_client_secret" \
    --dry-run=client -o yaml
} >"$work/homeworld-external-secrets.yaml"

# The cluster domain lives only in Infisical (/argocd/BASE_DOMAIN). The
# repo-server cannot render anything without it, External Secrets included,
# so read it once with the same machine identity and seed the Secret that
# apps/argocd/-1_secrets.yaml adopts afterwards.
log "Reading the cluster domain from Infisical"
store="$repo/apps/external-secrets/2_secret_store.yaml"
infisical=$(yq '.spec.provider.infisical.hostAPI' "$store")
token=$(jq -n --arg id "$es_client_id" --arg secret "$es_client_secret" '{clientId: $id, clientSecret: $secret}' |
  curl -fsS -H 'Content-Type: application/json' -d @- "$infisical/api/v1/auth/universal-auth/login" | jq -r .accessToken)
domain=$(curl -fsS -G -H "Authorization: Bearer $token" \
  --data-urlencode "workspaceSlug=$(yq '.spec.provider.infisical.secretsScope.projectSlug' "$store")" \
  --data-urlencode "environment=$(yq '.spec.provider.infisical.secretsScope.environmentSlug' "$store")" \
  --data-urlencode secretPath=/argocd \
  "$infisical/api/v3/secrets/raw/BASE_DOMAIN" | jq -r .secret.secretValue)
case "$domain" in
  *.*) ;;
  *) echo "/argocd/BASE_DOMAIN in Infisical is not a domain" >&2; exit 1 ;;
esac
case "$domain" in
  *[!a-z0-9.-]* | .* | *. | *..*) echo "/argocd/BASE_DOMAIN in Infisical is not a domain" >&2; exit 1 ;;
esac
if [ "$domain" != "$BASE_DOMAIN" ]; then
  echo "/argocd/BASE_DOMAIN in Infisical ($domain) differs from BASE_DOMAIN in /etc/homeworld/env ($BASE_DOMAIN)" >&2
  exit 1
fi
echo "Cluster domain: $domain"
k3s kubectl create secret generic homeworld-domain --namespace argocd \
  --from-literal=BASE_DOMAIN="$domain" --dry-run=client -o yaml >"$work/homeworld-argocd-domain.yaml"

oneshot=(homeworld-cilium-crds homeworld-cilium-namespace homeworld-cilium
  homeworld-argocd-namespace homeworld-argocd-domain homeworld-argocd homeworld-root
  homeworld-external-secrets)
for f in "${oneshot[@]}"; do
  install -m 0600 "$work/$f.yaml" "$manifests/$f.yaml"
done

# The credentials file only has to live until k3s has applied it.
until k3s kubectl -n external-secrets get secret universal-auth-credentials >/dev/null 2>&1; do sleep 5; done
rm -f "$manifests/homeworld-external-secrets.yaml"

log "Waiting for Argo CD to adopt Cilium and itself"
synced() {
  [ "$(k3s kubectl -n argocd get application "$1" \
    -o jsonpath='{.status.sync.status}/{.status.health.status}' 2>/dev/null)" = Synced/Healthy ]
}
until synced cilium && synced argocd; do sleep 15; done

# Argo CD owns everything now. k3s re-applies files still present at every
# start, so remove the one-shot ones (deleting files or Addon objects never
# deletes the resources), then drop the bootstrap-only bundled Redis, which
# apps/argocd replaces with Valkey and therefore never adopts.
for f in "${oneshot[@]}"; do
  rm -f "$manifests/$f.yaml"
  k3s kubectl -n kube-system delete addon "$f" --ignore-not-found >/dev/null
done
yq -N 'select(.metadata.name | test("^argocd-redis")) | [.kind, (.metadata.namespace // "argocd"), .metadata.name] | join(" ")' \
  "$work/homeworld-argocd.yaml" | while read -r kind ns name; do
  if ! k3s kubectl -n "$ns" get "$kind" "$name" \
    -o jsonpath='{.metadata.annotations.argocd\.argoproj\.io/tracking-id}' 2>/dev/null | grep . >/dev/null; then
    k3s kubectl -n "$ns" delete "$kind" "$name" --ignore-not-found
  fi
done

log "Bootstrap complete. Join the other servers with host/bootstrap.sh <profile>."
