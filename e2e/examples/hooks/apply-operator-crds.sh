#!/usr/bin/env bash
# Argo resource.exclusions skip all CRDs (Envoy Gateway VAP forbids
# re-applying Gateway API CRDs on --keep-cluster). ESO/Cilium/Envoy
# CRDs have their own hooks; install the remaining operator CRDs so
# CNPG/Grafana/Dragonfly/RustFS/cert-manager/ServiceMonitor CRs apply.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
PROM_VER="${PROMETHEUS_OPERATOR_VERSION:-v0.94.1}"
PROM_BASE="https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/${PROM_VER}/example/prometheus-operator-crd-full"

chart_dir() {
  local glob="$1"
  local match
  # Multiple downloaded versions can coexist (e.g. after a chart bump);
  # pick the latest so version bumps don't stale this hook.
  match="$(ls -d ${glob} 2>/dev/null | sort -V | tail -n 1)"
  if [[ -z "${match}" || ! -d "${match}" ]]; then
    echo "[apply-operator-crds] chart not found: ${glob}" >&2
    exit 1
  fi
  printf '%s' "${match}"
}

filter_crds() {
  python3 -c '
import re, sys
for part in re.split(r"(?m)^---\s*$", sys.stdin.read()):
    if re.search(r"(?m)^kind: CustomResourceDefinition\s*$", part):
        sys.stdout.write("---\n" + part.strip() + "\n")
'
}

apply_helm_crds() {
  local name="$1" chart="$2"
  shift 2
  helm template "${name}-crds" "${chart}" "$@" \
    | filter_crds \
    | kubectl apply --server-side --force-conflicts -f -
  echo "[apply-operator-crds] ${name} CRDs applied"
}

kubectl apply --server-side --force-conflicts \
  -f "${PROM_BASE}/monitoring.coreos.com_alertmanagerconfigs.yaml" \
  -f "${PROM_BASE}/monitoring.coreos.com_alertmanagers.yaml" \
  -f "${PROM_BASE}/monitoring.coreos.com_podmonitors.yaml" \
  -f "${PROM_BASE}/monitoring.coreos.com_probes.yaml" \
  -f "${PROM_BASE}/monitoring.coreos.com_prometheusagents.yaml" \
  -f "${PROM_BASE}/monitoring.coreos.com_prometheuses.yaml" \
  -f "${PROM_BASE}/monitoring.coreos.com_prometheusrules.yaml" \
  -f "${PROM_BASE}/monitoring.coreos.com_scrapeconfigs.yaml" \
  -f "${PROM_BASE}/monitoring.coreos.com_servicemonitors.yaml" \
  -f "${PROM_BASE}/monitoring.coreos.com_thanosrulers.yaml"
echo "[apply-operator-crds] prometheus-operator CRDs from ${PROM_VER}"

apply_helm_crds cert-manager \
  "$(chart_dir "${ROOT}/apps/cert-manager/helm/charts/cert-manager-*/cert-manager")" \
  --set crds.enabled=true --set crds.keep=true

apply_helm_crds cloudnative-pg \
  "$(chart_dir "${ROOT}/apps/cloudnative-pg/helm/charts/cloudnative-pg-*/cloudnative-pg")"

GRAFANA_CRDS="$(chart_dir "${ROOT}/apps/grafana-operator/helm/charts/grafana-operator-*/grafana-operator/charts/crds/crds")"
kubectl apply --server-side --force-conflicts -f "${GRAFANA_CRDS}"
echo "[apply-operator-crds] grafana-operator CRDs applied"

apply_helm_crds dragonfly-operator \
  "$(chart_dir "${ROOT}/apps/dragonfly-operator/helm/charts/dragonfly-operator-*/dragonfly-operator")"

# The OpenTelemetry Operator chart ships its CRDs as rendered templates
# (templates/admission-webhooks/operator-webhook.yaml embeds conf/crds via
# .Files.Get), so Kustomize's includeCRDs never captures them — and the kind
# bootstrap's argocd-cm resource.exclusions drops every CRD from Argo's sync
# (the Envoy Gateway VAP conflict), which leaves the operator crash-looping
# on "OpenTelemetryCollector CRDs are not present". Apply them here like the
# other operator CRDs. The rendered CRDs reference the admission webhook's
# CA through cert-manager injection; the operator only starts in wave 5,
# long after cert-manager (wave 3) has filled the caBundles.
apply_helm_crds opentelemetry-operator \
  "$(chart_dir "${ROOT}/apps/opentelemetry-operator/helm/charts/opentelemetry-operator-*")" \
  --set crds.create=true

RUSTFS_CRDS="${ROOT}/apps/rustfs-operator/helm/local-charts/rustfs-operator/crds"
# The vendored chart ships identical tenants.rustfs.com CRDs; skip tenant.yaml.
kubectl apply --server-side --force-conflicts \
  -f "${RUSTFS_CRDS}/tenant-crd.yaml" \
  -f "${RUSTFS_CRDS}/policybinding-crd.yaml"
echo "[apply-operator-crds] rustfs-operator CRDs applied"

DOCUMENTDB_CRDS="${ROOT}/apps/documentdb-operator/helm/local-charts/documentdb-operator/crds"
kubectl apply --server-side --force-conflicts -f "${DOCUMENTDB_CRDS}"
echo "[apply-operator-crds] documentdb-operator CRDs applied"

kubectl get crd \
  servicemonitors.monitoring.coreos.com \
  clusterissuers.cert-manager.io \
  clusters.postgresql.cnpg.io \
  grafanas.grafana.integreatly.org \
  dragonflies.dragonflydb.io \
  tenants.rustfs.com \
  opentelemetrycollectors.opentelemetry.io \
  dbs.documentdb.io \
  backups.documentdb.io \
  scheduledbackups.documentdb.io
