# Changelog

All notable changes to the Con Services GitOps template are documented in
this file. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and the repository uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

First version of the template.

### Changed

- **BREAKING:** modules are now opt-in. Every `modules.<name>.enabled`
  defaults to `false`, and only Den is deployed until you enable modules.
  What to do: in `cluster.yaml`, under *Pick the modules to run*, set
  `enabled: true` for every module you want to keep. A module you leave at
  `false` has its Application deleted on the next sync; its database and
  bucket are kept.
- `cluster.yaml` lists all eight modules in a visible block (*Pick the
  modules to run*) instead of a commented-out example. Zero enabled modules
  is a valid installation.
- `charts.targetRevision` defaults to `v1.1.0`: the Den and module charts
  of that release are needed for the two settings below.

### Added

- Every module Application sets `den.mode: required`: until a module is
  paired with Den, it shows *Waiting for Den* and its API answers
  `503 den_pairing_required`. There is no standalone option; the root chart
  stops when `modules.<name>.values.den.mode` tries to change it.
- Den's Application sets `preregisterModules` from the enabled modules
  (slug, display name and `https://<host>.<domain>`; Rally is `events`), so
  Den lists them as unpaired on its Modules page and an admin only clicks
  **Pair**.
- CI: `ci/check.py` asserts that every module Application has
  `den.mode: required` (and `DEN_MODE=required` in its rendered ConfigMap)
  and that Den's `preregisterModules` lists exactly the enabled modules. The
  workflow also renders and checks an installation with Den only
  (`ci/no-modules.yaml`); `ci/render.py` accepts several `--values` files.
- `examples/cluster.example-filled.yaml` enables Stash, HR, Rally, Wiki and
  Tasks.

- One settings file, `cluster.yaml`: domain, Git repository, Let's Encrypt,
  S3 service, modules, network and sizing. It is the only file an operator
  edits. Rendering stops with a list of every value that is still
  `change-me`, and `values.schema.json` rejects unknown or misspelt keys.
- Root Helm chart `charts/root` that renders every Argo CD Application from
  `cluster.yaml`, ordered by sync waves, plus the root Application itself.
  `bootstrap/install-root.sh` creates the root Application once.
- Argo CD 3.6.1 (chart `argo-cd` 10.14.0) in HA mode with Redis HA, served
  on the internal Gateway with a certificate from the internal CA, and
  managing itself after the first install (`argocd.selfManage`).
- cert-manager v1.21.3 and trust-manager v0.26.0, 2 replicas each with
  PodDisruptionBudgets, and the Con Services internal CA
  (`ClusterIssuer/conservices-internal-ca`, `Bundle/conservices-internal-ca`).
- Let's Encrypt ClusterIssuers `letsencrypt-staging` and `letsencrypt-prod`
  with DNS-01 (Cloudflare, or your own cert-manager solvers in
  `acme.dns01.solvers`), and a wildcard certificate for the domain.
- Gateways `public` (internet-facing, HTTP to HTTPS redirect) and
  `internal` (admin UIs: Argo CD, OpenBao, Keycloak admin console, and
  optionally Longhorn and Hubble) in the namespace `conservices-gateway`.
- Optional Cilium LB IPAM pool and L2 announcement policy
  (`loadBalancer.ciliumL2`), optional CoreDNS rewrite so pods reach
  Keycloak's public address inside the cluster (`oidcHairpin`), and an
  optional `longhorn-single` StorageClass (`storage.longhornSingle`).
- OpenBao 2.7.2 (chart 0.30.7) with Raft storage, 3 replicas and TLS from
  the internal CA; External Secrets Operator 2.14.0 with the
  `ClusterSecretStore` `openbao`.
- Scripts to initialise, unseal and fill OpenBao:
  `bootstrap/scripts/openbao-init.sh`, `openbao-unseal.sh` and
  `openbao-seed.sh`. The seed script reads `cluster.yaml`, creates only the
  entries the enabled modules and options need, generates the random
  values, asks for the provider credentials, never prints a value, and
  rotates only safe entries with `--rotate`.
- Platform namespaces `cnpg-system`, `conservices-data` and
  `conservices-identity` with default-deny NetworkPolicies and Pod Security
  labels.
- CloudNativePG operator 1.30.1 (chart `cloudnative-pg` 0.29.1, 2 replicas)
  and the Barman Cloud plugin v0.15.1 (chart `plugin-barman-cloud` 0.8.1).
- PostgreSQL 16.15 cluster `conservices-pg` (`charts/postgres`): 3
  instances on different nodes, quorum synchronous replication, TLS-only
  `pg_hba` with one login per database, roles and databases for exactly
  the enabled modules, passwords from OpenBao, continuous WAL archiving and
  daily base backups (30 days) to a managed S3 service, egress to S3 by
  host name (Cilium `toFQDNs`).
- Keycloak Operator 26.8.2 and Keycloak 26.8.2 with 2 instances
  (`charts/keycloak`): database over `verify-full` TLS, HTTPS only, public
  sign-in route limited to `/realms/` and `/resources/`, admin console on
  the internal Gateway, the Con Services login theme, NetworkPolicies, and
  production realm imports without test users, localhost URIs or dev
  secrets (generated by `bootstrap/scripts/keycloak-realm.py`).
- Argo CD Applications for Den (sync wave 5) and every enabled module
  (wave 10): the chart from the main repository at a pinned tag, values
  computed from `cluster.yaml`, and `charts/module-extras` with the
  ExternalSecrets for `DATABASE_URL`, S3 keys, client secrets and service
  tokens. The `ghcr-pull` image pull secret is optional
  (`images.pullSecret.enabled`).
- Optional self-hosted GitHub Actions runners (`arc.enabled`): Actions
  Runner Controller 0.15.1 with rootless BuildKit and a test database as
  sidecars, scale to zero, egress on port 443 only.
- CPU and memory requests and limits on every container, set in
  `cluster.yaml`; the defaults total about 4.2 CPU and 11 GiB of requests.
- Applications that hold data (`platform-namespaces`, `postgres`) have no
  deletion finalizer, and databases use `databaseReclaimPolicy: retain`, so
  deleting an Application or disabling a module never deletes data.
- `bootstrap/example-k3s/`: one tested way to build a three-node k3s
  cluster with Cilium and Longhorn for the template.
- `examples/cluster.example-filled.yaml`, a complete example with
  `example.org`.
- CI workflow `.github/workflows/validate.yml`: shell checks, `helm lint`,
  a check that the blank `cluster.yaml` is rejected, a full render of
  every Application, a check for requests, limits and pinned image tags,
  strict validation against the Kubernetes 1.37 and CRD schemas, and a
  check that no installation-specific data (real IP or e-mail addresses)
  is committed.
- The root chart sets each web app's sign-in settings (`frontend.config`,
  served as `/config.json`): issuer `https://auth.<domain>/realms/conservices`
  and client `<module>-spa` (`events-spa` for Rally), and for Rally's
  submission site `submit.config` with the attendee realm and client
  `rally-submit`. The published frontend images are used unchanged; no new
  `cluster.yaml` keys. Needs module charts 0.2.2 (Den 0.1.2) or newer; older
  charts ignore the values.
