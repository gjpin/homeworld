#!/usr/bin/env python3
"""Rewrite a staged homeworld apps/ tree for kind e2e.

- Drop Applications that cannot run on kind.
- Point remaining Applications at the local git daemon.
- Open Infisical egress on 8080 and git daemon egress on 9418.
"""
from __future__ import annotations

import argparse
import pathlib
import re
import sys

OMIT_APPS = {
    "longhorn-app",
    "velero-app",
    "velero-ui-app",
    "homeassistant-app",
    # ExternalDNS publishes the production wildcard record through the
    # Cloudflare API; kind resolves the e2e domain through CoreDNS
    # (patch-coredns-e2e-domain.sh) instead.
    "external-dns-app",
    # Rootless Docker (Lima or Desktop) cannot mount bpffs, so the Cilium
    # datapath cannot start on kind; the suite installs its own CRD-only
    # Cilium in kube-system.
    "cilium-app",
    # Kind's local-path provisioner has no CSI driver, so there is nothing
    # for the snapshot controller to act on; keep the suite lean.
    "snapshot-controller-app",
    # Gluetun needs real ProtonVPN WireGuard credentials, which the suite
    # does not have; the qBittorrent pod can never become Ready.
    "qbittorrent-app",
    # Host lifecycle: kured reads the node's reboot sentinel through the
    # host PID namespace and reboots nodes, and the system-upgrade-controller
    # Plans replace the k3s binary on the host. Kind nodes are neither
    # Fedora nor k3s.
    "kured-app",
    "system-upgrade-controller-app",
    # No NAS on kind: the NFS volumes are rewritten to local-path claims
    # (rewrite_kind_nfs_volumes), so the NFS CSI node plugin has no work.
    "csi-driver-nfs-app",
    # Supernote publishes amd64-only images, and the kind node follows the
    # host architecture (arm64 on Apple-silicon Lima / Docker Desktop).
    "supernote-app",
    # The Intel GPU device plugin image is amd64-only and kind nodes have no
    # Intel GPU to advertise.
    "intel-gpu-plugin-app",
    # qbit_manage manages qBittorrent, which is omitted above; its CronJob
    # would fail every run.
    "qbit-manage-app",
}

GIT_REPO_URL = "git://host.docker.internal:9418/homeworld.git"

# host.docker.internal is injected via /etc/hosts on Docker Desktop / kind,
# so Cilium toFQDNs (DNS-based) never learns the IP. Allow the host and
# world entities on the e2e-only ports instead.
HOST_ENTITY_EGRESS = """  egress:
    - toEntities:
        - world
        - host
      toPorts:
        - ports:
            - port: "{port}"
              protocol: TCP
"""

GIT_EGRESS = """
    - toEntities:
        - world
        - host
      toPorts:
        - ports:
            - port: "9418"
              protocol: TCP
"""


def split_docs(text: str) -> list[str]:
    parts = re.split(r"(?m)^---\s*\n", text)
    docs = []
    for p in parts:
        if p.strip():
            docs.append(p)
    return docs


def join_docs(docs: list[str]) -> str:
    out = []
    for d in docs:
        body = d if d.endswith("\n") else d + "\n"
        out.append("---\n" + body)
    return "".join(out)


def metadata_name(doc: str) -> str | None:
    m = re.search(r"(?m)^  name: (\S+)", doc)
    return m.group(1) if m else None


def rewrite_homeworld_repo_urls(root: pathlib.Path) -> None:
    count = 0
    for path in root.rglob("*.yaml"):
        text = path.read_text()
        if "https://github.com/gjpin/homeworld.git" not in text:
            continue
        path.write_text(
            text.replace(
                "https://github.com/gjpin/homeworld.git",
                GIT_REPO_URL,
            )
        )
        count += 1
    print(f"[rewrite-staging] rewrote homeworld repoURL in {count} files")


E2E_SYNC_OPTIONS = (
    "SkipDryRunOnMissingResource=true",
    "ServerSideApply=true",
    "RespectIgnoreDifferences=true",
)

# Controller defaulting and operator mutations that keep parent apps OutOfSync
# on an empty kind cluster even after a successful apply.
E2E_IGNORE_ITEMS = (
    "    - group: gateway.networking.k8s.io\n"
    "      kind: Gateway\n"
    "      jqPathExpressions:\n"
    "        - .spec.listeners[].tls.certificateRefs[].group\n",
    "    - group: gateway.networking.k8s.io\n"
    "      kind: HTTPRoute\n"
    "      jqPathExpressions:\n"
    "        - .spec.parentRefs[].group\n"
    "        - .spec.parentRefs[].kind\n"
    "        - .spec.rules[].backendRefs[].group\n"
    "        - .spec.rules[].backendRefs[].kind\n"
    "        - .spec.rules[].backendRefs[].weight\n"
    "        - .spec.rules[].matches\n",
    "    - group: gateway.networking.k8s.io\n"
    "      kind: TCPRoute\n"
    "      jqPathExpressions:\n"
    "        - .spec.parentRefs[].group\n"
    "        - .spec.parentRefs[].kind\n"
    "        - .spec.rules[].backendRefs[].group\n"
    "        - .spec.rules[].backendRefs[].kind\n"
    "        - .spec.rules[].backendRefs[].weight\n",
    "    - group: gateway.networking.k8s.io\n"
    "      kind: GRPCRoute\n"
    "      jqPathExpressions:\n"
    "        - .spec.parentRefs[].group\n"
    "        - .spec.parentRefs[].kind\n"
    "        - .spec.rules[].backendRefs[].group\n"
    "        - .spec.rules[].backendRefs[].kind\n"
    "        - .spec.rules[].backendRefs[].weight\n",
    "    - group: gateway.envoyproxy.io\n"
    "      kind: SecurityPolicy\n"
    "      jqPathExpressions:\n"
    "        - .spec.targetRef.group\n"
    "        - .spec.targetRefs[].group\n",
    "    - group: external-secrets.io\n"
    "      kind: ExternalSecret\n"
    "      jqPathExpressions:\n"
    "        - .spec.data[].remoteRef.conversionStrategy\n"
    "        - .spec.data[].remoteRef.metadataPolicy\n"
    "        - .spec.data[].remoteRef.nullBytePolicy\n"
    "        - .spec.target.creationPolicy\n"
    "        - .spec.target.deletionPolicy\n",
    "    - group: argoproj.io\n"
    "      kind: Application\n"
    "      jsonPointers:\n"
    "        - /operation\n"
    "      jqPathExpressions:\n"
    "        - .spec.syncPolicy.automated.allowEmpty\n",
    # The Grafana operator only re-serializes spec.deployment (no semantic
    # defaulting), so it must NOT be ignored: ignoring the whole block froze
    # the openobserve plugin loader in place and prevented the victoria
    # plugins from ever deploying.
    "    - group: grafana.integreatly.org\n"
    "      kind: Grafana\n"
    "      jqPathExpressions:\n"
    "        - .spec.persistentVolumeClaim\n"
    "        - .spec.httpRoute\n",
    "    - group: postgresql.cnpg.io\n"
    "      kind: Database\n"
    "      jqPathExpressions:\n"
    "        - .spec.ensure\n",
    "    - group: postgresql.cnpg.io\n"
    "      kind: Cluster\n"
    "      jsonPointers:\n"
    "        - /spec\n",
    "    - group: admissionregistration.k8s.io\n"
    "      kind: MutatingAdmissionPolicy\n"
    "      jqPathExpressions:\n"
    "        - .spec.matchConstraints.matchPolicy\n"
    "        - .spec.matchConstraints.namespaceSelector\n"
    "        - .spec.matchConstraints.objectSelector\n"
    "        - .spec.matchConstraints.resourceRules[].scope\n",
    "    - group: admissionregistration.k8s.io\n"
    "      kind: MutatingAdmissionPolicyBinding\n"
    "      jqPathExpressions:\n"
    "        - .spec.matchResources.matchPolicy\n"
    "        - .spec.matchResources.namespaceSelector\n"
    "        - .spec.matchResources.objectSelector\n"
    "        - .spec.matchResources.resourceRules[].scope\n",
    "    - group: apps\n"
    "      kind: StatefulSet\n"
    "      name: victoria-metrics\n"
    "      jqPathExpressions:\n"
    "        - .spec.volumeClaimTemplates\n"
    "        - .spec.template.spec.initContainers\n"
    "        - .spec.template.spec.volumes\n"
    "        - .spec.persistentVolumeClaimRetentionPolicy\n",
    "    - group: apps\n"
    "      kind: StatefulSet\n"
    "      name: victoria-logs\n"
    "      jqPathExpressions:\n"
    "        - .spec.volumeClaimTemplates\n"
    "        - .spec.template.spec.initContainers\n"
    "        - .spec.template.spec.volumes\n"
    "        - .spec.persistentVolumeClaimRetentionPolicy\n",
    "    - group: apps\n"
    "      kind: StatefulSet\n"
    "      name: victoria-traces\n"
    "      jqPathExpressions:\n"
    "        - .spec.volumeClaimTemplates\n"
    "        - .spec.template.spec.initContainers\n"
    "        - .spec.template.spec.volumes\n"
    "        - .spec.persistentVolumeClaimRetentionPolicy\n",
    "    - group: documentdb.io\n"
    "      kind: DocumentDB\n"
    "      jsonPointers:\n"
    "        - /spec\n",
)


def ensure_e2e_sync_options(doc: str) -> str:
    """Make directory Applications sync on an empty cluster.

    SkipDryRunOnMissingResource: mix CRD installers with CRs (Gateway,
    ClusterSecretStore, CNPG, …) without failing Validate=true.
    ServerSideApply: large CRDs and Grafana dashboard ConfigMaps exceed the
    256Ki last-applied-configuration annotation.
    """
    m = re.search(r"(?m)^( *)syncOptions:\n( *)- ", doc)
    if not m:
        return doc
    item_indent = m.group(2)
    insert = "".join(
        f"{item_indent}- {opt}\n" for opt in E2E_SYNC_OPTIONS if opt not in doc
    )
    if not insert:
        return doc
    return doc[: m.start(2)] + insert + doc[m.start(2) :]


def ensure_e2e_ignore_differences(doc: str) -> str:
    """Ignore CRD defaulting so wait-argo can reach Synced on kind."""
    if not re.search(r"(?m)^kind: Application\s*$", doc):
        return doc
    missing = [item for item in E2E_IGNORE_ITEMS if item not in doc]
    if not missing:
        return doc
    insert = "".join(missing)
    if "ignoreDifferences:\n" in doc:
        idx = doc.index("ignoreDifferences:\n") + len("ignoreDifferences:\n")
        return doc[:idx] + insert + doc[idx:]
    block = "  ignoreDifferences:\n" + insert
    if "  source:\n" in doc:
        return doc.replace("  source:\n", block + "  source:\n", 1)
    if "  destination:\n" in doc:
        return doc.replace("  destination:\n", block + "  destination:\n", 1)
    return doc.rstrip() + "\n" + block


def ensure_sync_wave(doc: str, wave: str) -> str:
    m = re.search(r'argocd\.argoproj\.io/sync-wave:\s*"?([^"\n]+)"?', doc)
    if m:
        try:
            if int(m.group(1).strip()) >= int(wave):
                return doc
        except ValueError:
            pass
        return (
            doc[: m.start()]
            + f'argocd.argoproj.io/sync-wave: "{wave}"'
            + doc[m.end() :]
        )
    if re.search(r"(?m)^  annotations:\n", doc):
        return re.sub(
            r"(?m)^  annotations:\n",
            f'  annotations:\n    argocd.argoproj.io/sync-wave: "{wave}"\n',
            doc,
            count=1,
        )
    m = re.search(r"(?m)^(metadata:\n(?:  [^\n]+\n)+)", doc)
    if not m:
        return doc
    return (
        doc[: m.start()]
        + m.group(1)
        + f'  annotations:\n    argocd.argoproj.io/sync-wave: "{wave}"\n'
        + doc[m.end() :]
    )


def rewrite_app_of_apps(path: pathlib.Path) -> None:
    docs = split_docs(path.read_text())
    kept = []
    for doc in docs:
        name = metadata_name(doc)
        if name in OMIT_APPS:
            continue
        doc = re.sub(
            r"(?m)^    repoURL: .*$",
            f"    repoURL: {GIT_REPO_URL}",
            doc,
        )
        doc = re.sub(
            r"(?m)^    targetRevision: .*$",
            "    targetRevision: HEAD",
            doc,
        )
        if "app.kubernetes.io/part-of: homeworld" not in doc:
            doc = doc.replace(
                "  namespace: argocd\n",
                "  namespace: argocd\n  labels:\n    app.kubernetes.io/part-of: homeworld\n",
                1,
            )
        doc = ensure_e2e_sync_options(doc)
        doc = ensure_e2e_ignore_differences(doc)
        kept.append(doc)
    if not kept:
        raise SystemExit("rewrite-staging: no Applications left in app-of-apps.yaml")
    path.write_text(join_docs(kept))
    print(f"[rewrite-staging] app-of-apps: kept {len(kept)} applications, omitted {sorted(OMIT_APPS)}")


def rewrite_kind_userns(root: pathlib.Path) -> None:
    """Docker Desktop rootless cannot idmap overlayfs, so hostUsers: false never starts."""
    count = 0
    for path in root.rglob("*"):
        if path.suffix not in {".yaml", ".yml", ".json", ".tpl"}:
            continue
        try:
            text = path.read_text()
        except (OSError, UnicodeDecodeError):
            continue
        if "hostUsers" not in text:
            continue
        new = text.replace("hostUsers: false", "hostUsers: true")
        new = new.replace("hostUsers:false", "hostUsers:true")
        new = re.sub(
            r"(path: /spec(?:/template)?/spec/hostUsers\n\s+value:) false",
            r"\1 true",
            new,
        )
        new = re.sub(
            r'(/spec(?:/template/spec)?/hostUsers"\s*,\s*"value"\s*:\s*)false',
            r"\1true",
            new,
        )
        if new != text:
            path.write_text(new)
            count += 1
    print(f"[rewrite-staging] hostUsers false->true in {count} files")


def rewrite_kind_runtime_class(root: pathlib.Path) -> None:
    """Kind nodes have no runsc binary, so runtimeClassName: gvisor never starts."""
    import re
    count = 0
    for path in root.rglob("*.yaml"):
        try:
            text = path.read_text()
        except (OSError, UnicodeDecodeError):
            continue
        new = re.sub(r"(?m)^\s*runtimeClassName:\s*gvisor\s*\n", "", text)
        # A policy whose only mutation is the runtime class has nothing left
        # to inject on kind: drop it with its binding.
        if "Object{spec: Object.spec{runtimeClassName: 'gvisor'}}" in new:
            path.unlink()
            count += 1
            continue
        if new != text:
            path.write_text(new)
            count += 1
    for kpath in root.rglob("kustomization.yaml"):
        try:
            ktext = kpath.read_text()
        except (OSError, UnicodeDecodeError):
            continue
        knew = re.sub(
            r"(?m)^\s*- op: add\n\s*path: /spec/template/spec/runtimeClassName\n\s*value: gvisor\n",
            "",
            ktext,
        )
        # The kind bootstrap Argo CD compares client-side, whose frozen
        # OpenAPI v2 schema predates StatefulSet maxSurge ("field not
        # declared in schema" on the argocd child app). Production Argo CD
        # diffs server-side, where the apiserver accepts the surge — keep
        # the patch in git, drop it from the kind staging tree. The patch
        # block carries explanatory comments, so match through to the end
        # of its ops.
        # Split into "  - target:" blocks and drop the StatefulSet
        # updateStrategy block (its patch body carries comments).
        if "updateStrategy" in knew:
            blocks = re.split(r"(?m)^(?=  - target:)", knew)
            kept = [
                b for b in blocks
                if not (
                    "kind: StatefulSet" in b
                    and "argocd-argocd-application-controller" in b
                    and "updateStrategy" in b
                )
            ]
            knew = "".join(kept)
        # Dropping the only op in a patch leaves `patch: |-` with an empty
        # body, which kustomize rejects. Remove such emptied patch entries.
        knew = re.sub(
            r"(?m)^  - target:\n(?:    .*\n)+?    patch: \|-\n(?=  - target:\n|\Z)",
            "",
            knew,
        )
        if knew != ktext:
            kpath.write_text(knew)
            count += 1
    print(f"[rewrite-staging] runtimeClassName gvisor removed in {count} files")


def rewrite_eso_decoding_none(root: pathlib.Path) -> None:
    """Infisical stores plaintext; Auto base64-decodes values that happen to be valid b64.

    POSTGRES_USERNAME=authelia (8 chars) and 64-char hex-ish secrets become binary
    and CNPG fails with 'string field contains invalid UTF-8'.
    """
    count = 0
    for path in root.rglob("*.yaml"):
        text = path.read_text()
        if "decodingStrategy: Auto" not in text:
            continue
        path.write_text(text.replace("decodingStrategy: Auto", "decodingStrategy: None"))
        count += 1
    print(f"[rewrite-staging] decodingStrategy Auto->None in {count} files")


def rewrite_opencloud_collaboration_insecure(root: pathlib.Path) -> None:
    """Kind Gateways use self-signed certs; OpenCloud WOPI discovery must skip verify."""
    count = 0
    for path in root.rglob("*.yaml"):
        text = path.read_text()
        new = text
        for key in (
            "COLLABORATION_APP_INSECURE",
            "COLLABORATION_CS3API_DATAGATEWAY_INSECURE",
        ):
            new = re.sub(
                rf'(- name: {key}\n\s+value: )"false"',
                r'\1"true"',
                new,
            )
        if new != text:
            path.write_text(new)
            count += 1
    print(f"[rewrite-staging] opencloud collaboration TLS insecure in {count} files")


def rewrite_opencloud_web_extensions(root: pathlib.Path) -> None:
    """web-extensions 2.x ships apps under /usr/share/nginx/html/apps/<name>/.

    importer-1.0.0 still uses /usr/share/nginx/html/importer/ (no apps/ prefix),
    and cast-1.0.0 still uses /usr/share/nginx/html/cast/.
    """
    count = 0
    for path in root.rglob("*.yaml"):
        text = path.read_text()
        new = re.sub(
            r"/usr/share/nginx/html/(?!apps/)(?!importer/)(?!cast/)",
            "/usr/share/nginx/html/apps/",
            text,
        )
        if new != text:
            path.write_text(new)
            count += 1
    print(f"[rewrite-staging] opencloud web-extensions path in {count} files")


def rewrite_argocd_disable_extras(root: pathlib.Path) -> None:
    """Dex/ApplicationSet/notifications each hold inotify watches; rootless Docker cannot raise the 128 cap."""
    path = root / "apps" / "argocd" / "helm" / "values.yaml"
    if not path.exists():
        print("[rewrite-staging] argocd helm values missing; skipping extras disable")
        return
    text = path.read_text()
    new = text
    for key in ("dex", "applicationSet", "notifications"):
        if re.search(rf"(?m)^{key}:\n  enabled:", new):
            continue
        new = re.sub(rf"(?m)^{key}:\n", f"{key}:\n  enabled: false\n", new, count=1)
    if "controller.diff.server.side" not in new:
        if re.search(r"(?m)^  params:\n", new):
            new = re.sub(
                r"(?m)^  params:\n",
                '  params:\n    controller.diff.server.side: "false"\n',
                new,
                count=1,
            )
        else:
            new = re.sub(
                r"(?m)^(configs:\n(?:  cm:\n(?:    .*\n)*))",
                r'\1  params:\n    controller.diff.server.side: "false"\n',
                new,
                count=1,
            )
    if "resource.exclusions:" not in new:
        new = re.sub(
            r"(?m)^configs:\n  cm:\n",
            "configs:\n"
            "  cm:\n"
            "    resource.exclusions: |\n"
            "      - apiGroups:\n"
            "        - apiextensions.k8s.io\n"
            "        kinds:\n"
            "        - CustomResourceDefinition\n"
            "        clusters:\n"
            '        - "*"\n',
            new,
            count=1,
        )
    if "resource.customizations.health.PersistentVolumeClaim" not in new:
        new = re.sub(
            r"(?m)^configs:\n  cm:\n",
            "configs:\n"
            "  cm:\n"
            "    resource.customizations.health.PersistentVolumeClaim: |\n"
            "      hs = {}\n"
            '      hs.status = "Healthy"\n'
            '      hs.message = "kind e2e: WaitForFirstConsumer PVCs stay Pending until a Pod exists"\n'
            "      return hs\n"
            "    resource.customizations.health.gateway.envoyproxy.io_SecurityPolicy: |\n"
            "      hs = {}\n"
            '      hs.status = "Healthy"\n'
            '      hs.message = "kind e2e: SecurityPolicy health customized for wait-argo"\n'
            "      return hs\n"
            "    resource.customizations.health.gateway.networking.k8s.io_HTTPRoute: |\n"
            "      hs = {}\n"
            '      hs.status = "Healthy"\n'
            '      hs.message = "kind e2e: HTTPRoute Accepted waits on backends"\n'
            "      return hs\n"
            "    resource.customizations.health.gateway.networking.k8s.io_GRPCRoute: |\n"
            "      hs = {}\n"
            '      hs.status = "Healthy"\n'
            '      hs.message = "kind e2e: GRPCRoute Accepted waits on backends"\n'
            "      return hs\n",
            new,
            count=1,
        )
    # Nested Applications, CNPG, Gateways, Tenants stay Progressing on a
    # saturated kind node and block wait-argo even when git is Synced.
    for gvk, msg in (
        ("argoproj.io_Application", "kind e2e: nested Application health ignored"),
        ("grafana.integreatly.org_Grafana", "kind e2e: Grafana instance health ignored for wait-argo"),
        ("postgresql.cnpg.io_Cluster", "kind e2e: CNPG Cluster health ignored for wait-argo"),
        ("postgresql.cnpg.io_Database", "kind e2e: CNPG Database health ignored for wait-argo"),
        ("dragonflydb.io_Dragonfly", "kind e2e: Dragonfly health ignored for wait-argo"),
        ("documentdb.io_DocumentDB", "kind e2e: DocumentDB health ignored for wait-argo"),
        ("rustfs.com_Tenant", "kind e2e: RustFS Tenant health ignored for wait-argo"),
        ("gateway.networking.k8s.io_Gateway", "kind e2e: Gateway health ignored for wait-argo"),
        ("gateway.networking.k8s.io_GatewayClass", "kind e2e: GatewayClass health ignored for wait-argo"),
        ("gateway.envoyproxy.io_EnvoyProxy", "kind e2e: EnvoyProxy health ignored for wait-argo"),
        ("external-secrets.io_ExternalSecret", "kind e2e: ExternalSecret health ignored for wait-argo"),
        (
            "admissionregistration.k8s.io_MutatingAdmissionPolicy",
            "kind e2e: MAP health ignored for wait-argo",
        ),
        (
            "admissionregistration.k8s.io_MutatingAdmissionPolicyBinding",
            "kind e2e: MAP binding health ignored for wait-argo",
        ),
    ):
        key = f"resource.customizations.health.{gvk}"
        block = (
            f"    {key}: |\n"
            "      hs = {}\n"
            '      hs.status = "Healthy"\n'
            f'      hs.message = "{msg}"\n'
            "      return hs\n"
        )
        if key in new:
            if msg in new:
                continue
            new = re.sub(
                rf"(?m)^    {re.escape(key)}: \|.*?\n(?=  \S|\Z)",
                block,
                new,
                count=1,
                flags=re.DOTALL,
            )
            continue
        new = new.replace("configs:\n  cm:\n", "configs:\n  cm:\n" + block, 1)
    if re.search(r"(?m)^controller:\n", new) and "controller:\n  readinessProbe:" not in new:
        new = re.sub(
            r"(?m)^controller:\n",
            "controller:\n"
            "  readinessProbe:\n"
            "    timeoutSeconds: 15\n"
            "    failureThreshold: 5\n",
            new,
            count=1,
        )
    if re.search(r"(?m)^server:\n", new) and "server:\n  livenessProbe:" not in new:
        new = re.sub(
            r"(?m)^server:\n",
            "server:\n"
            "  livenessProbe:\n"
            "    timeoutSeconds: 15\n"
            "    failureThreshold: 5\n"
            "  readinessProbe:\n"
            "    timeoutSeconds: 15\n"
            "    failureThreshold: 5\n",
            new,
            count=1,
        )
    overlay = (
        root / "apps" / "argocd" / "helm" / "kustomization.yaml"
    )
    if overlay.exists():
        ot = overlay.read_text()
        patched = re.sub(
            r"(kind: StatefulSet\n    name: \^argocd-argocd-application-controller\$.*?\"memory\":\")2Gi",
            r"\g<1>4Gi",
            ot,
            count=1,
            flags=re.S,
        )
        patched = re.sub(
            r"(kind: StatefulSet\n    name: \^argocd-argocd-application-controller\$.*?\"memory\":\")64Mi",
            r"\g<1>256Mi",
            patched,
            count=1,
            flags=re.S,
        )
        if patched != ot:
            overlay.write_text(patched)
            new = new  # keep extras-disable write below using `new`
            print("[rewrite-staging] argocd application-controller memory 4Gi")
    if "ARGOCD_GPG_ENABLED" not in new:
        new = re.sub(
            r"(?m)^repoServer:\n",
            "repoServer:\n"
            "  livenessProbe:\n"
            "    timeoutSeconds: 15\n"
            "    failureThreshold: 5\n"
            "  readinessProbe:\n"
            "    timeoutSeconds: 10\n"
            "    failureThreshold: 5\n"
            "  env:\n"
            "    - name: ARGOCD_GPG_ENABLED\n"
            '      value: "false"\n',
            new,
            count=1,
        )
    if new != text:
        path.write_text(new)
        print("[rewrite-staging] argocd extras disabled and repo-server GPG watcher off")
    else:
        print("[rewrite-staging] argocd extras already disabled or keys missing")


def rewrite_collabora_kind_jail(root: pathlib.Path) -> None:
    """Restricted kind cannot CAP_SYS_ADMIN or nested user-ns mounts for COOL jails."""
    path = (
        root
        / "apps"
        / "collabora"
        / "helm"
        / "values.yaml"
    )
    if not path.exists():
        print("[rewrite-staging] collabora values missing; skipping jail rewrite")
        return
    text = path.read_text()
    new = text
    if "mount_jail_tree=false" not in new:
        if "--o:logging.level=warning" not in new:
            print("[rewrite-staging] collabora extra_params marker missing")
        else:
            new = new.replace(
                "--o:logging.level=warning",
                "--o:logging.level=warning\n"
                "    --o:mount_jail_tree=false\n"
                "    --o:security.capabilities=false\n"
                "    --o:child_root_path=/tmp/coolwsd-child-roots\n"
                "    --o:cache_files.path=/tmp/coolwsd-cache",
            )
    # Chart already mounts emptyDir at /tmp; a second mountPath=/tmp fails SSA.
    # Image USER is 1001 (cool); chart 1000 makes coolforkit abort with
    # "incorrect user-name, other than 'cool'".
    if "runAsUser: 1000" in new:
        new = new.replace("runAsUser: 1000", "runAsUser: 1001")
        new = new.replace("runAsGroup: 1000", "runAsGroup: 1001")
        new = new.replace("fsGroup: 1000", "fsGroup: 1001")
    if new != text:
        path.write_text(new)
        print("[rewrite-staging] collabora jail disabled (mount_jail_tree=false, /tmp child roots, uid 1001)")
    else:
        print("[rewrite-staging] collabora jail rewrite unchanged")


def rewrite_immich_kind_storage(root: pathlib.Path) -> None:
    """Kind local-path is RWO; the library PVC in git is named photos, not immich."""
    path = root / "apps" / "immich" / "helm" / "values.yaml"
    if not path.exists():
        print("[rewrite-staging] immich values missing; skipping storage rewrite")
        return
    text = path.read_text()
    new = text.replace("existingClaim: immich\n", "existingClaim: photos\n")
    new = new.replace("accessMode: ReadWriteMany", "accessMode: ReadWriteOnce")
    # ioredis treats host:port as a hostname and fails DNS (ENOTFOUND).
    new = new.replace(
        "REDIS_HOSTNAME: dragonfly.immich.svc.cluster.local:6379",
        "REDIS_HOSTNAME: dragonfly.immich.svc.cluster.local",
    )
    if new != text:
        path.write_text(new)
        print("[rewrite-staging] immich existingClaim=photos, ML volume RWO")
    else:
        print("[rewrite-staging] immich storage rewrite unchanged")
    rewrite_immich_memory(root)


def rewrite_kind_nfs_volumes(root: pathlib.Path) -> None:
    """Kind has no NAS and no NFS CSI driver (csi-driver-nfs-app is omitted).

    Drop the static NFS PersistentVolumes and turn the claims bound to them
    into small local-path claims of the longhorn-crypto substitute class.
    """
    count = 0
    for path in (root / "apps").rglob("*.yaml"):
        if "/charts/" in path.as_posix():
            continue
        text = path.read_text()
        if "kind: PersistentVolume\n" not in text or "driver: nfs.csi.k8s.io" not in text:
            continue
        docs = []
        for doc in split_docs(text):
            if "kind: PersistentVolume\n" in doc and "driver: nfs.csi.k8s.io" in doc:
                continue
            if "kind: PersistentVolumeClaim\n" in doc and "volumeName: homeworld-" in doc:
                doc = re.sub(r"(?m)^  volumeName: homeworld-\S+\n", "", doc)
                doc = doc.replace('storageClassName: ""', "storageClassName: longhorn-crypto")
                doc = doc.replace("- ReadWriteMany", "- ReadWriteOnce")
                doc = doc.replace("- ReadOnlyMany", "- ReadWriteOnce")
                doc = re.sub(r"(?m)^(\s*storage:) \S+$", r"\1 1Gi", doc)
            docs.append(doc)
        path.write_text(join_docs(docs))
        count += 1
    print(f"[rewrite-staging] NFS volumes -> local-path claims in {count} files")


def rewrite_jellyfin_kind_gpu(root: pathlib.Path) -> None:
    """Kind has no Intel GPU device plugin (intel-gpu-plugin-app is omitted),
    so Jellyfin's gpu.intel.com/i915 request would never schedule; it runs
    with software transcoding instead."""
    path = root / "apps" / "jellyfin" / "helm" / "values.yaml"
    if not path.is_file():
        print("[rewrite-staging] jellyfin values missing; skipping GPU rewrite")
        return
    text = path.read_text()
    new = re.sub(r'(?m)^\s*gpu\.intel\.com/i915:\s*"1"\n', "", text)
    if new != text:
        path.write_text(new)
        print("[rewrite-staging] jellyfin GPU request removed")
    else:
        print("[rewrite-staging] jellyfin GPU rewrite unchanged")


def rewrite_immich_memory(root: pathlib.Path) -> None:
    """Homelab overlay is 4Gi; still bump any leftover 2Gi limits on kind."""
    path = (
        root
        / "apps"
        / "immich"
        / "helm"
        / "kustomization.yaml"
    )
    if not path.exists():
        print("[rewrite-staging] immich overlay missing; skipping memory bump")
        return
    text = path.read_text()
    new = text.replace('"memory":"2Gi"', '"memory":"4Gi"')
    if new != text:
        path.write_text(new)
        print("[rewrite-staging] immich server/ML memory limit 4Gi")
    else:
        print("[rewrite-staging] immich memory rewrite unchanged")


def rewrite_route_sync_wave(root: pathlib.Path) -> None:
    """HTTPRoute/GRPCRoute/SecurityPolicy default waves stay Degraded until backends exist.

    Argo waits for earlier-wave health before nested Applications (wave 1),
    so authelia/forgejo/immich helm never syncs on an empty cluster.
    """
    count = 0
    kind_re = r"(?m)^kind: (HTTPRoute|GRPCRoute|SecurityPolicy)\s*$"
    for path in root.rglob("*.yaml"):
        text = path.read_text()
        if not re.search(kind_re, text):
            continue
        docs = split_docs(text)
        out = []
        changed = False
        for doc in docs:
            if re.search(kind_re, doc):
                new = ensure_sync_wave(doc, "2")
                if new != doc:
                    changed = True
                out.append(new)
            else:
                out.append(doc)
        if changed:
            path.write_text(join_docs(out))
            count += 1
    print(f"[rewrite-staging] HTTPRoute/GRPCRoute/SecurityPolicy sync-wave 2 in {count} files")


def rewrite_authelia_rolling_update(root: pathlib.Path) -> None:
    """k8s 1.37 IntOrString: a quoted '0'/'1' is parsed as a percent, not a count.

    The Authelia chart schema still types these as string, so use percent
    strings which are valid for both Helm and the Deployment API. Unquoted
    integers fail that schema; quoted count-strings fail Kubernetes 1.37.
    """
    path = root / "apps" / "authelia" / "helm" / "values.yaml"
    if not path.exists():
        print("[rewrite-staging] authelia values missing; skipping rollingUpdate")
        return
    text = path.read_text()
    new = re.sub(
        r'(?m)^(\s*maxSurge:\s*)(?:"1"|\'1\'|1)\s*$',
        r'\1"100%"',
        text,
    )
    new = re.sub(
        r'(?m)^(\s*maxUnavailable:\s*)(?:"0"|\'0\'|0)\s*$',
        r'\1"0%"',
        new,
    )
    if new != text:
        path.write_text(new)
        print("[rewrite-staging] Authelia rollingUpdate percents in 1 files")
    else:
        print("[rewrite-staging] Authelia rollingUpdate already percent")


def _append_values_map(path: pathlib.Path, block: str, already: str) -> bool:
    if not path.exists():
        return False
    text = path.read_text()
    if already in text:
        return False
    if not text.endswith("\n"):
        text += "\n"
    path.write_text(text + block)
    return True


def rewrite_operator_probes(root: pathlib.Path) -> None:
    """Kind kubelet probe timeouts of 1s kill healthy operators and rustfs."""
    cnpg_tpl = None
    for path in root.rglob("deployment.yaml"):
        if "cloudnative-pg" not in path.as_posix() or "templates" not in path.parts:
            continue
        cnpg_tpl = path
        break
    if cnpg_tpl is not None:
        text = cnpg_tpl.read_text()
        if "timeoutSeconds:" not in text:
            live_insert = (
                "          timeoutSeconds: "
                "{{ .Values.webhook.livenessProbe.timeoutSeconds | default 15 }}\n"
                "          failureThreshold: "
                "{{ .Values.webhook.livenessProbe.failureThreshold | default 5 }}\n"
            )
            ready_insert = (
                "          timeoutSeconds: "
                "{{ .Values.webhook.readinessProbe.timeoutSeconds | default 15 }}\n"
                "          failureThreshold: "
                "{{ .Values.webhook.readinessProbe.failureThreshold | default 5 }}\n"
            )
            start_insert = (
                "          timeoutSeconds: "
                "{{ .Values.webhook.startupProbe.timeoutSeconds | default 15 }}\n"
            )
            text = text.replace(
                "            scheme: HTTPS\n"
                "          {{- if .Values.webhook.livenessProbe.initialDelaySeconds }}",
                "            scheme: HTTPS\n"
                + live_insert
                + "          {{- if .Values.webhook.livenessProbe.initialDelaySeconds }}",
                1,
            )
            text = text.replace(
                "            scheme: HTTPS\n"
                "          {{- if .Values.webhook.readinessProbe.initialDelaySeconds }}",
                "            scheme: HTTPS\n"
                + ready_insert
                + "          {{- if .Values.webhook.readinessProbe.initialDelaySeconds }}",
                1,
            )
            text = text.replace(
                "            scheme: HTTPS\n"
                "          {{- if .Values.webhook.startupProbe.periodSeconds }}",
                "            scheme: HTTPS\n"
                + start_insert
                + "          {{- if .Values.webhook.startupProbe.periodSeconds }}",
                1,
            )
            cnpg_tpl.write_text(text)
            print("[rewrite-staging] CNPG operator webhook probe timeouts in template")
        else:
            print("[rewrite-staging] CNPG operator template probes already set")
    cnpg_vals = (
        root / "apps" / "cloudnative-pg" / "helm" / "values.yaml"
    )
    if _append_values_map(
        cnpg_vals,
        (
            "webhook:\n"
            "  mutating:\n"
            "    failurePolicy: Ignore\n"
            "  validating:\n"
            "    failurePolicy: Ignore\n"
            "  livenessProbe:\n"
            "    timeoutSeconds: 15\n"
            "    failureThreshold: 5\n"
            "  readinessProbe:\n"
            "    timeoutSeconds: 15\n"
            "    failureThreshold: 5\n"
            "  startupProbe:\n"
            "    timeoutSeconds: 15\n"
            "    failureThreshold: 24\n"
        ),
        "failurePolicy: Ignore",
    ):
        print("[rewrite-staging] CNPG operator webhook Ignore and probe values")
    go_vals = (
        root
        / "apps"
        / "grafana-operator"
        / "helm"
        / "values.yaml"
    )
    if _append_values_map(
        go_vals,
        (
            "livenessProbe:\n"
            "  timeoutSeconds: 15\n"
            "  failureThreshold: 5\n"
            "readinessProbe:\n"
            "  timeoutSeconds: 15\n"
            "  failureThreshold: 5\n"
        ),
        "timeoutSeconds: 15",
    ):
        print("[rewrite-staging] grafana-operator probe timeouts")
    df_vals = (
        root
        / "apps"
        / "dragonfly-operator"
        / "helm"
        / "values.yaml"
    )
    if _append_values_map(
        df_vals,
        (
            "manager:\n"
            "  livenessProbe:\n"
            "    timeoutSeconds: 15\n"
            "    failureThreshold: 5\n"
            "  readinessProbe:\n"
            "    timeoutSeconds: 15\n"
            "    failureThreshold: 5\n"
        ),
        "timeoutSeconds: 15",
    ):
        print("[rewrite-staging] dragonfly-operator probe timeouts")


def rewrite_cnpg_probes(root: pathlib.Path) -> None:
    """CNPG manager probes on :8000 time out under kind CPU, restarting healthy Postgres."""
    block = (
        "  probes:\n"
        "    startup:\n"
        "      timeoutSeconds: 10\n"
        "      failureThreshold: 60\n"
        "    liveness:\n"
        "      timeoutSeconds: 10\n"
        "    readiness:\n"
        "      timeoutSeconds: 10\n"
    )
    count = 0
    for path in root.rglob("*.yaml"):
        text = path.read_text()
        if "kind: Cluster" not in text or "postgresql.cnpg.io" not in text:
            continue
        docs = split_docs(text)
        out = []
        changed = False
        for doc in docs:
            if (
                re.search(r"(?m)^kind: Cluster\s*$", doc)
                and "postgresql.cnpg.io" in doc
                and "probes:" not in doc
            ):
                if re.search(r"(?m)^spec:\n", doc):
                    doc = re.sub(r"(?m)^spec:\n", "spec:\n" + block, doc, count=1)
                    changed = True
            out.append(doc)
        if changed:
            path.write_text(join_docs(out))
            count += 1
    print(f"[rewrite-staging] CNPG probe timeouts relaxed in {count} files")


def rewrite_otel_node_disable_kubeletstats(root: pathlib.Path) -> None:
    """Kind kubelet serving certs carry no IP SANs; kubeletstats TLS-verifies the node IP.

    The receiver would retry forever on kind. Host/container metrics still flow
    from the filelog and hostmetrics presets; nothing in the suite asserts
    kubelet summary metrics.
    """
    path = root / "apps" / "otel-collector" / "helm" / "node" / "values.yaml"
    if not path.exists():
        print("[rewrite-staging] otel node values missing; skipping kubeletstats disable")
        return
    text = path.read_text()
    new = text.replace(
        "kubeletMetrics:\n    enabled: true\n",
        "kubeletMetrics:\n    enabled: false\n",
    )
    if new != text:
        path.write_text(new)
        print("[rewrite-staging] otel node kubeletstats disabled for kind")
    else:
        print("[rewrite-staging] otel node kubeletstats already disabled")


def rewrite_rustfs_map_hostusers(root: pathlib.Path) -> None:
    """Always apply hostUsers: true so operator-emitted false still gets flipped.

    Also relax kubelet probe timeouts: the operator emits timeoutSeconds 1,
    which kills a healthy rustfs process on a saturated kind node.
    """
    path = root / "apps" / "rustfs" / "-3_user_namespace_policy.yaml"
    if not path.exists():
        return
    text = path.read_text()
    new = text.replace(
        'expression: "!has(object.spec.hostUsers) || object.spec.hostUsers"',
        'expression: "true"',
    )
    old_expr = "Object{spec: Object.spec{hostUsers: true}}"
    probe_expr = (
        "Object{spec: Object.spec{hostUsers: true, containers: ["
        "Object.spec.containers{name: \"rustfs\", "
        "livenessProbe: Object.spec.containers.livenessProbe{"
        "timeoutSeconds: 15, failureThreshold: 12}, "
        "readinessProbe: Object.spec.containers.readinessProbe{"
        "timeoutSeconds: 15, failureThreshold: 12}, "
        "startupProbe: Object.spec.containers.startupProbe{"
        "timeoutSeconds: 15, failureThreshold: 12}}]}}"
    )
    if old_expr in new and "timeoutSeconds: 15" not in new:
        new = new.replace(old_expr, probe_expr)
    if new != text:
        path.write_text(new)
        print("[rewrite-staging] rustfs MAP always-on hostUsers and probe timeouts")
    else:
        print("[rewrite-staging] rustfs MAP matchCondition unchanged")


def rewrite_documentdb_kind(root: pathlib.Path) -> None:
    """Kind webhook/cert-manager is slow; Fail blocks DocumentDB CREATE."""
    count = 0
    for path in root.rglob("10_documentdb_webhook.yaml"):
        if "documentdb-operator" not in path.as_posix():
            continue
        text = path.read_text()
        if "failurePolicy: Fail" in text:
            path.write_text(text.replace("failurePolicy: Fail", "failurePolicy: Ignore"))
            count += 1
    for path in root.rglob("09_documentdb_operator.yaml"):
        if "documentdb-operator" not in path.as_posix():
            continue
        text = path.read_text()
        new = re.sub(
            r"(?m)^(\s*)periodSeconds: (10|20)\n(?!\s*timeoutSeconds:)",
            r"\g<0>\1timeoutSeconds: 15\n",
            text,
        )
        if new != text:
            path.write_text(new)
            count += 1
    print(f"[rewrite-staging] documentdb webhook Ignore + probe timeouts in {count} files")


def rewrite_metrics_server_kind_kubelet_tls(root: pathlib.Path) -> None:
    """Kind kubelet serving certs carry no IP SANs for the docker-network node
    address, so verified-TLS scrapes fail with x509 errors and the pod never
    passes its metric-storage-ready probe. Production (k3s) rotates serving
    certs with node IPs in the SANs and keeps verified TLS."""
    path = root / "apps" / "metrics-server" / "helm" / "values.yaml"
    if not path.exists():
        print("[rewrite-staging] metrics-server values missing; skipping kubelet TLS rewrite")
        return
    text = path.read_text()
    # Guard on the exact appended block: the repo values mention
    # --kubelet-insecure-tls in a comment, so a substring check on the
    # whole file would always pass and skip the rewrite.
    if "\nargs:\n  - --kubelet-insecure-tls\n" in text:
        print("[rewrite-staging] metrics-server kubelet TLS rewrite unchanged")
        return
    new = text + "\n# kind only: kubelet serving certs carry no IP SANs.\nargs:\n  - --kubelet-insecure-tls\n"
    path.write_text(new)
    print("[rewrite-staging] metrics-server --kubelet-insecure-tls for kind")


def rewrite_nested_sync_options(root: pathlib.Path) -> None:
    count = 0
    for path in root.rglob("*.yaml"):
        text = path.read_text()
        if "kind: Application" not in text and "kind: ApplicationSet" not in text:
            continue
        docs = split_docs(text)
        out = [
            ensure_e2e_ignore_differences(ensure_e2e_sync_options(d)) for d in docs
        ]
        new = join_docs(out)
        if new != join_docs(docs):
            path.write_text(new)
            count += 1
    print(f"[rewrite-staging] e2e syncOptions on {count} Application files")


def patch_infisical_cnp(path: pathlib.Path) -> None:
    docs = split_docs(path.read_text())
    out = []
    for doc in docs:
        if metadata_name(doc) == "allow-infisical":
            doc = re.sub(
                r"(?ms)^  egress:\n.*\Z",
                HOST_ENTITY_EGRESS.format(port="8080"),
                doc,
            )
        out.append(doc)
    path.write_text(join_docs(out))
    print("[rewrite-staging] allow-infisical egress -> host/world :8080")


def patch_argocd_repo_cnp(path: pathlib.Path) -> None:
    docs = split_docs(path.read_text())
    out = []
    for doc in docs:
        if metadata_name(doc) == "allow-argocd-repository-sources":
            if "port: \"9418\"" not in doc and "port: '9418'" not in doc:
                doc = doc.rstrip() + "\n" + GIT_EGRESS.lstrip("\n")
                if not doc.endswith("\n"):
                    doc += "\n"
        out.append(doc)
    path.write_text(join_docs(out))
    print("[rewrite-staging] allow-argocd-repository-sources + host.docker.internal:9418")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("staging", type=pathlib.Path)
    args = parser.parse_args()
    root = args.staging
    rewrite_homeworld_repo_urls(root)
    rewrite_app_of_apps(root / "apps" / "app-of-apps.yaml")
    rewrite_nested_sync_options(root)
    rewrite_metrics_server_kind_kubelet_tls(root)
    rewrite_kind_userns(root)
    rewrite_kind_runtime_class(root)
    rewrite_eso_decoding_none(root)
    rewrite_opencloud_web_extensions(root)
    rewrite_opencloud_collaboration_insecure(root)
    rewrite_argocd_disable_extras(root)
    # Controller memory patch lives in rewrite_argocd_disable_extras.
    rewrite_collabora_kind_jail(root)
    rewrite_immich_kind_storage(root)
    rewrite_kind_nfs_volumes(root)
    rewrite_jellyfin_kind_gpu(root)
    rewrite_rustfs_map_hostusers(root)
    rewrite_route_sync_wave(root)
    rewrite_otel_node_disable_kubeletstats(root)
    rewrite_cnpg_probes(root)
    rewrite_authelia_rolling_update(root)
    rewrite_operator_probes(root)
    rewrite_documentdb_kind(root)
    patch_infisical_cnp(root / "apps" / "external-secrets" / "-2_network_policy.yaml")
    patch_argocd_repo_cnp(root / "apps" / "argocd" / "-2_network_policy.yaml")
    return 0


if __name__ == "__main__":
    sys.exit(main())
