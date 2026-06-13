{{/*
Helpers for the ArcadeDB cell chart.
*/}}

{{- define "arcadedb.name" -}}
{{- default "arcadedb" .Values.cellId | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "arcadedb.fullname" -}}
{{- printf "%s" (include "arcadedb.name" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "arcadedb.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "arcadedb.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{/* Standard labels */}}
{{- define "arcadedb.labels" -}}
app.kubernetes.io/name: arcadedb
app.kubernetes.io/instance: {{ include "arcadedb.fullname" . }}
app.kubernetes.io/part-of: arcadedb-kb
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
platform.kb/cell-id: {{ .Values.cellId | quote }}
{{- range $k, $v := .Values.extraLabels }}
{{ $k }}: {{ $v | quote }}
{{- end }}
{{- end -}}

{{- define "arcadedb.selectorLabels" -}}
app.kubernetes.io/name: arcadedb
app.kubernetes.io/instance: {{ include "arcadedb.fullname" . }}
{{- end -}}

{{- define "arcadedb.headlessServiceName" -}}
{{- printf "%s-headless" (include "arcadedb.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* Fully-qualified image reference — digest wins over tag (ADR-0012). */}}
{{- define "arcadedb.image" -}}
{{- if .Values.image.digest -}}
{{- printf "%s@%s" .Values.image.repository .Values.image.digest -}}
{{- else -}}
{{- printf "%s:%s" .Values.image.repository .Values.image.tag -}}
{{- end -}}
{{- end -}}

{{/*
SIZING RULE GUARD (prime directive #7): fail the render if pod memory limit is
below maxPageRAM + heap + overhead. Mirrors the Terraform cell precondition.
*/}}
{{- define "arcadedb.validateSizing" -}}
{{- $req := add (int .Values.sizing.maxPageRAMGib) (int .Values.sizing.heapGib) (int .Values.sizing.overheadGib) -}}
{{- if lt (int .Values.sizing.podMemoryLimitGib) $req -}}
{{- fail (printf "SIZING RULE VIOLATION: podMemoryLimitGib (%d) < maxPageRAM+heap+overhead (%d) — prime directive #7" (int .Values.sizing.podMemoryLimitGib) $req) -}}
{{- end -}}
{{- end -}}

{{/*
VERSION FLOOR GUARD (ADR-0012): best-effort check that image.tag is >= 26.4.1
when a tag (not a digest) is used. Operators must still mirror+verify in CI.
*/}}
{{- define "arcadedb.validateVersion" -}}
{{- if not .Values.image.digest -}}
{{- $t := .Values.image.tag -}}
{{- if or (eq $t "latest") (eq $t "") -}}
{{- fail "VERSION FLOOR VIOLATION: image.tag must be a semver >= 26.4.1, never empty or 'latest' (ADR-0012)" -}}
{{- end -}}
{{- end -}}
{{- end -}}
