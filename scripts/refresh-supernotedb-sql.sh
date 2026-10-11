#!/usr/bin/env bash
# Re-vendor Supernote's database script into the supernotedb-seed SqlJob.
#
# Upstream publishes supernotedb.sql at a fixed, unversioned URL that its
# installer re-runs on every update as both seed and migration, so neither a
# Renovate datasource nor a version pin can track it. This script downloads
# the current script, normalizes its CRLF line endings to LF, and rewrites the
# SqlJob's `sql:` block and header checksum in apps/supernote/1_sql_job.yaml.
# Running it against an unchanged upstream leaves the file untouched.
#
# The check-supernotedb-sql workflow runs it daily and opens a PR when the
# file changes; it also works locally. The new script only reaches the
# database once the SqlJob is re-run (docs/upgrades.md, Supernote Database
# Script).

set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

manifest="apps/supernote/1_sql_job.yaml"
url="https://supernote-private-cloud.supernote.com/cloud/supernotedb.sql"

sql="$(mktemp)"
out="$(mktemp)"
trap 'rm -f "${sql}" "${out}"' EXIT

curl -fsSL --retry 3 -o "${sql}" "${url}"

# Table names created by a script, in any of upstream's spellings
# (`supernotedb.`name``, `name`, bare name; with or without IF NOT EXISTS).
tables() {
  { grep -ioE 'create[[:space:]]+table[[:space:]]+(if[[:space:]]+not[[:space:]]+exists[[:space:]]+)?[`a-z0-9_.]+' || true; } |
    sed -E 's/.*[[:space:]]//; s/`//g; s/.*\.//' | tr '[:upper:]' '[:lower:]' | sort -u
}

# Upstream's script only ever adds tables, so a download that drops one is
# truncated or not the real script (an error page served with HTTP 200, a
# placeholder after a move): refuse it instead of vendoring it.
new_tables="$(tables <"${sql}")"
if [[ -z "${new_tables}" ]]; then
  echo "refresh-supernotedb-sql: ${url} did not return a SQL script (no CREATE TABLE statements)" >&2
  exit 1
fi
missing="$(comm -23 <(sed -n '/^  sql: |$/,$p' "${manifest}" | tables) <(printf '%s\n' "${new_tables}"))"
if [[ -n "${missing}" ]]; then
  echo "refresh-supernotedb-sql: ${url} no longer creates tables the vendored script does; refusing to vendor it:" >&2
  while read -r table; do echo "  ${table}"; done <<<"${missing}" >&2
  exit 1
fi

if command -v sha256sum >/dev/null 2>&1; then
  sum="$(sha256sum "${sql}" | cut -d' ' -f1)"
else
  sum="$(shasum -a 256 "${sql}" | cut -d' ' -f1)"
fi

# Everything up to and including the `sql: |` line is kept; the block below
# it is replaced by the upstream script indented four spaces (blank lines
# stay empty, and upstream's final-newline state is preserved).
header_lines="$(grep -n '^  sql: |$' "${manifest}" | cut -d: -f1)"
if [[ -z "${header_lines}" ]]; then
  echo "refresh-supernotedb-sql: no 'sql: |' block found in ${manifest}" >&2
  exit 1
fi
{
  head -n "${header_lines}" "${manifest}" |
    sed -E "s/^(# sha256 )[0-9a-f]{64}/\\1${sum}/"
  tr -d '\r' <"${sql}" | sed 's/^\(.\)/    \1/'
} >"${out}"

if ! grep -q "^# sha256 ${sum}" "${out}"; then
  echo "refresh-supernotedb-sql: failed to patch the sha256 header in ${manifest}" >&2
  exit 1
fi

if cmp -s "${out}" "${manifest}"; then
  echo "refresh-supernotedb-sql: ${manifest} already vendors sha256 ${sum}"
else
  cat "${out}" >"${manifest}"
  echo "refresh-supernotedb-sql: ${manifest} now vendors sha256 ${sum}"
fi
