#!/usr/bin/env bash
# kind nodes default to 128 inotify instances; Argo repo-server and Envoy
# die with "too many open files" / inotify_init1 EMFILE. Rootless Docker
# cannot write these sysctls from inside the node; raise them on the
# Linux VM (Lima) instead. This hook still tries, and drops spare
# CoreDNS replicas either way.
set -euo pipefail
CLUSTER="${KIND_CLUSTER_NAME:-homeworld-e2e}"
for node in $(kind get nodes --name "${CLUSTER}"); do
  if docker exec "${node}" sysctl -w fs.inotify.max_user_instances=1024 \
      fs.inotify.max_user_watches=524288; then
    echo "[raise-inotify-limits] raised on ${node}"
  else
    echo "[raise-inotify-limits] WARN cannot sysctl ${node} (rootless docker?); continuing"
  fi
done
if kubectl get deploy coredns -n kube-system >/dev/null 2>&1; then
  kubectl scale deploy/coredns -n kube-system --replicas=1
  echo "[raise-inotify-limits] coredns replicas=1"
fi
