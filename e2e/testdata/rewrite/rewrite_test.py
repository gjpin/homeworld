#!/usr/bin/env python3
import pathlib
import shutil
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "examples" / "hooks" / "rewrite-staging.py"
FIXTURE = pathlib.Path(__file__).resolve().parent


def main() -> int:
    with tempfile.TemporaryDirectory() as tmp:
        dest = pathlib.Path(tmp)
        shutil.copytree(FIXTURE / "apps", dest / "apps")
        subprocess.check_call([sys.executable, str(SCRIPT), str(dest)])
        apps = (dest / "apps" / "app-of-apps.yaml").read_text()
        if "longhorn-app" in apps:
            raise SystemExit("longhorn-app should be omitted")
        if "forgejo-app" not in apps:
            raise SystemExit("forgejo-app should be kept")
        if "grafana-app" not in apps:
            raise SystemExit("grafana-app should be kept")
        if "opencloud-app" not in apps:
            raise SystemExit("opencloud-app should be kept")
        if "crowdsec-app" not in apps:
            raise SystemExit("crowdsec-app should be kept")
        if "immich-app" not in apps:
            raise SystemExit("immich-app should be kept")
        if "authelia-app" not in apps:
            raise SystemExit("authelia-app should be kept")
        if "git://host.docker.internal:9418/homeworld.git" not in apps:
            raise SystemExit("repoURL not rewritten")
        if "SkipDryRunOnMissingResource=true" not in apps:
            raise SystemExit("parent Applications missing SkipDryRunOnMissingResource")
        if "ServerSideApply=true" not in apps:
            raise SystemExit("parent Applications missing ServerSideApply")
        nested = (dest / "apps" / "argocd" / "1_helm.yaml").read_text()
        if "github.com/gjpin/homeworld.git" in nested:
            raise SystemExit("nested Application repoURL not rewritten")
        if "git://host.docker.internal:9418/homeworld.git" not in nested:
            raise SystemExit("nested Application missing local git URL")
        if "hostUsers: false" in nested:
            raise SystemExit("hostUsers: false left in place")
        if "hostUsers: true" not in nested:
            raise SystemExit("hostUsers not flipped to true")
        if '"/spec/hostUsers","value":false' in nested:
            raise SystemExit("cnpg podPatch still sets hostUsers false")
        if '"/spec/hostUsers","value":true' not in nested:
            raise SystemExit("cnpg podPatch hostUsers not flipped")
        if "from: all" in nested:
            raise SystemExit("Gateway from: all not capitalized")
        if "from: All" not in nested:
            raise SystemExit("Gateway from: All missing")
        if "SkipDryRunOnMissingResource=true" not in nested:
            raise SystemExit("nested Application missing SkipDryRunOnMissingResource")
        if "RespectIgnoreDifferences=true" not in apps:
            raise SystemExit("parent Applications missing RespectIgnoreDifferences")
        if "RespectIgnoreDifferences=true" not in nested:
            raise SystemExit("nested Application missing RespectIgnoreDifferences")
        if ".spec.listeners[].tls.certificateRefs[].group" not in apps:
            raise SystemExit("parent Applications missing Gateway ignoreDifferences")
        if ".spec.parentRefs[].group" not in nested:
            raise SystemExit("nested Application missing HTTPRoute ignoreDifferences")
        if "/operation" not in apps:
            raise SystemExit("parent Applications missing Application /operation ignore")
        if 'argocd.argoproj.io/sync-wave: "2"' in apps:
            raise SystemExit("parent Application should not gain HTTPRoute sync-wave")
        nested_app = nested.split("kind: Application", 1)[1].split("---")[0]
        if 'argocd.argoproj.io/sync-wave: "2"' in nested_app:
            raise SystemExit("nested Application should not gain HTTPRoute sync-wave")
        inf = (dest / "apps" / "external-secrets" / "0_network_policy.yaml").read_text()
        inf_doc = inf.split("name: allow-infisical", 1)[1].split("---")[0]
        if 'port: "8080"' not in inf_doc or "toEntities:" not in inf_doc:
            raise SystemExit("allow-infisical not patched to host/world :8080")
        if "toFQDNs:" in inf_doc:
            raise SystemExit("allow-infisical still uses toFQDNs")
        if inf.split("name: allow-kubernetes-api")[1].split("---")[0].count('port: "443"') < 1:
            raise SystemExit("non-infisical 443 port was removed")
        argocd = (dest / "apps" / "argocd" / "0_network_policy.yaml").read_text()
        if "toEntities:" not in argocd or 'port: "9418"' not in argocd:
            raise SystemExit("git daemon egress not added")
        work = (dest / "apps" / "workarounds.yaml").read_text()
        if "decodingStrategy: Auto" in work:
            raise SystemExit("decodingStrategy Auto left in place")
        if "decodingStrategy: None" not in work:
            raise SystemExit("decodingStrategy not set to None")
        if "kind: Dragonfly" in work and "runAsNonRoot: true" in work.split("kind: Dragonfly", 1)[1].split("---")[0]:
            raise SystemExit("Dragonfly still runAsNonRoot true")
        if "runAsNonRoot: false" not in work:
            raise SystemExit("Dragonfly runAsNonRoot not flipped")
        if "SETUID" not in work:
            raise SystemExit("Dragonfly missing SETUID capability")
        if "strategy:" in work.split("kind: StatefulSet", 1)[1].split("---")[0]:
            raise SystemExit("StatefulSet spec.strategy not removed")
        if "persistentVolumeClaim:" in work.split("kind: Grafana", 1)[1].split("---")[0]:
            raise SystemExit("Grafana persistentVolumeClaim not removed")
        if "/usr/share/nginx/html/external-sites/" in work:
            raise SystemExit("opencloud web-extensions path not rewritten")
        if "/usr/share/nginx/html/apps/external-sites/" not in work:
            raise SystemExit("opencloud web-extensions apps/ path missing")
        if "/usr/share/nginx/html/apps/importer/" in work:
            raise SystemExit("importer-1.0.0 path should not gain apps/")
        if "/usr/share/nginx/html/importer/" not in work:
            raise SystemExit("importer-1.0.0 original path missing")
        oc_deploy = work.split("name: opencloud\n  namespace: opencloud", 1)[1].split("---")[0]
        if 'name: COLLABORATION_APP_INSECURE\n              value: "false"' in oc_deploy:
            raise SystemExit("opencloud COLLABORATION_APP_INSECURE still false")
        if 'name: COLLABORATION_APP_INSECURE\n              value: "true"' not in oc_deploy:
            raise SystemExit("opencloud COLLABORATION_APP_INSECURE not flipped")
        if 'name: COLLABORATION_CS3API_DATAGATEWAY_INSECURE\n              value: "true"' not in oc_deploy:
            raise SystemExit("opencloud COLLABORATION_CS3API_DATAGATEWAY_INSECURE not flipped")
        if "storeCAPICredentialsInSecret: true" in work:
            raise SystemExit("crowdsec still stores CAPI credentials in a secret")
        if "storeCAPICredentialsInSecret: false" not in work:
            raise SystemExit("crowdsec storeCAPICredentialsInSecret not flipped")
        if "kind: SecurityPolicy" in work:
            raise SystemExit("SecurityPolicy should be omitted when bouncer is omitted")
        g_k = (dest / "apps" / "grafana" / "kustomization.yaml").read_text()
        if "7_security_policy.yaml" in g_k:
            raise SystemExit("grafana kustomization still lists omitted SecurityPolicy")
        if "3_grafana.yaml" not in g_k:
            raise SystemExit("grafana kustomization dropped unrelated resource")
        if (dest / "apps" / "grafana" / "7_security_policy.yaml").exists():
            raise SystemExit("grafana SecurityPolicy file not omitted")
        if "crowdsec-envoy-bouncer-app" in apps:
            raise SystemExit("crowdsec-envoy-bouncer-app should be omitted")
        if "otel-collector-app" in apps:
            raise SystemExit("otel-collector-app should be omitted")
        cs = (dest / "apps" / "crowdsec" / "1_secrets.yaml").read_text()
        if '{{ .password }}' not in cs:
            raise SystemExit("crowdsec postgres template missing password")
        token = (dest / "apps" / "crowdsec" / "helm" / "values.yaml").read_text()
        if 'token: "e2e-crowdsec-registration-token"' in token:
            raise SystemExit("crowdsec registration token still shorter than 32 chars")
        if 'token: "e2e-crowdsec-registration-token-x"' not in token:
            raise SystemExit("crowdsec registration token not padded")
        if "ENROLL_KEY" in token:
            raise SystemExit("crowdsec ENROLL_KEY should be removed")
        if "DISABLE_ONLINE_API" not in token:
            raise SystemExit("crowdsec DISABLE_ONLINE_API missing")
        rustfs_crds = dest / "apps" / "rustfs-operator" / "helm" / "chart" / "crds"
        if (rustfs_crds / "tenant.yaml").exists():
            raise SystemExit("duplicate rustfs tenant.yaml CRD not removed")
        if not (rustfs_crds / "tenant-crd.yaml").exists():
            raise SystemExit("rustfs tenant-crd.yaml should be kept")
        argocd_vals = (dest / "apps" / "argocd" / "helm" / "argocd" / "base" / "values.yaml").read_text()
        if "enabled: false" not in argocd_vals.split("dex:", 1)[1].split("\n", 2)[1]:
            raise SystemExit("argocd dex not disabled")
        if "enabled: false" not in argocd_vals.split("applicationSet:", 1)[1].split("\n", 2)[1]:
            raise SystemExit("argocd applicationSet not disabled")
        if "enabled: false" not in argocd_vals.split("notifications:", 1)[1].split("\n", 2)[1]:
            raise SystemExit("argocd notifications not disabled")
        if "ARGOCD_GPG_ENABLED" not in argocd_vals:
            raise SystemExit("argocd repo-server GPG watcher not disabled")
        if 'controller.diff.server.side: "false"' not in argocd_vals:
            raise SystemExit("argocd server-side diff not disabled")
        if "timeoutSeconds: 15" not in argocd_vals.split("repoServer:", 1)[1]:
            raise SystemExit("argocd repo-server liveness timeout not relaxed")
        if "resource.exclusions:" not in argocd_vals:
            raise SystemExit("argocd resource.exclusions for CRDs missing")
        if "CustomResourceDefinition" not in argocd_vals.split("resource.exclusions:", 1)[1]:
            raise SystemExit("argocd resource.exclusions does not skip CRDs")
        if "resource.customizations.health.PersistentVolumeClaim" not in argocd_vals:
            raise SystemExit("argocd PVC health customization missing")
        if "resource.customizations.health.gateway.envoyproxy.io_SecurityPolicy" not in argocd_vals:
            raise SystemExit("argocd SecurityPolicy health customization missing")
        if "resource.customizations.health.gateway.networking.k8s.io_HTTPRoute" not in argocd_vals:
            raise SystemExit("argocd HTTPRoute health customization missing")
        if "resource.customizations.health.argoproj.io_Application" not in argocd_vals:
            raise SystemExit("argocd nested Application health customization missing")
        if "resource.customizations.health.postgresql.cnpg.io_Cluster" not in argocd_vals:
            raise SystemExit("argocd CNPG Cluster health customization missing")
        if "kind: Cluster\n      jsonPointers:\n        - /spec" not in apps:
            raise SystemExit("parent Applications missing CNPG Cluster /spec ignore")
        if "resource.customizations.health.rustfs.com_Tenant" not in argocd_vals:
            raise SystemExit("argocd RustFS Tenant health customization missing")
        if "timeoutSeconds: 15" not in argocd_vals.split("controller:", 1)[1]:
            raise SystemExit("argocd application-controller readiness timeout not relaxed")
        if "timeoutSeconds: 15" not in argocd_vals.split("server:", 1)[1]:
            raise SystemExit("argocd-server probe timeout not relaxed")
        cool = (
            dest / "apps" / "collabora" / "helm" / "collabora-online" / "base" / "values.yaml"
        ).read_text()
        if "mount_jail_tree=false" not in cool:
            raise SystemExit("collabora mount_jail_tree not disabled")
        if "name: cool-tmp" in cool:
            raise SystemExit("collabora must not add a second /tmp volumeMount")
        if "runAsUser: 1000" in cool:
            raise SystemExit("collabora still runAsUser 1000; coolforkit needs uid 1001")
        if "runAsUser: 1001" not in cool:
            raise SystemExit("collabora runAsUser not set to image USER 1001")
        immich = (dest / "apps" / "immich" / "helm" / "immich" / "base" / "values.yaml").read_text()
        if "existingClaim: photos" not in immich:
            raise SystemExit("immich existingClaim not rewritten to photos")
        if "existingClaim: immich" in immich:
            raise SystemExit("immich existingClaim still immich")
        if "accessMode: ReadWriteMany" in immich:
            raise SystemExit("immich ML volume still RWX")
        if "accessMode: ReadWriteOnce" not in immich:
            raise SystemExit("immich ML volume not RWO")
        if "runAsUser: 1000" not in immich:
            raise SystemExit("immich runAsUser not set for root image")
        if "REDIS_HOSTNAME: dragonfly.immich.svc.cluster.local:6379" in immich:
            raise SystemExit("immich REDIS_HOSTNAME still includes port")
        if "REDIS_HOSTNAME: dragonfly.immich.svc.cluster.local\n" not in immich:
            raise SystemExit("immich REDIS_HOSTNAME port not stripped")
        if "dragonfly.immich.svc.cluster.local:6379" in immich:
            raise SystemExit("immich REDIS_HOSTNAME still includes :6379")
        overlay = (
            dest
            / "apps"
            / "immich"
            / "helm"
            / "immich"
            / "overlays"
            / "homelab"
            / "kustomization.yaml"
        ).read_text()
        if '"memory":"2Gi"' in overlay:
            raise SystemExit("immich overlay still limits memory to 2Gi")
        if '"memory":"4Gi"' not in overlay:
            raise SystemExit("immich overlay memory not bumped to 4Gi")
        pg = (dest / "apps" / "immich" / "3_postgres.yaml").read_text()
        if "shared_preload_libraries:" not in pg or "- vchord" not in pg:
            raise SystemExit("immich Cluster missing vchord shared_preload_libraries")
        if "superuser: true" not in pg:
            raise SystemExit("immich role not rewritten to superuser")
        if "CREATE EXTENSION IF NOT EXISTS vchord CASCADE" not in pg:
            raise SystemExit("immich postInitSQL missing vchord")
        if "name: earthdistance" not in pg:
            raise SystemExit("immich Database missing earthdistance extension")
        oo_vals = (
            dest / "apps" / "openobserve" / "helm" / "openobserve" / "base" / "values.yaml"
        ).read_text()
        if "timeoutSeconds: 15" not in oo_vals:
            raise SystemExit("openobserve probe timeoutSeconds missing")
        oo_tpl = next(
            (dest / "apps" / "openobserve").rglob("openobserve-statefulset.yaml")
        ).read_text()
        if "timeoutSeconds:" not in oo_tpl:
            raise SystemExit("openobserve statefulset template missing timeoutSeconds")
        rustfs_map = (dest / "apps" / "rustfs" / "5_user_namespace_policy.yaml").read_text()
        if "hostUsers: false" in rustfs_map:
            raise SystemExit("rustfs MAP still patches hostUsers false")
        if 'expression: "true"' not in rustfs_map:
            raise SystemExit("rustfs MAP matchCondition not always-on")
        work = (dest / "apps" / "workarounds.yaml").read_text()
        httproute = work.split("kind: HTTPRoute", 1)[1].split("---")[0]
        if 'argocd.argoproj.io/sync-wave: "2"' not in httproute:
            raise SystemExit("HTTPRoute missing sync-wave 2")
        if "kind: SecurityPolicy" in work:
            raise SystemExit("SecurityPolicy should be omitted before sync-wave rewrite")
        cs_vals = (dest / "apps" / "crowdsec" / "helm" / "values.yaml").read_text()
        if "agent:\n  enabled: true\n" in cs_vals:
            raise SystemExit("crowdsec agent still enabled")
        if "agent:\n  enabled: false\n" not in cs_vals:
            raise SystemExit("crowdsec agent not disabled")
        cs_app = (dest / "apps" / "crowdsec" / "3_helm.yaml").read_text()
        if "SkipHooks=true" not in cs_app:
            raise SystemExit("crowdsec Application missing SkipHooks")
        cnpg = work.split("kind: Cluster", 1)[1].split("---")[0]
        if "timeoutSeconds: 10" not in cnpg:
            raise SystemExit("CNPG cluster probes not relaxed")
        if ".spec.httpRoute" not in apps:
            raise SystemExit("parent Applications missing Grafana httpRoute ignore")
        if ".spec.rules[].backendRefs[].kind" not in apps:
            raise SystemExit("parent Applications missing HTTPRoute backendRefs.kind ignore")
        if "kind: MutatingAdmissionPolicy" not in apps:
            raise SystemExit("parent Applications missing MAP ignoreDifferences")
        if ".spec.volumeClaimTemplates" not in apps:
            raise SystemExit("parent Applications missing StatefulSet volumeClaimTemplates ignore")
        sts_ignore = apps.split("kind: StatefulSet", 1)[1].split("kind:", 1)[0]
        if "name: openobserve" not in sts_ignore:
            raise SystemExit("StatefulSet ignoreDifferences must be named openobserve")
        authelia = (
            dest / "apps" / "authelia" / "helm" / "authelia" / "base" / "values.yaml"
        ).read_text()
        if 'maxSurge: "1"' in authelia or "maxSurge: '1'" in authelia:
            raise SystemExit("authelia maxSurge still count-string")
        if 'maxSurge: "100%"' not in authelia:
            raise SystemExit("authelia maxSurge not rewritten to percent")
        if 'maxUnavailable: "0%"' not in authelia:
            raise SystemExit("authelia maxUnavailable not rewritten to percent")
        cnpg_vals = (
            dest
            / "apps"
            / "cloudnative-pg"
            / "helm"
            / "cloudnative-pg"
            / "base"
            / "values.yaml"
        ).read_text()
        if "failurePolicy: Ignore" not in cnpg_vals:
            raise SystemExit("CNPG webhook failurePolicy not Ignore")
        cnpg_tpl = next(
            (dest / "apps" / "cloudnative-pg").rglob("deployment.yaml")
        ).read_text()
        if "timeoutSeconds:" not in cnpg_tpl:
            raise SystemExit("CNPG operator template missing timeoutSeconds")
        go_vals = (
            dest
            / "apps"
            / "grafana-operator"
            / "helm"
            / "grafana-operator"
            / "base"
            / "values.yaml"
        ).read_text()
        if "timeoutSeconds: 15" not in go_vals:
            raise SystemExit("grafana-operator probe timeout missing")
        df_vals = (
            dest
            / "apps"
            / "dragonfly-operator"
            / "helm"
            / "dragonfly-operator"
            / "base"
            / "values.yaml"
        ).read_text()
        if "timeoutSeconds: 15" not in df_vals:
            raise SystemExit("dragonfly-operator probe timeout missing")
        rustfs_map = (dest / "apps" / "rustfs" / "5_user_namespace_policy.yaml").read_text()
        if "timeoutSeconds: 15" not in rustfs_map:
            raise SystemExit("rustfs MAP missing probe timeouts")
        sc = (ROOT / "examples" / "manifests" / "longhorn-crypto-storageclass.yaml").read_text()
        if "volumeBindingMode: WaitForFirstConsumer" not in sc:
            raise SystemExit("kind longhorn-crypto StorageClass not WaitForFirstConsumer")
    print("rewrite-staging.py ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
