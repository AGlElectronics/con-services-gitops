# Bootstrap

Everything in this folder is used **by hand**: once to hand the cluster to
Argo CD, and then for the few steps only a person can do (preparing and
filling OpenBao). After that, Argo CD manages Con Services from
`cluster.yaml` and `charts/root`.

| File | What it is | Guide |
| --- | --- | --- |
| `argocd/values.yaml` | Argo CD Helm values for the first install (`helm install`); with `argocd.selfManage: true` Argo CD then manages itself with the same file | [Argo CD](https://aglelectronics.github.io/con-services/deploy/argocd/) |
| `install-root.sh` | Checks the cluster prerequisites, renders the root Application from `cluster.yaml` and applies it (`--dry-run` prints it instead, `--skip-preflight` skips the checks) | [Argo CD](https://aglelectronics.github.io/con-services/deploy/argocd/) |
| `scripts/openbao-configure.sh` | Prepares the cluster's OpenBao for Con Services: KV v2 engine, Kubernetes auth, read policy and the role External Secrets Operator logs in with | [Secrets with OpenBao](https://aglelectronics.github.io/con-services/deploy/secrets-openbao/) |
| `scripts/openbao-seed.sh` | Write every secret the enabled modules and options need: generates the random ones, asks for the provider credentials (S3, SMTP, Cloudflare, GitHub) | [Secrets with OpenBao](https://aglelectronics.github.io/con-services/deploy/secrets-openbao/#3-seed-the-secrets) |
| `scripts/lib/openbao.sh` | Helpers shared by the scripts | |
| `scripts/keycloak-realm.py` | For maintainers: regenerates the realm templates of `charts/keycloak` from the development realms of the main repository | [Identity](https://aglelectronics.github.io/con-services/deploy/identity/#the-realms) |
| `example-k3s/` | One tested way to build a cluster for the template: k3s configs for three nodes, Cilium and Longhorn values, `node-prep.sh`. Not used by Argo CD; skip it if you already have a cluster | [Example: a k3s cluster](https://aglelectronics.github.io/con-services/deploy/cluster/) |

OpenBao, External Secrets Operator, cert-manager, trust-manager and
CloudNativePG are cluster prerequisites: installing, initialising and
unsealing them is the cluster operator's job, not this template's.

Order: a cluster that meets the
[prerequisites](https://aglelectronics.github.io/con-services/deploy/prerequisites/),
`helm install` Argo CD with `argocd/values.yaml`, `openbao-configure.sh`,
`openbao-seed.sh`, then `install-root.sh`.
