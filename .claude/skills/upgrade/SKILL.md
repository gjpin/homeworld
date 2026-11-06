---
name: upgrade
description: Review, fix, and merge Renovate dependency PRs end to end — compare the old and new charts, read every chart and application release note in range, adapt Helm values and application config to the target version, enforce the repository conventions, take a pre-merge Velero backup for stateful apps, then merge once CI passes. Use when asked to upgrade, update, or process Renovate PRs.
argument-hint: "[PR#… | component… | all] [--allow-jumps] [--no-cluster] [--dry-run]"
disable-model-invocation: true
---

# /upgrade

Works open Renovate PRs from review to merge. Renovate finds the versions
and runs CI; this skill does the part a human reviewer would: release notes,
values and configuration drift, conventions, and the merge itself.

AGENTS.md applies in full. docs/upgrades.md §4 (version stepping) and §9
(upstream procedures and the review checklist) are the reference for every
decision below.

## Arguments

- `PR#…` — specific PR numbers. `component…` — every open Renovate PR that
  touches `apps/<component>/`. `all` — every open Renovate PR, plus a
  coverage audit of components with no PR. No argument means `all`.
- `--allow-jumps` — ignore the version-stepping rules of docs/upgrades.md §4
  and go straight to the latest stable release. Only valid while the cluster
  is not deployed; without it, stepping rules are followed.
- `--no-cluster` — the cluster is not deployed: skip the live gates (Velero
  backup, Cilium pre-flight). Without it, an unreachable cluster blocks every
  merge that needs a live gate.
- `--dry-run` — review and propose only: no commits, pushes, merges, PR
  closes, or live actions. Report the proposed diff per PR.

## What this skill may do without asking

- Push commits to `renovate/*` PR branches and merge those PRs (merge
  commit, `gh pr merge --merge --delete-branch`).
- Close superseded Renovate PRs (intermediate versions under
  `--allow-jumps`) with a comment naming the PR that supersedes them.
- Commit Renovate coverage fixes (`renovate.json`) straight to `main`.
- On the live cluster, run exactly two things: `scripts/pre-upgrade-backup.sh`
  (creates a Velero `Backup`) and `scripts/cilium-preflight.sh` (applies and
  deletes the Cilium pre-flight resources). No other `kubectl apply`,
  `create`, `delete`, `helm install`, or Argo CD sync.

Never force-push, never push PR work to `main`, never merge with failing CI.

## Workflow

### 1. Prepare

- Require a clean working tree on `main`; `git pull --ff-only`.
- `gh auth status` must pass. Tools: `yq jq kubectl helm crane gh timeout`.
- Work directory: a fresh directory under your scratchpad (or `mktemp -d`).

### 2. Collect the work

```bash
gh pr list --state open --limit 200 \
  --json number,title,headRefName,body,files \
  --jq '[.[] | select(.headRefName | startswith("renovate/"))]'
```

Map the arguments to PRs. For each PR record the component(s) it touches
(`apps/<component>/`), or "outside apps" (GitHub Actions, host pins, e2e).

Stepping: Renovate opens one PR per minor for the components with
`separateMultipleMinor` (Cilium, Longhorn, cert-manager, External Secrets)
and one PR per major where `separateMultipleMajor` is set. Group PRs of the
same package.
- With `--allow-jumps`: keep the highest target, close the others (comment:
  "Superseded by #N: the cluster is not deployed yet, so the stepping
  constraint in docs/upgrades.md §4 does not apply.").
- Without it: process the group in ascending order; a later PR waits until
  the earlier one is merged.

Order: sort PRs by the component's sync wave in `apps/app-of-apps.yaml`
(CRD and operator providers before their consumers), then by PR number.
PRs outside `apps/` go last.

Coverage audit (only for `all`):

```bash
scripts/upgrade-report.sh --base origin/main --head origin/main --all --out <work>/audit
```

In `<work>/audit/summary.json`, every chart or image with
`newer_available: true` and no open PR is a candidate gap. Confirm it on the
Dependency Dashboard issue (`gh issue list --search "Dependency Dashboard"`):
pending or rate-limited is not a gap; a dependency Renovate does not detect
at all, or a rule that hides the version, is. Fix real gaps in
`renovate.json` on `main` (custom regex manager or package rule, matching
the existing style), parse it with `jq empty renovate.json`, commit, push,
and list them in the summary. The newer version then arrives as a PR on the
next Renovate run; do not bump it by hand.

### 3. Report and review (parallel)

For every PR, bring the branch up to date first, then generate the report
against current `main`:

```bash
gh pr update-branch <N>   # merges main into the PR branch
git fetch origin
scripts/upgrade-report.sh --base origin/main --head origin/<branch> --out <work>/pr-<N>
```

The report must not warn that head is behind `origin/main`; if it does,
update the branch again.

**Patch fast path.** A PR qualifies when every row of the PR body's
Renovate table has Update `patch`, `digest`, or `pinDigest`, and the body
carries no `prBodyNotes` warning (⚠️). Triage it yourself from the report
instead of dispatching a reviewer:

- `summary.json`: `render_failed` false and `convention_regressions` empty.
- Render: 0 resources added or removed, and `render.diff` changes only
  image tags, chart/version labels, and checksum annotations. Default-values
  diff empty, or only image tags and appVersion.
- Release notes: `release-notes.md` (or the PR body when the report found
  none) exists for every release in range. Read it, paying particular
  attention to anything matching
  `breaking|deprecat|remov|renam|migrat|manual|action required|CRD|telemetry|analytics|usage stat|tracking|update check`.
  None of them may touch a setting, resource, or behavior this repository
  uses.
- The target artifact exists: the report's image table, `crane digest`, or
  the chart repository index.

If every check holds, the PR goes straight to step 4 with no commit. If
any check fails, or you are unsure, send it to a full reviewer like any
other PR. Fast-path PRs can start merging while the full reviews run.

Dispatch one subagent for each remaining PR, all in one message so they run in
parallel. Give each `isolation: "worktree"` and the prompt in
[Reviewer prompt](#reviewer-prompt). Fill in the PR number, branch, report
directory, the flags, and the stepping constraint for that component from
docs/upgrades.md §4.

### 4. Merge (sequential)

Process the PRs in the order from step 2. For each:

1. **Blockers.** If the reviewer reported a blocker, do not merge. Comment
   on the PR with the blocker and the exact action needed, and move on.
   Blockers are: a decision that belongs to the user (AGENTS.md: telemetry
   that may be a feature, data-loss risk), an Immich major (mobile apps
   first), a Gateway API or Kubernetes/k3s minimum the cluster does not meet,
   a stepping violation without `--allow-jumps`, an unsupported upgrade
   path, or anything the reviewer could not verify.
2. **Up to date.** `gh pr update-branch <N>` if `main` moved since the
   review. On a conflict, check out the branch, merge `origin/main`,
   resolve it, render and validate the component again, and push.
3. **Live gates** (skipped with `--no-cluster`):
   - Stateful component (`stateful_namespaces` in the report's
     `summary.json` is non-empty): run
     `scripts/pre-upgrade-backup.sh <namespace>...` in the background
     (`run_in_background`) and wait for it. Exit 0: continue. Exit 1: block
     (backup failed). Exit 3: block (cluster unreachable without
     `--no-cluster`).
   - Cilium minor bump: run `scripts/cilium-preflight.sh <target>` in the
     background. Non-zero: block and paste the cnp-validator logs into a PR
     comment.
4. **CI.** `gh pr checks <N> --watch --fail-fast` (in the background). On a
   failure, read `gh run view <run> --log-failed`, fix it on the branch, push,
   and wait again; after two failed fix attempts, block.
5. **Merge.** `gh pr merge <N> --merge --delete-branch`, then
   `git pull --ff-only` on `main`.

With `--dry-run`, stop after step 3 and present each reviewer's proposed
diff and findings.

### 5. Summary

End with one table, one row per PR:

| PR | Component | From → To | Review | Changes made | Result | Follow-up |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |

Review is `fast path` or `full`.

Result is merged, blocked (with the reason), or closed (superseded). Follow-up
lists post-merge steps from docs/upgrades.md §9 (e.g. `forgejo doctor check
--all`, Woodpecker migration actions, CNPG `vacuumdb --analyze-in-stages`
after a PostgreSQL major), the Velero backup name taken for each stateful
merge (the rollback point), notable new upstream features that were not
adopted, and the Renovate coverage gaps fixed. Then list anything blocked
with the exact action the user needs to take.

## Reviewer prompt

Use this prompt for each subagent, filled in:

```
You are upgrading one component of the homeworld repository (a Kubernetes
homelab managed by Argo CD). Work only on Renovate PR #<N>, branch <branch>.
Flags: <--allow-jumps | stepping enforced: <constraint>>, <--dry-run or not>.

Read AGENTS.md first; every rule in it applies. Then docs/upgrades.md §4 and
§9, and any docs/<component>.md.

Setup, in your worktree:
  git fetch origin && git switch -C <branch> origin/<branch>

Inputs:
- The upgrade report: <work>/pr-<N>/report.md, with per-release files under
  <work>/pr-<N>/<component>/ (default-values diff, values schema diff,
  values-analysis.json, render.diff, conventions.*.txt, release-notes.md).
- The PR body: gh pr view <N>.

Do all of the following:

1. Release notes. Read every chart and application release between the old
   and new version: release-notes.md, the PR body, and the upstream
   CHANGELOG, upgrade guide, and chart README "Upgrading" section. When the
   report says no notes were found, find them yourself. Collect breaking
   changes, removed or renamed settings, new prerequisites (CRD, Gateway
   API, Kubernetes, dependency minimums), required version stepping, and
   one-time manual steps.
2. Latest version. If the report shows a newer stable chart or image than
   the PR targets and stepping allows it (--allow-jumps, or no constraint
   for this component), bump this PR to the latest stable release — every
   place Renovate moves together for this package — and run
   scripts/upgrade-report.sh again for the new range.
3. Helm values (apps/<component>/helm/**/values.yaml and kustomization
   patches):
   - Keys the new chart removed or renamed: migrate them to the replacement.
   - Keys absent from both chart versions: confirm against the chart
     templates; delete dead configuration (e.g. subcharts the chart no longer
     has).
   - Values equal to the new default: remove them, unless they encode a
     repository convention that must survive an upstream default change
     (security contexts, telemetry and update checks off, resources,
     replicas, image registry/repository overrides). Keep those.
   - New chart options and changed defaults under keys we do not set:
     adopt what this homelab needs (new telemetry or phone-home knobs must
     be turned off; metrics/ServiceMonitor, security, and resource options
     follow AGENTS.md). Do not enable features speculatively; list notable
     ones you did not adopt.
   - Kustomize patches: each still matches its target and field in the new
     render.
4. Application configuration. For the target application version, check
   every config file, ConfigMap, environment variable, CLI flag, and CR
   field the component sets, against the upstream configuration reference:
   replace deprecated options, drop removed ones, and add new ones that a
   convention requires (telemetry off, metrics on, OIDC per the Authelia
   client guide).
   Home Assistant: the bootstrap init container seeds `.storage/http` in the
   HTTP store's own format (1_homeassistant_deployment.yaml). Compare
   `STORAGE_VERSION`, `STORAGE_MINOR_VERSION`, `HTTP_STORAGE_SCHEMA` and
   `_async_migrate_func` in `homeassistant/components/http/config.py` (and
   the default SSL profile in `http/const.py`) between the old and new
   tags. When any changed, rewrite the seed to the new format: the stable
   config with every schema key, `pending: null`, `yaml_migration_done:
   true`. Then confirm with the new `homeassistant` package that
   `async_load_config` on a fresh config directory holding the seed
   activates the stable config with no revert scheduled.
5. Conventions. Render the component (kubectl kustomize --enable-helm) and
   confirm every AGENTS.md requirement still holds in the output:
   Restricted security contexts, runtimeClassName gvisor or hostUsers:
   false, requests and limits on every container, 60s ServiceMonitors and
   PodMonitors, fully qualified images, Gateway/HTTPRoute alignment,
   network policies for new ports or egress, the base-domain.invalid
   placeholder (never a real domain) in new hostnames, CRD ordering, helm.sh/hook Jobs disabled or
   converted. Fix every regression the report lists. Pre-existing findings
   that are documented exceptions in docs/pod-security.md stay.
6. Docs. Update docs/ as AGENTS.md requires (pod-security tables,
   docs/upgrades.md §9 and the Renovate prBodyNotes when the release brings
   a new standing procedure). No application version numbers in docs.
7. Validate. Run the AGENTS.md validation commands relevant to the changed
   files and render again. Run scripts/scan-security.sh homelab when
   kubescape and kube-linter are installed; otherwise CI covers it.
8. Commit and push (skip with --dry-run). One commit, conventional style
   scoped to the component (e.g. "fix(forgejo): adapt values to chart 18"),
   whose body lists each change with the release note or doc that requires
   it. End the message with:
     Co-Authored-By: Claude <noreply@anthropic.com>
   Push to <branch> only. Never force-push, never push to main.

Do not touch the cluster (no kubectl apply/create/delete), do not merge or
close PRs, and do not change other components beyond what this upgrade
requires.

Stop and report a BLOCKER instead of guessing when: a decision belongs to
the user (a mechanism that may be telemetry or a feature; possible data
loss), the upgrade needs a prerequisite the cluster may not meet (Gateway
API or Kubernetes/k3s minimum), the path is unsupported or crosses a
stepping constraint, it is an Immich major, or you could not verify
something.

Reply with:
- PR, component, from → to (final target)
- Commit SHA pushed (or the proposed diff with --dry-run)
- Changes made, each with its reason
- Pre-merge manual steps (should be none unless BLOCKER)
- Post-merge steps (docs/upgrades.md §9)
- Notable new features not adopted
- BLOCKER: <reason and the exact action needed>, or "none"
```
