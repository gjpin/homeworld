#!/usr/bin/env bash
# Force every homeworld Application to fetch HEAD. Argo's 180s reconcile
# plus a warm repo-server cache leaves wait-argo sitting on a stale SHA
# after --keep-cluster restages git://host.docker.internal:9418.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
GENERATED="${ROOT}/e2e/examples/.generated/app-of-apps.yaml"
KUBECTL=(kubectl --request-timeout=25s)

log() { printf '[refresh-argo] %s\n' "$*" >&2; }

kretry() {
  local tries=5 n=0
  while (( n < tries )); do
    if "${KUBECTL[@]}" "$@"; then
      return 0
    fi
    n=$((n + 1))
    log "retry ${n}/${tries}: kubectl $*"
    sleep $((n * 2))
  done
  return 1
}

# Argo's settings informer only lists ConfigMaps labeled part-of=argocd.
# A live patch of health lua that replaces the object leaves apps Unknown.
kretry label cm argocd-cm -n argocd \
  app.kubernetes.io/name=argocd-cm \
  app.kubernetes.io/part-of=argocd \
  app.kubernetes.io/instance=argocd \
  --overwrite >/dev/null || log "WARN could not label argocd-cm"

# Restage rewrites Application specs (ignoreDifferences, syncOptions). Refresh
# annotations do not update those fields; apply the generated parent CRs first.
if [[ -f "${GENERATED}" ]]; then
  kretry apply -f "${GENERATED}" >/dev/null
  log "applied ${GENERATED}"
  # kubectl apply does not delete Applications rewrite-staging omitted.
  # Delete those parent CRs so Argo prunes their pods and frees inotify.
  wanted="$(python3 -c '
import pathlib, re, sys
text = pathlib.Path(sys.argv[1]).read_text()
for doc in re.split(r"(?m)^---\s*$", text):
    m = re.search(r"(?m)^metadata:\n  name: (\S+)", doc)
    if m:
        print(m.group(1))
' "${GENERATED}")"
  live="$(kretry get applications -n argocd -l app.kubernetes.io/part-of=homeworld -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' || true)"
  while IFS= read -r app; do
    [[ -z "${app}" ]] && continue
    if printf '%s\n' "${wanted}" | grep -qx "${app}"; then
      continue
    fi
    log "pruning omitted application ${app}"
    # Delete the parent's nested child Applications first, while the API is
    # calm and their status.resources lists are valid. Argo's cascade prune
    # of a child Application CR skips the child's own resources-finalizer,
    # which orphans the child's workloads (observed with openobserve-app).
    src_path="$(kretry get application "${app}" -n argocd -o jsonpath='{.spec.source.path}' || true)"
    if [[ -n "${src_path}" ]]; then
      children="$(python3 -c '
import json, subprocess, sys
path = sys.argv[1]
apps = json.loads(subprocess.check_output([
    "kubectl", "--request-timeout=25s", "get", "applications", "-n", "argocd",
    "-o", "json",
], stderr=subprocess.DEVNULL)).get("items", [])
for a in apps:
    src = (a.get("spec") or {}).get("source") or {}
    child_path = src.get("path") or ""
    if child_path.startswith(path + "/"):
        print(a["metadata"]["name"])
' "${src_path}" || true)"
      while IFS= read -r child; do
        [[ -z "${child}" ]] && continue
        log "pruning nested application ${child}"
        kretry delete application "${child}" -n argocd --wait=false >/dev/null \
          || log "WARN delete ${child} failed"
        sleep 1
      done <<<"${children}"
    fi
    # Drop part-of=homeworld first: wait-argo selects on that label, and a
    # Terminating Application with resources-finalizer stays Progressing.
    kretry label application "${app}" -n argocd app.kubernetes.io/part-of- --overwrite >/dev/null \
      || log "WARN unlabel ${app} failed"
    kretry delete application "${app}" -n argocd --wait=false >/dev/null || log "WARN delete ${app} failed"
    sleep 1
  done <<<"${live}"
fi

# skipIfPresent bootstrap can leave ApplicationSet from an older helm install.
kretry scale deploy/argocd-argocd-applicationset-controller -n argocd --replicas=0 >/dev/null \
  || log "WARN could not scale applicationset to 0"

# Nested helm Applications (argocd, rustfs-operator, ...) do not
# carry part-of=homeworld. Hard-refresh every Application so a restage that
# rewrites git history does not leave them fetching a vanished SHA. Force a
# sync only on the apps whose manifests must land immediately; nested
# auto-sync follows. Patching operation.sync on every parent at once OOMs
# the application-controller on kind.
#
# Annotate one-by-one with retries: a kind apiserver TLS timeout must not
# fail the suite after the parent CRs already applied.
apps="$(kretry get applications -n argocd -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')"
force_apps="argocd-app authelia-app authelia"
n=0
fail=0
i=0
while IFS= read -r app; do
  [[ -z "${app}" ]] && continue
  if kretry annotate application "${app}" -n argocd argocd.argoproj.io/refresh=hard --overwrite >/dev/null; then
    n=$((n + 1))
  else
    log "WARN hard-refresh ${app} failed after retries"
    fail=$((fail + 1))
  fi
  i=$((i + 1))
  if (( i % 5 == 0 )); then
    sleep 1
  fi
done <<<"${apps}"
s=0
for app in ${force_apps}; do
  kretry get application "${app}" -n argocd >/dev/null 2>&1 || continue
  "${KUBECTL[@]}" patch application "${app}" -n argocd --type json -p '[{"op":"remove","path":"/operation"}]' >/dev/null 2>&1 || true
  if kretry patch application "${app}" -n argocd --type merge -p '{"operation":{"initiatedBy":{"username":"e2e"},"sync":{"revision":"HEAD","syncOptions":["CreateNamespace=true","SkipDryRunOnMissingResource=true","ServerSideApply=true","RespectIgnoreDifferences=true","SkipHooks=true"]}}}' >/dev/null; then
    s=$((s + 1))
  else
    log "WARN force-sync ${app} failed after retries"
    fail=$((fail + 1))
  fi
  sleep 1
done
log "hard-refreshed ${n} applications, forced sync on ${s} apps (${fail} warnings)"
# Parent CRs are applied; wait-argo can proceed even if some annotates missed.
exit 0
