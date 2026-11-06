#!/usr/bin/env bash
# Fail when a manifest references a Secret key that no in-repo resource
# produces.
#
# A missing key fails the pod with CreateContainerConfigError (or blocks a
# CNPG bootstrap) only once it reaches the cluster. This check resolves every
# reference against the ExternalSecret and Secret manifests in the same
# namespace, following External Secrets' template rules: with
# `target.template.data` (or `templateFrom`) and the default
# `mergePolicy: Replace`, the Secret holds only the templated keys, not the
# `data`/`dataFrom` entries.
#
# Checked references: every `secretKeyRef` (container env, init containers,
# operator CRs such as the RustFS Tenant), the CNPG `bootstrap.initdb.secret`
# (username and password keys), and the password key of every user in a
# Valkey release's `auth.usersExistingSecret` (apps/*/helm/valkey). Other
# Helm values are out of scope: their secrets are wired by the chart.

set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

find apps -type f -name '*.yaml' -not -path '*/charts/*' -not -path '*/local-charts/*' -print0 |
  sort -z |
  while IFS= read -r -d '' file; do
    yq -o=json -I=0 'select(. != null and .kind != null) | {"file": filename, "doc": .}' "$file"
  done |
  python3 -c '
import json
import sys

docs = [json.loads(line) for line in sys.stdin if line.strip()]

# (namespace, secret name) -> (set of keys, or None when unknowable, source file)
producers = {}
for entry in docs:
    doc, path = entry["doc"], entry["file"]
    kind = doc.get("kind")
    meta = doc.get("metadata") or {}
    namespace = meta.get("namespace")
    if kind == "ExternalSecret":
        spec = doc.get("spec") or {}
        target = spec.get("target") or {}
        template = target.get("template") or {}
        templated = bool(template.get("data") or template.get("templateFrom"))
        merge = template.get("mergePolicy") == "Merge"
        keys = set((template.get("data") or {}).keys())
        if template.get("templateFrom"):
            keys = None
        elif not templated or merge:
            if spec.get("dataFrom"):
                keys = None
            else:
                keys |= {item["secretKey"] for item in spec.get("data") or []}
        producers[(namespace, target.get("name") or meta.get("name"))] = (keys, path)
    elif kind == "Secret":
        keys = set((doc.get("data") or {}).keys()) | set((doc.get("stringData") or {}).keys())
        producers[(namespace, meta.get("name"))] = (keys, path)

refs = []

def walk(node, namespace, path):
    if isinstance(node, dict):
        for key, value in node.items():
            if key == "secretKeyRef" and isinstance(value, dict):
                refs.append((namespace, value.get("name"), value.get("key"), path))
            else:
                walk(value, namespace, path)
    elif isinstance(node, list):
        for item in node:
            walk(item, namespace, path)

for entry in docs:
    doc, path = entry["doc"], entry["file"]
    namespace = (doc.get("metadata") or {}).get("namespace")
    spec = doc.get("spec") or {}
    walk(spec, namespace, path)
    if doc.get("kind") == "Cluster" and doc.get("apiVersion", "").startswith("postgresql.cnpg.io/"):
        initdb = ((spec.get("bootstrap") or {}).get("initdb") or {})
        name = (initdb.get("secret") or {}).get("name")
        if name:
            refs.extend((namespace, name, key, path) for key in ("username", "password"))

# Valkey releases: the init script reads the password of each user from
# usersExistingSecret under passwordKey (default: the user name).
import glob, subprocess
for values_path in sorted(glob.glob("apps/*/helm/valkey/values.yaml")):
    kust = values_path.rsplit("/", 1)[0] + "/kustomization.yaml"
    namespace = subprocess.run(["yq", ".namespace", kust], capture_output=True, text=True, check=True).stdout.strip()
    values = json.loads(subprocess.run(["yq", "-o=json", ".", values_path], capture_output=True, text=True, check=True).stdout)
    auth = values.get("auth") or {}
    if auth.get("enabled") and auth.get("usersExistingSecret"):
        for user, spec in (auth.get("aclUsers") or {}).items():
            refs.append((namespace, auth["usersExistingSecret"], (spec or {}).get("passwordKey") or user, values_path))

failures = 0
for namespace, name, key, path in sorted(set(refs), key=lambda ref: tuple(str(part) for part in ref)):
    produced = producers.get((namespace, name))
    if produced is None:
        print(f"check-secret-refs: {path}: {namespace}/{name} is not produced by any ExternalSecret or Secret in the repo", file=sys.stderr)
        failures += 1
        continue
    keys, source = produced
    if keys is not None and key not in keys:
        print(f"check-secret-refs: {path}: {namespace}/{name} has no key \"{key}\" (produced by {source} with keys {sorted(keys)})", file=sys.stderr)
        failures += 1

sys.exit(1 if failures else 0)
'
