{{/* URL prefix Superset runs under ("/superset"), or "" when it has a host of its own (path "/") */}}
{{- define "superset.root" -}}
{{- trimSuffix "/" .Values.ingress.path -}}
{{- end }}

{{/* Connection settings read by superset_config.py; shared by the init and web containers */}}
{{- define "superset.env" -}}
{{- if include "superset.root" . }}
- name: SUPERSET_APP_ROOT
  value: {{ include "superset.root" . | quote }}
{{- end }}
- name: SUPERSET_SECRET_KEY
  valueFrom:
    secretKeyRef:
      name: {{ .Values.secretName }}
      key: secret-key
{{- if .Values.database.external }}
{{- with .Values.database.configMap }}
{{- /* host and database name from the environment's shared ConfigMap (egov-config, created by cluster-configs) */}}
- name: SUPERSET_DB_HOST
  valueFrom:
    configMapKeyRef:
      name: {{ .name }}
      key: {{ .hostKey }}
- name: SUPERSET_DB_NAME
  valueFrom:
    configMapKeyRef:
      name: {{ .name }}
      key: {{ .nameKey }}
{{- else }}
- name: SUPERSET_DB_HOST
  value: {{ required "database.host (or database.configMap)" .Values.database.host | quote }}
- name: SUPERSET_DB_NAME
  value: {{ required "database.name (or database.configMap)" .Values.database.name | quote }}
{{- end }}
- name: SUPERSET_DB_PORT
  value: {{ .Values.database.port | quote }}
- name: SUPERSET_DB_SCHEMA
  value: {{ .Values.database.schema | quote }}
- name: SUPERSET_DB_SSLMODE
  value: {{ .Values.database.sslmode | quote }}
- name: SUPERSET_DB_USER
  valueFrom:
    secretKeyRef:
      name: {{ .Values.database.secretName }}
      key: {{ .Values.database.usernameKey }}
- name: SUPERSET_DB_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ .Values.database.secretName }}
      key: {{ .Values.database.passwordKey }}
{{- else }}
- name: SUPERSET_DB_HOST
  value: {{ .Values.name }}-postgres
- name: SUPERSET_DB_PORT
  value: "5432"
- name: SUPERSET_DB_NAME
  value: superset
- name: SUPERSET_DB_USER
  value: superset
- name: SUPERSET_DB_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ .Values.secretName }}
      key: postgres-password
{{- end }}
- name: REDIS_HOST
  value: {{ .Values.name }}-redis
- name: REDIS_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ .Values.secretName }}
      key: redis-password
{{- end }}

{{/*
Environment overrides. ArgoCD passes the whole environments/<env>.yaml as a values file to every backbone chart,
so this chart's settings live under a "superset:" key there (top-level keys would leak into the other charts).
Merges .Values.superset over the chart defaults; included at the top of every template (idempotent).
*/}}
{{- define "superset.applyEnvOverrides" -}}
{{- if and (hasKey .Values "superset") (kindIs "map" .Values.superset) -}}
{{- $_ := set . "Values" (mergeOverwrite (deepCopy .Values) .Values.superset) -}}
{{- end -}}
{{- end }}
