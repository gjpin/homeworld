#!/usr/bin/env bash
# Upgrade report for dependency bumps (docs/upgrades.md §9, the /upgrade
# skill). Compares each touched component between two git revisions and
# checks the head revision against upstream. Read-only: it renders charts and
# queries registries and release APIs, and never touches the cluster.
#
# Per component:
#   1. Helm charts: base/head/latest-stable version and appVersion; our
#      values keys the new chart dropped, keys no chart version knows, values
#      equal to the new default; chart options new in the head version and
#      defaults that changed underneath values we do not set.
#   2. Render diff (kubectl kustomize --enable-helm) per resource, CRD
#      changes, image changes, and the latest stable tag of every image.
#   3. Convention findings (gVisor/hostUsers, Restricted security context,
#      requests/limits, fully qualified images, 60s monitors) on the head
#      render, with the ones new since base called out as regressions.
#   4. Upstream release notes for every chart and application release in
#      the bumped ranges (GitHub and Gitea/Forgejo release APIs, application
#      repositories resolved from image OCI source labels), with lines that
#      mention breaking changes, deprecations, or removals extracted.
#   5. Whether the component holds state, and in which namespaces (the
#      pre-merge Velero backup guard, scripts/pre-upgrade-backup.sh).
#
# usage: scripts/upgrade-report.sh [--base REF] [--head REF] [--out DIR] [--all | component...]
#
# --head defaults to HEAD and --base to its merge base with origin/main.
# Without components, every apps/<component> the range touches is reported.
# With --base equal to --head (or --all), the report audits the current state:
# latest versions, redundant values, and convention findings.
# Writes report.md and summary.json to --out (default: a fresh temp dir).

set -euo pipefail

base_ref=""
head_ref="HEAD"
out_dir=""
all=0
components=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --base) base_ref="$2"; shift 2 ;;
    --head) head_ref="$2"; shift 2 ;;
    --out) out_dir="$2"; shift 2 ;;
    --all) all=1; shift ;;
    -h | --help) sed -n '2,32p' "$0"; exit 0 ;;
    -*) echo "unknown option: $1" >&2; exit 2 ;;
    *) components+=("$1"); shift ;;
  esac
done

for tool in git yq jq kubectl helm curl gh crane timeout; do
  command -v "$tool" >/dev/null || { echo "missing required tool: $tool" >&2; exit 2; }
done

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

head_sha="$(git rev-parse --verify "${head_ref}^{commit}")"
if [[ -z "$base_ref" ]]; then
  base_sha="$(git merge-base origin/main "$head_sha")"
else
  base_sha="$(git rev-parse --verify "${base_ref}^{commit}")"
fi

if [[ "$all" -eq 1 ]]; then
  components=()
  while IFS= read -r d; do components+=("$d"); done < <(git ls-tree -d --name-only "$head_sha" apps/ | sed 's|^apps/||')
elif [[ ${#components[@]} -eq 0 ]]; then
  while IFS= read -r d; do components+=("$d"); done < <(
    git diff --name-only "$base_sha" "$head_sha" -- apps/ | cut -d/ -f2 | sort -u
  )
fi

out_dir="${out_dir:-$(mktemp -d "${TMPDIR:-/tmp}/upgrade-report.XXXXXX")}"
mkdir -p "$out_dir"
out_dir="$(cd "$out_dir" && pwd)"
work="$out_dir/.work"
rm -rf "$work"
mkdir -p "$work/cache"

# Every chart and image here is public: query registries anonymously. With
# no credentials configured, Helm and crane fall back to the platform's
# native credential helper, which can block indefinitely (the macOS keychain
# waiting on an access prompt). A non-empty auths map turns that detection
# off.
mkdir -p "$work/registry"
echo '{"auths": {"anonymous.invalid": {}}}' >"$work/registry/config.json"
export DOCKER_CONFIG="$work/registry"
export HELM_REGISTRY_CONFIG="$work/registry/config.json"

base_tree="$work/base"
head_tree="$work/head"

cleanup() {
  git -C "$repo_root" worktree remove --force "$base_tree" >/dev/null 2>&1 || true
  git -C "$repo_root" worktree remove --force "$head_tree" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# A detached worktree per side, seeded with the chart caches kustomize already
# pulled into this checkout so unchanged chart versions are not re-downloaded.
make_tree() {
  local sha="$1" dir="$2" charts
  git worktree add --detach --quiet "$dir" "$sha"
  while IFS= read -r charts; do
    mkdir -p "$dir/$charts"
    cp -R "$charts/." "$dir/$charts/"
  done < <(find apps -type d -name charts -path '*/helm/*' -not -path '*/charts/*/*' 2>/dev/null)
}
make_tree "$head_sha" "$head_tree"
if [[ "$base_sha" != "$head_sha" ]]; then
  make_tree "$base_sha" "$base_tree"
else
  base_tree="$head_tree"
fi

# --- jq programs -------------------------------------------------------------

# Values analysis. Inputs: $ours (merged values files), $old and $new (the
# base and head charts' default values.yaml). A key absent from the new
# defaults counts only when its deepest existing ancestor there is a
# non-empty map: free-form maps ({}, null) such as podAnnotations accept any
# key.
read -r -d '' jq_values <<'JQ' || true
def has_path($p): reduce $p[] as $k ({ok: true, v: .};
  if .ok and (.v | type) == "object" and (.v | has($k)) then {ok: true, v: .v[$k]} else {ok: false} end) | .ok;
def ancestor($p): reduce $p[] as $k ({v: ., done: false};
  if .done then . elif (.v | type) == "object" and (.v | has($k)) then .v = .v[$k] else .done = true end) | .v;
def structured($p): ancestor($p) | (type == "object" and . != {});
def leaves: [paths(type != "object" or . == {}) as $p | select(all($p[]; type == "string")) | $p];
def show($p): {key: ($p | join(".")), value: (getpath($p))};
$ours[0] as $o | ($old[0] // {}) as $od | ($new[0] // {}) as $nd |
($o | leaves) as $ol |
{
  removed: [$ol[] as $p | select(($nd | has_path($p) | not) and ($od | has_path($p)) and ($nd | structured($p)))
    | $o | show($p)],
  unknown: [$ol[] as $p | select(($nd | has_path($p) | not) and ($od | has_path($p) | not) and ($nd | structured($p)))
    | $o | show($p)],
  redundant: [$ol[] as $p | select(($nd | has_path($p)) and (($nd | getpath($p)) == ($o | getpath($p))))
    | $o | show($p)],
  new_options: (if $changed then [($nd | leaves)[] as $p | select($od | has_path($p) | not) | $nd | show($p)] else [] end),
  changed_defaults: (if $changed then [($nd | leaves)[] as $p
    | select(($od | has_path($p)) and (($od | getpath($p)) != ($nd | getpath($p))) and ($o | has_path($p) | not))
    | {key: ($p | join(".")), old: ($od | getpath($p)), new: ($nd | getpath($p))}] else [] end)
}
JQ

# Convention findings over an array of manifests.
read -r -d '' jq_conventions <<'JQ' || true
def podspec:
  if .kind == "Pod" then .spec
  elif .kind == "CronJob" then .spec.jobTemplate.spec.template.spec
  elif (.kind | IN("Deployment", "StatefulSet", "DaemonSet", "Job", "ReplicaSet")) then .spec.template.spec
  else empty end;
def eff($c; $s; f): (($c.securityContext // {}) | f) as $v | if $v != null then $v else (($s.securityContext // {}) | f) end;
def qualified: (split("/") | length > 1) and (split("/")[0] | test("[.:]"));
[
  (.[] | select(type == "object") | . as $d | podspec as $s
    | "\($d.kind)/\($d.metadata.namespace // "-")/\($d.metadata.name)" as $id
    | (if $s.runtimeClassName == "gvisor" and $s.hostUsers == false then "\($id): runtimeClassName gvisor with hostUsers: false" else empty end),
      (if $s.runtimeClassName != "gvisor" and $s.hostUsers != false then "\($id): neither runtimeClassName: gvisor nor hostUsers: false" else empty end),
      ((($s.initContainers // []) + ($s.containers // []))[] as $c | "\($id)[\($c.name)]" as $cid
        | (if eff($c; $s; .runAsNonRoot) != true then "\($cid): runAsNonRoot not true" else empty end),
          (if (eff($c; $s; .seccompProfile.type) | IN("RuntimeDefault", "Localhost") | not) then "\($cid): seccompProfile not RuntimeDefault" else empty end),
          (if ($c.securityContext // {}).allowPrivilegeEscalation != false then "\($cid): allowPrivilegeEscalation not false" else empty end),
          (if ((($c.securityContext // {}).capabilities.drop // []) | index("ALL")) == null then "\($cid): capabilities.drop lacks ALL" else empty end),
          (if (($c.resources // {}).requests // {}) == {} then "\($cid): no resource requests" else empty end),
          (if (($c.resources // {}).limits // {}) == {} then "\($cid): no resource limits" else empty end),
          (if ($c.image | type) == "string" and ($c.image | qualified | not) then "\($cid): image not fully qualified (\($c.image))" else empty end))),
  (.[] | select(type == "object" and .kind == "ServiceMonitor") | . as $d
    | (.spec.endpoints // [])[] | select(.interval != "60s")
    | "ServiceMonitor/\($d.metadata.namespace // "-")/\($d.metadata.name): interval \(.interval // "unset") (want 60s)"),
  (.[] | select(type == "object" and .kind == "PodMonitor") | . as $d
    | (.spec.podMetricsEndpoints // [])[] | select(.interval != "60s")
    | "PodMonitor/\($d.metadata.namespace // "-")/\($d.metadata.name): interval \(.interval // "unset") (want 60s)")
] | unique | .[]
JQ

# Namespaces holding state: PVCs, StatefulSet claim templates, and the
# operator-managed datastores.
read -r -d '' jq_stateful <<'JQ' || true
[.[] | select(type == "object") | select(
    .kind == "PersistentVolumeClaim"
    or (.kind == "StatefulSet" and ((.spec.volumeClaimTemplates // []) | length > 0))
    or (.kind == "Cluster" and ((.apiVersion // "") | startswith("postgresql.cnpg.io/")))
    or (.kind == "MariaDB" and ((.apiVersion // "") | startswith("k8s.mariadb.com/")))
    or (.kind == "DocumentDB" and ((.apiVersion // "") | startswith("documentdb.io/")))
    or (.kind == "Tenant" and ((.apiVersion // "") | startswith("rustfs.com/"))))
  | .metadata.namespace // $default_ns | select(. != "")] | unique | .[]
JQ

# Image references anywhere in the manifests (containers, CNPG imageName,
# operator CRs with a string image field).
read -r -d '' jq_images <<'JQ' || true
[.. | objects | (.image?, .imageName?) | strings] | unique | .[]
JQ

# Release filter. Input: release objects {tag_name, name, body, html_url,
# prerelease, draft}. Keeps stable releases whose tag prefix is empty or one
# of $names and whose version lies in ($lo, $hi].
read -r -d '' jq_releases <<'JQ' || true
def parse: capture("^(?<p>.*?)v?(?<n>[0-9]+(\\.[0-9]+)+)(?<s>[-+.].*)?$")
  | .p |= (ascii_downcase | sub("[-_/@]+$"; "")) | .v = (.n | split(".") | map(tonumber));
def pre: (.s // "") | test("(?i)^[-.](rc|alpha|beta|pre|dev|nightly|snapshot|canary|next)");
($lo | parse | .v) as $lov | ($hi | parse | .v) as $hiv |
[.[] | select((.draft | not) and (.prerelease | not))
  | . as $r | (.tag_name | try parse catch null) as $t | select($t != null)
  | select(($t | pre | not) and ($t.p == "" or ($names | index($t.p)) != null))
  | select($t.v > $lov and $t.v <= $hiv)
  | $r + {version: $t.v}] | sort_by(.version) | .[]
JQ

# --- helpers -------------------------------------------------------------------

# Registries with tens of thousands of tags (signature and attestation tags
# included) take minutes to list; past this budget the latest tag is reported
# as unknown and Renovate's own lookup stands.
registry_timeout=60

render_docs_json() {
  # Multi-document YAML files to one JSON array (empty documents dropped).
  if [[ $# -eq 0 ]]; then echo '[]'; return; fi
  yq ea -o=json -I0 '[. | select(. != null)]' "$@" 2>/dev/null || echo '[]'
}

handwritten_files() {
  local tree="$1" component="$2"
  [[ -d "$tree/apps/$component" ]] || return 0
  find "$tree/apps/$component" -type f -name '*.yaml' -not -path '*/helm/*' | sort
}

# Latest stable chart version from a classic repository index or an OCI
# registry, keeping the current version's leading "v" convention.
latest_chart() {
  local repo="$1" name="$2" current="$3" key versions
  key="$(printf '%s' "$repo" | tr -c 'A-Za-z0-9' '_')"
  if [[ "$repo" == oci://* ]]; then
    # A timed-out listing is partial; discard it rather than report a stale "latest".
    versions="$(timeout "$registry_timeout" crane ls "${repo#oci://}/$name" 2>/dev/null)" || versions=""
  else
    if [[ ! -f "$work/cache/$key.index.yaml" ]]; then
      curl -sfL --max-time 120 "${repo%/}/index.yaml" -o "$work/cache/$key.index.yaml" 2>/dev/null || : >"$work/cache/$key.index.yaml"
    fi
    versions="$(NAME="$name" yq -r '.entries[strenv(NAME)][].version' "$work/cache/$key.index.yaml" 2>/dev/null || true)"
  fi
  latest_matching "$current" "$versions"
}

# Highest tag with the same shape as $current: same non-numeric prefix, same
# number of version components, same suffix (e.g. 18.1-system-trixie).
latest_matching() {
  local current="${1%%@*}" candidates="$2" prefix numbers suffix shape
  if [[ ! "$current" =~ ^([^0-9]*)([0-9]+(\.[0-9]+)*)(.*)$ ]]; then
    echo ""
    return
  fi
  prefix="${BASH_REMATCH[1]}"
  numbers="${BASH_REMATCH[2]}"
  suffix="${BASH_REMATCH[4]}"
  shape="$(printf '%s' "$numbers" | sed 's/[0-9][0-9]*/[0-9]+/g; s/\./\\./g')"
  printf '%s\n' "$candidates" |
    grep -E "^$(printf '%s' "$prefix" | sed 's/[.[\*^$+?(){}|/]/\\&/g')${shape}$(printf '%s' "$suffix" | sed 's/[.[\*^$+?(){}|/]/\\&/g')\$" |
    sort -V | tail -n1 || true
}

image_repo() { local i="${1%%@*}"; if [[ "${i##*/}" == *:* ]]; then echo "${i%:*}"; else echo "$i"; fi; }
image_tag() { local i="${1%%@*}"; if [[ "${i##*/}" == *:* ]]; then echo "${i##*:}"; else echo ""; fi; }

latest_image() {
  local image="$1" repo tag key
  repo="$(image_repo "$image")"
  tag="$(image_tag "$image")"
  [[ -n "$tag" ]] || { echo ""; return; }
  key="$(printf '%s' "$repo" | tr -c 'A-Za-z0-9' '_')"
  if [[ ! -f "$work/cache/$key.tags" ]]; then
    timeout "$registry_timeout" crane ls "$repo" >"$work/cache/$key.tags" 2>/dev/null || : >"$work/cache/$key.tags"  # partial on timeout: discard
  fi
  latest_matching "$tag" "$(cat "$work/cache/$key.tags")"
}

# Source repository URL from an image's OCI labels.
image_source() {
  local image="$1" key
  key="$(printf '%s' "$image" | tr -c 'A-Za-z0-9' '_')"
  if [[ ! -f "$work/cache/$key.source" ]]; then
    timeout "$registry_timeout" crane config "$image" 2>/dev/null |
      jq -r '.config.Labels // {} | .["org.opencontainers.image.source"] // .["org.label-schema.vcs-url"] // empty' \
        >"$work/cache/$key.source" 2>/dev/null || : >"$work/cache/$key.source"
  fi
  head -n1 "$work/cache/$key.source"
}

# host/owner/repo from a repository URL, or nothing for unsupported hosts.
repo_slug() {
  local url="${1%.git}"
  url="${url%/}"
  if [[ "$url" =~ ^https?://([^/]+)/([^/]+)/([^/#?]+) ]]; then
    echo "${BASH_REMATCH[1]}/${BASH_REMATCH[2]}/${BASH_REMATCH[3]}"
  fi
}

# All releases of host/owner/repo as a JSON array (newest 500).
fetch_releases() {
  local slug="$1" host owner_repo key page body
  host="${slug%%/*}"
  owner_repo="${slug#*/}"
  key="$(printf '%s' "$slug" | tr -c 'A-Za-z0-9' '_')"
  if [[ ! -f "$work/cache/$key.releases.json" ]]; then
    {
      for page in 1 2 3 4 5; do
        if [[ "$host" == "github.com" ]]; then
          body="$(gh api "repos/$owner_repo/releases?per_page=100&page=$page" 2>/dev/null || echo '[]')"
        else
          body="$(curl -sfL --max-time 60 "https://$host/api/v1/repos/$owner_repo/releases?limit=50&page=$page" 2>/dev/null || echo '[]')"
        fi
        printf '%s\n' "$body"
        [[ "$(jq 'length' <<<"$body" 2>/dev/null || echo 0)" -gt 0 ]] || break
      done
    } | jq -s 'add // [] | map({tag_name, name, body, html_url, prerelease: (.prerelease // false), draft: (.draft // false)})' \
      >"$work/cache/$key.releases.json" 2>/dev/null || echo '[]' >"$work/cache/$key.releases.json"
  fi
  cat "$work/cache/$key.releases.json"
}

flag_pattern='breaking|deprecat|removed|removal|renamed|rename[sd]? |migrat|action required|manual (step|action|intervention)|must (be|now)|no longer|incompatib|upgrade notes?|⚠|dropped support|minimum (required )?version'

# Release notes for slug within ($lo, $hi], appended to the notes file; the
# number of releases written goes to stdout.
collect_notes() {
  local slug="$1" lo="$2" hi="$3" names="$4" notes="$5" seen="$6" releases
  [[ -n "$slug" && -n "$lo" && -n "$hi" && "$lo" != "$hi" ]] || { echo 0; return; }
  releases="$(fetch_releases "$slug" | jq -c --arg lo "$lo" --arg hi "$hi" --argjson names "$names" "$jq_releases" 2>/dev/null || true)"
  local count=0 line tag
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    tag="$(jq -r '.tag_name' <<<"$line")"
    if grep -qxF "$slug@$tag" "$seen" 2>/dev/null; then continue; fi
    echo "$slug@$tag" >>"$seen"
    count=$((count + 1))
    jq -r --arg slug "$slug" '"<!-- release \($slug) \(.tag_name) -->\n## \($slug) \(.tag_name)\n\n<\(.html_url)>\n\n\(.body // "(no release body)")\n"' <<<"$line" >>"$notes"
  done <<<"$releases"
  echo "$count"
}

# Drop removed/unknown keys the chart still consumes: a key whose path, or
# any ancestor passed through whole (toYaml .Values.podSecurityContext), is
# referenced from the templates, or that belongs to a dependency subchart.
filter_referenced() {
  local chart="$1" analysis="$2" kept key prefix referenced category
  [[ -d "$chart/templates" ]] || return 0
  local deps
  deps="$(yq -r '(.dependencies // [])[] | (.alias // .name)' "$chart/Chart.yaml" 2>/dev/null || true)"
  local library=false
  if grep -qs '^type: library' "$chart"/charts/*/Chart.yaml; then
    library=true
  fi
  for category in removed unknown; do
    kept="[]"
    while IFS= read -r key; do
      [[ -n "$key" ]] || continue
      referenced=false
      if [[ -n "$deps" ]] && grep -qxF "${key%%.*}" <<<"$deps"; then
        referenced=true
      else
        prefix="$key"
        while [[ -n "$prefix" ]]; do
          # Library and dependency charts (bjw-s common, libcoder) render the
          # parent's values, so search every template under the chart.
          if grep -rqE --include='*.yaml' --include='*.tpl' --exclude='values*.yaml' \
            "\.Values\.$(sed 's/[.]/\\./g' <<<"$prefix")([^A-Za-z0-9_.]|\$)" "$chart" 2>/dev/null; then
            referenced=true
            break
          fi
          [[ "$prefix" == *.* ]] || break
          prefix="${prefix%.*}"
        done
      fi
      # Library charts (bjw-s common) walk value trees with dig/get "key"
      # instead of .Values paths: a quoted segment counts as a reference.
      if [[ "$referenced" == false && "$library" == true ]]; then
        local segment
        for segment in ${key//./ }; do
          if grep -rqF --include='*.tpl' --include='*.yaml' --exclude='values*.yaml' "\"$segment\"" "$chart" 2>/dev/null; then
            referenced=true
            break
          fi
        done
      fi
      if [[ "$referenced" == false ]]; then
        kept="$(jq -c --arg k "$key" --arg c "$category" --slurpfile a "$analysis" '. + [$a[0][$c][] | select(.key == $k)]' <<<"$kept")"
      fi
    done < <(jq -r --arg c "$category" '.[$c][].key' "$analysis")
    jq --arg c "$category" --argjson kept "$kept" '.[$c] = $kept' "$analysis" >"$analysis.tmp"
    mv "$analysis.tmp" "$analysis"
  done
}

md_list() {
  # JSON array of {key, value} -> markdown bullets (values truncated).
  jq -r '.[] | "- `\(.key)`" + (if has("value") then " = `\(.value | tojson | .[0:120])`" elif has("old") then ": `\(.old | tojson | .[0:60])` → `\(.new | tojson | .[0:60])`" else "" end)'
}

capped() {
  # Print at most $1 lines of stdin, then a count of the rest.
  local max="$1" n=0 line
  while IFS= read -r line; do
    n=$((n + 1))
    if [[ $n -le $max ]]; then printf '%s\n' "$line"; fi
  done
  if [[ $n -gt $max ]]; then echo "- … and $((n - max)) more (see the full file)"; fi
}

# --- per component -------------------------------------------------------------

report="$out_dir/report.md"
summary_items="$work/summary.jsonl"
: >"$summary_items"

{
  echo "# Upgrade report"
  echo
  echo "- Base: \`$(git rev-parse --short "$base_sha")\` ($(git log -1 --format=%s "$base_sha"))"
  echo "- Head: \`$(git rev-parse --short "$head_sha")\` ($(git log -1 --format=%s "$head_sha"))"
  echo "- Components: ${components[*]:-(none)}"
  behind="$(git rev-list --count "$head_sha..origin/main" 2>/dev/null || echo 0)"
  if [[ "$behind" -gt 0 ]]; then
    echo
    echo "**Head is $behind commit(s) behind origin/main**: findings may already be fixed (or newly broken) on main. Update the branch and run the report again before acting on it."
  fi
  echo
  other="$(git diff --stat "$base_sha" "$head_sha" -- . ':(exclude)apps' | tail -n +1)"
  if [[ -n "$other" ]]; then
    echo "## Changes outside apps/"
    echo
    echo '```diff'
    git diff "$base_sha" "$head_sha" -- . ':(exclude)apps' | head -n 200
    echo '```'
    echo
  fi
} >"$report"

for component in "${components[@]}"; do
  cout="$out_dir/$component"
  mkdir -p "$cout"
  notes="$cout/release-notes.md"
  seen="$work/$component.seen"
  : >"$notes"
  : >"$seen"
  render_failed=false
  charts_json="[]"
  stateful_ns=""

  echo "==> $component" >&2

  {
    echo "## $component"
    echo
    changed="$(git diff --name-only "$base_sha" "$head_sha" -- "apps/$component")"
    if [[ -n "$changed" ]]; then
      echo "Changed files:"
      echo
      printf '%s\n' "$changed" | sed 's/^/- `/; s/$/`/'
      echo
      echo '```diff'
      git diff -U2 "$base_sha" "$head_sha" -- "apps/$component" | grep -v '^index ' | capped 120
      echo '```'
      echo
    fi
  } >>"$report"

  base_all="$cout/.base-all.yaml"
  head_all="$cout/.head-all.yaml"
  : >"$base_all"
  : >"$head_all"

  # Helm releases of the component.
  kusts="$(cd "$head_tree" && find "apps/$component" \( -path '*/helm/kustomization.yaml' -o -path '*/helm/*/kustomization.yaml' \) \
    -not -path '*/charts/*' -not -path '*/local-charts/*' 2>/dev/null | sort)"

  while IFS= read -r kust; do
    [[ -n "$kust" ]] || continue
    kdir="$(dirname "$kust")"
    rel="${kdir#"apps/$component/helm"}"
    rel="${rel#/}"
    label="${rel:-$component}"
    rdir="$cout/$label"
    mkdir -p "$rdir"

    for side in head base; do
      tree="$base_tree"
      [[ "$side" == head ]] && tree="$head_tree"
      if [[ "$side" == base && "$base_tree" == "$head_tree" ]]; then
        cp "$rdir/head.yaml" "$rdir/base.yaml"
        cp "$rdir/head.render.err" "$rdir/base.render.err"
      elif [[ -f "$tree/$kust" ]]; then
        # A stalled chart pull would otherwise hang the report indefinitely.
        if ! timeout 300 kubectl kustomize --enable-helm "$tree/$kdir" >"$rdir/$side.yaml" 2>"$rdir/$side.render.err"; then
          render_failed=true
          : >"$rdir/$side.yaml"
        fi
      else
        : >"$rdir/$side.yaml"
      fi
    done
    cat "$rdir/base.yaml" >>"$base_all"
    echo '---' >>"$base_all"
    cat "$rdir/head.yaml" >>"$head_all"
    echo '---' >>"$head_all"

    default_ns="$(yq -r '.helmCharts[0].namespace // ""' "$head_tree/$kust")"
    ns_found="$(render_docs_json "$rdir/head.yaml" | jq -r --arg default_ns "$default_ns" "$jq_stateful")"
    stateful_ns="$(printf '%s\n%s\n' "$stateful_ns" "$ns_found" | sed '/^$/d' | sort -u)"

    {
      echo "### Release \`$label\`"
      echo
      if [[ -s "$rdir/head.render.err" ]] && [[ ! -s "$rdir/head.yaml" ]]; then
        echo "**Head render failed** (\`$rdir/head.render.err\`):"
        echo
        echo '```'
        tail -n 20 "$rdir/head.render.err"
        echo '```'
        echo
      fi
    } >>"$report"

    chart_count="$(yq '.helmCharts | length' "$head_tree/$kust")"
    for ((i = 0; i < chart_count; i++)); do
      name="$(yq -r ".helmCharts[$i].name" "$head_tree/$kust")"
      repo="$(yq -r ".helmCharts[$i].repo // \"\"" "$head_tree/$kust")"
      head_version="$(yq -r ".helmCharts[$i].version // \"\"" "$head_tree/$kust")"
      base_version=""
      base_repo=""
      if [[ -f "$base_tree/$kust" ]]; then
        base_version="$(NAME="$name" yq -r '.helmCharts[] | select(.name == strenv(NAME)) | .version // ""' "$base_tree/$kust" | head -n1)"
        base_repo="$(NAME="$name" yq -r '.helmCharts[] | select(.name == strenv(NAME)) | .repo // ""' "$base_tree/$kust" | head -n1)"
      fi

      chart_home="$(yq -r '.helmGlobals.chartHome // "charts"' "$head_tree/$kust")"
      if [[ -z "$repo" ]]; then
        head_chart="$head_tree/$kdir/$chart_home/$name"
        base_chart="$base_tree/$kdir/$chart_home/$name"
        head_version="$(yq -r '.version' "$head_chart/Chart.yaml" 2>/dev/null || echo "")"
        base_version="$(yq -r '.version' "$base_chart/Chart.yaml" 2>/dev/null || echo "")"
      else
        head_chart="$head_tree/$kdir/charts/$name-$head_version/$name"
        base_chart="$base_tree/$kdir/charts/$name-$base_version/$name"
      fi
      head_app="$(yq -r '.appVersion // ""' "$head_chart/Chart.yaml" 2>/dev/null || echo "")"
      base_app="$(yq -r '.appVersion // ""' "$base_chart/Chart.yaml" 2>/dev/null || echo "")"

      latest=""
      if [[ -n "$repo" ]]; then
        latest="$(latest_chart "$repo" "$name" "$head_version")"
      fi
      newer=false
      if [[ -n "$latest" && "$latest" != "$head_version" ]] &&
        [[ "$(printf '%s\n%s\n' "$head_version" "$latest" | sort -V | tail -n1)" == "$latest" ]]; then
        newer=true
      fi

      # Values analysis against the merged values files of this chart.
      values_files=()
      vf="$(yq -r ".helmCharts[$i].valuesFile // \"\"" "$head_tree/$kust")"
      [[ -n "$vf" ]] && values_files+=("$head_tree/$kdir/$vf")
      while IFS= read -r vf; do
        [[ -n "$vf" ]] && values_files+=("$head_tree/$kdir/$vf")
      done < <(yq -r ".helmCharts[$i].additionalValuesFiles // [] | .[]" "$head_tree/$kust")
      yq -o=json ".helmCharts[$i].valuesInline // {}" "$head_tree/$kust" >"$rdir/.inline.json"
      if [[ ${#values_files[@]} -gt 0 ]]; then
        yq ea -o=json '. as $item ireduce ({}; . * $item)' "${values_files[@]}" >"$rdir/.files.json"
      else
        echo '{}' >"$rdir/.files.json"
      fi
      jq -s '.[0] * .[1]' "$rdir/.files.json" "$rdir/.inline.json" >"$rdir/$name.ours.json"
      yq -o=json '. // {}' "$head_chart/values.yaml" >"$rdir/$name.new-defaults.json" 2>/dev/null || echo '{}' >"$rdir/$name.new-defaults.json"
      yq -o=json '. // {}' "$base_chart/values.yaml" >"$rdir/$name.old-defaults.json" 2>/dev/null || cp "$rdir/$name.new-defaults.json" "$rdir/$name.old-defaults.json"
      chart_changed=false
      [[ -n "$base_version" && "$base_version" != "$head_version" ]] && chart_changed=true
      jq -n --argjson changed "$chart_changed" \
        --slurpfile ours "$rdir/$name.ours.json" \
        --slurpfile old "$rdir/$name.old-defaults.json" \
        --slurpfile new "$rdir/$name.new-defaults.json" \
        "$jq_values" >"$rdir/$name.values-analysis.json"
      if [[ "$chart_changed" == true && -f "$base_chart/values.yaml" && -f "$head_chart/values.yaml" ]]; then
        diff -u "$base_chart/values.yaml" "$head_chart/values.yaml" >"$rdir/$name.default-values.diff" || true
      fi
      if [[ -f "$base_chart/values.schema.json" || -f "$head_chart/values.schema.json" ]]; then
        diff -u <(jq -S . "$base_chart/values.schema.json" 2>/dev/null || true) \
          <(jq -S . "$head_chart/values.schema.json" 2>/dev/null || true) >"$rdir/$name.values-schema.diff" || true
        [[ -s "$rdir/$name.values-schema.diff" ]] || rm -f "$rdir/$name.values-schema.diff"
      fi

      va="$rdir/$name.values-analysis.json"
      filter_referenced "$head_chart" "$va"
      {
        echo "#### Chart \`$name\`"
        echo
        echo "- Repository: \`${repo:-vendored ($chart_home)}\`${base_repo:+$([[ "$base_repo" != "$repo" ]] && echo " (was \`$base_repo\`)")}"
        echo "- Version: \`${base_version:-new}\` → \`$head_version\`; latest stable upstream: \`${latest:-unknown}\`$([[ "$newer" == true ]] && echo " **(newer than head)**")"
        echo "- appVersion: \`${base_app:-?}\` → \`${head_app:-?}\`"
        [[ -f "$rdir/$name.default-values.diff" ]] && echo "- Default values diff: \`$rdir/$name.default-values.diff\`"
        [[ -f "$rdir/$name.values-schema.diff" ]] && echo "- Values schema diff: \`$rdir/$name.values-schema.diff\`"
        echo
        n="$(jq '.removed | length' "$va")"
        if [[ "$n" -gt 0 ]]; then
          echo "**Our values keys the new chart removed or renamed ($n)** — Helm silently ignores them:"
          echo
          jq '.removed' "$va" | md_list | capped 40
          echo
        fi
        n="$(jq '.unknown | length' "$va")"
        if [[ "$n" -gt 0 ]]; then
          echo "Our values keys absent from both versions' defaults ($n) — undocumented or dead; verify against the chart templates:"
          echo
          jq '.unknown' "$va" | md_list | capped 40
          echo
        fi
        n="$(jq '.redundant | length' "$va")"
        if [[ "$n" -gt 0 ]]; then
          echo "Our values equal to the new chart default ($n) — drop unless pinned on purpose:"
          echo
          jq '.redundant' "$va" | md_list | capped 40
          echo
        fi
        n="$(jq '.new_options | length' "$va")"
        if [[ "$n" -gt 0 ]]; then
          echo "Chart options new in \`$head_version\` ($n):"
          echo
          jq '.new_options' "$va" | md_list | capped 60
          echo
        fi
        n="$(jq '.changed_defaults | length' "$va")"
        if [[ "$n" -gt 0 ]]; then
          echo "Defaults that changed under keys we do not set ($n):"
          echo
          jq '.changed_defaults' "$va" | md_list | capped 60
          echo
        fi
      } >>"$report"

      # Chart release notes from the chart's repository; application notes
      # from repositories that publish the appVersion (images handled below).
      if [[ "$chart_changed" == true ]]; then
        names="$(jq -cn --arg n "$name" '[$n | ascii_downcase]')"
        while IFS= read -r url; do
          slug="$(repo_slug "$url")"
          [[ -n "$slug" ]] || continue
          if [[ "${slug##*/}" =~ [Cc]hart|[Hh]elm ]] || [[ "$repo" =~ ^https://([^./]+)\.github\.io/([^/]+) && "$slug" == "github.com/${BASH_REMATCH[1]}/${BASH_REMATCH[2]%/}" ]]; then
            collect_notes "$slug" "$base_version" "$head_version" "$names" "$notes" "$seen" >/dev/null
          elif [[ -n "$base_app" && -n "$head_app" && "$base_app" != "$head_app" ]]; then
            collect_notes "$slug" "$base_app" "$head_app" "$names" "$notes" "$seen" >/dev/null
          fi
        done < <(
          {
            yq -r '[(.sources // [])[], .home // ""] | .[] | select(. != "")' "$head_chart/Chart.yaml" 2>/dev/null || true
            # Classic chart repositories served from GitHub Pages
            # (https://<owner>.github.io/<repo>) publish their releases on
            # github.com/<owner>/<repo>, often missing from the chart's sources.
            if [[ "$repo" =~ ^https://([^./]+)\.github\.io/([^/]+) ]]; then
              echo "https://github.com/${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
            fi
          } | sort -u
        )
      fi

      charts_json="$(jq -c --arg label "$label" --arg name "$name" --arg base "$base_version" --arg head "$head_version" \
        --arg latest "$latest" --arg base_app "$base_app" --arg head_app "$head_app" --argjson newer "$newer" \
        --slurpfile va "$va" \
        '. + [{release: $label, chart: $name, base: $base, head: $head, latest: $latest, newer_available: $newer,
          base_app: $base_app, head_app: $head_app,
          removed_keys: ($va[0].removed | length), unknown_keys: ($va[0].unknown | length),
          redundant_values: ($va[0].redundant | length)}]' <<<"$charts_json")"
    done

    # Per-resource render diff.
    for side in base head; do
      mkdir -p "$rdir/resources/$side"
      if [[ -s "$rdir/$side.yaml" ]]; then
        yq 'select(.kind != null)' "$rdir/$side.yaml" >"$rdir/.$side.clean.yaml"
        (cd "$rdir/resources/$side" &&
          yq -s '(.kind) + "." + (.metadata.namespace // "_") + "." + (.metadata.name // "unnamed")' "$rdir/.$side.clean.yaml")
      fi
    done
    diff -ruN "$rdir/resources/base" "$rdir/resources/head" >"$rdir/render.diff" || true
    added="$(diff -rq "$rdir/resources/base" "$rdir/resources/head" 2>/dev/null | grep -c "^Only in $rdir/resources/head" || true)"
    removed="$(diff -rq "$rdir/resources/base" "$rdir/resources/head" 2>/dev/null | grep -c "^Only in $rdir/resources/base" || true)"
    modified="$(diff -rq "$rdir/resources/base" "$rdir/resources/head" 2>/dev/null | grep -c '^Files .* differ$' || true)"
    crd_diff="$(diff <(yq -r 'select(.kind == "CustomResourceDefinition") | .metadata.name + " " + ([.spec.versions[] | .name + (if .storage then "*" else "" end)] | join(","))' "$rdir/base.yaml" 2>/dev/null | sort) \
      <(yq -r 'select(.kind == "CustomResourceDefinition") | .metadata.name + " " + ([.spec.versions[] | .name + (if .storage then "*" else "" end)] | join(","))' "$rdir/head.yaml" 2>/dev/null | sort) | grep '^[<>]' || true)"
    {
      echo "#### Render"
      echo
      echo "- Resources: $added added, $removed removed, $modified changed — \`$rdir/render.diff\`"
      if [[ -s "$rdir/base.render.err" && ! -s "$rdir/base.yaml" ]]; then
        echo "- Base render failed: \`$rdir/base.render.err\`"
      fi
      echo
      if [[ -n "$crd_diff" ]]; then
        echo "CRD changes (\`<\` base, \`>\` head, \`*\` storage version):"
        echo
        echo '```'
        printf '%s\n' "$crd_diff"
        echo '```'
        echo
      fi
      if [[ "$added" -gt 0 || "$removed" -gt 0 ]]; then
        echo "Added/removed resources:"
        echo
        diff -rq "$rdir/resources/base" "$rdir/resources/head" 2>/dev/null | grep '^Only in' |
          sed "s|^Only in $rdir/resources/base: |- removed |; s|^Only in $rdir/resources/head: |- added |; s|\.yml$||" | capped 40
        echo
      fi
    } >>"$report"
  done <<<"$kusts"

  # Handwritten manifests (everything outside helm/).
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    cat "$f" >>"$base_all"
    echo '---' >>"$base_all"
  done < <(handwritten_files "$base_tree" "$component")
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    cat "$f" >>"$head_all"
    echo '---' >>"$head_all"
  done < <(handwritten_files "$head_tree" "$component")
  render_docs_json "$base_all" >"$cout/.base-all.json"
  render_docs_json "$head_all" >"$cout/.head-all.json"

  ns_found="$(jq -r --arg default_ns "" "$jq_stateful" "$cout/.head-all.json")"
  stateful_ns="$(printf '%s\n%s\n' "$stateful_ns" "$ns_found" | sed '/^$/d' | sort -u)"

  # Images.
  jq -r "$jq_images" "$cout/.base-all.json" >"$cout/images.base.txt"
  jq -r "$jq_images" "$cout/.head-all.json" >"$cout/images.head.txt"
  images_json="[]"
  {
    echo "#### Images"
    echo
    echo "| Image | Base | Head | Latest stable |"
    echo "| :--- | :--- | :--- | :--- |"
  } >>"$report"
  while IFS= read -r image; do
    [[ -n "$image" ]] || continue
    repo="$(image_repo "$image")"
    tag="$(image_tag "$image")"
    base_image="$(awk -v r="$repo" '{ i = $0; sub(/@.*/, "", i); n = split(i, a, "/"); last = a[n]; p = index(last, ":"); rr = (p ? substr(i, 1, length(i) - length(last) + p - 1) : i); if (rr == r) print $0 }' "$cout/images.base.txt" | head -n1)"
    base_tag="$(image_tag "$base_image")"
    latest="$(latest_image "$image")"
    mark=""
    if [[ -n "$latest" && "$latest" != "$tag" ]] &&
      [[ "$(printf '%s\n%s\n' "${tag%%@*}" "$latest" | sort -V | tail -n1)" == "$latest" ]]; then
      mark=" **newer**"
    fi
    echo "| \`$repo\` | \`${base_tag:-new}\` | \`${tag:-untagged}\` | \`${latest:-unknown}\`$mark |" >>"$report"
    images_json="$(jq -c --arg image "$repo" --arg base "$base_tag" --arg head "$tag" --arg latest "$latest" \
      --argjson newer "$([[ -n "$mark" ]] && echo true || echo false)" \
      '. + [{image: $image, base: $base, head: $head, latest: $latest, newer_available: $newer}]' <<<"$images_json")"

    # Application release notes for a changed tag, from the image's source label.
    if [[ -n "$base_tag" && "${base_tag%%@*}" != "${tag%%@*}" ]]; then
      src="$(image_source "$image")"
      slug="$(repo_slug "$src")"
      if [[ -n "$slug" ]]; then
        names="$(jq -cn --arg n "${repo##*/}" '[$n | ascii_downcase]')"
        collect_notes "$slug" "${base_tag%%@*}" "${tag%%@*}" "$names" "$notes" "$seen" >/dev/null
      else
        echo "- no OCI source label on \`$image\`: find its release notes manually" >>"$cout/.notes-gaps"
      fi
    fi
  done <"$cout/images.head.txt"
  echo >>"$report"

  # Conventions.
  jq -r "$jq_conventions" "$cout/.head-all.json" >"$cout/conventions.head.txt"
  jq -r "$jq_conventions" "$cout/.base-all.json" >"$cout/conventions.base.txt"
  comm -13 "$cout/conventions.base.txt" "$cout/conventions.head.txt" >"$cout/conventions.regressions.txt"
  {
    echo "#### Conventions"
    echo
    echo "- Findings on head: $(wc -l <"$cout/conventions.head.txt" | tr -d ' ') — \`$cout/conventions.head.txt\` (compare with the documented exceptions in docs/pod-security.md)"
    if [[ -s "$cout/conventions.regressions.txt" ]]; then
      echo "- **New since base ($(wc -l <"$cout/conventions.regressions.txt" | tr -d ' ')):**"
      sed 's/^/  - /' "$cout/conventions.regressions.txt" | capped 40
    fi
    echo
  } >>"$report"

  # Stateful.
  {
    echo "#### State"
    echo
    if [[ -n "$stateful_ns" ]]; then
      echo "- Stateful: yes — namespaces: $(printf '%s\n' "$stateful_ns" | sed 's/.*/`&`/' | paste -sd, - | sed 's/,/, /g')"
    else
      echo "- Stateful: no"
    fi
    echo
  } >>"$report"

  # Release notes.
  releases="$(grep -c '^<!-- release ' "$notes" || true)"
  {
    echo "#### Release notes"
    echo
    if [[ "$releases" -gt 0 ]]; then
      echo "- $releases release(s) in range — \`$notes\`"
      sed -n 's/^<!-- release \(.*\) -->$/  - \1/p' "$notes"
      echo
      flagged="$(awk -v pat="$flag_pattern" '
        /^<!-- release / { tag = $3 " " $4; next }
        tolower($0) ~ pat { line = $0; gsub(/^[ \t*#-]+/, "", line); if (length(line) > 220) line = substr(line, 1, 220) "…"; print "- [" tag "] " line }
      ' "$notes")"
      if [[ -n "$flagged" ]]; then
        echo "Flagged lines (breaking, deprecated, removed, renamed, migration):"
        echo
        printf '%s\n' "$flagged" | capped 80
        echo
      fi
    else
      echo "- No release notes found in range; check the Renovate PR body and the projects' CHANGELOGs."
      echo
    fi
    if [[ -f "$cout/.notes-gaps" ]]; then
      cat "$cout/.notes-gaps"
      echo
    fi
  } >>"$report"

  jq -cn --arg component "$component" --argjson charts "$charts_json" --argjson images "$images_json" \
    --arg stateful "$stateful_ns" --argjson render_failed "$render_failed" \
    --argjson regressions "$(wc -l <"$cout/conventions.regressions.txt" | tr -d ' ')" \
    --argjson releases "$releases" \
    '{component: $component, stateful_namespaces: ($stateful | split("\n") | map(select(. != ""))),
      render_failed: $render_failed, convention_regressions: $regressions, release_notes: $releases,
      charts: $charts, images: $images}' >>"$summary_items"
done

jq -s --arg base "$base_sha" --arg head "$head_sha" '{base: $base, head: $head, components: .}' "$summary_items" >"$out_dir/summary.json"

rm -f "$out_dir"/*/.base-all.yaml "$out_dir"/*/.head-all.yaml
echo "$out_dir"
