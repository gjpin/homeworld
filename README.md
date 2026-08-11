# Apps

| App | Domain(s) | Description |
| --- | --- | --- |
| Argo CD | `argocd.${BASE_DOMAIN}`<br>`grpc.argocd.${BASE_DOMAIN}` | GitOps continuous delivery and its gRPC API. |
| Authelia | `auth.${BASE_DOMAIN}` | Identity provider for OpenCloud. |
| cert-manager | — | TLS certificate management. |
| CloudNativePG | — | PostgreSQL operator. |
| Collabora | `office.${BASE_DOMAIN}` | WOPI office editor for OpenCloud. |
| Dragonfly Operator | — | Dragonfly, a Redis-compatible datastore, operator. |
| Envoy Gateway | `envoy.${BASE_DOMAIN}` | Gateway API implementation and control-plane metrics. |
| ExternalDNS | — | DNS record management. |
| External Secrets | — | Infisical-backed secret synchronization. |
| Forgejo | `git.${BASE_DOMAIN}` | Git forge. |
| Grafana | `grafana.${BASE_DOMAIN}` | Dashboards and observability visualization. |
| Grafana Operator | — | Grafana instance, dashboard, and datasource operator. |
| Home Assistant | `home.${BASE_DOMAIN}` | Home automation. |
| Immich | `photos.${BASE_DOMAIN}` | Photo and video management. |
| Longhorn | `longhorn.${BASE_DOMAIN}` | Distributed block-storage management. |
| OpenObserve | `openobserve.${BASE_DOMAIN}` | Logs, metrics, and traces backend. |
| OpenTelemetry Collector | — | Telemetry collection and export. |
| OpenCloud | `cloud.${BASE_DOMAIN}` | Files, sharing, search, collaboration, CalDAV, and CardDAV. |
| Prometheus Operator CRDs | — | Custom resource definitions required for monitoring resources. |
| Radicale | — | Internal CalDAV and CardDAV backend authenticated by OpenCloud. |
| RustFS | `s3.${BASE_DOMAIN}`<br>`console.rustfs.${BASE_DOMAIN}` | Shared S3-compatible object storage and Tenant console. |
| RustFS Operator | `rustfs.${BASE_DOMAIN}` | RustFS storage operator and management console. |
| Syncthing | `sync.${BASE_DOMAIN}` | Peer-to-peer file synchronization. |
| Velero | — | Whole-cluster backups to Backblaze B2. |
| Velero UI | `velero.${BASE_DOMAIN}` | Web interface for managing Velero. |

# Helm security profiles

Pinned upstream charts are rendered through Kustomize overlays under each
component's `helm/` directory. Argo CD deploys the `homelab` overlay; CI renders
both `homelab` and `production` with the same chart version and values.

Argo CD must have `kustomize.buildOptions: --enable-helm` before chart
Applications are switched to local overlay sources. Argo CD itself remains on
the direct Helm bootstrap source until that setting has been synced, and should
be migrated last. RustFS Operator remains direct Helm because chart `0.0.5`
contains a duplicate CRD; CI renders it with Helm until upstream fixes the
package.

Security findings must pass or have a resource-specific entry in
`security/exceptions.yaml` with a substantive reason and owner. Global scanner
exclusions and wildcard resource exceptions are not accepted.

Profile resource fallbacks, applied only when an upstream value is absent:

| Profile | Requests | Limits |
| --- | --- | --- |
| Homelab | `10m` CPU, `64Mi` memory, `64Mi` ephemeral storage | `1` CPU, `2Gi` memory, `2Gi` ephemeral storage |
| Production | `100m` CPU, `128Mi` memory, `128Mi` ephemeral storage | `2` CPU, `4Gi` memory, `4Gi` ephemeral storage |

Render either profile without touching the cluster:

```bash
scripts/render-helm-profiles.sh homelab /tmp/homeworld-homelab
scripts/render-helm-profiles.sh production /tmp/homeworld-production
```

# Pod Security Admission

The root Argo CD Applications manage Pod Security Admission labels through
`managedNamespaceMetadata`. The labels currently use Kubernetes minor version
`v1.36`, matching the version pinned by CI; verify the live cluster minor version
before syncing and update the labels if it differs.

These namespaces enforce Restricted: `argocd`, `cert-manager`,
`cloudnative-pg`, `collabora`, `envoy-gateway`, `external-dns`,
`prometheus-operator-crd`, `radicale`, and `rustfs-operator`. `longhorn-system`
is Privileged because Longhorn uses host integration, while `velero`,
`otel-collector-node`, and `rustfs` are Baseline for their hostPath or operator
limitations. The node-level OpenTelemetry collector is isolated in
`otel-collector-node`; ordinary collectors remain in `otel-collector`.

The remaining application namespaces start with Restricted audit and warning
labels while workload startup is verified. Promote them to Restricted enforcement
after reviewing the live admission warnings and operator-generated pods.

# Variables
```bash
# public HTTP routes
export BASE_DOMAIN=domain.com

# external-dns, cert-manager
export CLOUDFLARE_API_TOKEN= # API token with DNS edit permissions for the zone

# cert-manager
export ACME_EMAIL=

# external-dns
export EXTERNAL_IP=10.0.0.1

# Authelia SMTP notifier (implicit TLS)
export AUTHELIA_SMTP_HOST=smtp.example.com
export AUTHELIA_SMTP_USERNAME=
export AUTHELIA_SMTP_SENDER='Authelia <authelia@example.com>'

# velero
export B2_BUCKET=
export B2_REGION=

# external-secrets
export INFISICAL_CLIENT_ID=
export INFISICAL_CLIENT_SECRET=
export INFISICAL_HOSTNAME=app.infisical.com
export INFISICAL_HOST=https://app.infisical.com
export INFISICAL_PROJECT_SLUG=
export INFISICAL_ENVIRONMENT_SLUG=dev

```

# Secrets
* Create secrets in cluster:
```bash
envsubst < secrets.yaml | kubectl apply -f -
```

# Helm repos
```bash
# argo
helm repo add argo https://argoproj.github.io/argo-helm

# cert-manager
helm repo add cert-manager https://charts.jetstack.io

# clickhouse
helm repo add altinity-clickhouse-operator https://docs.altinity.com/clickhouse-operator/

# cloudnative-pg
helm repo add cloudnative-pg https://cloudnative-pg.io/charts

# external-dns
helm repo add external-dns https://kubernetes-sigs.github.io/external-dns/


# kube-prometheus-stack
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts

# longhorn
helm repo add longhorn https://charts.longhorn.io

# metrics-server
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/

# otel-collector
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts

# openobserve
helm repo add openobserve https://charts.openobserve.ai

# rustfs-operator
helm repo add rustfs-operator https://operator.rustfs.com

# velero
helm repo add vmware-tanzu https://vmware-tanzu.github.io/helm-charts

# velero-ui
helm repo add otwld https://helm.otwld.com/

```

# Network egress
Cilium and its `CiliumNetworkPolicy` CRD must be installed before Argo CD syncs
this repository. Every application namespace has a Cilium default-deny baseline
for both ingress and egress. The only namespace-wide egress exception is DNS to
the `kube-dns` endpoints on UDP/TCP 53; all other paths select their exact
source, destination, and port. The Cilium `world` entity is used only for the
public TCP 443 listener on the merged Envoy data plane. No other application
pod has unrestricted Internet egress.

The merged Envoy data plane is the only public application ingress boundary.
Gateway backends are allowed one service and listener port at a time. OTel
receiver ports remain closed because no current in-repository sender uses them.
The Longhorn manager and Velero node-agent retain only the rendered host-facing
ports required for node integration; the policy comments document those
exceptions.

Documented external egress exceptions:

| Workload | Destination | Reason |
| --- | --- | --- |
| Argo CD repo-server | Declared Git sources, pinned Helm repositories, and OCI registries over TCP 443 | Git checkout and Helm/Kustomize rendering |
| cert-manager controller | `acme-v02.api.letsencrypt.org:443`, `acme-staging-v02.api.letsencrypt.org:443`, and `api.cloudflare.com:443` | ACME DNS-01 certificate issuance |
| external-dns | `api.cloudflare.com:443` | Cloudflare DNS reconciliation |
| external-secrets controller | `${INFISICAL_HOSTNAME}:443` | Infisical secret synchronization |
| Velero server/node-agent | `s3.${B2_REGION}.backblazeb2.com:443` | Backups and CSI data movement |
| Forgejo | `github.com:443`, `gitlab.com:443`, and `git.*.*:443` | User-requested HTTPS repository clone/fetch support |
| Grafana pod | `zincsearch-releases.s3.us-west-2.amazonaws.com:443` | Existing plugin-loader init-container download |
| Authelia | `time.cloudflare.com:123/UDP` and `${AUTHELIA_SMTP_HOST}:465/TCP` | NTP and SMTP |
| OpenCloud/Collabora | Existing exact `auth.${BASE_DOMAIN}`, `cloud.${BASE_DOMAIN}`, and `office.${BASE_DOMAIN}` FQDNs over TCP 443 | OIDC, WOPI, and collaboration callbacks |

The Forgejo `git.*.*` entry is intentionally limited to hostnames matching
that pattern and TCP 443. It does not permit arbitrary hostnames or SSH. The
OpenCloud browser CSP URLs are client-side destinations, not pod egress, and
receive no network-policy exception.

Home Assistant may use TCP/UDP ports in RFC1918 ranges
(`10.0.0.0/8` except `10.42.0.0/16` and `10.43.0.0/16`, plus
`172.16.0.0/12` and `192.168.0.0/16`) for device integrations. Syncthing may
use those ranges only on TCP/UDP 22000 and UDP 21027, and may accept peer
traffic only on TCP/UDP 22000. Its GUI remains Gateway-only on TCP 8384.
Mosquitto and Zigbee2MQTT remain deny-by-default because no rendered or
configured endpoint currently proves an additional path is required. No other
application pod receives direct LAN ingress.

# Velero B2 backups
Velero creates a whole-cluster backup every day at 03:00 Europe/Lisbon. The B2
backup location is `https://s3.${B2_REGION}.backblazeb2.com`, storing data in
`${B2_BUCKET}` under the `velero` prefix. Backups expire after 30 days, retaining
30 daily restore points.

Before syncing Velero, create a dedicated Backblaze B2 application key limited
to the backup bucket with list, read, write, and delete permissions. Enable
bucket-default SSE-B2, and configure the bucket lifecycle to permanently delete
hidden object versions one day after Velero deletes them. B2 versions objects by
default, so this prevents expired backups from accumulating indefinitely.

Create the following Infisical values before the first Velero backup:

* `/velero/B2_APPLICATION_KEY_ID`
* `/velero/B2_APPLICATION_KEY`
* `/velero/KOPIA_REPOSITORY_PASSWORD`

`KOPIA_REPOSITORY_PASSWORD` encrypts the Kopia repository and must remain
recoverable for restores. Do not rotate it after the repository is initialized
without a coordinated repository migration. A restore requires B2 access using
the same application key and repository password, plus a target cluster with
Velero, the AWS plugin, CSI snapshot APIs, and the Longhorn CSI driver installed.

# Velero UI credentials
Create the following values in Infisical before syncing Velero UI. The chart's
default `admin`/`admin` credentials are not used.

* `/velero-ui/AUTH_SECRET_PASSPHRASE`
* `/velero-ui/BASIC_AUTH_USERNAME`
* `/velero-ui/BASIC_AUTH_PASSWORD`

# Grafana admin credentials
Create the following values in Infisical before syncing Grafana:

* `/grafana/GF_SECURITY_ADMIN_USER`
* `/grafana/GF_SECURITY_ADMIN_PASSWORD`

# OpenObserve credentials
Create the following values in Infisical before syncing OpenObserve, the OTel
Collector, and Grafana:

* `/openobserve/ZO_ROOT_USER_EMAIL`
* `/openobserve/ZO_ROOT_USER_PASSWORD`
* `/openobserve/OTLP_AUTHORIZATION` (the complete `Basic <base64(email:password)>` header)

# Longhorn encryption credential
Create the following value in Infisical before syncing Longhorn:

* `/longhorn/CRYPTO_KEY_VALUE`

# RustFS
The RustFS Operator console is available at `https://rustfs.${BASE_DOMAIN}`.
Generate a short-lived bearer token for the chart-managed console
ServiceAccount, then paste it into the console login form:

```bash
kubectl -n rustfs-operator create token rustfs-operator-console --duration=24h
```

The console session-signing key is generated by the Helm chart on first install
and preserved by Argo CD; no console token or session key is stored in Git.

RustFS Operator requires Kubernetes 1.30 or newer. The shared `rustfs` Tenant
uses one RustFS server with one `50Gi` `longhorn-crypto` volume. Its S3 API is
available at `https://s3.${BASE_DOMAIN}` and its Tenant console is available at
`https://console.rustfs.${BASE_DOMAIN}`. Tenant storage health and capacity are
exported through the Operator metrics service, whose existing ServiceMonitor
scrapes every `60s`; a duplicate Tenant ServiceMonitor is not required.

Create the following Infisical values before syncing the RustFS Tenant. Both
values must be at least eight characters:

* `/rustfs/RUSTFS_ACCESS_KEY`
* `/rustfs/RUSTFS_SECRET_KEY`

Use these administrator credentials only for the Tenant console and initial
administration. Each consuming application should receive its own bucket,
least-privilege policy, and identity rather than sharing the administrator
credentials.

OpenCloud uses a separate `opencloud` bucket and identity. Create the bucket,
identity, and least-privilege policy in the RustFS administration interface
before syncing OpenCloud. The OpenCloud credentials in Infisical must be for
that identity, not the Tenant administrator.

# PostgreSQL application credentials
Create the following values in Infisical before syncing CloudNativePG and its
database consumers:

* `/authelia/POSTGRES_USERNAME`
* `/authelia/POSTGRES_PASSWORD`
* `/forgejo/POSTGRES_USERNAME`
* `/forgejo/POSTGRES_PASSWORD`
* `/immich/POSTGRES_USERNAME`
* `/immich/POSTGRES_PASSWORD`

Set each `POSTGRES_USERNAME` value to its matching application role:
`authelia`, `forgejo`, or `immich`.

# Authelia identities, encryption, and notifications
Create all of the following values in Infisical before syncing Authelia:

* `/authelia/POSTGRES_USERNAME` — must be `authelia`
* `/authelia/POSTGRES_PASSWORD`
* `/authelia/DRAGONFLY_PASSWORD`
* `/authelia/RESET_PASSWORD_JWT_SECRET`
* `/authelia/SESSION_SECRET`
* `/authelia/STORAGE_ENCRYPTION_KEY`
* `/authelia/OIDC_HMAC_SECRET`
* `/authelia/OIDC_JWK_RS256`
* `/authelia/SMTP_PASSWORD`
* `/authelia/USERS_DATABASE`

Generate independent 64-character random values for
`RESET_PASSWORD_JWT_SECRET`, `SESSION_SECRET`, `STORAGE_ENCRYPTION_KEY`, and
`OIDC_HMAC_SECRET`. `OIDC_JWK_RS256` must contain an RSA-2048 private key in PEM
format. Authelia uses SMTP over implicit TLS on port 465; the SMTP host,
username, and sender are the deployment variables documented above.

`USERS_DATABASE` contains the complete `users_database.yml`, including every
user and group assignment. Store Argon2id hashes, never plaintext passwords:

```yaml
users:
  alice:
    disabled: false
    displayname: Alice Example
    password: '$argon2id$v=19$m=65536,t=3,p=4$<salt>$<hash>'
    email: alice@example.com
    groups:
      - opencloud-admin
  bob:
    disabled: false
    displayname: Bob Example
    password: '$argon2id$v=19$m=65536,t=3,p=4$<salt>$<hash>'
    email: bob@example.com
    groups:
      - opencloud-user
```

The allowed OpenCloud groups, from highest to lowest precedence, are
`opencloud-admin`, `opencloud-spaceadmin`, `opencloud-user`, and
`opencloud-user-light`. Users without one of these groups cannot authorize an
OpenCloud client. To change a password, generate a new Argon2id hash, replace
the hash inside `/authelia/USERS_DATABASE`, wait for the External Secrets
refresh, and restart the Authelia Deployment. Self-service password reset and
password change are disabled.

Create `/immich/DRAGONFLY_PASSWORD` before syncing Immich.

# OpenCloud credentials and access groups
Create the following values in Infisical before syncing OpenCloud and
Collabora:

* `/opencloud/IDM_ADMIN_PASSWORD`
* `/opencloud/RUSTFS_ACCESS_KEY`
* `/opencloud/RUSTFS_SECRET_KEY`
* `/opencloud/COLLABORA_ADMIN_USER`
* `/opencloud/COLLABORA_ADMIN_PASSWORD`
* `/opencloud/COLLABORA_PROOF_KEY`
* `/opencloud/COLLABORA_PROOF_KEY_PUB`

Authelia publishes four public Authorization Code + PKCE clients for OpenCloud:
`web`, `OpenCloudDesktop`, `OpenCloudAndroid`, and `OpenCloudIOS`. All clients
require MFA and one of the OpenCloud groups above, request the `openid`,
`profile`, `email`, `groups`, and `offline_access` scopes, use RS256 access
tokens, remember consent for one week, and issue refresh tokens for 30 days.
Authelia limits authenticated elevation/email initiation per source IP to three
requests per hour and five per day. The SMTP provider's own quota remains the
account-wide backstop.

# OpenCloud calendars and contacts

OpenCloud authenticates and proxies CalDAV and CardDAV requests to the internal
Radicale service. Configure clients with `https://cloud.${BASE_DOMAIN}` as the
discovery URL, the OpenCloud username, and an app token generated in the user's
OpenCloud settings as the password. Clients can also use `/caldav/` and
`/carddav/` directly; `/.well-known/caldav` and `/.well-known/carddav` support
automatic discovery.

Each user receives a “Personal Calendar” and “Personal Address Book” on first
access. Radicale has no public hostname or web UI; the retired
`https://contacts.${BASE_DOMAIN}` endpoint must not be used.

## DAVx⁵ on Android

To sync calendars and contacts with DAVx⁵, create an app token in the user's
OpenCloud settings. In DAVx⁵, add an account using the URL and username/password
login method with the following values:

* URL: `https://cloud.${BASE_DOMAIN}`
* Username: the OpenCloud username
* Password: the generated OpenCloud app token

The root URL supports automatic CalDAV and CardDAV discovery. If discovery does
not work, use `https://cloud.${BASE_DOMAIN}/caldav/` and
`https://cloud.${BASE_DOMAIN}/carddav/` as separate account URLs. Do not use the
Authelia password or connect to Radicale directly; OpenCloud authenticates the
request and proxies it to Radicale.

# ArgoCD
* **Sync wave 0**
   * argocd: enables Helm inflation for the Kustomize-rendered chart profiles
* **Sync wave 1**
   * prometheus-operator-crd: CRDs required by service monitors
   * external-secrets: External Secrets Operator and Infisical ClusterSecretStore
* **Sync wave 2**
   * envoy-gateway: Gateway API and provides CRDs required by HTTP/GRPC routes
* **Sync wave 3**
   * cert-manager: TLS certificates management
   * external-dns: manages DNS records
   * longhorn: block storage
* **Sync wave 4**
   * cloudnative-pg: postgresql operator
   * dragonfly-operator: dragonfly (redis-compatible) operator
   * grafana-operator: Grafana instance, dashboard, and datasource operator
   * rustfs-operator: RustFS storage operator, console, and STS endpoint
   * velero: whole-cluster backups after External Secrets and Longhorn
* **Sync wave 5**
   * openobserve: standalone logs, metrics, and traces backend
   * rustfs: shared S3-compatible storage Tenant, after the RustFS Operator,
     External Secrets, and Longhorn
   * velero-ui: web interface for Velero, after the Velero server
* **Sync wave 6**
   * authelia: OpenCloud identity provider, after CloudNativePG, Dragonfly,
     External Secrets, and Prometheus Operator CRDs
   * homeassistant
   * immich
   * otel-collector
   * forgejo
   * grafana
   * radicale: internal CalDAV and CardDAV backend, before OpenCloud's
     authenticated DAV proxy
   * syncthing
* **Sync wave 7**
   * collabora: standalone Collabora chart and WOPI endpoint
* **Sync wave 8**
   * opencloud: OpenCloud, Tika, RustFS storage integration, authenticated DAV
     proxy, and routes

# Testing
* Add 'homelab' role to all nodes:
```bash
kubectl label nodes --all node-role.kubernetes.io/homelab=homelab
```

# Dependency updates
Renovate runs daily at 04:17 UTC and can also be started from the **Run
workflow** button for the `Renovate` GitHub Actions workflow. It opens review
PRs only: updates, including major releases, are never auto-merged. Merging a
reviewed Renovate PR is the only way an update reaches Argo CD; the workflows
do not run `kubectl`, Helm, or Argo CD commands.

Create a GitHub App, install it on this repository, and save its app ID and
private key as these repository Actions secrets:

* `RENOVATE_APP_ID`
* `RENOVATE_APP_PRIVATE_KEY`

Configure the GitHub App permissions as documented for
[self-hosted Renovate](https://docs.renovatebot.com/modules/platform/github/#running-as-a-github-app):

| Permission | Scope |
| --- | --- |
| Checks | `read` + `write` |
| Commit statuses | `read` + `write` |
| Contents | `read` + `write` |
| Issues | `read` + `write` |
| Pull requests | `read` + `write` |
| Workflows | `read` + `write` |
| Administration | `read` |
| Dependabot alerts | `read` |
| Members | `read` |
| Metadata | `read` |

The installation token is generated per workflow run and is not stored in the
repository. Renovate updates Argo CD Helm and Git-tag revisions, explicit
container images, and the CloudNativePG, Grafana, OpenObserve, RustFS Operator,
RustFS Tenant, Collabora, OpenCloud, Tika, and OpenCloud web-extension image
fields.
`apps/app-of-apps.yaml` intentionally remains on `HEAD`; Helm image repository
overrides without an explicit tag continue to inherit their chart's image tag.

# Authelia cutover cleanup

After Argo CD has pruned the replaced application and OpenCloud login is
verified, manually remove obsolete `/authentik/*` values from Infisical and
delete the old `authentik` namespace if it remains empty. This repository does
not perform either cleanup and no pre-cutover state backup or migration is
required.

* Enable minikube's metrics-server addon
```bash
minikube addons enable metrics-server
```

* Bootstrap Argo
```bash
# Add ArgoCD helm repo
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update

# Install ArgoCD
helm install argocd argo/argo-cd \
  --version 8.2.2 \
  --namespace argocd \
  --create-namespace \
  -f configs/argocd/helm_values.yaml
```

* Access ArgoCD UI:
```bash
# Get default secret
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d && echo

# Port forward UI
kubectl port-forward -n argocd svc/argocd-server 8080:80

# Access: admin:$password
```
