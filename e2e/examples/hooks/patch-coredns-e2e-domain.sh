#!/usr/bin/env bash
# Point *.${BASE_DOMAIN} at the Envoy Gateway ClusterIP so in-cluster
# clients (OpenCloud WOPI discovery, Collabora callbacks) resolve public
# hostnames. There is no external-dns on kind; CoreDNS otherwise forwards
# e2e.local to the Docker VM resolver, which times out.
set -euo pipefail

DOMAIN="${BASE_DOMAIN:-e2e.local}"

log() { printf '[patch-coredns-e2e-domain] %s\n' "$*"; }

wait_envoy_ip() {
  local deadline=$((SECONDS + 180)) ip
  while (( SECONDS < deadline )); do
    ip="$(kubectl -n envoy-gateway get svc \
      -l app.kubernetes.io/component=proxy,app.kubernetes.io/name=envoy \
      -o jsonpath='{range .items[?(@.spec.type=="LoadBalancer")]}{.spec.clusterIP}{"\n"}{end}' \
      2>/dev/null | awk 'NF && $1 != "None" {print; exit}')"
    if [[ -n "${ip}" ]]; then
      printf '%s' "${ip}"
      return 0
    fi
    sleep 3
  done
  log "timeout waiting for envoy-gateway LoadBalancer ClusterIP"
  return 1
}

ENVOY_IP="$(wait_envoy_ip)"
log "envoy ClusterIP=${ENVOY_IP} domain=${DOMAIN}"

python3 - "${ENVOY_IP}" "${DOMAIN}" <<'PY'
import json, subprocess, sys

ip, domain = sys.argv[1], sys.argv[2]
zone = domain if domain.endswith(".") else domain
cm = json.loads(
    subprocess.check_output(
        ["kubectl", "-n", "kube-system", "get", "cm", "coredns", "-o", "json"]
    )
)
core = cm["data"]["Corefile"]
block = (
    f"{zone}:53 {{\n"
    "    errors\n"
    "    template IN A {\n"
    "        match .*\n"
    f'        answer "{{{{ .Name }}}} 30 IN A {ip}"\n'
    "    }\n"
    "    template IN AAAA {\n"
    "        match .*\n"
    "        rcode NOERROR\n"
    "    }\n"
    "}\n"
)
if f"{zone}:53" in core:
    # Replace an existing stub so a changed ClusterIP is picked up.
    import re
    core = re.sub(
        rf"(?ms)^{re.escape(zone)}:53 \{{.*?\}}\n",
        block,
        core,
        count=1,
    )
else:
    core = block + core
if core == cm["data"]["Corefile"]:
    print("[patch-coredns-e2e-domain] Corefile already current")
    sys.exit(0)
cm["data"]["Corefile"] = core
path = "/tmp/homeworld-e2e-coredns.json"
with open(path, "w") as f:
    json.dump(
        {
            "apiVersion": "v1",
            "kind": "ConfigMap",
            "metadata": {"name": "coredns", "namespace": "kube-system"},
            "data": cm["data"],
        },
        f,
    )
subprocess.check_call(["kubectl", "apply", "-f", path])
print("[patch-coredns-e2e-domain] patched Corefile")
PY

# kind mounts the Corefile such that plugin/reload often misses ConfigMap
# updates; restart so the stub is actually served.
kubectl -n kube-system rollout restart deploy/coredns
kubectl -n kube-system rollout status deploy/coredns --timeout=90s
log "coredns restarted"
