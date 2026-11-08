# Bootstrap

Everything in this folder is used **by hand**: once to let OpenBao trust
the template and hand the cluster to Argo CD, and then optionally to enter
your provider credentials. After that, Argo CD manages Con Services from
`cluster.yaml` and `charts/root`; External Secrets creates the random
secrets.

| File | What it is | Guide |
| --- | --- | --- |
| `argocd/values.yaml` | Reference Argo CD Helm values: the Application health check the sync waves need (required in your Argo CD), plus HA settings and resource limits you may reuse. The template does not install or manage Argo CD | [Prerequisites: Argo CD](https://aglelectronics.github.io/con-services/deploy/prerequisites/#9-argo-cd) |
| `install-root.sh` | Checks the cluster prerequisites, renders the root Application from `cluster.yaml` and applies it (`--dry-run` prints it instead, `--skip-preflight` skips the checks) | [Argo CD](https://aglelectronics.github.io/con-services/deploy/argocd/) |
| `scripts/openbao-configure.sh` | The OpenBao administrator's one-time step: Kubernetes auth, External Secrets' policy, and the narrow policy and role of the setup Job (with `openbao.setup.enabled: false`: the KV engine and External Secrets' role instead) | [Secrets with OpenBao](https://aglelectronics.github.io/con-services/deploy/secrets-openbao/#2-the-administrators-one-time-step) |
| `scripts/openbao-seed.sh` | Optional helper: asks for the provider credentials the enabled modules and options need (S3, SMTP, Cloudflare, registry); the OpenBao web UI works as well | [Secrets with OpenBao](https://aglelectronics.github.io/con-services/deploy/secrets-openbao/#4-enter-your-provider-credentials) |
| `scripts/lib/openbao.sh` | Helpers shared by the scripts | |
| `scripts/keycloak-realm.py` | For maintainers: regenerates the realm templates of `charts/keycloak` from the development realms of the main repository | [Identity](https://aglelectronics.github.io/con-services/deploy/identity/#the-realms) |

Argo CD, OpenBao, External Secrets Operator, cert-manager, trust-manager
and CloudNativePG are cluster prerequisites: installing, upgrading, initialising and unsealing
them is the cluster operator's job, not this template's.

Order: a cluster that meets the
[prerequisites](https://aglelectronics.github.io/con-services/deploy/prerequisites/),
including Argo CD with the Application health check, then
`openbao-configure.sh` and `install-root.sh`; sync `openbao-setup` in Argo
CD, then enter your provider credentials.
