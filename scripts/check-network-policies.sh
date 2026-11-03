#!/usr/bin/env bash
# Fail on CiliumNetworkPolicy rules that parse but can never match
# (docs/network-policies.md, "How policy matches").
#
# The e2e suite cannot catch these: its Cilium is CRD-only and enforces nothing.
#
# - kube-apiserver egress on 443: the backend port is 6443, and Cilium enforces
#   policy after Service translation.
# - toServices on a Service port whose target port differs, for the same reason.
# - An empty ingress or egress list: Cilium rejects the whole policy as invalid,
#   so a default-deny written that way denies nothing. The form is `- {}`.
# - fromEntities kube-apiserver without remote-node: an API server on another
#   node arrives from its cilium_host address, which is only remote-node.
# - toFQDNs on a cluster hostname: in-cluster clients resolve those names to the
#   envoy-node-access Service, so the rule must select the Envoy pods.
# - toEndpoints on the Envoy pods at 10443 without serverNames, which would
#   open every route (only Homepage and Envoy's own OIDC calls need that).
# - toFQDNs without a DNS rule: no rules.dns on the pods' kube-dns egress means
#   the DNS proxy never sees a lookup, and the rule stays empty.
#
# An optional directory of rendered charts adds their Services and Pods to the
# port check (scripts/scan-security.sh passes its render). Operator-generated
# Services are in neither, and a target port no rendered Pod names is skipped.

set -euo pipefail

render_dir="${1:-}"
repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

{
  find apps -type f -name '*.yaml' -not -path '*/charts/*' -not -path '*/local-charts/*' -print0 |
    sort -z |
    while IFS= read -r -d '' file; do
      yq -o=json -I=0 'select(. != null and .kind != null) | {"file": filename, "doc": .}' "$file"
    done
  if [[ -n "$render_dir" ]]; then
    for file in "$render_dir"/*.yaml; do
      yq -o=json -I=0 'select(. != null and .kind != null) | {"file": filename, "rendered": true, "doc": .}' "$file"
    done
  fi
} | python3 -c '
import json
import sys

policies, services, pods = [], {}, []
for line in sys.stdin:
    entry = json.loads(line)
    doc = entry["doc"]
    if not isinstance(doc, dict):
        continue
    kind = doc.get("kind")
    meta = doc.get("metadata") or {}
    namespace = meta.get("namespace")
    if kind == "CiliumNetworkPolicy" and not entry.get("rendered"):
        policies.append((entry["file"], meta.get("name"), namespace, doc.get("spec") or {}))
    elif kind == "Service":
        services.setdefault(meta.get("name"), []).append((namespace, doc.get("spec") or {}))
    elif kind in ("Deployment", "StatefulSet", "DaemonSet"):
        template = (doc.get("spec") or {}).get("template") or {}
        spec = template.get("spec") or {}
        ports = {
            port["name"]: port["containerPort"]
            for container in spec.get("containers") or []
            for port in container.get("ports") or []
            if port.get("name")
        }
        pods.append(((template.get("metadata") or {}).get("labels") or {}, ports))


def rule_ports(rule):
    return [
        str(port.get("port"))
        for to_port in rule.get("toPorts") or []
        for port in to_port.get("ports") or []
    ]


def has_dns_rule(rule):
    return any((to_port.get("rules") or {}).get("dns") for to_port in rule.get("toPorts") or [])


def target_ports(spec):
    """Map each Service port to its numeric target, leaving out unresolved names."""
    selector = spec.get("selector") or {}
    selected = [
        ports for labels, ports in pods
        if selector and all(labels.get(k) == v for k, v in selector.items())
    ]
    targets = {}
    for port in spec.get("ports") or []:
        target = port.get("targetPort", port["port"])
        if isinstance(target, str):
            resolved = [ports[target] for ports in selected if target in ports]
            if resolved:
                targets[port["port"]] = resolved[0]
        else:
            targets[port["port"]] = target
    return targets


dns_selectors = {}
for _, _, namespace, spec in policies:
    for rule in spec.get("egress") or []:
        if has_dns_rule(rule):
            dns_selectors.setdefault(namespace, []).append(spec.get("endpointSelector") or {})

errors = []
for file, name, namespace, spec in policies:
    where = f"{file}: {name}"
    selector = spec.get("endpointSelector") or {}
    for direction in ("ingress", "egress"):
        if spec.get(direction) == []:
            errors.append(f"{where}: empty {direction} list is invalid; default deny is - {{}}")
    for rule in spec.get("ingress") or []:
        entities = rule.get("fromEntities") or []
        if "kube-apiserver" in entities and "remote-node" not in entities:
            errors.append(f"{where}: kube-apiserver ingress also needs remote-node")
    for rule in spec.get("egress") or []:
        ports = rule_ports(rule)
        if "kube-apiserver" in (rule.get("toEntities") or []) and "443" in ports:
            errors.append(f"{where}: kube-apiserver egress must use 6443, not 443")
        to_envoy = any(
            (endpoint.get("matchLabels") or {}).get("k8s:gateway.envoyproxy.io/owning-gatewayclass")
            for endpoint in rule.get("toEndpoints") or []
        )
        if to_envoy and name not in ("allow-homepage-apps-egress", "allow-envoy-authelia-oidc"):
            for to_port in rule.get("toPorts") or []:
                numbers = [port.get("port") for port in to_port.get("ports") or []]
                if "10443" in numbers and not to_port.get("serverNames"):
                    errors.append(f"{where}: Envoy 10443 egress needs serverNames")
        fqdns = rule.get("toFQDNs") or []
        if fqdns:
            for fqdn in fqdns:
                value = fqdn.get("matchName") or fqdn.get("matchPattern") or ""
                if value.endswith("base-domain.invalid"):
                    errors.append(f"{where}: {value} needs toEndpoints on the Envoy pods, not toFQDNs")
            covers = dns_selectors.get(namespace, [])
            if {} not in covers and selector not in covers:
                errors.append(f"{where}: toFQDNs without rules.dns on these pods kube-dns egress")
        for entry in rule.get("toServices") or []:
            service = entry.get("k8sService") or {}
            service_name = service.get("serviceName")
            service_namespace = service.get("namespace", namespace)
            for candidate_namespace, service_spec in services.get(service_name, []):
                if candidate_namespace not in (None, service_namespace):
                    continue
                targets = target_ports(service_spec)
                for port in ports:
                    number = int(port)
                    if number in targets and targets[number] != number and number not in targets.values():
                        errors.append(
                            f"{where}: {service_namespace}/{service_name} port {number} "
                            f"targets {targets[number]}; policy needs the target port"
                        )

if errors:
    print("network policy rules that can never match:", file=sys.stderr)
    print("\n".join(sorted(set(errors))), file=sys.stderr)
    sys.exit(1)
print(f"checked {len(policies)} CiliumNetworkPolicy resources")
'
