#!/usr/bin/env bash
# Point *.${BASE_DOMAIN} at the Envoy Gateway ClusterIP so in-cluster
# clients (OpenCloud WOPI discovery, Collabora callbacks) resolve public
# hostnames. There is no external-dns on kind; CoreDNS otherwise forwards
# e2e.local to the Docker VM resolver, which times out.
set -euo pipefail

DOMAIN="${BASE_DOMAIN:-e2e.local}"
WAIT_IP_SECS="${WAIT_IP_SECS:-600}"

log() { printf '[patch-coredns-e2e-domain] %s\n' "$*"; }

wait_envoy_ip() {
  # The Gateway only becomes Programmed (and the envoy LoadBalancer Service
  # only appears) once cert-manager has issued the listener certificates, so
  # the full wave chain has to light up first; 480s covers a cold node.
  local deadline=$((SECONDS + WAIT_IP_SECS)) ip
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
def strip_zone(core: str, zone: str) -> str:
    """Remove every `<zone>:53 { ... }` server block, matching nested braces.

    A regex cannot do this: `.*?}` stops at the first inner template close
    and leaves a dangling fragment that breaks CoreDNS parsing.
    """
    out = []
    i = 0
    header = f"{zone}:53"
    while True:
        j = core.find(header, i)
        if j == -1:
            out.append(core[i:])
            break
        # Only treat it as a server block when `{` follows the header on the
        # same line; otherwise keep the text as-is.
        k = j + len(header)
        while k < len(core) and core[k] in (" ", "\t"):
            k += 1
        if k >= len(core) or core[k] != "{":
            out.append(core[i : k if k < len(core) else len(core)])
            i = k if k < len(core) else len(core)
            continue
        depth = 0
        m = k
        while m < len(core):
            if core[m] == "{":
                depth += 1
            elif core[m] == "}":
                depth -= 1
                if depth == 0:
                    m += 1
                    if m < len(core) and core[m] == "\n":
                        m += 1
                    break
            m += 1
        out.append(core[i:j])
        i = m
    return "".join(out)


stripped = strip_zone(core, zone)
# A previous regex-based replace could leave a dangling top-level fragment
# (`template IN AAAA {...}` plus a stray `}`) that breaks CoreDNS parsing.
# It never appears inside any other server block, so drop it outright.
import re

stripped = re.sub(
    r"(?:\n|^)    template IN AAAA \{\n        match \.\*\n        rcode NOERROR\n    \}\n\}\n?",
    "\n",
    stripped,
)
core = block + stripped
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
