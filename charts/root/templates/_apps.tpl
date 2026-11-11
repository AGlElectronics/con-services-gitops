{{/*
Values for the Den and module charts (deploy/charts/<app> in the main
repository), computed from cluster.yaml. The keys are documented in each
chart's values.yaml.
*/}}

{{/* Shared by every app. Argument: dict root, host, s3 (bool), fqdns (list). */}}
{{- define "root.appCommon" -}}
route:
  enabled: true
  host: {{ .host }}
  parentRefs:
    - name: public
      namespace: conservices-gateway
      sectionName: https
  timeout: 60s
ingress:
  enabled: false
{{- $ha := (include "root.profile" .root | fromJson).appHA }}
ha:
  podDisruptionBudget: {{ $ha }}
  topologySpread: {{ $ha }}
{{- if .root.Values.images.pullSecret.enabled }}
imagePullSecrets:
  - name: ghcr-pull
{{- else }}
imagePullSecrets: []
{{- end }}
networkPolicy:
  gateway:
    cilium: true
  oidc:
    inCluster: true
    namespace: conservices-identity
    port: 8443
  oidcViaIngressController: false
  data:
    enabled: true
    namespace: conservices-data
    postgres:
      podSelector:
        cnpg.io/cluster: conservices-pg
      port: 5432
    s3:
      # No in-cluster S3; managed S3 by DNS name (Cilium toFQDNs).
      enabled: false
      {{- if .s3 }}
      external:
        fqdns: {{ toJson .fqdns }}
        port: 443
      {{- end }}
  {{- if .google }}
  google:
    enabled: true
  {{- end }}
{{- end }}

{{/* S3 settings of an app's config. Argument: dict s3 (root.s3 as dict), bucket. */}}
{{- define "root.appS3Config" -}}
S3_ENDPOINT: {{ .s3.endpoint | quote }}
S3_REGION: {{ .s3.region | quote }}
S3_BUCKET: {{ .bucket | quote }}
S3_USE_PATH_STYLE: {{ .s3.pathStyle | quote }}
{{- end }}

{{/* Den. Argument: root. */}}
{{- define "root.denValues" -}}
{{- $v := .Values }}
{{- $d := $v.domain }}
{{- $s3 := include "root.s3" . | fromYaml }}
{{- $tag := $v.den.version }}
{{- $denHost := include "root.fqdn" (dict "root" . "host" $v.den.host) }}
{{- $meta := include "root.moduleMeta" . | fromYaml }}
{{- $buckets := list (printf "%s-conservices-den" $s3.prefix) }}
{{- $prereg := list }}
{{- range $n := fromJsonArray (include "root.enabledModules" .) }}
{{- $mm := index $meta $n }}
{{- if $mm.s3 }}{{ $buckets = append $buckets (printf "%s-conservices-%s" $s3.prefix $n) }}{{ end }}
{{- $prereg = append $prereg (dict "slug" $mm.slug "display_name" $mm.title "base_url" (printf "https://%s" (include "root.fqdn" (dict "root" $ "host" (index $v.modules $n).host)))) }}
{{- end }}
image:
  backend: { tag: {{ $tag | quote }} }
  frontend: { tag: {{ $tag | quote }} }
  operator: { tag: {{ $tag | quote }} }
existingSecret: den-secrets
# The web app's /config.json (the image names no domain).
frontend:
  config:
    authMode: oidc
    oidcAuthority: {{ include "root.issuer" . }}
    oidcClientId: den-spa
config:
  APP_BASE_URL: https://{{ $denHost }}
  OIDC_ISSUER_URL: {{ include "root.issuer" . }}
  CORS_ALLOWED_ORIGINS: https://{{ $denHost }}
  # Den keeps the realm display name equal to the organisation name;
  # empty turns that off (keycloak.realm.denDisplayNameSync).
  KEYCLOAK_ADMIN_URL: {{ ternary "https://keycloak.conservices-identity.svc.cluster.local:8443" "" $v.keycloak.realm.denDisplayNameSync | quote }}
  {{- include "root.appS3Config" (dict "s3" $s3 "bucket" (printf "%s-conservices-den" $s3.prefix)) | nindent 2 }}
# The enabled modules, listed unpaired on Den's Modules page from the first
# start (DEN_PREREGISTER_MODULES). Den adds new slugs and never changes or
# removes existing ones.
preregisterModules: {{ toJson $prereg }}
operator:
  existingSecret: den-operator-secrets
operatorConfig:
  # Databases are declared in Git (charts/postgres); Den backs them up but
  # does not create or drop them.
  MANAGED_DATABASES: "false"
  PROTECTED_DATABASES: den,keycloak
  MODULE_DB_HOST: conservices-pg-rw.conservices-data.svc.cluster.local:5432
  MODULE_DB_PARAMS: sslmode=verify-full&sslrootcert=/etc/conservices-internal-ca/ca.crt
  BACKUP_ENABLED: "true"
  BACKUP_TIMEZONE: UTC
  BACKUP_S3_ENDPOINT: {{ $s3.backupEndpoint | quote }}
  BACKUP_S3_REGION: {{ $s3.backupRegion | quote }}
  BACKUP_S3_BUCKET: {{ printf "%s-den-backups" $s3.prefix | quote }}
  BACKUP_S3_USE_PATH_STYLE: {{ $s3.backupPathStyle | quote }}
  BACKUP_AGE_RECIPIENTS: {{ $v.den.backupAgeRecipients | quote }}
  # "true": backups share the live data's S3 service; Den warns on its
  # Backups page.
  BACKUP_SAME_STORAGE_AS_DATA: {{ $s3.backupSameAsData | toString | quote }}
  FILES_S3_ENDPOINT: {{ $s3.endpoint | quote }}
  FILES_S3_REGION: {{ $s3.region | quote }}
  FILES_S3_USE_PATH_STYLE: {{ $s3.pathStyle | quote }}
  FILES_S3_BUCKETS: {{ join "," $buckets | quote }}
{{ include "root.appCommon" (dict "root" . "host" $denHost "s3" true "fqdns" $s3.backupFqdns) }}
{{- end }}

{{/* A module. Argument: dict root, name. */}}
{{- define "root.moduleValues" -}}
{{- $root := .root }}
{{- $v := $root.Values }}
{{- $n := .name }}
{{- $d := $v.domain }}
{{- $m := index $v.modules $n }}
{{- $meta := index (include "root.moduleMeta" $root | fromYaml) $n }}
{{- $enabled := fromJsonArray (include "root.enabledModules" $root) }}
{{- $s3 := include "root.s3" $root | fromYaml }}
{{- $tag := $m.version }}
{{- $host := include "root.fqdn" (dict "root" $root "host" $m.host) }}
{{- $denHost := include "root.fqdn" (dict "root" $root "host" $v.den.host) }}
image:
  backend: { tag: {{ $tag | quote }} }
  frontend: { tag: {{ $tag | quote }} }
  {{- if $meta.migrate }}
  migrate: { tag: {{ $tag | quote }} }
  {{- end }}
existingSecret: {{ $n }}-secrets
# The module waits for Den (503 den_pairing_required) until it is paired.
den:
  mode: required
{{- if $meta.access }}
accessConfig:
  enabled: true
  existingConfigMap: {{ $n }}-access-config
{{- end }}
# The web app's /config.json (the image names no domain).
frontend:
  config:
    authMode: oidc
    oidcAuthority: {{ include "root.issuer" $root }}
    oidcClientId: {{ $meta.role }}-spa
  {{- if eq $n "hr" }}
  securityHeaders:
    keycloakOrigin: https://{{ include "root.fqdn" (dict "root" $root "host" $root.Values.keycloak.host) }}
  {{- end }}
  {{- if eq $n "desk" }}
  securityHeaders:
    keycloakOrigin: https://{{ include "root.fqdn" (dict "root" $root "host" $root.Values.keycloak.host) }}
    denOrigin: https://{{ $denHost }}
    s3Origin: {{ $s3.endpoint | quote }}
  {{- end }}
config:
  APP_BASE_URL: https://{{ $host }}
  OIDC_ISSUER_URL: {{ include "root.issuer" $root }}
  {{- if eq $n "rally" }}
  CORS_ALLOWED_ORIGINS: https://{{ $host }},https://{{ include "root.fqdn" (dict "root" $root "host" $m.submit.host) }}
  ATTENDEE_OIDC_ISSUER_URL: {{ include "root.issuer" (dict "root" $root "realm" "attendees") }}
  PUBLIC_SCHEDULE_ENABLED: "false"
  PUBLIC_API_BUILTIN_KEY: ""
  {{- else if eq $n "learn" }}
  CORS_ALLOWED_ORIGINS: https://{{ $host }},https://{{ $denHost }}
  PUBLIC_BASE_URL: https://{{ $host }}
  SMTP_FROM: {{ $v.smtp.from | default (printf "no-reply@%s" $d) | quote }}
  {{- else }}
  CORS_ALLOWED_ORIGINS: https://{{ $host }}
  {{- end }}
  {{- if eq $n "hr" }}
  OIDC_AUDIENCE: hr-api
  KEYCLOAK_SETUP_REDIRECT_URI: https://{{ $denHost }}/
  {{- $catalogs := list }}
  {{- if has "stash" $enabled }}{{ $catalogs = append $catalogs "stash=https://stash-backend.conservices-stash.svc.cluster.local:8080/api/role-catalog" }}{{ end }}
  {{- if has "rally" $enabled }}{{ $catalogs = append $catalogs "events=https://rally-backend.conservices-rally.svc.cluster.local:8080/api/role-catalog" }}{{ end }}
  {{- if has "learn" $enabled }}{{ $catalogs = append $catalogs "learn=https://learn-backend.conservices-learn.svc.cluster.local:8080/api/role-catalog" }}{{ end }}
  {{- if has "finance" $enabled }}{{ $catalogs = append $catalogs "finance=https://finance-backend.conservices-finance.svc.cluster.local:8080/api/role-catalog" }}{{ end }}
  {{- if has "desk" $enabled }}{{ $catalogs = append $catalogs "desk=https://desk-backend.conservices-desk.svc.cluster.local:8080/api/role-catalog" }}{{ end }}
  {{- if has "tasks" $enabled }}{{ $catalogs = append $catalogs "tasks=https://tasks-backend.conservices-tasks.svc.cluster.local:8080/api/role-catalog" }}{{ end }}
  {{- if has "wiki" $enabled }}{{ $catalogs = append $catalogs "wiki=https://wiki-backend.conservices-wiki.svc.cluster.local:8080/api/role-catalog" }}{{ end }}
  ROLE_CATALOG_SOURCES: {{ join "," $catalogs | quote }}
  LEARN_HOLDINGS_URL: {{ ternary "https://learn-backend.conservices-learn.svc.cluster.local:8080/api/internal/holdings" "" (has "learn" $enabled) | quote }}
  {{- end }}
  {{- if $meta.s3 }}
  {{- include "root.appS3Config" (dict "s3" $s3 "bucket" (printf "%s-conservices-%s" $s3.prefix $n)) | nindent 2 }}
  {{- end }}
{{- if eq $n "rally" }}
submit:
  enabled: {{ $m.submit.enabled }}
  host: {{ include "root.fqdn" (dict "root" $root "host" $m.submit.host) }}
  # Attendees sign in through their own realm. No publicScheduleKey: the
  # builtin key is off (PUBLIC_API_BUILTIN_KEY above).
  config:
    authMode: oidc
    oidcAuthority: {{ include "root.issuer" (dict "root" $root "realm" "attendees") }}
    oidcClientId: rally-submit
    publicScheduleKey: ""
{{- end }}
{{ include "root.appCommon" (dict "root" $root "host" $host "s3" $meta.s3 "fqdns" $s3.fqdns "google" (eq $n "desk")) }}
{{- if eq $n "hr" }}
  {{- $egress := list }}
  {{- range $t := list "stash" "rally" "learn" "wiki" "tasks" "finance" "desk" }}
  {{- if has $t $enabled }}{{ $egress = append $egress (printf "conservices-%s" $t) }}{{ end }}
  {{- end }}
  # HR calls these backends (role catalogs, holdings, hooks).
  moduleEgressNamespaces: {{ toJson $egress }}
{{- end }}
{{- end }}

{{/* Values of charts/module-extras. Argument: dict root, name. */}}
{{- define "root.extrasValues" -}}
{{- $v := .root.Values }}
{{- $access := "" }}
{{- if ne .name "den" }}{{ $access = (index $v.modules .name).accessConfig | default "" }}{{- end }}
app: {{ .name }}
namespace: conservices-{{ .name }}
enabledModules: {{ include "root.enabledModules" .root }}
pullSecret: {{ $v.images.pullSecret.enabled }}
accessConfig: {{ $access | quote }}
{{- if eq .name "hr" }}
{{- $hr := index $v.modules "hr" | default dict }}
googleWorkspace: {{ dig "googleWorkspace" "enabled" false ($hr.values | default dict) }}
{{- end }}
{{- end }}
