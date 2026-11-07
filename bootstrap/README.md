# Bootstrap

Everything in this folder is used **by hand**: once to hand the cluster to
Argo CD, and then for the few steps only a person can do (OpenBao). After
that, Argo CD manages the cluster from `cluster.yaml` and `charts/root`.

| File | What it is | Guide |
| --- | --- | --- |
| `argocd/values.yaml` | Argo CD Helm values for the first install (`helm install`); with `argocd.selfManage: true` Argo CD then manages itself with the same file | [Argo CD](https://aglelectronics.github.io/con-services/deploy/argocd/) |
| `install-root.sh` | Renders the root Application from `cluster.yaml` and applies it (`--dry-run` prints it instead) | [Argo CD](https://aglelectronics.github.io/con-services/deploy/argocd/) |
| `scripts/openbao-init.sh` | Initialise, unseal and configure OpenBao; writes `openbao-init.json` (keep it offline, never commit it) | [Secrets with OpenBao](https://aglelectronics.github.io/con-services/deploy/secrets-openbao/) |
| `scripts/openbao-unseal.sh` | Unseal OpenBao after pod restarts | [Secrets with OpenBao](https://aglelectronics.github.io/con-services/deploy/secrets-openbao/) |
| `scripts/openbao-seed.sh` | Write every secret the enabled modules and options need: generates the random ones, asks for the provider credentials (S3, SMTP, Cloudflare, GitHub) | [Secrets with OpenBao](https://aglelectronics.github.io/con-services/deploy/secrets-openbao/#3-seed-the-secrets) |
| `scripts/lib/openbao.sh` | Helpers shared by the OpenBao scripts | |
| `scripts/keycloak-realm.py` | For maintainers: regenerates the realm templates of `charts/keycloak` from the development realms of the main repository | [Identity](https://aglelectronics.github.io/con-services/deploy/identity/#the-realms) |
| `example-k3s/` | One tested way to build a cluster for the template: k3s configs for three nodes, Cilium and Longhorn values, `node-prep.sh`. Not used by Argo CD; skip it if you already have a cluster | [Example: a k3s cluster](https://aglelectronics.github.io/con-services/deploy/cluster/) |

Order: a cluster that meets the
[prerequisites](https://aglelectronics.github.io/con-services/deploy/prerequisites/),
`helm install` Argo CD with `argocd/values.yaml`, `install-root.sh`, then
the OpenBao scripts when the `openbao` Application waits for them.
