{{/* Module list in install order, and their fixed properties. */}}
{{- define "root.moduleNames" -}}
stash hr rally finance learn wiki desk tasks
{{- end }}

{{/*
Per module: PostgreSQL role, Den's module slug and display name, whether it
stores files in S3, has a migrate image, reads an access configuration.
The host label is a setting (modules.<name>.host).
*/}}
{{- define "root.moduleMeta" -}}
stash:   { role: stash,   label: stash,   slug: stash,   title: Stash,   s3: true,  migrate: false, access: true }
hr:      { role: hr,      label: hr,      slug: hr,      title: HR,      s3: false, migrate: true,  access: false }
rally:   { role: events,  label: events,  slug: events,  title: Rally,   s3: true,  migrate: true,  access: true }
finance: { role: finance, label: finance, slug: finance, title: Finance, s3: false, migrate: true,  access: false }
learn:   { role: learn,   label: learn,   slug: learn,   title: Learn,   s3: true,  migrate: true,  access: true }
wiki:    { role: wiki,    label: wiki,    slug: wiki,    title: Wiki,    s3: true,  migrate: true,  access: true }
desk:    { role: desk,    label: desk,    slug: desk,    title: Desk,    s3: false, migrate: true,  access: true }
tasks:   { role: tasks,   label: tasks,   slug: tasks,   title: Tasks,   s3: true,  migrate: true,  access: true }
{{- end }}

{{/*
Names of the Applications this chart renders besides the root Application
itself (rootApplication.name must differ from all of them).
*/}}
{{- define "root.childNames" -}}
longhorn-storage pki openbao-setup cluster-secret-store letsencrypt gateway platform-namespaces keycloak-operator postgres keycloak den {{ include "root.moduleNames" . }}
{{- end }}

{{/* Full host name of a host label. Argument: dict root, host. */}}
{{- define "root.fqdn" -}}
{{ .host }}.{{ .root.Values.domain }}
{{- end }}

{{/*
Every host label in use, as JSON: a list of { key, host } in a fixed
order, for the uniqueness check and the Keycloak realms.
*/}}
{{- define "root.hostsInUse" -}}
{{- $v := .Values }}
{{- $out := list (dict "key" "den.host" "host" $v.den.host) (dict "key" "keycloak.host" "host" $v.keycloak.host) (dict "key" "keycloak.adminHost" "host" $v.keycloak.adminHost) }}
{{- range $n := fromJsonArray (include "root.enabledModules" .) }}
{{- $out = append $out (dict "key" (printf "modules.%s.host" $n) "host" (index $v.modules $n).host) }}
{{- if eq $n "rally" }}{{ $out = append $out (dict "key" "modules.rally.submit.host" "host" $v.modules.rally.submit.host) }}{{ end }}
{{- end }}
{{- if $v.adminRoutes.longhorn }}{{ $out = append $out (dict "key" "adminRoutes.longhorn (fixed host longhorn)" "host" "longhorn") }}{{ end }}
{{- if $v.adminRoutes.hubble }}{{ $out = append $out (dict "key" "adminRoutes.hubble (fixed host hubble)" "host" "hubble") }}{{ end }}
{{- toJson $out }}
{{- end }}

{{/* MAJOR.MINOR.PATCH of a version MAJOR.MINOR.PATCH-BUILD. */}}
{{- define "root.semver" -}}
{{- regexReplaceAll "-[0-9]+$" . "" }}
{{- end }}

{{/*
Git revision of an app's chart in charts.repoURL: chartRevision, or the
app's release tag <app>/v<MAJOR.MINOR.PATCH>. Argument: dict app, version,
chartRevision.
*/}}
{{- define "root.chartRevision" -}}
{{- .chartRevision | default (printf "%s/v%s" .app (include "root.semver" .version)) }}
{{- end }}

{{/*
What the profile decides, as JSON. Explicit keys (postgres.instances,
keycloak.instances) win; den/modules values.ha.* win because they are
merged last into the app values.
*/}}
{{- define "root.profile" -}}
{{- $v := .Values }}
{{- $small := eq ($v.profile | default "standard") "small" }}
{{- dict
  "small" $small
  "postgresInstances" ($v.postgres.instances | default (ternary 1 3 $small) | int)
  "keycloakInstances" ($v.keycloak.instances | default (ternary 1 2 $small) | int)
  "appHA" (not $small)
  "strictSpread" (not $small)
  | toJson }}
{{- end }}

{{/* Names of the enabled modules as a JSON list; use with fromJsonArray. */}}
{{- define "root.enabledModules" -}}
{{- $out := list }}
{{- range $n := splitList " " (include "root.moduleNames" .) }}
{{- if (index $.Values.modules $n).enabled }}{{ $out = append $out $n }}{{ end }}
{{- end }}
{{- toJson $out }}
{{- end }}

{{/*
What OpenBao holds for this cluster.yaml, as JSON. Paths are below the KV
version 2 mount openbao.kvPath (default "conservices"): "modules/<app>/..."
for Den and the modules, "infra/..." for shared and platform entries.
"generated" lists the entries External Secrets fills with random values
(path and properties). "manual" lists the entries a person enters
(bootstrap/scripts/openbao-seed.*): path, kind, fields, the Applications
that stay Degraded without it, and what the value is.
*/}}
{{- define "root.seedPlan" -}}
{{- $v := .Values }}
{{- $meta := include "root.moduleMeta" . | fromYaml }}
{{- $enabled := include "root.enabledModules" . | fromJsonArray }}
{{- $prefix := (include "root.s3" . | fromYaml).prefix }}
{{- $roles := list "den" "keycloak" }}
{{- $tokens := list }}
{{- $s3mods := list }}
{{- range $n := $enabled }}
{{- $m := index $meta $n }}
{{- $roles = append $roles $m.role }}
{{- if $m.s3 }}{{ $s3mods = append $s3mods $n }}{{ end }}
{{- if has $n (list "learn" "wiki" "tasks") }}{{ $tokens = append $tokens $n }}{{ end }}
{{- end }}
{{- $buckets := list (printf "%s-conservices-den" $prefix) }}
{{- range $s3mods }}{{ $buckets = append $buckets (printf "%s-conservices-%s" $prefix .) }}{{ end }}
{{- $s3f := list "access_key" "secret_key" }}
{{- $manual := list
  (dict "path" "infra/postgres/backup-s3" "kind" "s3" "fields" $s3f "apps" (list "postgres")
    "what" (printf "read and write on bucket %s-pg-backups only (CloudNativePG backups)" $prefix))
  (dict "path" "modules/den/s3" "kind" "s3" "fields" $s3f "apps" (list "den")
    "what" (printf "read and write on bucket %s-conservices-den only" $prefix))
  (dict "path" "modules/den/files-s3" "kind" "s3" "fields" $s3f "apps" (list "den")
    "what" (printf "read only on %s (Den copies module files into its backups)" (join ", " $buckets)))
  (dict "path" "modules/den/backup-s3" "kind" "s3" "fields" $s3f "apps" (list "den")
    "what" (printf "read and write on bucket %s-den-backups only" $prefix)) }}
{{- range $s3mods }}
{{- $manual = append $manual (dict "path" (printf "modules/%s/s3" .) "kind" "s3" "fields" $s3f "apps" (list .)
    "what" (printf "read and write on bucket %s-conservices-%s only" $prefix .)) }}
{{- end }}
{{- if $v.keycloak.smtp.enabled }}
{{- $manual = append $manual (dict "path" "infra/keycloak/smtp" "kind" "smtp"
    "fields" (list "host" "port" "from" "username" "password") "apps" (list "keycloak")
    "what" "mail server Keycloak sends password-reset and verification mail through") }}
{{- end }}
{{- if eq $v.acme.dns01.provider "cloudflare" }}
{{- $manual = append $manual (dict "path" "infra/cloudflare" "kind" "cloudflare" "fields" (list "api-token")
    "apps" (list "letsencrypt") "what" "Cloudflare API token with Zone:DNS:Edit and Zone:Zone:Read on your zone only") }}
{{- end }}
{{- if $v.images.pullSecret.enabled }}
{{- $manual = append $manual (dict "path" "infra/ghcr" "kind" "ghcr" "fields" (list "username" "token")
    "apps" (prepend $enabled "den") "what" "GitHub user and a classic token with only read:packages, for the ghcr-pull Secrets") }}
{{- end }}
{{- $gen := list (dict "path" "infra/postgres/superuser" "properties" (list "password")) }}
{{- range $roles }}{{ $gen = append $gen (dict "path" (printf "infra/postgres/roles/%s" .) "properties" (list "password")) }}{{ end }}
{{- $gen = append $gen (dict "path" "modules/den/operator-token" "properties" (list "token")) }}
{{- range $tokens }}{{ $gen = append $gen (dict "path" (printf "modules/%s/service-token" .) "properties" (list "token")) }}{{ end }}
{{- if has "desk" $enabled }}{{ $gen = append $gen (dict "path" "modules/desk/secret-key" "properties" (list "key")) }}{{ end }}
{{- /* DEN_LINK_ENCRYPTION_KEY: 43 letters and digits, read as unpadded base64 = 32 bytes. */ -}}
{{- range $enabled }}{{ $gen = append $gen (dict "path" (printf "modules/%s/den-link" .) "properties" (list "key") "generator" "aes-key") }}{{ end }}
{{- $gen = append $gen (dict "path" "infra/keycloak/bootstrap-admin" "properties" (list "password")) }}
{{- $gen = append $gen (dict "path" "infra/keycloak/clients" "properties" (list "den-keycloak" "hr-provisioner" "learn-provisioner")) }}
{{- $s3 := list }}
{{- range $manual }}{{ if eq .kind "s3" }}{{ $s3 = append $s3 .path }}{{ end }}{{ end }}
{{- dict
  "modules" $enabled
  "roles" $roles
  "s3" $s3
  "manual" $manual
  "serviceTokens" $tokens
  "generated" $gen
  "desk" (has "desk" $enabled)
  "backupSameAsData" (include "root.s3" . | fromYaml).backupSameAsData
  "smtp" $v.keycloak.smtp.enabled
  "cloudflare" (eq $v.acme.dns01.provider "cloudflare")
  "ghcr" $v.images.pullSecret.enabled
  "kvPath" $v.openbao.kvPath
  "authMount" $v.openbao.auth.mountPath
  "authRole" $v.openbao.auth.role
  "esoNamespace" $v.externalSecrets.namespace
  "esoServiceAccount" $v.externalSecrets.serviceAccount
  "setup" $v.openbao.setup
  "setupNamespace" (include "root.setupNamespace" .)
  "caBundle" (dict
    "kind" $v.openbao.caBundle.kind
    "name" $v.openbao.caBundle.name
    "namespace" ($v.openbao.caBundle.namespace | default $v.externalSecrets.namespace))
  | toJson }}
{{- end }}

{{/*
Namespace of the openbao-setup Job: where OpenBao's CA bundle is, so the
Job can mount it.
*/}}
{{- define "root.setupNamespace" -}}
{{- .Values.openbao.caBundle.namespace | default .Values.externalSecrets.namespace }}
{{- end }}

{{/* Issuer URL of a Keycloak realm. Argument: root; realm "conservices" unless given as dict root, realm. */}}
{{- define "root.issuer" -}}
{{- $root := .root | default . }}
{{- $realm := .realm | default "conservices" -}}
https://{{ include "root.fqdn" (dict "root" $root "host" $root.Values.keycloak.host) }}/realms/{{ $realm }}
{{- end }}

{{/* Source block for a path in this repository. Argument: dict root, path. */}}
{{- define "root.repoSource" -}}
repoURL: {{ .root.Values.git.repoURL }}
targetRevision: {{ .root.Values.git.targetRevision }}
path: {{ .path }}
{{- end }}

{{/* The same as a list item. */}}
{{- define "root.repoSourceItem" -}}
- repoURL: {{ .root.Values.git.repoURL }}
  targetRevision: {{ .root.Values.git.targetRevision }}
  path: {{ .path }}
{{- end }}

{{/* The "values" ref source: lets upstream charts read value files from this repository. */}}
{{- define "root.valuesRef" -}}
- repoURL: {{ .Values.git.repoURL }}
  targetRevision: {{ .Values.git.targetRevision }}
  ref: values
{{- end }}

{{/*
syncPolicy. Argument: dict manual (bool), options (list), labels (dict).
*/}}
{{- define "root.syncPolicy" -}}
syncPolicy:
  {{- if not .manual }}
  automated:
    prune: true
    selfHeal: true
  {{- end }}
  {{- with .options }}
  syncOptions:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with .labels }}
  managedNamespaceMetadata:
    labels:
      {{- toYaml . | nindent 6 }}
  {{- end }}
  retry:
    limit: 10
    # A retry uses the newest revision, so a fix pushed while an operation
    # is retrying is picked up by the next attempt.
    refresh: true
    backoff:
      duration: 10s
      factor: 2
      maxDuration: 5m
{{- end }}

{{/* StorageClass for PostgreSQL (it replicates itself). Argument: dict root, override. */}}
{{- define "root.selfReplicatingClass" -}}
{{- if .override }}{{ .override }}
{{- else if .root.Values.storage.longhornSingle.enabled }}longhorn-single
{{- else }}{{ .root.Values.storage.className }}
{{- end }}
{{- end }}

{{/* S3 settings with the backup fallbacks resolved, as YAML. */}}
{{- define "root.s3" -}}
{{- $s := .Values.s3 }}
{{- $b := $s.backup }}
endpoint: {{ $s.endpoint | quote }}
region: {{ $s.region | quote }}
pathStyle: {{ $s.pathStyle | toString | quote }}
prefix: {{ $s.bucketPrefix | quote }}
fqdns: {{ toJson $s.fqdns }}
backupEndpoint: {{ $b.endpoint | default $s.endpoint | quote }}
backupRegion: {{ $b.region | default $s.region | quote }}
backupPathStyle: {{ (ternary $s.pathStyle $b.pathStyle (kindIs "invalid" $b.pathStyle)) | toString | quote }}
backupFqdns: {{ toJson (uniq (concat $s.fqdns $b.fqdns)) }}
backupSameAsData: {{ or (empty $b.endpoint) (eq (trimSuffix "/" $b.endpoint) (trimSuffix "/" $s.endpoint)) }}
{{- end }}

{{/* Warning shown when backups go to the same S3 service as the live data. */}}
{{- define "root.backupWarning" -}}
Backups go to the same S3 service as the live data (s3.backup.endpoint is empty or equals s3.endpoint). One provider outage, a lost account or a leaked key then takes the data and its backups together. Set s3.backup in cluster.yaml to another provider or account: https://aglelectronics.github.io/con-services/operations/databases-and-backups/#where-backups-go
{{- end }}

{{/* Common labels of Con Services namespaces. Argument: dict tier, module. */}}
{{- define "root.nsLabels" -}}
app.kubernetes.io/part-of: conservices
conservices.io/tier: {{ .tier }}
conservices.io/module: {{ .module }}
pod-security.kubernetes.io/enforce: restricted
pod-security.kubernetes.io/warn: restricted
{{- end }}
