{{/*
Expand the name of the chart.
*/}}
{{- define "swiftacular.name" -}}
{{- .Chart.Name | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "swiftacular.fullname" -}}
{{- .Chart.Name | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "swiftacular.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Storage image reference
*/}}
{{- define "swiftacular.storageImage" -}}
{{- printf "%s/%s:%s" .Values.registry .Values.storage.image .Values.storage.tag }}
{{- end }}

{{/*
Proxy image reference
*/}}
{{- define "swiftacular.proxyImage" -}}
{{- printf "%s/%s:%s" .Values.registry .Values.proxy.image .Values.proxy.tag }}
{{- end }}

{{/*
Keystone image reference
*/}}
{{- define "swiftacular.keystoneImage" -}}
{{- printf "%s/%s:%s" .Values.registry .Values.keystone.image .Values.keystone.tag }}
{{- end }}

{{/*
Package cache image reference
*/}}
{{- define "swiftacular.packageCacheImage" -}}
{{- printf "%s/%s:%s" .Values.registry .Values.packageCache.image .Values.packageCache.tag }}
{{- end }}

{{/*
Grafana image reference — uses the public image directly, no local registry prefix.
*/}}
{{- define "swiftacular.grafanaImage" -}}
{{- printf "%s:%s" .Values.grafana.image .Values.grafana.tag }}
{{- end }}

{{/*
BlueStore image reference
*/}}
{{- define "swiftacular.bluestoreImage" -}}
{{- printf "%s/%s:%s" .Values.registry .Values.bluestore.image .Values.bluestore.tag }}
{{- end }}

{{/*
Namespace helper
*/}}
{{- define "swiftacular.namespace" -}}
{{- .Values.namespace | default .Release.Namespace }}
{{- end }}
