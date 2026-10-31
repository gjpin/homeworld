# Media Stack

The media automation, download and streaming apps (the README's *arr Stack
table) share one NAS library and are wired together by an hourly job. This
page records how they fit together: the design choices, the per-app
packaging, who owns which job, and what is automated. Every app syncs at
app-of-apps wave 7, after qBittorrent and Authelia; the Intel GPU plugin
syncs at wave 3. The one-time UI steps are in the README's
[Set Up the Media Stack](../README.md#15-set-up-the-media-stack).

## Design

| Topic | Choice |
| --- | --- |
| Library storage | One NAS share for downloads and libraries, so imports hardlink ([nas.md](nas.md#media-share)) |
| Sonarr line | The development (beta) line, the only one the rootless `home-operations` image builds |
| Indexer traffic | Direct, not through the VPN (private trackers ban VPN exits; Cloudflare penalises them) |
| Prowlarr/FlareSolverr egress | A documented world `80`/`443` exception, like Woodpecker's pipeline egress (indexer hosts are open-ended) |
| 4K | Preferred: one Sonarr and one Radarr on TRaSH's combined 2160p profiles, falling back to lower resolutions ([below](#4k)) |
| Upgrades | Off in every Sonarr, Radarr and Lidarr profile: one download per title, the first grab stays |
| Older titles without a WEB release | Grabbed automatically: the profiles fall back to Blu-ray and lower resolutions |
| Collections | Jellyfin-Auto-Collections (Kometa's released versions support Plex only) |
| Jellyfin sign-in | Jellyfin's own login (no SSO plugin) |
| Jellyfin metadata | On the NAS share (`jellyfin/metadata`), not Longhorn; no backup |
| Jellyfin transcode cache | 32Gi `emptyDir` on corebox's disk, with throttling and segment deletion |
| Audiobookshelf podcasts | On (world `80`/`443` egress exception, podcast library read-write) |
| Navidrome artist info | AudioMuse-AI first for similar songs and artists, then Deezer, Last.fm, ListenBrainz |
| Music imports | Copied, not hardlinked, so beets can retag the library ([Music tagging](#music-tagging)) |
| Bindery packaging | Handwritten manifests (its chart is unpublished) |
| Books/audiobooks backup | Restic copies `media/books` and `media/audiobooks` nightly |
| qbit_manage | Live (`dry_run: False`); it must support the pinned qBittorrent (README step 15) |

### 4K

One instance each, on TRaSH's combined profiles (Sonarr **WEB-2160p
(Combined)**, Radarr **WEBDL 2160p (Combined)**) for their custom-format
scores, with the quality list widened by Recyclarr so every title finds a
release without manual steps: one group per resolution (WEB and Blu-ray
encodes equal inside it) from 2160p down to SD, plus, in Sonarr, TV
captures below the group of their resolution. Upgrades are off (and
propers/repacks are not preferred), so each title is downloaded once: the
first grab stays. The global delay profile, kept by media-config, holds a
fresh release back for 6 hours and then grabs the best release seen in that
window, at once if it is 2160p, so an early 1080p release does not beat a
2160p one posted soon after; older releases are past the delay and are
grabbed immediately. Remuxes and full discs stay out. Both sync the *DV (w/o
HDR fallback)* custom-format group, which avoids Dolby Vision releases
without an HDR10 layer, so HDR TVs without Dolby Vision still direct-play.

Release ranking is Sonarr's and Radarr's own, fixed in code: quality (the
profile order above), then custom-format score, then protocol, indexer
priority and (Radarr) indexer flags, then seeders, compared on a rounded
log10 scale (1–3, 4–31, 32–316, 317–3162 seeders each rank equal), then
size.

- **Direct play first.** 4K HEVC HDR clients (TVs, streaming boxes) play
  the file untouched: the cost is the NAS's network read (about 15–25 Mbit/s
  per 2160p WEB stream, far below the Pi's gigabit link at 4 streams).
- **Transcodes** (browsers, phones, SDR screens) run on corebox's UHD 730.
  Jellyfin's Intel guide puts the UHD 7xx series in its high-performance
  tier; tone mapping uses OpenCL, which also maps Dolby Vision profile 5.
  The UHD 730 has one video engine, so a few tone-mapped transcodes at once
  is the realistic load; measure it with `intel_gpu_top` while several
  clients transcode.
- **Storage**: a 2160p WEB release is roughly two to three times its 1080p
  counterpart.

Separate `radarr-4k`/`sonarr-4k` instances are not used: they only help
when some clients cannot be served 4K at all.

## Storage

The `homeworld-media` share, its layout, the hardlink rules and the
per-namespace PersistentVolumes are described in
[nas.md](nas.md#media-share). Every consumer runs as the share's owner,
`20004`. Cleanuparr needs no share: its queue cleaner, malware blocker and
blacklist sync work through the APIs, and the filesystem jobs belong to
qbit_manage.

| App | Mount | Access |
| --- | --- | --- |
| qBittorrent, Sonarr, Radarr, Lidarr, Bindery, Unpackerr | `/data` | read-write |
| qbit_manage | `/data` | read-write (orphans, no-hardlink tagging, recycle bin) |
| Bazarr | `/data/media` | read-write (subtitles next to media) |
| Audiobookshelf | `/data/media/audiobooks`, `/data/media/podcasts` | audiobooks read-only, podcasts read-write |
| Jellyfin | `/data/media`; `/metadata` (`jellyfin/metadata`) | library read-only; artwork, trickplay and chapter images read-write |
| Navidrome | `/data/media/music` | read-only |
| beets | `/data/media/music` | read-write (tags in place) |

## Per-app design

| App | Packaging | Image | Runtime | Database | Sign-in | Metrics |
| --- | --- | --- | --- | --- | --- | --- |
| Prowlarr | handwritten | `ghcr.io/home-operations/prowlarr` | gVisor | CNPG (main + log) | gateway OIDC + `External` | exportarr |
| FlareSolverr | handwritten | `ghcr.io/flaresolverr/flaresolverr` | gVisor | — | none (no route; Prowlarr-only ingress) | native `:8192` |
| Sonarr | handwritten | `ghcr.io/home-operations/sonarr` | gVisor | CNPG (main + log) | gateway OIDC + `External` | exportarr |
| Radarr | handwritten | `ghcr.io/home-operations/radarr` | gVisor | CNPG (main + log) | gateway OIDC + `External` | exportarr |
| Lidarr | handwritten | `ghcr.io/home-operations/lidarr` | gVisor | CNPG (main + log) | gateway OIDC + `External` | exportarr |
| Bindery | handwritten | `ghcr.io/vavallee/bindery` | gVisor | SQLite (Longhorn) | native OIDC | native `/metrics` |
| Bazarr | handwritten | `ghcr.io/home-operations/bazarr` | gVisor | CNPG | gateway OIDC | exportarr |
| Jellyfin | official chart (`jellyfin/jellyfin-helm`) | `docker.io/jellyfin/jellyfin` | runc + Intel iGPU (corebox) | SQLite (Longhorn) | native login | native `/metrics` (blocked on the route) |
| Seerr | official chart (`oci://ghcr.io/seerr-team/seerr/seerr-chart`) | `ghcr.io/seerr-team/seerr` | gVisor | CNPG | native (Jellyfin accounts) | — |
| Recyclarr | handwritten CronJob | `ghcr.io/recyclarr/recyclarr` | gVisor | — | — | — |
| Maintainerr | handwritten | `ghcr.io/maintainerr/maintainerr` | gVisor | SQLite (Longhorn) | gateway OIDC (no built-in login) | — |
| Cleanuparr | handwritten | `ghcr.io/cleanuparr/cleanuparr` | gVisor | CNPG | native login + native OIDC | — |
| Houndarr | official chart (`oci://ghcr.io/av1155/charts/houndarr`) | `ghcr.io/av1155/houndarr` | gVisor | SQLite (Longhorn) | gateway OIDC + built-in login | — |
| qbit_manage | handwritten CronJob | `ghcr.io/stuffanthings/qbit_manage` | gVisor | — | — | — |
| Audiobookshelf | handwritten | `ghcr.io/advplyr/audiobookshelf` | gVisor | SQLite (Longhorn) | native OIDC (official Authelia guide) | — |
| Jellyfin-Auto-Collections | handwritten CronJob | `ghcr.io/ghomashudson/jellyfin-auto-collections` (digest) | gVisor | — | — | — |
| Streamystats | handwritten (frontend + job server) | `ghcr.io/fredrikburmester/streamystats-*` | gVisor | CNPG (`vector`, `uuid-ossp`, `pg_trgm`) | native (Jellyfin accounts) | — |
| Navidrome | handwritten | `ghcr.io/navidrome/navidrome` | gVisor | SQLite (Longhorn) | native login | native `/metrics` |
| AudioMuse-AI | official chart (`NeptuneHub/AudioMuse-AI-helm`; its Redis and PostgreSQL off) | `ghcr.io/neptunehub/audiomuse-ai` | gVisor | CNPG | gateway OIDC + built-in login | — |
| Feishin | handwritten | `ghcr.io/jeffvli/feishin` | gVisor | — (static web client) | Navidrome accounts | — |
| beets | handwritten CronJob (no official image or chart) | `ghcr.io/linuxserver/beets` (`beet` run directly) | gVisor | SQLite (Longhorn) | — | — |
| Unpackerr | handwritten (no official chart) | `ghcr.io/unpackerr/unpackerr` | gVisor | — (environment-only config) | local admin over `kubectl port-forward` (no route) | native `/metrics` (API key) |
| media-config | handwritten CronJob | `docker.io/library/python` (standard library script) | gVisor | — | — | — |

Every image is multi-arch (amd64 + arm64). Every Pod uses the Restricted
security context, `readOnlyRootFilesystem` where the image allows it (not
FlareSolverr, which patches chromedriver under `/app`), requests and limits, and
`automountServiceAccountToken: false`. Postgres-capable apps use one
single-instance CNPG `Cluster` each (with a 60s `PodMonitor`).

Behaviour checked outside the cluster:

| Question | Result |
| --- | --- |
| Prowlarr on CNPG without a superuser (the Servarr wiki says VACUUM needs one) | Migrations and the `Housekeeping` command complete with a `NOSUPERUSER` owner: VACUUM processes every Prowlarr table and only skips the shared catalogs (`pg_authid`, `pg_database`, …) with warnings, which autovacuum maintains. |
| FlareSolverr's Chromium under gVisor | Runs under the pinned `runsc` (systrap, netstack) as UID 1000 with all capabilities dropped, on arm64 and x86_64: the browser starts, JavaScript runs, metrics answer on `:8192`. The image ships no `/etc/hosts`; the kubelet's mount provides `localhost`. |
| Hardlinks under gVisor | Through the gofer as UID 20004: `ln` gives one inode with `st_nlink` 2, renames across directories work, unlink drops it to 1. Over NFS, check it once on the cluster ([nas.md](nas.md#media-share)). |
| AudioMuse-AI as non-root, read-only | The web app and worker ran as UID/GID 1000 with a read-only root filesystem, all capabilities dropped and the manifest's environment and emptyDir mounts, against a UTF-8 PostgreSQL and a Navidrome: the admin is seeded from the environment (the setup wizard is skipped), a full analysis of a test album completed (musicnn, CLAP, lyrics detection, every index), and `/api/similar_tracks` answers the plugin's bearer token. No write outside the emptyDirs. |
| beets as non-root, read-only | The CronJob's script and config ran as UID/GID 20004 with a read-only root filesystem and all capabilities dropped, bypassing the image's s6 init: the library and state are written to `/config`, an unmatched album is skipped with its files byte-identical, and a second run skips the imported folder in seconds. beets writes files only for an applied match (`beet write` on an as-is album fills empty fields with zeros), hence `quiet_fallback: skip`. |
| media-config against the apps | Each step ran against the pinned Sonarr, Radarr, Lidarr, Prowlarr, Seerr, Maintainerr, Bindery, qBittorrent and Jellyfin images: the first run creates everything, a second changes nothing. qBittorrent's `WebUI\ServerDomains` must be quoted (Qt's INI parser treats `;` as a comment), which its seed does. The Bazarr step and Lidarr's copy and tag-writing settings were checked against the apps' API source only. |

### Sign-in

- **Gateway OIDC** (`envoy` client, `platform` group): Prowlarr, Sonarr,
  Radarr, Lidarr, Bazarr, Maintainerr, Houndarr, AudioMuse-AI. Machine
  consumers use the in-cluster Services.
- **Native Authelia clients**: `audiobookshelf` (official guide; RS256 instead
  of the guide's `none`; no role claim, roles are set in Audiobookshelf),
  `bindery` (`bindery-admin`/`bindery-user`; media-config sets the provider),
  `cleanuparr` (`client_secret_post`: its ASP.NET handler posts the secret in
  the body).
- **App-native**: Jellyfin, Seerr and Streamystats (Jellyfin accounts), and
  Navidrome and Feishin (Navidrome accounts; Subsonic clients); their
  mobile/API clients cannot complete a gateway OIDC redirect.
- Servarr `External` auth hands the API key to whoever loads the UI, so each
  *arr's ingress allows Envoy and the named consumers only, and never uses
  `DisabledForLocalAddresses`.
- Cleanuparr's setup endpoints are anonymous until the first account exists:
  complete setup over `kubectl port-forward` before relying on the route.

The per-app details are in [oidc.md](oidc.md).

### Telemetry and phone-home

| App | Setting |
| --- | --- |
| Sonarr, Radarr, Lidarr, Prowlarr | `*__LOG__ANALYTICSENABLED=False`, `*__UPDATE__MECHANISM=Docker`; `*.servarr.com`/`sentry.*` not allowed (Sonarr's `services.sonarr.tv` is also scene mappings and stays allowed) |
| Bazarr | `analytics.enabled: false`, `general.auto_update: false` in the seeded `config.yaml`; `api.github.com`/`cdn.jsdelivr.net` not allowed |
| Maintainerr | `TELEMETRY=off`; `api.github.com` not allowed |
| Bindery | `BINDERY_TELEMETRY_DISABLED=true` |
| Navidrome | `ND_ENABLEINSIGHTSCOLLECTOR=false` |
| Seerr | `versionCheck: false` (seeded), `api.github.com` not allowed |
| Cleanuparr | Status Check off in the UI; `cleanuparr-status.pages.dev` not allowed |
| Streamystats | `NEXT_TELEMETRY_DISABLED=1`; update check blocked by egress |
| qbit_manage, Houndarr | version check fails closed (no egress) |
| Jellyfin | `EnableUPnP=false`, auto-discovery off, no DLNA plugin |
| Unpackerr | no telemetry; its update check exists only in the desktop tray build |
| AudioMuse-AI | no telemetry; `PLUGINS_ENABLED=false` (no hourly plugin-catalog fetch from GitHub), Hugging Face offline, no AI provider configured |
| Feishin | `ANALYTICS_DISABLED=true` (Umami, loaded by the browser) |
| beets | no telemetry or update check; egress only to the enabled plugins' sources |

AudioMuse-AI's analysis, similarity, clustering and text search run on
models baked into its image. Without an AI provider, only its chat
playlists and AI playlist names are unavailable; enabling them needs a
provider's API key and egress to its hostname (or an in-cluster Ollama).

## Tool ownership

| Job | Owner | Disabled in |
| --- | --- | --- |
| Malware blocker (strict `blacklist` for Sonarr/Radarr, `blacklist_permissive` for Lidarr) | Cleanuparr | — |
| Queue cleaner (stalled, slow, failed imports, metadata) | Cleanuparr | — |
| Blacklist sync to qBittorrent (`blacklist_permissive`) | Cleanuparr | — |
| Tracker tags, share limits, unregistered removal, no-hardlink tagging, orphans, recycle bin | qbit_manage | Cleanuparr Download Cleaner |
| Proactive missing search | Houndarr | Cleanuparr Seeker proactive search |
| Library cleanup through the *arrs | Maintainerr | its qBittorrent and Jellyfin delete fallbacks |
| Extracting packed (RAR) downloads | Unpackerr | — |
| Music import and file names | Lidarr | beets (`copy`/`move` off) |
| Music tags, cover art, genres, lyrics, ReplayGain | beets | Lidarr (writes its MusicBrainz tags to new imports only) |
| Quality profiles and custom formats (Sonarr, Radarr) | Recyclarr | — |
| Cross-app connections, delay profiles, Lidarr's settings | media-config | — |

qbit_manage acts for real; Cleanuparr starts in its Dry Run mode.

### Music tagging

Lidarr imports every music download from `/data/torrents/music` into
`/data/media/music`, so beets does not import from the download folder
(each album would land twice), and an inotify watcher could not see
qBittorrent's or Lidarr's writes anyway: on NFS, inotify reports only the
watching pod's own changes. Instead:

1. Lidarr copies the album into the library (a hardlink would share its
   data with the seeding torrent, which a retag would then corrupt) and
   writes its MusicBrainz IDs into the copy.
2. Every 15 minutes the beets job passes each album folder Lidarr has not
   touched for 15 minutes to `beet import` in place (`copy` and `move` off,
   so Lidarr's paths stay valid; `incremental`, so each folder is tagged
   once). The MusicBrainz IDs make the match strong, and beets then writes
   its tags plus Cover Art Archive art (`cover.jpg`), Last.fm genres,
   LRCLIB synced lyrics and ReplayGain. A weaker match is skipped and keeps
   Lidarr's tags (`quiet_fallback: skip`): beets writes files only for an
   applied match, and writing an as-is album fills its empty fields with
   zeros (original date `0000`, disc `0`).
3. Navidrome's hourly scan picks up the new tags.

The torrent's own copy carries qbit_manage's `noHL` tag from the import on:
it seeds at least 7 days and is removed at a 2.0 ratio or after 30 days, so
music takes its space twice only for that time.

## Setup automation

`apps/media-config` runs an hourly CronJob (after Recyclarr) with a Python
standard-library script that reads each app's current settings through its
REST API and writes only what differs:

| App | Set by media-config |
| --- | --- |
| Sonarr, Radarr, Lidarr | qBittorrent download client (WebAPI key), root folder, Jellyfin library-refresh connection (once the Jellyfin key exists), global delay profile (torrent preferred, 6 hours, bypass at the highest quality) |
| Lidarr | upgrades off on every profile, propers not preferred, imports copied (not hardlinked), Write Audio Tags for new downloads only; root folder on the **Any** profile |
| Prowlarr | Sonarr, Radarr and Lidarr app links (full sync); FlareSolverr proxy on the `flaresolverr` tag |
| Seerr | Sonarr and Radarr default servers on the combined 2160p profiles (after the first sign-in) |
| Maintainerr | Sonarr, Radarr, Seerr and Jellyfin |
| Bazarr | English language profile (created once), default for new series and films |
| Bindery | Prowlarr server and indexer sync, qBittorrent client (WebUI login), Authelia OIDC provider |

AudioMuse-AI's first admin, API token and Navidrome account come from
Infisical, so its setup wizard is not needed. Account creation and content
choices (indexers, subtitle providers, Jellyfin's wizard and API keys,
Seerr's first sign-in, Streamystats' Jellyfin server, Cleanuparr's first
account, the Navidrome account and plugin settings for AudioMuse-AI,
AudioMuse-AI's analysis schedule) are the README's manual steps.

## Platform pieces

- **Intel GPU**: Intel's GPU device plugin from its release's own kustomize
  base, scheduled on corebox only (the
  `node.homeworld/profile=corebox` label). Jellyfin requests
  `gpu.intel.com/i915: 1`, which also places it on corebox; containerd's
  `device_ownership_from_security_context` gives the render node to
  Jellyfin's user, and `host/apply.sh` keeps `container_use_dri_devices` on.
- **qBittorrent**: the shared `/data` volume, UID 20004, one category per
  library, `WebUI\ServerDomains` (quoted) listing the Service FQDNs, and
  ingress from the *arrs, Bindery, Cleanuparr and qbit_manage
  ([qbittorrent.md](qbittorrent.md)).

## Known limitations

- Lidarr's metadata server (`api.lidarr.audio`) can fail name searches:
  add artists by MusicBrainz ID instead.
- Bazarr's authenticated path-traversal advisory (GHSA-2876-64fx-p4m9) is
  limited to `platform` users by the gateway OIDC until a fixed release is
  pinned.
- Audiobookshelf's advisory history is heavy: keep it current.
- AudioMuse-AI and beets were run with their pod security settings in
  Docker on arm64 (runc), not under gVisor; Feishin was not run. On the
  first sync, check that both start under gVisor (AudioMuse-AI's x86 build
  needs AVX2, which gVisor passes through) and that Feishin's nginx binds
  its IPv6 listener under gVisor.
- The AudioMuse-AI chart templates a Redis URL and its own Redis and
  PostgreSQL; both are off, and the kustomization drops the URL.
- Single-maintainer projects: Bindery, Houndarr, Streamystats,
  Jellyfin-Auto-Collections.
- Unpackerr renames settings between majors: read the release notes before
  Renovate bumps it.
- media-config writes through the apps' APIs: a release that renames a
  field fails that step, visibly, in the job's log.
