#!/usr/bin/env bash
# Fail when any pinned Kubernetes version reference drifts from the rest.
#
# Renovate's kubernetes-version group (customManagers in renovate.json)
# bumps every reference atomically in a single PR. This guard catches
# manual edits and stale match patterns that update only some of them.

set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

failures=0

# Baseline: every Pod Security Admission version label under apps/ (vendored
# Helm trees under charts/ and local-charts/ are excluded, matching the
# manifest parsing scope documented in AGENTS.md).
psa_refs="$(
  grep -rnoE --include='*.yaml' --exclude-dir=charts --exclude-dir=local-charts \
    'pod-security\.kubernetes\.io/(enforce|audit|warn)-version:[[:space:]]*v[0-9]+\.[0-9]+' apps |
    sed -E 's/^([^:]+):([0-9]+):.*[[:space:]]v([0-9]+\.[0-9]+)$/\1:\2:\3/' || true
)"

if [[ -z "$psa_refs" ]]; then
  echo 'check-k8s-version: no Pod Security Admission version labels found under apps/' >&2
  exit 1
fi

expected_minor="$(printf '%s\n' "$psa_refs" | cut -d: -f3 | sort -u)"

if [[ "$(printf '%s\n' "$expected_minor" | wc -l)" -ne 1 ]]; then
  echo 'check-k8s-version: Pod Security Admission labels disagree:' >&2
  printf '%s\n' "$psa_refs" | sort -t: -k3,3 -u |
    awk -F: '{print "  v" $3 " at " $1 ":" $2}' >&2
  exit 1
fi

check_refs() {
  local label="$1" refs="$2" row file line version
  if [[ -z "$refs" ]]; then
    echo "check-k8s-version: no ${label} references matched (renovate.json pattern or wording drift?)" >&2
    failures=$((failures + 1))
    return
  fi
  while IFS= read -r row; do
    [[ -z "$row" ]] && continue
    file="${row%%:*}"
    line="${row#*:}"
    line="${line%%:*}"
    version="${row##*:}"
    if [[ "$version" != "$expected_minor" ]]; then
      printf 'check-k8s-version: %s pins %s at %s:%s (PSA labels pin %s)\n' \
        "$label" "$version" "$file" "$line" "$expected_minor" >&2
      failures=$((failures + 1))
    fi
  done <<<"$refs"
}

# e2e suite kind node image pin.
suite_refs="$(
  grep -noE '^[[:space:]]*kubeVersion:[[:space:]]*v[0-9]+\.[0-9]+\.[0-9]+[[:space:]]*$' e2e/examples/homeworld.suite.yaml |
    sed -E 's#^([0-9]+):.*[[:space:]]v([0-9]+\.[0-9]+)\.[0-9]+[[:space:]]*$#e2e/examples/homeworld.suite.yaml:\1:\2#' || true
)"

# e2e README kind node image tag.
e2e_readme_refs="$(
  grep -noE 'Kubernetes[[:space:]]+`v[0-9]+\.[0-9]+\.[0-9]+`' e2e/README.md |
    sed -E 's#^([0-9]+):.*`v([0-9]+\.[0-9]+)\.[0-9]+`$#e2e/README.md:\1:\2#' || true
)"

# User namespaces documentation.
docs_refs="$(
  grep -noE 'Kubernetes[[:space:]]+[0-9]+\.[0-9]+[[:space:]]+[Uu]ser[[:space:]]+[Nn]amespaces' \
    README.md AGENTS.md docs/pod-security.md |
    sed -E 's#^([^:]+):([0-9]+):Kubernetes[[:space:]]+([0-9]+\.[0-9]+)[[:space:]]+.*#\1:\2:\3#' || true
)"

# e2e staging hook comments.
hook_refs="$(
  grep -noE '([Kk]8s|fail Kubernetes)[[:space:]]+[0-9]+\.[0-9]+' e2e/examples/hooks/rewrite-staging.py |
    sed -E 's#^([0-9]+):.*[[:space:]]([0-9]+\.[0-9]+)$#e2e/examples/hooks/rewrite-staging.py:\1:\2#' || true
)"

check_refs 'e2e suite kubeVersion' "$suite_refs"
check_refs 'e2e README kind node tag' "$e2e_readme_refs"
check_refs 'user namespaces documentation' "$docs_refs"
check_refs 'e2e staging hook comments' "$hook_refs"

if [[ "$failures" -ne 0 ]]; then
  echo "check-k8s-version: $failures reference(s) drift from the Pod Security Admission pin v${expected_minor}" >&2
  echo 'check-k8s-version: Renovate must bump every reference together via the kubernetes-version group (docs/upgrades.md)' >&2
  exit 1
fi

echo "check-k8s-version: every Kubernetes version reference agrees on v${expected_minor}"
