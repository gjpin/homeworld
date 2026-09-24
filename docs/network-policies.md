# Network Connections

All applications enforce default-deny egress via Cilium Network Policies, with baseline access granted to internal cluster DNS (`kube-system/kube-dns:53`). Workload connections below detail all permitted ingress sources, internal cluster destinations, and outbound internet access.

| App | Outbound Internet | Inbound Sources | Internal Outbound | External (Internet) Destinations |
| --- | :---: | --- | --- | --- |
| Argo CD | **Yes** | Envoy Gateway (`8080`), internal components | `kube-apiserver:443`<br>`argocd-redis:6379`<br>`argocd-repo-server:8081`<br>`argocd-dex-server:5556`<br>`auth.${BASE_DOMAIN}:443` (OIDC) | Git repositories (`github.com`, `code.forgejo.org`)<br>Helm repositories (`argoproj.github.io`, `charts.authelia.com`, `charts.jetstack.io`, `cloudnative-pg.github.io`, `collaboraonline.github.io`, `charts.external-secrets.io`, `charts.longhorn.io`, `charts.openobserve.ai`, `open-telemetry.github.io`, `operator.rustfs.com`, `helm.otwld.com`, `vmware-tanzu.github.io`, `kubernetes-sigs.github.io`)<br>Registries (`ghcr.io`, `docker.io`, `registry-1.docker.io`, `auth.docker.io`) |
| Authelia | **Yes** | Envoy Gateway (`80`), internal pods | `authelia-rw:5432` (PostgreSQL)<br>`dragonfly:6379` (Redis) | NTP (`time.cloudflare.com:123`)<br>SMTP (`${AUTHELIA_SMTP_HOST}`) |
| cert-manager | **Yes** | `kube-apiserver:10250` (webhook), controller | `kube-apiserver:443`<br>`cert-manager-webhook:10250` | ACME CA (`acme-v02.api.letsencrypt.org`, `acme-staging-v02.api.letsencrypt.org`)<br>DNS-01 challenge API (`api.cloudflare.com:443`) |
| CloudNativePG | **No** | `kube-apiserver:9443` (webhook), OpenTelemetry Collector (metrics) | `kube-apiserver:443` | — |
| Collabora | **No** | Envoy Gateway (`9980`), OpenTelemetry Collector (metrics) | OpenCloud WOPI callback (`cloud.${BASE_DOMAIN}:443`) | — |
| CrowdSec | **Yes** | CrowdSec Envoy Bouncer (`8080`, `7422`), internal agents | `crowdsec-rw:5432` (PostgreSQL)<br>`crowdsec-service:8080`<br>`kube-apiserver:443` (registration jobs) | CrowdSec Central API, Hub & Blocklists (`api.crowdsec.net`, `papi.api.crowdsec.net`, `version.crowdsec.net`, `cdn-hub.crowdsec.net`, `hub-data.crowdsec.net`, `blocklists.api.crowdsec.net:443`) |
| CrowdSec Envoy Bouncer | **No** | Envoy Gateway ext-auth (`8080`), Prometheus Operator (metrics `9090`) | `crowdsec-service:8080` (LAPI)<br>`crowdsec-appsec-service:7422` (AppSec) | — |
| Dragonfly Operator | **No** | `kube-apiserver:9443` (webhook) | `kube-apiserver:443` | — |
| Envoy Gateway | **No** | Internet (`world:443`), `kube-apiserver:9443` (webhook), control-plane (`18000`), OpenTelemetry Collector (metrics `19001`) | `kube-apiserver:443`<br>Control-plane (`18000`)<br>Metrics (`19001`)<br>All application backend services (Argo CD, Authelia, Collabora, Forgejo, Grafana, Home Assistant, Immich, Longhorn, OpenCloud, OpenObserve, RustFS, RustFS Operator, Velero UI) | — *(Inbound reverse proxy only; egress to internet is denied)* |
| ExternalDNS | **Yes** | — | `kube-apiserver:443` | Cloudflare DNS API (`api.cloudflare.com:443`) |
| External Secrets | **Yes** | `kube-apiserver:10250` (webhook), controller, OpenTelemetry Collector (metrics `8080`) | `kube-apiserver:443`<br>`external-secrets-webhook:443` | Infisical Secret Manager (`${INFISICAL_HOSTNAME}:443`) |
| Forgejo | **Yes** | Envoy Gateway (`3000`), OpenTelemetry Collector (metrics `3000`), internal pods | `forgejo-rw:5432` (PostgreSQL)<br>`auth.${BASE_DOMAIN}:443` (OIDC) | Git remotes, federation & mirroring (`github.com`, `gitlab.com`, `git.*.*:443`) |
| Grafana | **Yes** | Envoy Gateway (`3000`) | `openobserve:5080` (datasource)<br>`auth.${BASE_DOMAIN}:443` (OIDC) | S3 plugin downloads (`zincsearch-releases.s3.us-west-2.amazonaws.com:443`) |
| Grafana Operator | **No** | — | `kube-apiserver:443` | — |
| Home Assistant | **Yes** | Envoy Gateway (HA `8123`, Z2M `8080`), OpenTelemetry Collector (metrics `8123`), Mosquitto (`1883`) | `homeassistant-mosquitto:1883`<br>LAN IoT devices (RFC 1918 subnets: `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`) | Internet access (`world`: HA HTTP `80`, HTTPS `443`, NTP `123`; Zigbee2MQTT HTTPS `443` OTA updates) |
| Immich | **No** | Envoy Gateway (`2283`), server to machine-learning (`3003`) | `immich-rw:5432` (PostgreSQL)<br>`dragonfly:6379` (Redis)<br>`immich-machine-learning:3003`<br>`auth.${BASE_DOMAIN}:443` (OIDC) | — |
| Longhorn | **No** | Envoy Gateway (`80`), `kube-apiserver`, internal components | `kube-apiserver:443`<br>Kubelet (`host:10250`)<br>`longhorn-backend:9500`<br>`longhorn-recovery-backend` | — |
| OpenCloud | **No** | Envoy Gateway (`9200`), OpenTelemetry Collector (metrics), internal microservices | `rustfs-io:9000` (RustFS S3)<br>`radicale:5232` (CalDAV/CardDAV)<br>`opencloud-tika:9998` (Search)<br>`auth.${BASE_DOMAIN}:443`<br>`office.${BASE_DOMAIN}:443`<br>`cloud.${BASE_DOMAIN}:443` | — |
| OpenObserve | **No** | Envoy Gateway (`5080`), Grafana (`5080`), OpenTelemetry Collector (`5080`) | — | — |
| OpenTelemetry Collector | **No** | Collector agent pods/nodes (`4317`, `4318`), self-metrics (`8888`) | `openobserve:5080`<br>`kube-apiserver:443`<br>Kubelet stats (`host:10250`)<br>Cluster workload metrics endpoints (Envoy Gateway, Velero node-agent, etc.) | — |
| Prometheus Operator CRDs | **No** | — | — | — |
| Radicale | **No** | OpenCloud DAV proxy (`5232`) | — | — |
| RustFS | **No** | Envoy Gateway (S3 `9000`, Console `9001`), OpenCloud (`9000`), RustFS Operator (`9000`, `9001`) | `auth.${BASE_DOMAIN}:443` (OIDC/STS) | — |
| RustFS Operator | **No** | Envoy Gateway (`9090`) | `kube-apiserver:443`<br>`rustfs-io:9000`<br>`rustfs-console:9001` | — |
| Velero | **Yes** | OpenTelemetry Collector (node-agent metrics `8085`) | `kube-apiserver:443`<br>Kubelet (`host:10250` for node-agent volume backups) | Backblaze B2 S3 storage (`s3.${B2_REGION}.backblazeb2.com:443`) |
| Velero UI | **No** | Envoy Gateway (`3000`) | `kube-apiserver:443`<br>`auth.${BASE_DOMAIN}:443` (OIDC) | — |