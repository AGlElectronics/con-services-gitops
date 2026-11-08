{{/* Module list in install order, and their fixed properties. */}}
{{- define "root.moduleNames" -}}
stash hr rally finance learn wiki desk tasks
{{- end }}

{{/*
Per module: host prefix, PostgreSQL role, Den's module slug and display
name, whether it stores files in S3, has a migrate image, reads an access
configuration.
*/}}
{{- define "root.moduleMeta" -}}
stash:   { host: stash,   role: stash,   label: stash,   slug: stash,   title: Stash,   s3: true,  migrate: false, access: true }
hr:      { host: hr,      role: hr,      label: hr,      slug: hr,      title: HR,      s3: false, migrate: true,  access: false }
rally:   { host: events,  role: events,  label: events,  slug: events,  title: Rally,   s3: true,  migrate: true,  access: true }
finance: { host: finance, role: finance, label: finance, slug: finance, title: Finance, s3: false, migrate: true,  access: false }
learn:   { host: learn,   role: learn,   label: learn,   slug: learn,   title: Learn,   s3: true,  migrate: true,  access: true }
wiki:    { host: wiki,    role: wiki,    label: wiki,    slug: wiki,    title: Wiki,    s3: true,  migrate: true,  access: true }
desk:    { host: desk,    role: desk,    label: desk,    slug: desk,    title: Desk,    s3: false, migrate: true,  access: true }
tasks:   { host: tasks,   role: tasks,   label: tasks,   slug: tasks,   title: Tasks,   s3: true,  migrate: true,  access: true }
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
What OpenBao holds for this cluster.yaml, as JSON. "generated" lists the
entries External Secrets fills with random values (path below kvPath and
its properties); the rest are entered by a person.
*/}}
{{- define "root.seedPlan" -}}
{{- $v := .Values }}
{{- $meta := include "root.moduleMeta" . | fromYaml }}
{{- $enabled := include "root.enabledModules" . | fromJsonArray }}
{{- $roles := list "den" "keycloak" }}
{{- $s3 := list "postgres/backup-s3" "den/backup-s3" "den/files-s3" "den/s3" }}
{{- $tokens := list }}
{{- range $n := $enabled }}
{{- $m := index $meta $n }}
{{- $roles = append $roles $m.role }}
{{- if $m.s3 }}{{ $s3 = append $s3 (printf "%s/s3" $n) }}{{ end }}
{{- if has $n (list "learn" "wiki" "tasks") }}{{ $tokens = append $tokens $n }}{{ end }}
{{- end }}
{{- $gen := list (dict "path" "conservices/postgres/superuser" "properties" (list "password")) }}
{{- range $roles }}{{ $gen = append $gen (dict "path" (printf "conservices/postgres/roles/%s" .) "properties" (list "password")) }}{{ end }}
{{- $gen = append $gen (dict "path" "conservices/den/operator-token" "properties" (list "token")) }}
{{- range $tokens }}{{ $gen = append $gen (dict "path" (printf "conservices/service-tokens/%s" .) "properties" (list "token")) }}{{ end }}
{{- if has "desk" $enabled }}{{ $gen = append $gen (dict "path" "conservices/desk/secret-key" "properties" (list "key")) }}{{ end }}
{{- $gen = append $gen (dict "path" "conservices/keycloak/bootstrap-admin" "properties" (list "password")) }}
{{- $gen = append $gen (dict "path" "conservices/keycloak/clients" "properties" (list "den-keycloak" "hr-provisioner" "learn-provisioner")) }}
{{- dict
  "modules" $enabled
  "roles" $roles
  "s3" $s3
  "serviceTokens" $tokens
  "generated" $gen
  "desk" (has "desk" $enabled)
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

{{- define "root.issuer" -}}
https://auth.{{ .Values.domain }}/realms/conservices
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
{{- end }}

{{/* Common labels of Con Services namespaces. Argument: dict tier, module. */}}
{{- define "root.nsLabels" -}}
app.kubernetes.io/part-of: conservices
conservices.io/tier: {{ .tier }}
conservices.io/module: {{ .module }}
pod-security.kubernetes.io/enforce: restricted
pod-security.kubernetes.io/warn: restricted
{{- end }}
