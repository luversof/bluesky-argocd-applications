{{/*
Expand the name of the chart.
*/}}
{{- define "bluesky-project.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}