#!/usr/bin/env python3
"""Case tests of the root chart, run by CI after ci/render.py.

  python3 ci/cases.py failures
      Every ci/fail-*.yaml, laid over examples/cluster.example-filled.yaml,
      must make `helm template` fail, and the error must contain every line
      the file lists as "# expect: ...".

  python3 ci/cases.py small build/rendered-small
      Output of ci/render.py with ci/small-profile.yaml: one PostgreSQL
      instance without PodDisruptionBudgets or required anti-affinity, one
      Keycloak without PodDisruptionBudget, Den and modules with ha off,
      no DoNotSchedule anywhere.

  python3 ci/cases.py hosts build/rendered-hosts
      Output of ci/render.py with ci/custom-hosts.yaml: no default host name
      left anywhere, the custom ones present, the root Application named
      after rootApplication.name.

  python3 ci/cases.py same-s3 build/rendered-same-s3
      Output of ci/render.py with ci/same-s3-backups.yaml: the Den
      Application carries the backup warning, Den's operator gets
      BACKUP_SAME_STORAGE_AS_DATA "true", Den's realm sync is off
      (KEYCLOAK_ADMIN_URL empty, den-keycloak without realm-management
      roles) and the password policy says length(16).

Needs helm on PATH and PyYAML.
"""

import pathlib
import re
import subprocess
import sys

import yaml

REPO = pathlib.Path(__file__).resolve().parent.parent
EXAMPLE = REPO / "examples/cluster.example-filled.yaml"
errors = []


def docs(path):
    return [d for d in yaml.safe_load_all(path.read_text(encoding="utf-8")) if d]


def all_docs(out):
    for f in sorted(out.glob("*.yaml")):
        for d in docs(f):
            yield f.name, d


def apps(out):
    return {d["metadata"]["name"]: d for d in docs(out / "root.yaml") if d.get("kind") == "Application"}


def first_values(app):
    spec = app["spec"]
    return ((spec.get("sources") or [spec.get("source")])[0].get("helm") or {}).get("valuesObject") or {}


def failures():
    cases = sorted((REPO / "ci").glob("fail-*.yaml"))
    if not cases:
        errors.append("no ci/fail-*.yaml found")
    for case in cases:
        expect = [line.split("# expect:", 1)[1].strip()
                  for line in case.read_text(encoding="utf-8").splitlines() if line.startswith("# expect:")]
        res = subprocess.run(["helm", "template", "root", str(REPO / "charts/root"), "-f", str(EXAMPLE), "-f", str(case)],
                             capture_output=True, text=True)
        if res.returncode == 0:
            errors.append(f"{case.name}: rendered without error, expected a failure")
            continue
        for e in expect:
            if e not in res.stderr:
                errors.append(f"{case.name}: error does not contain {e!r}:\n{res.stderr.strip()}")
        print(f"{case.name}: fails as expected")


def small(out):
    for name, d in all_docs(out):
        kind = d.get("kind")
        where = f"{name}: {kind}/{d.get('metadata', {}).get('name')}"
        if kind == "Cluster" and d["apiVersion"].startswith("postgresql.cnpg.io"):
            s = d["spec"]
            if s.get("instances") != 1:
                errors.append(f"{where}: instances {s.get('instances')}, want 1")
            if s.get("enablePDB") is not False:
                errors.append(f"{where}: enablePDB {s.get('enablePDB')}, want false")
            if (s.get("affinity") or {}).get("podAntiAffinityType") != "preferred":
                errors.append(f"{where}: podAntiAffinityType is not preferred")
        if kind == "Keycloak" and d["spec"].get("instances") != 1:
            errors.append(f"{where}: instances {d['spec'].get('instances')}, want 1")
        if kind == "PodDisruptionBudget" and not name.startswith("root"):
            errors.append(f"{where}: PodDisruptionBudget with the small profile")
        if "DoNotSchedule" in yaml.safe_dump(d):
            errors.append(f"{where}: topology spread DoNotSchedule with the small profile")
    for n, app in apps(out).items():
        if (app["metadata"].get("labels") or {}).get("conservices.io/module"):
            ha = first_values(app).get("ha") or {}
            if ha.get("podDisruptionBudget") or ha.get("topologySpread"):
                errors.append(f"{n}: values ha {ha}, want both false")
    print("small profile: checked")


DEFAULT_HOST = re.compile(
    r"\b(den|auth|auth-admin|events|submit|stash|hr|finance|learn|wiki|desk|tasks)\.example\.org\b")
CUSTOM = ["portal.example.org", "login.example.org/realms/conservices", "login-admin.example.org",
          "con.example.org", "cfp.example.org", "inventory.example.org", "people.example.org",
          "ledger.example.org", "courses.example.org", "docs.example.org", "support.example.org",
          "todo.example.org"]


def hosts(out):
    names = set(apps(out))
    if "con-stack" not in names or "conservices-stack" in names:
        errors.append(f"root.yaml: root Application is not named con-stack ({sorted(names)})")
    text = ""
    for f in sorted(out.glob("*.yaml")):
        t = f.read_text(encoding="utf-8")
        text += t
        for n, line in enumerate(t.splitlines(), 1):
            if DEFAULT_HOST.search(line):
                errors.append(f"{f.name}:{n}: default host name left: {line.strip()}")
    for c in CUSTOM:
        if c not in text:
            errors.append(f"custom host {c!r} appears nowhere in the rendered output")
    print("custom hosts: checked")


def same_s3(out):
    den = apps(out).get("den")
    info = {i.get("name"): i.get("value", "") for i in (den or {}).get("spec", {}).get("info") or []}
    if "s3.backup" not in info.get("Warning: backups", ""):
        errors.append(f"root.yaml: Application den has no backup warning in spec.info ({info})")
    configs = {d["metadata"]["name"]: d.get("data") or {} for d in docs(out / "den--0.yaml") if d.get("kind") == "ConfigMap"}
    if configs.get("den-operator-config", {}).get("BACKUP_SAME_STORAGE_AS_DATA") != "true":
        errors.append("den--0.yaml: den-operator-config BACKUP_SAME_STORAGE_AS_DATA is not \"true\"")
    if configs.get("den-config", {}).get("KEYCLOAK_ADMIN_URL", "missing") != "":
        errors.append("den--0.yaml: den-config KEYCLOAK_ADMIN_URL is not empty with denDisplayNameSync false")
    realm = next((d["spec"]["realm"] for d in docs(out / "keycloak--0.yaml")
                  if d.get("kind") == "KeycloakRealmImport" and d["metadata"]["name"] == "conservices"), None)
    if realm is None:
        errors.append("keycloak--0.yaml: no KeycloakRealmImport conservices")
        return
    sa = next((u for u in realm.get("users", []) if u.get("serviceAccountClientId") == "den-keycloak"), {})
    if (sa.get("clientRoles") or {}).get("realm-management") != []:
        errors.append(f"realm conservices: den-keycloak roles {sa.get('clientRoles')}, want none")
    if not str(realm.get("passwordPolicy", "")).startswith("length(16)"):
        errors.append(f"realm conservices: passwordPolicy {realm.get('passwordPolicy')!r}, want length(16) ...")
    if realm.get("bruteForceProtected") is not True:
        errors.append("realm conservices: bruteForceProtected is not true")
    if "roles" in realm:
        errors.append(f"realm conservices: realm roles left: {realm['roles']}")
    print("backups on the same S3, realm settings: checked")


def main():
    if len(sys.argv) < 2 or sys.argv[1] not in ("failures", "small", "hosts", "same-s3"):
        sys.exit(__doc__)
    if sys.argv[1] == "failures":
        failures()
    else:
        {"small": small, "hosts": hosts, "same-s3": same_s3}[sys.argv[1]](pathlib.Path(sys.argv[2]))
    if errors:
        print("\n".join(errors), file=sys.stderr)
        print(f"\n{len(errors)} problem(s)", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
