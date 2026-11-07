{{/* Realm import placeholders. Argument: dict root, clients (placeholder -> client ID). */}}
{{- define "keycloak.placeholders" -}}
{{- $out := dict }}
{{- range $name, $key := .clients }}
{{- $_ := set $out $name (dict "secret" (dict "name" "keycloak-realm-secrets" "key" $key)) }}
{{- end }}
{{- if .root.Values.smtp.enabled }}
{{- range $name, $key := dict "SMTP_HOST" "smtp-host" "SMTP_PORT" "smtp-port" "SMTP_FROM" "smtp-from" "SMTP_USERNAME" "smtp-username" "SMTP_PASSWORD" "smtp-password" }}
{{- $_ := set $out $name (dict "secret" (dict "name" "keycloak-realm-secrets" "key" $key)) }}
{{- end }}
{{- end }}
{{- toYaml $out }}
{{- end }}

{{/* The realm's mail server, only with smtp.enabled. Argument: dict root, displayName. */}}
{{- define "keycloak.smtpServer" -}}
{{- if .root.Values.smtp.enabled }}
smtpServer:
  host: ${SMTP_HOST}
  port: ${SMTP_PORT}
  from: ${SMTP_FROM}
  fromDisplayName: {{ .displayName }}
  auth: "true"
  user: ${SMTP_USERNAME}
  password: ${SMTP_PASSWORD}
  starttls: "true"
  ssl: "false"
{{- end }}
{{- end }}
