#!/usr/bin/env python3
"""Render everything Argo CD would deploy from a cluster.yaml, without a cluster.

1. `helm template` of charts/root with the given values file.
2. For every Application source the way Argo CD renders it:
   - upstream Helm charts (HTTP and OCI repositories) with their valueFiles
     ($values/... resolved to this repository) and helm.valuesObject;
   - local Helm charts (charts/*) with helm.valuesObject;
   - Kustomize directories (components/*) with kustomize.patches;
   - the Den and module charts from the main repository (--main-repo).
3. Writes one file per source into --out, plus root.yaml.

Needs helm and kubectl on PATH, and PyYAML.

  python3 ci/render.py --values examples/cluster.example-filled.yaml \
      --main-repo ../con-services --out build/rendered
"""

import argparse
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile

import yaml

REPO = pathlib.Path(__file__).resolve().parent.parent
KUBE_VERSION = "1.37.0"
# APIs the target cluster serves; charts check them with .Capabilities.
API_VERSIONS = [
    "gateway.networking.k8s.io/v1",
    "gateway.networking.k8s.io/v1beta1",
    "cert-manager.io/v1",
    "cilium.io/v2",
    "cilium.io/v2alpha1",
    "external-secrets.io/v1",
    "postgresql.cnpg.io/v1",
    "policy/v1",
]


def run(cmd, **kw):
    res = subprocess.run(cmd, capture_output=True, text=True, **kw)
    if res.returncode != 0:
        sys.stderr.write(f"FAILED: {' '.join(map(str, cmd))}\n{res.stderr}\n")
        sys.exit(1)
    return res.stdout


def helm_template(release, chart, namespace, value_files, values_obj, extra, tmp):
    cmd = ["helm", "template", release, str(chart), "--namespace", namespace,
           "--include-crds", "--kube-version", KUBE_VERSION]
    for api in API_VERSIONS:
        cmd += ["--api-versions", api]
    for f in value_files:
        cmd += ["-f", str(f)]
    if values_obj:
        p = pathlib.Path(tmp) / f"{release}-values-object.yaml"
        p.write_text(yaml.safe_dump(values_obj), encoding="utf-8")
        cmd += ["-f", str(p)]
    return run(cmd + extra)


def kustomize(path, patches, tmp, name):
    if not patches:
        return run(["kubectl", "kustomize", str(path)])
    d = pathlib.Path(tmp) / f"kustomize-{name}"
    d.mkdir()
    rel = os.path.relpath(path, d).replace(os.sep, "/")
    (d / "kustomization.yaml").write_text(yaml.safe_dump({
        "apiVersion": "kustomize.config.k8s.io/v1beta1",
        "kind": "Kustomization",
        "resources": [rel],
        "patches": patches,
    }), encoding="utf-8")
    return run(["kubectl", "kustomize", str(d)])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--values", required=True)
    ap.add_argument("--main-repo", required=True, help="checkout of AGlElectronics/con-services")
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    out = pathlib.Path(args.out)
    shutil.rmtree(out, ignore_errors=True)
    out.mkdir(parents=True)
    root = run(["helm", "template", "root", str(REPO / "charts/root"), "-f", args.values])
    (out / "root.yaml").write_text(root, encoding="utf-8")
    cluster = yaml.safe_load(open(args.values, encoding="utf-8"))
    main_repo_url = None
    apps = [d for d in yaml.safe_load_all(root) if d and d.get("kind") == "Application"]

    with tempfile.TemporaryDirectory() as tmp:
        for app in apps:
            name = app["metadata"]["name"]
            if name == "root":
                continue
            spec = app["spec"]
            ns = spec["destination"].get("namespace", "default")
            sources = spec.get("sources") or [spec["source"]]
            for i, src in enumerate(sources):
                if "ref" in src and "chart" not in src and "path" not in src:
                    continue
                helm = src.get("helm", {})
                files = [REPO / f.replace("$values/", "") for f in helm.get("valueFiles", [])]
                obj = helm.get("valuesObject")
                release = helm.get("releaseName", name)
                if "chart" in src:
                    url, chart, ver = src["repoURL"], src["chart"], src["targetRevision"]
                    if url.startswith("http"):
                        target, extra = chart, ["--repo", url, "--version", ver]
                    else:
                        target, extra = f"oci://{url}/{chart}", ["--version", ver]
                    text = helm_template(release, target, ns, files, obj, extra, tmp)
                    kind = f"chart {chart} {ver}"
                else:
                    path = src["path"]
                    if src["repoURL"] == (cluster.get("git") or {}).get("repoURL"):
                        base = REPO
                    else:
                        base = pathlib.Path(args.main_repo)
                        main_repo_url = src["repoURL"]
                    full = base / path
                    if (full / "Chart.yaml").exists():
                        text = helm_template(release, full, ns, files, obj, [], tmp)
                        kind = f"local chart {path}"
                    else:
                        text = kustomize(full, src.get("kustomize", {}).get("patches"), tmp, f"{name}-{i}")
                        kind = f"kustomize {path}"
                docs = [d for d in yaml.safe_load_all(text) if d]
                for d in docs:
                    d.setdefault("metadata", {})
                (out / f"{name}--{i}.yaml").write_text(
                    f"# Application {name}, source {i}: {kind}\n" + text, encoding="utf-8")
                print(f"{name:22} source {i}: {kind:55} {len(docs):4} objects")
    if main_repo_url:
        print(f"(module charts read from {args.main_repo} instead of {main_repo_url})")


if __name__ == "__main__":
    main()
