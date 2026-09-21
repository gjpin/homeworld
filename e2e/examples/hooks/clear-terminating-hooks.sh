#!/usr/bin/env bash
# Argo hook-finalizers on helm hook Jobs/SAs leave Terminating objects after a
# --keep-cluster rerun and block helm pre-upgrade (before-hook-creation).
set -euo pipefail

log() { printf '[clear-terminating-hooks] %s\n' "$*"; }

kubectl get sa,job,role,rolebinding,configmap,secret -A -o json | python3 -c '
import json, subprocess, sys

data = json.load(sys.stdin)
n = 0
for obj in data.get("items", []):
    md = obj.get("metadata") or {}
    if not md.get("deletionTimestamp"):
        continue
    fins = md.get("finalizers") or []
    if "argocd.argoproj.io/hook-finalizer" not in fins:
        continue
    kind = obj["kind"]
    name = md["name"]
    ns = md.get("namespace") or ""
    print(f"[clear-terminating-hooks] stripping {kind}/{ns}/{name}", flush=True)
    cmd = ["kubectl", "patch", kind, name, "-p", "{\"metadata\":{\"finalizers\":[]}}", "--type=merge"]
    if ns:
        cmd[3:3] = ["-n", ns]
    subprocess.check_call(cmd)
    n += 1
print(f"[clear-terminating-hooks] stripped {n} hook-finalizer(s)", flush=True)
'
