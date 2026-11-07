# Con Services GitOps template

A blank production template for running Con Services on Kubernetes with
[Argo CD](https://argo-cd.readthedocs.io/). You make your own private copy,
fill in **one settings file, `cluster.yaml`**, and Argo CD installs and
keeps running everything else: certificates, secrets, the database,
sign-in, Den and the modules.

Full guide: <https://aglelectronics.github.io/con-services/deploy/>

## Quick start

You need a Kubernetes cluster that meets the
[prerequisites](https://aglelectronics.github.io/con-services/deploy/prerequisites/)
(3+ nodes, Cilium with the Gateway API, a default StorageClass), an S3
service, a domain, and `kubectl`, `helm` and `git` on your computer.

1. **Copy the template.** On GitHub, **Use this template → Create a new
   repository**, make it **private**, and clone it.
2. **Fill in `cluster.yaml`.** Replace every `change-me`; until the file is
   complete, rendering stops and lists what is missing:

    ```sh
    grep -n change-me cluster.yaml          # prints nothing when done
    helm template root charts/root -f cluster.yaml > /dev/null && echo OK
    ```

3. **Install Argo CD** with the template's values (pinned chart version):

    ```sh
    helm repo add argo https://argoproj.github.io/argo-helm
    helm install argocd argo/argo-cd --version 10.14.0 \
      -n argocd --create-namespace -f bootstrap/argocd/values.yaml
    ```

4. **Commit, push, and create the root Application:**

    ```sh
    git add cluster.yaml && git commit -m "Configure cluster" && git push
    bash bootstrap/install-root.sh
    ```

5. **Do the steps only a person can do:** initialise and unseal OpenBao and
   store the secrets (`bootstrap/scripts/openbao-init.sh`, then
   `openbao-seed.sh`), create the DNS records and the S3 buckets. Argo CD
   waits for them and continues by itself.

Each step is explained, with expected output and troubleshooting, in the
[installation guide](https://aglelectronics.github.io/con-services/deploy/argocd/).

## What you get

| Layer | Components | High availability (default) |
| --- | --- | --- |
| Delivery | Argo CD, managing itself after the first install | Redis HA, 2+ replicas of server and repo-server |
| Certificates | cert-manager (Let's Encrypt, internal CA), trust-manager | 2 replicas, webhook PDB |
| Secrets | OpenBao (Raft), External Secrets Operator | 3 OpenBao voters, ESO 2 replicas |
| Network | Gateway API (public and internal Gateway), Cilium network policies; optional Cilium LB IPAM | default-deny in every Con Services namespace |
| Data | CloudNativePG with backups to S3 (Barman Cloud plugin); files at a **managed S3 service** | 3 PostgreSQL instances, quorum synchronous replication |
| Identity | Keycloak via the Keycloak Operator | 2 instances, shared sessions |
| Apps | Den and the modules, from the Helm charts of `AGlElectronics/con-services` | web apps 2+ replicas with PDBs |
| CI (optional) | Actions Runner Controller with rootless BuildKit | scale to zero |

Every container has CPU and memory requests and limits. Defaults total
about 4.2 CPU and 11 GiB of requests; see
[Sizing](https://aglelectronics.github.io/con-services/deploy/sizing/).

## Layout

```text
cluster.yaml                  The only file you edit
charts/
  root/                       Renders every Argo CD Application from cluster.yaml
    values.yaml               Defaults of every setting (override in cluster.yaml)
    values.schema.json        Rejects unknown or misspelt keys
  module-extras/              ExternalSecrets and access configs of Den and the modules
  postgres/, keycloak/, gateway/, letsencrypt/, ...
                              Small charts for the objects specific to an installation
values/                       Fixed Helm values of the upstream charts (cert-manager, OpenBao, ...)
components/                   Fixed Kustomize folders (internal CA, namespaces, ...)
bootstrap/                    Used by hand: install-root.sh, Argo CD values,
                              OpenBao scripts, example-k3s/ (an example cluster)
examples/                     cluster.example-filled.yaml, a complete example
ci/                           Render and validation scripts used by CI
```

The root chart renders one Application per component, ordered by sync
waves. Den and the module charts are read from
[`AGlElectronics/con-services`](https://github.com/AGlElectronics/con-services)
at the tag `charts.targetRevision`; their values are computed from
`cluster.yaml`.

## Conventions

- **One settings file.** Everything specific to an installation is in
  `cluster.yaml`. If you need to change a file elsewhere, that is a gap in
  the template: please open an issue.
- **Every version is pinned:** Helm chart versions, image tags
  (`MAJOR.MINOR.PATCH-BUILD` for Con Services images, never `latest`), and
  the tag of the main repository. The one exception is your copy itself:
  Argo CD follows its branch (`git.targetRevision`, default `main`),
  because a push *is* the deployment.
- **No secret in Git.** Secrets live in OpenBao; External Secrets Operator
  creates the Kubernetes Secrets (`ExternalSecret` objects are in Git,
  their values are not).
- **Data is never deleted by Argo CD.** The Applications holding the
  namespaces and the database have no deletion finalizer, and databases
  use `databaseReclaimPolicy: retain`.
- **Validate before you push:**

    ```sh
    helm template root charts/root -f cluster.yaml > /dev/null && echo OK
    ```

    CI (`.github/workflows/validate.yml`) additionally renders every
    Application, checks resources and image tags, and validates the output
    against the Kubernetes schemas.

## License

Same as Con Services.
