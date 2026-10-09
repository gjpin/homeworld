#!/usr/bin/env bash
# Fail when any in-scope manifest repeats a mapping key.
#
# YAML parsers (yq, kubectl, Argo CD) accept duplicate keys and keep the last
# value, so a missing `---` between two documents silently merges them and
# drops the first resource. yq keeps every key in its node tree, which lets
# this check compare each mapping's key count with its unique key count.

set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

failures=0

while IFS= read -r -d '' file; do
  if yq '[.. | select(tag == "!!map") | (keys | length) - (keys | unique | length)] | any_c(. > 0)' \
    "$file" 2>/dev/null | grep -qx true; then
    echo "check-yaml-duplicates: $file repeats a mapping key (missing '---' between documents?)" >&2
    failures=$((failures + 1))
  fi
done < <(find apps -type f -name '*.yaml' -not -path '*/charts/*' -not -path '*/local-charts/*' -print0)

if ((failures > 0)); then
  exit 1
fi
