{{/*
Environment overrides. Argo CD passes the whole environments/<env>.yaml as a values file to every backbone chart,
so this chart's settings live under a "lenspack:" key there (top-level keys would leak into the other charts).
Merges .Values.lenspack over the chart defaults; included at the top of every template (idempotent). Same as the
superset chart's superset.applyEnvOverrides.
*/}}
{{- define "lenspack.applyEnvOverrides" -}}
{{- if and (hasKey .Values "lenspack") (kindIs "map" .Values.lenspack) -}}
{{- $_ := set . "Values" (mergeOverwrite (deepCopy .Values) .Values.lenspack) -}}
{{- end -}}
{{- end }}

{{/* Lenspack's superset.yaml: the datasets and config values, plus what the chart decides (port, path, state) */}}
{{- define "lenspack.config" -}}
{{- $required := dict "datasets" (required "lenspack.datasets: name the Superset datasets before enabling" (.Values.datasets | default nil)) "host" "0.0.0.0" "port" (int .Values.port) "publicPath" .Values.publicPath "state" "/data/superset-boards.json" "superset" (dict "url" .Values.supersetUrl "username" .Values.serviceUser) -}}
{{- toYaml (mergeOverwrite (deepCopy (.Values.config | default dict)) $required) -}}
{{- end }}
