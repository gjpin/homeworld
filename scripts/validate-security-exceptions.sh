#!/usr/bin/env bash
set -euo pipefail

registry="${1:-security/exceptions.yaml}"

yq -o=json '.' "$registry" |
  jq -e '
    (.exceptions | type) == "array" and
    all(.exceptions[];
      .profiles != null and .scanner != null and .check != null and
      .control != null and .reason != null and .owner != null and
      (.profiles | sort) == ["homelab"] and
      (.reason | length) >= 20
    )
  ' >/dev/null

jq -e '
  length > 0 and
  all(.[];
    .policyType == "postureExceptionPolicy" and
    .actions == ["alertOnly"] and
    (.resources | length) > 0 and
    all(.resources[];
      .designatorType == "Attributes" and
      (.attributes.kind | startswith("^") and endswith("$")) and
      (.attributes.name | startswith("^") and endswith("$")) and
      ([.attributes.kind, .attributes.name, (.attributes.namespace // "")]
        | all(. != ".*" and . != "^.*$"))
    )
  )
' security/kubescape-exceptions.json >/dev/null

diff -u \
  <(yq -o=json '.' "$registry" | jq '[.exceptions[] | select(.scanner == "kubescape") | .check] | sort') \
  <(jq '[.[].posturePolicies[0].controlID] | sort' security/kubescape-exceptions.json)
