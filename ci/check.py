#!/usr/bin/env python3
"""Policy checks on the output of ci/render.py.

  - every container (and init container) in any pod template, also inside
    custom resources, has CPU and memory requests and limits;
  - CloudNativePG Clusters, Keycloak instances and the Barman Cloud sidecar
    have requests and limits too;
  - every image has a pinned tag or digest, never "latest";
  - prints a sizing table (replicas x requests and limits, PVC sizes).

  python3 ci/check.py build/rendered [--sizing]
"""

import pathlib
import sys

import yaml

CPU_UNITS = {"m": 0.001}
MEM_UNITS = {"Ki": 2**10, "Mi": 2**20, "Gi": 2**30, "Ti": 2**40, "K": 1e3, "M": 1e6, "G": 1e9}

errors = []
rows = []


def cpu(v):
    v = str(v)
    return float(v[:-1]) / 1000 if v.endswith("m") else float(v)


def mem(v):
    v = str(v)
    for u, f in MEM_UNITS.items():
        if v.endswith(u):
            return float(v[: -len(u)]) * f
    return float(v)


def check_resources(res, where):
    res = res or {}
    missing = [f"{k}.{r}" for k in ("requests", "limits") for r in ("cpu", "memory")
               if not (res.get(k) or {}).get(r)]
    if missing:
        errors.append(f"{where}: missing resources {', '.join(missing)}")
        return None
    return res


def check_image(image, where):
    if not image:
        return
    name = image.split("@")[0]
    tag = name.rsplit(":", 1)[1] if ":" in name.rsplit("/", 1)[-1] else None
    if "@sha256:" in image:
        return
    if tag is None or tag == "latest":
        errors.append(f"{where}: image {image!r} has no pinned tag")


def replicas_of(obj):
    kind = obj.get("kind")
    spec = obj.get("spec") or {}
    if kind in ("Deployment", "StatefulSet", "ReplicaSet"):
        return spec.get("replicas", 1)
    if kind == "DaemonSet":
        return "per node"
    if kind in ("Job", "CronJob"):
        return "job"
    if kind == "AutoscalingRunnerSet":
        return f"0-{spec.get('maxRunners', '?')}"
    return 1


def walk(node, obj, where, app):
    if isinstance(node, dict):
        for key in ("containers", "initContainers"):
            items = node.get(key)
            if isinstance(items, list) and items and all(isinstance(c, dict) for c in items):
                if not any("image" in c for c in items):
                    continue
                for c in items:
                    w = f"{where} {key[:-1]} {c.get('name')}"
                    check_image(c.get("image"), w)
                    res = check_resources(c.get("resources"), w)
                    if res:
                        rows.append((app, f"{obj['kind']}/{obj['metadata'].get('name')}",
                                     c.get("name") + (" (init)" if key == "initContainers" else ""),
                                     replicas_of(obj), res))
        for v in node.values():
            walk(v, obj, where, app)
    elif isinstance(node, list):
        for v in node:
            walk(v, obj, where, app)


def main():
    out = pathlib.Path(sys.argv[1])
    sizing = "--sizing" in sys.argv
    pvcs = []
    for f in sorted(out.glob("*--*.yaml")):
        app = f.name.split("--")[0]
        for obj in yaml.safe_load_all(f.read_text(encoding="utf-8")):
            if not obj or "kind" not in obj:
                continue
            kind = obj["kind"]
            name = obj.get("metadata", {}).get("name")
            where = f"{app}: {kind}/{name}"
            if kind == "CustomResourceDefinition":
                continue
            hook = (obj.get("metadata", {}).get("annotations") or {}).get("helm.sh/hook", "")
            if hook.startswith("test"):
                continue  # Argo CD never runs Helm test hooks
            spec = obj.get("spec") or {}
            if kind == "Cluster" and obj["apiVersion"].startswith("postgresql.cnpg.io"):
                res = check_resources(spec.get("resources"), where)
                if res:
                    rows.append((app, f"{kind}/{name}", "postgres", spec.get("instances"), res))
                for key in ("storage", "walStorage"):
                    if key in spec:
                        pvcs.append((app, f"{kind}/{name} {key}", spec.get("instances"),
                                     spec[key].get("size"), spec[key].get("storageClass", "(default)")))
            if kind == "Keycloak":
                res = check_resources(spec.get("resources"), where)
                if res:
                    rows.append((app, f"{kind}/{name}", "keycloak", spec.get("instances"), res))
            if kind == "ObjectStore":
                res = check_resources((spec.get("instanceSidecarConfiguration") or {}).get("resources"), where + " sidecar")
                if res:
                    rows.append((app, f"{kind}/{name}", "barman sidecar", "per PostgreSQL pod", res))
            if kind == "PersistentVolumeClaim":
                pvcs.append((app, f"{kind}/{name}", 1, spec.get("resources", {}).get("requests", {}).get("storage"),
                             spec.get("storageClassName", "(default)")))
            if kind == "StatefulSet":
                for t in spec.get("volumeClaimTemplates") or []:
                    tspec = t.get("spec", {})
                    pvcs.append((app, f"{kind}/{name} {t['metadata']['name']}", spec.get("replicas", 1),
                                 tspec.get("resources", {}).get("requests", {}).get("storage"),
                                 tspec.get("storageClassName", "(default)")))
            walk(obj, obj, where, app)

    pg = [n for _, o, c, n, _ in rows if o.startswith("Cluster/") and c == "postgres"]
    rows[:] = [(a, o, c, (pg[0] if c == "barman sidecar" and pg else n), r) for a, o, c, n, r in rows]

    if sizing:
        print(f"{'app':20} {'object':45} {'container':24} {'replicas':>9}  req cpu  req mem  lim cpu  lim mem")
        for app, o, c, n, r in rows:
            print(f"{app:20} {o:45} {c:24} {str(n):>9}  {r['requests']['cpu']:>7}  {r['requests']['memory']:>7}"
                  f"  {r['limits']['cpu']:>7}  {r['limits']['memory']:>7}")
        tot = [0.0, 0.0, 0.0, 0.0]
        for _, _, c, n, r in rows:
            if isinstance(n, int) and not c.endswith("(init)"):
                tot[0] += n * cpu(r["requests"]["cpu"])
                tot[1] += n * mem(r["requests"]["memory"])
                tot[2] += n * cpu(r["limits"]["cpu"])
                tot[3] += n * mem(r["limits"]["memory"])
        print(f"\nTotal of always-running containers (fixed replica counts, init containers and jobs excluded): requests {tot[0]:.2f} CPU, "
              f"{tot[1] / 2**30:.2f} GiB; limits {tot[2]:.2f} CPU, {tot[3] / 2**30:.2f} GiB")
        print(f"\n{'app':20} {'volume':55} {'count':>5}  size     class")
        for app, o, n, size, cls in pvcs:
            print(f"{app:20} {o:55} {str(n):>5}  {str(size):8} {cls}")

    if errors:
        print("\n".join(sorted(set(errors))), file=sys.stderr)
        print(f"\n{len(set(errors))} problem(s)", file=sys.stderr)
        sys.exit(1)
    print(f"check: {len(rows)} containers with requests and limits, all images pinned")


if __name__ == "__main__":
    main()
