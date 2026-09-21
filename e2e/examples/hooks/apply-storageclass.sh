#!/usr/bin/env bash
# Recreate the kind local-path StorageClass named longhorn-crypto.
# volumeBindingMode is immutable, so a --keep-cluster rerun that changes
# it must delete the class first.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
kubectl delete storageclass longhorn-crypto --ignore-not-found
kubectl apply -f "${ROOT}/e2e/examples/manifests/longhorn-crypto-storageclass.yaml"
echo "[apply-storageclass] StorageClass/longhorn-crypto -> rancher.io/local-path WaitForFirstConsumer"
