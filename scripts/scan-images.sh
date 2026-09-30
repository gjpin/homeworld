#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

images=()

if [[ $# -ge 1 ]] && [[ "$1" =~ : ]]; then
  images+=("$1")
else
  if [[ -n "${1:-}" ]]; then
    base_ref="$1"
  elif [[ -n "${GITHUB_BASE_REF:-}" ]]; then
    # Pull request: diff against the PR base branch (existing behavior).
    base_ref="$GITHUB_BASE_REF"
  elif git rev-parse --verify "HEAD~1" >/dev/null 2>&1; then
    # Push event: GITHUB_BASE_REF is unset and origin/main points at HEAD,
    # which would produce an empty diff, so diff against the previous commit.
    base_ref="HEAD~1"
  else
    # Single-commit repo: no HEAD~1 exists, so diff against the empty tree
    # to scan the full image inventory instead of nothing.
    base_ref="4b825dc642cb6eb9a060e54bf8d69288fbee4904"
  fi
  if [[ "$base_ref" != "4b825dc642cb6eb9a060e54bf8d69288fbee4904" ]] && ! git rev-parse --verify "$base_ref" >/dev/null 2>&1; then
    if git rev-parse --verify "origin/$base_ref" >/dev/null 2>&1; then
      base_ref="origin/$base_ref"
    elif git rev-parse --verify "origin/main" >/dev/null 2>&1; then
      base_ref="origin/main"
    elif git rev-parse --verify "main" >/dev/null 2>&1; then
      base_ref="main"
    else
      base_ref="HEAD~1"
    fi
  fi

  echo "Finding updated container images against $base_ref..."
  while IFS= read -r img; do
    if [[ -n "$img" ]]; then
      images+=("$img")
    fi
  done < <(python3 - "$base_ref" <<'EOF'
import sys, subprocess, os, json, re

base_ref = sys.argv[1]

def extract_images_from_obj(obj):
    images = set()
    if isinstance(obj, dict):
        if "repository" in obj and "tag" in obj:
            repo = str(obj["repository"]).strip()
            tag = str(obj["tag"]).strip()
            registry = str(obj.get("registry", "")).strip()
            if repo and tag:
                if registry:
                    images.add(f"{registry}/{repo}:{tag}")
                else:
                    images.add(f"{repo}:{tag}")
        for k, v in obj.items():
            if k in ("image", "imageName", "version") and isinstance(v, str) and ":" in v:
                if not re.match(r"^[a-zA-Z]+(?:\.[a-zA-Z0-9.-]+)?/v[0-9]+", v):
                    images.add(v.strip())
            else:
                images.update(extract_images_from_obj(v))
    elif isinstance(obj, list):
        for item in obj:
            images.update(extract_images_from_obj(item))
    return images

def get_file_images(content):
    images = set()
    try:
        p = subprocess.run(["yq", "-o=json", "-I=0", "."], input=content, capture_output=True, text=True, check=True)
        for line in p.stdout.strip().split("\n"):
            if line.strip():
                try:
                    obj = json.loads(line)
                    images.update(extract_images_from_obj(obj))
                except Exception:
                    pass
    except Exception:
        pass
    return images

try:
    changed_files_raw = subprocess.check_output(
        ["git", "diff", "--name-only", base_ref, "--", "apps/"], text=True
    ).strip()
    changed_files = [
        f for f in changed_files_raw.splitlines()
        if f.endswith((".yaml", ".yml")) and "charts/" not in f and "incubator/" not in f
    ]
except Exception:
    changed_files = []

try:
    untracked_raw = subprocess.check_output(
        ["git", "ls-files", "--others", "--exclude-standard", "apps/"], text=True
    ).strip()
    if untracked_raw:
        for f in untracked_raw.splitlines():
            if f.endswith((".yaml", ".yml")) and "charts/" not in f and "incubator/" not in f:
                if f not in changed_files:
                    changed_files.append(f)
except Exception:
    pass

images_to_scan = set()

for path in changed_files:
    try:
        old_content = subprocess.check_output(["git", "show", f"{base_ref}:{path}"], stderr=subprocess.DEVNULL, text=True)
        old_imgs = get_file_images(old_content)
    except Exception:
        old_imgs = set()
    if os.path.exists(path):
        try:
            with open(path, "r") as f:
                new_imgs = get_file_images(f.read())
        except Exception:
            new_imgs = set()
    else:
        new_imgs = set()
    images_to_scan.update(new_imgs - old_imgs)

try:
    raw_diff = subprocess.check_output(["git", "diff", "-U3", base_ref, "--", "apps/"], text=True)
    current_repo = None
    for line in raw_diff.splitlines():
        if line.startswith("+++"):
            current_repo = None
            continue
        m_repo = re.search(r'repository:\s*["\']?([a-zA-Z0-9._/-]+)["\']?', line)
        if m_repo:
            current_repo = m_repo.group(1).strip()
        if line.startswith("+") and not line.startswith("+++"):
            m = re.search(r'(?:image|imageName):\s*["\']?([a-zA-Z0-9._/-]+:[a-zA-Z0-9._-]+)["\']?', line)
            if m:
                images_to_scan.add(m.group(1).strip())
            m_tag = re.search(r'tag:\s*["\']?([a-zA-Z0-9._-]+)["\']?', line)
            if m_tag and current_repo:
                images_to_scan.add(f"{current_repo}:{m_tag.group(1).strip()}")
except Exception:
    pass

for img in sorted(images_to_scan):
    if "${" not in img and "$" not in img and ":" in img:
        print(img)
EOF
  )
fi

if [[ ${#images[@]} -eq 0 ]]; then
  echo "No updated container images detected."
  exit 0
fi

echo "Images to scan: ${images[*]}"
failed=0
for img in "${images[@]}"; do
  echo "Scanning $img with Trivy..."
  if ! trivy image --exit-code 1 --severity CRITICAL,HIGH --ignore-unfixed "$img"; then
    echo "ERROR: Vulnerabilities detected in $img" >&2
    failed=1
  fi
done

if [[ $failed -ne 0 ]]; then
  echo "Trivy scan failed: unpatched Critical/High CVEs found." >&2
  exit 1
fi

echo "All scanned images passed security checks."
