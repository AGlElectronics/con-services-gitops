# Changelog

All notable changes to the Con Services GitOps template are documented in
this file. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and the repository uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

First release of the template (1.0.0).

### Added

**Installation with Argo CD**

- One settings file, `cluster.yaml`: domain, Git repository, Let's Encrypt,
  S3 service, modules, network and sizing. It is the only file an operator
  edits. Rendering stops with a list of every value that is still
  `change-me`, and `values.schema.json` rejects unknown or misspelt keys.
- App of apps: the root chart `charts/root` renders every Argo CD
  Application from `cluster.yaml`, plus the root Application itself,
  named `conservices-stack` (setting `rootApplication.name`).
- Sync waves: cluster-wide objects first (waves -8 to -2), then
  namespaces, Keycloak and PostgreSQL (waves 0 to 4), and Den and every
  module together in the last wave (5), so a failing app never blocks Den,
  the other modules or a fix you push for it. Retries use the latest
  commit.
- `bootstrap/install-root.sh` and `install-root.ps1` (Windows PowerShell
  5.1 and PowerShell 7) create the root Application once. They check the
  cluster prerequisites first (cert-manager, trust-manager, External
  Secrets Operator, CloudNativePG with the Barman Cloud plugin, the OpenBao
  CA), warn loudly when Argo CD's Application health check is missing,
  and print the next steps. `--dry-run` / `-DryRun` prints the
  Application; `--skip-preflight` / `-SkipPreflight` skips the checks.
- Reference Argo CD values in `bootstrap/argocd/values.yaml`: the
  Application health check the sync waves need, plus optional HA settings.
  Argo CD itself, cert-manager, trust-manager, External Secrets Operator,
  OpenBao and CloudNativePG are cluster prerequisites the template uses but
  does not install.

**Den and the modules**

- Argo CD Applications for Den and every enabled module: the chart from
  `AGlElectronics/con-services`, values computed from `cluster.yaml`, and
  `charts/module-extras` with the ExternalSecrets for database URLs, S3
  keys, client secrets and service tokens.
- Modules are opt-in: `cluster.yaml` lists all eight under *Pick the
  modules to run*, each with `enabled: false`. With none enabled, only Den
  runs.
- Every module waits for Den (`den.mode: required`, not configurable) until
  it is paired; Den lists the enabled modules as unpaired on its Modules
  page (`preregisterModules`). Nothing pairs automatically: an admin creates
  the pairing URL in Den (**Modules → Pair**) and pastes it into the module's
  *Den connection* page.
- Each web app's sign-in settings (issuer and client) are set from
  `cluster.yaml`, including Rally's public submission site.
- Per-app versions: `den.version` and `modules.<name>.version`
  (`MAJOR.MINOR.PATCH-BUILD`, default `1.0.0-1`, never `latest`) pin both
  the images and the chart tag `<app>/v<MAJOR.MINOR.PATCH>`;
  `chartRevision` overrides the chart's Git revision. Den leads: rendering
  stops when an enabled module's MAJOR differs from Den's.
- Configurable host names: `den.host`, `modules.<name>.host`,
  `modules.rally.submit.host`, `keycloak.host` and `keycloak.adminHost`.
  Each must be a single, unique DNS label, so the wildcard certificate
  covers it.

**Secrets with OpenBao and External Secrets**

- Con Services keeps its secrets in its own OpenBao KV version 2 mount,
  `conservices/` (`openbao.kvPath`), with `modules/` for Den and the
  modules and `infra/` for PostgreSQL, Keycloak, Cloudflare and the
  registry login.
- The `openbao-setup` Application (wave -5) is the only one without
  automatic sync: Argo CD waits until you have reviewed its diff and
  pressed **Sync**. Its Job enables the KV engine and writes External
  Secrets' role. Set `openbao.setup.enabled: false` to leave OpenBao's
  configuration entirely to its administrator.
- `bootstrap/scripts/openbao-configure.sh` and `.ps1`: the OpenBao
  administrator's one-time step (Kubernetes auth, External Secrets' policy,
  the setup Job's policy and role).
- `bootstrap/scripts/openbao-seed.sh` and `.ps1`: optional helper that asks
  only for the provider credentials the enabled modules and options need
  (S3, SMTP, Cloudflare, registry). It checks every value before storing
  it and checks values already stored, lists missing entries with the
  Applications that wait for them (`--no-prompt`), replaces wrong ones
  (`--overwrite`, `--reenter`), and warns when two S3 entries share an
  access key.
- External Secrets generates every random secret (database passwords, Den
  operator token, service tokens, Desk key, Keycloak client secrets and
  bootstrap admin password) through PushSecrets and never replaces an
  existing value. The `ClusterSecretStore` `openbao` connects it to the
  cluster's OpenBao (`openbao.*`, `externalSecrets.*`).
- Every enabled module gets its own `DEN_LINK_ENCRYPTION_KEY` (the key
  that encrypts the Den credential the module stores), generated in
  OpenBao at `conservices/modules/<module>/den-link` (property `key`, 43
  letters and digits = 32 bytes as unpadded base64) and wired into the
  module's `<module>-secrets`. A module built on the shared `denlink`
  refuses to start without it.

**Platform**

- Keycloak Operator and Keycloak 26.8.2 (`charts/keycloak`) with 2
  instances, the database over `verify-full` TLS, HTTPS only, the public
  sign-in route limited to `/realms/` and `/resources/`, the admin console
  on the internal Gateway, the Con Services login theme, and production
  realm imports (`conservices` and the attendee realm) without test users,
  localhost URIs or development secrets.
- PostgreSQL 16.15 cluster `conservices-pg` (`charts/postgres`) on the
  cluster's CloudNativePG: 3 instances on different nodes, quorum
  synchronous replication, TLS-only access with one login per database,
  databases for exactly the enabled modules, continuous WAL archiving and
  daily base backups (30 days) to S3 through the Barman Cloud plugin.
- Gateways `public` (internet-facing, HTTP to HTTPS redirect) and
  `internal` (admin UIs) in `conservices-gateway`. `cluster.yaml`
  recommends pinning both Gateway IPs (`gateway.*.loadBalancerIP`), so the
  router's port forward always reaches the public Gateway.
- Let's Encrypt ClusterIssuers (staging and production) with DNS-01
  (Cloudflare, or your own solvers) and a wildcard certificate for the
  domain; the Con Services internal CA on the cluster's cert-manager and
  trust-manager.
- `profile: small` for clusters with 1 or 2 nodes: one PostgreSQL and one
  Keycloak instance, no PodDisruptionBudgets and no rules that need
  separate nodes. It is not highly available.
- CPU and memory requests and limits on every container, set in
  `cluster.yaml`.
- Applications that hold data (`platform-namespaces`, `postgres`) have no
  deletion finalizer and databases use `databaseReclaimPolicy: retain`, so
  deleting an Application or disabling a module never deletes data.
- `examples/cluster.example-filled.yaml`, a complete example with
  `example.org`.

**CI**

- `.github/workflows/validate.yml`: shell checks, PowerShell parse check,
  `helm lint`, a check that the blank `cluster.yaml` is rejected, a full
  render of every Application, checks for requests, limits, pinned image
  tags and modules waiting for Den, strict validation against the
  Kubernetes and prerequisite CRD schemas, a check that every OpenBao path
  is part of the seed plan, and a check that no installation-specific data
  is committed.
- Test renders for Den only, without the OpenBao setup Job, the small
  profile and custom host names, and cases the root chart must reject (a
  module MAJOR that differs from Den's, invalid or duplicate host names).

### Security

- Narrow OpenBao policies: the setup Job logs in through the role
  `conservices-setup`, which can neither read secrets nor grant itself more
  rights. External Secrets may read Con Services' entries but write only
  `conservices/modules/`, `conservices/infra/postgres/` and
  `conservices/infra/keycloak/`; the Cloudflare token and the registry
  login are read-only for it.
- Default-deny NetworkPolicies and Pod Security labels in every Con
  Services namespace; PostgreSQL reaches S3 only by host name (Cilium
  `toFQDNs`).
- The bootstrap scripts pass tokens and secret values on standard input,
  never on a command line, never print a value (hidden answers show only
  their length and first and last four characters), and never store the
  OpenBao administrator's token in the cluster.
