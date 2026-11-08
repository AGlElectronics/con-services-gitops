#!/usr/bin/env python3
"""Turn CustomResourceDefinitions into JSON schemas for kubeconform.

Sources: CRDs found in the rendered manifests (ci/render.py includes them)
plus the CRDs of the cluster prerequisites the template does not install:
Gateway API and Cilium (downloaded), and cert-manager, trust-manager,
External Secrets Operator, CloudNativePG and the Barman Cloud plugin
(rendered from their Helm charts with "helm template --include-crds"). The
versions below are the ones the documentation lists as tested. Schemas are
strict: objects without x-kubernetes-preserve-unknown-fields get
additionalProperties: false, so a misspelt field fails validation.

  python3 ci/crd-schemas.py build/rendered build/schemas
  kubeconform -strict -schema-location default \
    -schema-location 'build/schemas/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' ...
"""

import json
import pathlib
import subprocess
import sys
import urllib.request

import yaml

GATEWAY_API = "v1.6.3"
CILIUM = "v1.20.4"
# (repository, chart, version, extra helm arguments)
PREREQUISITE_CHARTS = [
    ("https://charts.jetstack.io", "cert-manager", "v1.21.3", ["--set", "crds.enabled=true"]),
    ("https://charts.jetstack.io", "trust-manager", "v0.26.0", []),
    ("https://charts.external-secrets.io", "external-secrets", "2.14.0", []),
    ("https://cloudnative-pg.github.io/charts", "cloudnative-pg", "0.29.1", []),
    ("https://cloudnative-pg.github.io/charts", "plugin-barman-cloud", "0.8.1", []),
]
EXTRA = [
    f"https://github.com/kubernetes-sigs/gateway-api/releases/download/{GATEWAY_API}/standard-install.yaml",
] + [
    f"https://raw.githubusercontent.com/cilium/cilium/{CILIUM}/pkg/k8s/apis/cilium.io/client/crds/{p}"
    for p in (
        "v2/ciliumnetworkpolicies.yaml",
        "v2/ciliumclusterwidenetworkpolicies.yaml",
    )
]


def strict(node):
    if isinstance(node, dict):
        if node.get("type") == "object" and "properties" in node \
                and not node.get("x-kubernetes-preserve-unknown-fields") \
                and "additionalProperties" not in node:
            node["additionalProperties"] = False
        for v in node.values():
            strict(v)
    elif isinstance(node, list):
        for v in node:
            strict(v)
    return node


def write(crd, out):
    spec = crd["spec"]
    group, kind = spec["group"], spec["names"]["kind"].lower()
    for v in spec["versions"]:
        schema = (v.get("schema") or {}).get("openAPIV3Schema")
        if not schema:
            continue
        schema = strict(json.loads(json.dumps(schema)))
        props = schema.setdefault("properties", {})
        props.setdefault("apiVersion", {"type": "string"})
        props.setdefault("kind", {"type": "string"})
        props.setdefault("metadata", {"type": "object"})
        path = out / group / f"{kind}_{v['name']}.json"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(schema), encoding="utf-8")


def main():
    rendered, out = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
    docs = []
    for f in rendered.glob("*.yaml"):
        docs += list(yaml.safe_load_all(f.read_text(encoding="utf-8")))
    for url in EXTRA:
        with urllib.request.urlopen(url, timeout=60) as r:
            docs += list(yaml.safe_load_all(r.read().decode()))
    for repo, chart, version, args in PREREQUISITE_CHARTS:
        out_text = subprocess.run(
            ["helm", "template", chart, chart, "--repo", repo, "--version", version,
             "--namespace", "prerequisite", "--include-crds", *args],
            check=True, capture_output=True, text=True).stdout
        docs += list(yaml.safe_load_all(out_text))
    n = 0
    for d in docs:
        if d and d.get("kind") == "CustomResourceDefinition":
            write(d, out)
            n += 1
    print(f"wrote schemas for {n} CRDs to {out}")


if __name__ == "__main__":
    main()
