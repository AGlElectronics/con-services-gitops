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

{{/* StorageClass for PostgreSQL and OpenBao (they replicate themselves). Argument: dict root, override. */}}
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

{{/*
OpenBao server configuration: TLS listener, Raft with one retry_join per
replica, the audit log on its own volume. Argument: replica count.
*/}}
{{- define "root.openbaoRaftConfig" -}}
ui = true
listener "tcp" {
  address         = "[::]:8200"
  cluster_address = "[::]:8201"
  tls_cert_file   = "/openbao/userconfig/openbao-tls/tls.crt"
  tls_key_file    = "/openbao/userconfig/openbao-tls/tls.key"
}
storage "raft" {
  path = "/openbao/data"
{{- range $i := until (int .) }}
  retry_join {
    leader_api_addr     = "https://openbao-{{ $i }}.openbao-internal:8200"
    leader_ca_cert_file = "/openbao/userconfig/openbao-tls/ca.crt"
  }
{{- end }}
}
service_registration "kubernetes" {}
audit "file" "file" {
  description = "Audit log on the audit volume"
  options {
    file_path = "/openbao/audit/audit.log"
  }
}
{{- end }}

{{/* Common labels of Con Services namespaces. Argument: dict tier, module. */}}
{{- define "root.nsLabels" -}}
app.kubernetes.io/part-of: conservices
conservices.io/tier: {{ .tier }}
conservices.io/module: {{ .module }}
pod-security.kubernetes.io/enforce: restricted
pod-security.kubernetes.io/warn: restricted
{{- end }}
