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
ha:
  podDisruptionBudget: true
  topologySpread: true
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
{{- $tag := $v.den.imageTag | default $v.images.tag }}
{{- $meta := include "root.moduleMeta" . | fromYaml }}
{{- $buckets := list (printf "%s-conservices-den" $s3.prefix) }}
{{- $prereg := list }}
{{- range $n := fromJsonArray (include "root.enabledModules" .) }}
{{- $mm := index $meta $n }}
{{- if $mm.s3 }}{{ $buckets = append $buckets (printf "%s-conservices-%s" $s3.prefix $n) }}{{ end }}
{{- $prereg = append $prereg (dict "slug" $mm.slug "display_name" $mm.title "base_url" (printf "https://%s.%s" $mm.host $d)) }}
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
  APP_BASE_URL: https://den.{{ $d }}
  OIDC_ISSUER_URL: {{ include "root.issuer" . }}
  CORS_ALLOWED_ORIGINS: https://den.{{ $d }}
  KEYCLOAK_ADMIN_URL: https://keycloak.conservices-identity.svc.cluster.local:8443
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
  FILES_S3_ENDPOINT: {{ $s3.endpoint | quote }}
  FILES_S3_REGION: {{ $s3.region | quote }}
  FILES_S3_USE_PATH_STYLE: {{ $s3.pathStyle | quote }}
  FILES_S3_BUCKETS: {{ join "," $buckets | quote }}
{{ include "root.appCommon" (dict "root" . "host" (printf "den.%s" $d) "s3" true "fqdns" $s3.backupFqdns) }}
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
{{- $tag := $m.imageTag | default $v.images.tag }}
{{- $host := printf "%s.%s" $meta.host $d }}
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
config:
  APP_BASE_URL: https://{{ $host }}
  OIDC_ISSUER_URL: {{ include "root.issuer" $root }}
  {{- if eq $n "rally" }}
  CORS_ALLOWED_ORIGINS: https://{{ $host }},https://submit.{{ $d }}
  ATTENDEE_OIDC_ISSUER_URL: https://auth.{{ $d }}/realms/attendees
  PUBLIC_SCHEDULE_ENABLED: "false"
  PUBLIC_API_BUILTIN_KEY: ""
  {{- else if eq $n "learn" }}
  CORS_ALLOWED_ORIGINS: https://{{ $host }},https://den.{{ $d }}
  PUBLIC_BASE_URL: https://{{ $host }}
  SMTP_FROM: {{ $v.smtp.from | default (printf "no-reply@%s" $d) | quote }}
  {{- else }}
  CORS_ALLOWED_ORIGINS: https://{{ $host }}
  {{- end }}
  {{- if eq $n "hr" }}
  KEYCLOAK_SETUP_REDIRECT_URI: https://den.{{ $d }}/
  {{- $catalogs := list }}
  {{- if has "stash" $enabled }}{{ $catalogs = append $catalogs "stash=https://stash-backend.conservices-stash.svc.cluster.local:8080/api/role-catalog" }}{{ end }}
  {{- if has "rally" $enabled }}{{ $catalogs = append $catalogs "events=https://rally-backend.conservices-rally.svc.cluster.local:8080/api/role-catalog" }}{{ end }}
  ROLE_CATALOG_SOURCES: {{ join "," $catalogs | quote }}
  LEARN_HOLDINGS_URL: {{ ternary "https://learn-backend.conservices-learn.svc.cluster.local:8080/api/internal/holdings" "" (has "learn" $enabled) | quote }}
  {{- end }}
  {{- if $meta.s3 }}
  {{- include "root.appS3Config" (dict "s3" $s3 "bucket" (printf "%s-conservices-%s" $s3.prefix $n)) | nindent 2 }}
  {{- end }}
{{- if eq $n "rally" }}
submit:
  enabled: {{ $m.submit.enabled }}
  host: submit.{{ $d }}
  # Attendees sign in through their own realm. No publicScheduleKey: the
  # builtin key is off (PUBLIC_API_BUILTIN_KEY above).
  config:
    authMode: oidc
    oidcAuthority: https://auth.{{ $d }}/realms/attendees
    oidcClientId: rally-submit
    publicScheduleKey: ""
{{- end }}
{{ include "root.appCommon" (dict "root" $root "host" $host "s3" $meta.s3 "fqdns" $s3.fqdns) }}
{{- if eq $n "hr" }}
  {{- $egress := list }}
  {{- range $t := list "stash" "rally" "learn" "wiki" "tasks" }}
  {{- if has $t $enabled }}{{ $egress = append $egress (printf "conservices-%s" $t) }}{{ end }}
  {{- end }}
  # HR calls these backends (role catalogs, holdings, hooks).
  moduleEgressNamespaces: {{ toJson $egress }}
{{- end }}
{{- end }}

{{/*
ARC runner scale set: one pod per job with two native sidecars sharing
its network namespace (localhost only):
  buildkitd  rootless BuildKit; workflows use tcp://127.0.0.1:1234
  postgres   throw-away test database
  postgres://ci:ci-only-password@127.0.0.1:5432/ci_test?sslmode=disable
Argument: root.
*/}}
{{- define "root.arcRunnerValues" -}}
{{- $a := .Values.arc }}
githubConfigUrl: {{ $a.githubConfigUrl }}
runnerScaleSetName: {{ $a.runnerScaleSetName }}
minRunners: {{ $a.minRunners }}
maxRunners: {{ $a.maxRunners }}
listenerTemplate:
  spec:
    containers:
      - name: listener
        resources: {{ toJson $a.resources.listener }}
template:
  spec:
    securityContext:
      runAsNonRoot: true
      fsGroup: 1001
      seccompProfile:
        type: RuntimeDefault
    initContainers:
      - name: buildkitd
        image: {{ $a.buildkitImage }}
        restartPolicy: Always
        args:
          - --addr
          - tcp://127.0.0.1:1234
          - --oci-worker-no-process-sandbox
        securityContext:
          runAsUser: 1000
          runAsGroup: 1000
          seccompProfile:
            type: Unconfined
          appArmorProfile:
            type: Unconfined
        startupProbe:
          exec:
            command: [buildctl, --addr, tcp://127.0.0.1:1234, debug, workers]
          periodSeconds: 2
          failureThreshold: 30
        resources: {{ toJson $a.resources.buildkit }}
        volumeMounts:
          - name: buildkit-cache
            mountPath: /home/user/.local/share/buildkit
      - name: postgres
        image: {{ $a.testDatabaseImage }}
        restartPolicy: Always
        env:
          # Test-only credentials of a database that lives for one job.
          - name: POSTGRES_USER
            value: ci
          - name: POSTGRES_PASSWORD
            value: ci-only-password
          - name: POSTGRES_DB
            value: ci_test
          - name: PGDATA
            value: /var/lib/postgresql/data/pgdata
        args: [-c, listen_addresses=127.0.0.1]
        securityContext:
          runAsUser: 70
          runAsGroup: 70
          allowPrivilegeEscalation: false
          capabilities:
            drop: [ALL]
        startupProbe:
          exec:
            command: [pg_isready, -h, 127.0.0.1, -U, ci, -d, ci_test]
          periodSeconds: 2
          failureThreshold: 30
        resources: {{ toJson $a.resources.testDatabase }}
        volumeMounts:
          - name: pgdata
            mountPath: /var/lib/postgresql/data
    containers:
      - name: runner
        image: {{ $a.runnerImage }}
        command: ["/home/runner/run.sh"]
        securityContext:
          runAsUser: 1001
          runAsGroup: 1001
          allowPrivilegeEscalation: false
          capabilities:
            drop: [ALL]
        resources: {{ toJson $a.resources.runner }}
    volumes:
      - name: buildkit-cache
        emptyDir:
          sizeLimit: 30Gi
      - name: pgdata
        emptyDir: {}
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
{{- end }}
