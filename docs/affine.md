# AFFiNE

AFFiNE is a docs, whiteboard, and database workspace at `https://affine.base-domain.invalid`. AFFiNE publishes no official Helm chart, so `apps/affine` implements its official Docker Compose deployment as handwritten manifests, with each Compose service replaced by the cluster's own building blocks.

## Components

| Compose service | Here |
| --- | --- |
| `affine` | `affine` Deployment (gVisor, UID `1000`), port `3010`; Prometheus metrics on `9464`. The image's `/app` is root-owned, so the GraphQL schema the server regenerates at every start (`/app/src/schema.gql`) goes to an emptyDir |
| `affine_migration` | The Deployment's `migrate` init container (`self-host-predeploy.js`): Prisma schema migrations, then data migrations, on every pod start, so each image bump migrates before the new server starts (`Recreate` strategy) |
| `postgres` (pgvector) | CloudNativePG `Cluster` `affine`; `vector` and `pgcrypto` are created at bootstrap and kept by the `Database` CR |
| `redis` | `Dragonfly` `dragonfly` (job queues, cache, sessions) |
| `./data/storage` | RustFS buckets `affine-blobs`, `affine-avatars`, and `affine-copilot` on the shared Tenant (the `aws-s3` storage provider, path-style, server-side uploads); no PVC |
| `./config` | The `affine-config` Secret (`config.json` and `private.key`), mounted read-only at `/home/node/.affine/config` |
| Indexer (disabled in Compose) | Manticore Search from the official chart (`apps/affine/helm`, nested `affine-manticore` application at intra-component wave 0): one worker StatefulSet on a 2 GiB Longhorn volume, balancer disabled, telemetry off |

## Configuration

`config.json` is rendered by the `affine-config` ExternalSecret because it carries credentials AFFiNE reads only from the file: the OIDC client secret, the RustFS keypair, and the Exa and Unsplash keys. Settings changed in the admin panel (`/admin/settings`) are stored in the database and override the file. Edit the template in `apps/affine/-1_secrets.yaml` for anything that should stay declarative, then restart the pod (`kubectl -n affine rollout restart deploy/affine`), since the server reads the file only at startup.

The server key (`/affine/PRIVATE_KEY`) signs sessions and encrypts the BYOK keys that workspace owners store on the server. Keep it stable: rotating it invalidates every stored key and session.

## Sign-in

Authelia client `affine`; sign-in requires `affine-user` ([oidc.md](oidc.md)). Registration is closed except through OIDC, so every `affine-user` gets an account on first sign-in. The instance admin is the email/password account created in the `/admin` setup wizard on first start: create it right after the first sync. No SMTP is configured, so invitation and magic-link emails are not sent; invite members by sharing workspace invite links.

## AI

`copilot.enabled` turns on AFFiNE AI. AFFiNE does not take provider keys from server configuration: each workspace owner or admin adds them under **Workspace Settings → Integrations → AI BYOK**, and AFFiNE stores them encrypted in the database (or only in the browser, when the key is saved locally). The server allows the built-in providers `openai`, `anthropic`, `gemini`, and `fal`, plus custom OpenAI-compatible endpoints (`byok.allowCustomEndpoint`); endpoints on private networks stay blocked (`byok.allowPrivateEndpoint: false`).

| Provider | BYOK provider | Endpoint | API dialect |
| --- | --- | --- | --- |
| OpenAI | OpenAI | Provider default | — |
| Anthropic | Anthropic | Provider default | — |
| Google Gemini | Gemini | Provider default | — |
| fal (image generation) | fal | Provider default | — |
| OpenRouter | OpenAI, OpenAI-compatible endpoint | `https://openrouter.ai/api/v1` | Chat Completions |
| Mistral | OpenAI, OpenAI-compatible endpoint | `https://api.mistral.ai/v1` | Chat Completions |
| DeepSeek | OpenAI, OpenAI-compatible endpoint | `https://api.deepseek.com/v1` | Chat Completions |
| OpenCode Zen | OpenAI, OpenAI-compatible endpoint | `https://opencode.ai/inference/openai/v1` | Chat Completions |

The `allow-affine-ai-providers` CiliumNetworkPolicy allows exactly these hosts (and fal's media hosts) on `443`. A custom endpoint on any other host fails its connection probe until the host is added there and to [network-policies.md](network-policies.md).

Workspace AI search over documents (embeddings) needs a provider that serves an embedding model: OpenAI, Gemini, or Mistral (`mistral-embed`). DeepSeek serves chat models only. Embeddings land in PostgreSQL through pgvector.

AI web search uses the Exa key (`/affine/EXA_API_KEY`) and image search in documents uses the Unsplash key (`/affine/UNSPLASH_API_KEY`); both are server-wide.

## Search

`indexer.enabled` points AFFiNE at `http://manticore-worker-svc.affine.svc.cluster.local:9308`. Manticore holds derived data only: AFFiNE writes documents into it as they change. The chart's worker runs a replication supervisor that lists its peer pods through the Kubernetes API, scoped by a namespaced Role; with one worker it forms a single-node cluster, and tables stay outside it (`autoAddTablesInCluster: false`) because AFFiNE writes plain table names.

## Calendar

CalDAV sync offers one provider, OpenCloud (`https://cloud.base-domain.invalid/caldav/`, the DAV proxy in front of Radicale). Users connect it with their OpenCloud username and an OpenCloud app token. `blockPrivateNetwork` is off because the hostname resolves to the private Gateway VIP; `allowedHosts` limits CalDAV requests to that one host. Google Calendar sync is not configured (it needs a Google OAuth application).

## Telemetry

Server-side analytics forward to GA4 only when a measurement ID is configured; none is. The server's release check (`affine.pro/api/worker/releases`) and Prisma's update and usage checks have no egress (`CHECKPOINT_DISABLE` is set as well). Manticore telemetry is disabled in its `searchd` configuration.

The web client bundles a Sentry error reporter that the browser sends to `sentry.io` directly, outside the cluster's egress policies. It honours AFFiNE's per-browser telemetry setting: turn telemetry off in each browser's AFFiNE settings, or block `ingest.sentry.io` in the router's DNS filter.

## Metrics

`metrics.enabled` starts AFFiNE's OpenTelemetry Prometheus exporter on `9464` (`ServiceMonitor` `affine`); it also starts a Zipkin trace exporter that targets `localhost:9411` and drops its spans, since nothing listens there. Manticore's `/metrics` (port `9308`), the CloudNativePG instance, and the Dragonfly operand are scraped at 60s. Grafana's AFFiNE folder holds the AFFiNE and Manticore Search dashboards ([grafana-dashboards.md](grafana-dashboards.md)).
