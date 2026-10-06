{{- define "relativa.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "relativa.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{- define "relativa.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "relativa.componentName" -}}
{{- printf "%s-%s" (include "relativa.fullname" .root) .component | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "relativa.selectorLabels" -}}
app.kubernetes.io/name: {{ include "relativa.name" .root }}
app.kubernetes.io/instance: {{ .root.Release.Name }}
{{- with .component }}
app.kubernetes.io/component: {{ . }}
{{- end }}
{{- end }}

{{- define "relativa.labels" -}}
helm.sh/chart: {{ include "relativa.chart" .root }}
{{ include "relativa.selectorLabels" . }}
app.kubernetes.io/version: {{ .root.Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .root.Release.Service }}
app.kubernetes.io/part-of: {{ include "relativa.name" .root }}
{{- end }}

{{- define "relativa.configName" -}}
{{- printf "%s-config" (include "relativa.fullname" .) }}
{{- end }}

{{- define "relativa.secretName" -}}
{{- printf "%s-secrets" (include "relativa.fullname" .) }}
{{- end }}

{{- define "relativa.appImage" -}}
{{- $values := index .root.Values .component }}
{{- $image := default dict $values.image }}
{{- $repository := default (printf "%s-%s" .root.Values.image.repository .component) $image.repository }}
{{- $tag := default (default .root.Chart.AppVersion .root.Values.image.tag) $image.tag }}
{{- printf "%s:%s" $repository $tag }}
{{- end }}

{{- define "relativa.image" -}}
{{- printf "%s:%s" .repository .tag }}
{{- end }}

{{- define "relativa.serviceUrl" -}}
{{- $values := index .root.Values .component }}
{{- printf "http://%s:%v" (include "relativa.componentName" .) $values.port }}
{{- end }}

{{- define "relativa.clientUrl" -}}
{{- if .Values.ingress.enabled }}
{{- printf "%s://%s" .Values.ingress.scheme .Values.ingress.hosts.client }}
{{- else }}
{{- .Values.publicUrls.client }}
{{- end }}
{{- end }}

{{- define "relativa.gatewayUrl" -}}
{{- if .Values.ingress.enabled }}
{{- printf "%s://%s" .Values.ingress.scheme .Values.ingress.hosts.gateway }}
{{- else }}
{{- .Values.publicUrls.gateway }}
{{- end }}
{{- end }}

{{- define "relativa.clientAllowedHosts" -}}
{{- $hosts := list (include "relativa.componentName" (dict "root" . "component" "client")) }}
{{- if .Values.ingress.enabled }}
{{- $hosts = append $hosts .Values.ingress.hosts.client }}
{{- end }}
{{- join "," $hosts }}
{{- end }}

{{- define "relativa.configEnv" -}}
- name: {{ .name }}
  valueFrom:
    configMapKeyRef:
      name: {{ include "relativa.configName" .root }}
      key: {{ default .name .key }}
{{- end }}

{{- define "relativa.secretEnv" -}}
- name: {{ .name }}
  valueFrom:
    secretKeyRef:
      name: {{ include "relativa.secretName" .root }}
      key: {{ default .name .key }}
{{- end }}

{{- define "relativa.databaseEnv" -}}
{{- $password := default "DB_PASSWORD" .passwordName -}}
{{ include "relativa.configEnv" (dict "root" .root "name" "DB_HOST") }}
{{ include "relativa.configEnv" (dict "root" .root "name" "DB_PORT") }}
{{ include "relativa.configEnv" (dict "root" .root "name" "DB_NAME") }}
{{ include "relativa.configEnv" (dict "root" .root "name" "DB_USER") }}
{{ include "relativa.secretEnv" (dict "root" .root "name" $password "key" "DB_PASSWORD") }}
{{- if not .withoutConnectionString }}
- name: ConnectionStrings__Default
  value: {{ printf "Host=$(DB_HOST);Port=$(DB_PORT);Database=$(DB_NAME);Username=$(DB_USER);Password=$(%s)" $password }}
{{- end }}
{{- end }}

{{- define "relativa.rabbitmqEnv" -}}
{{ include "relativa.configEnv" (dict "root" .root "name" "RABBITMQ_HOST") }}
{{ include "relativa.configEnv" (dict "root" .root "name" "RABBITMQ_PORT") }}
{{ include "relativa.configEnv" (dict "root" .root "name" "RABBITMQ_USER") }}
{{ include "relativa.secretEnv" (dict "root" .root "name" "RABBITMQ_PASSWORD") }}
{{- range .sections }}
- name: {{ . }}__Host
  value: $(RABBITMQ_HOST)
- name: {{ . }}__Port
  value: $(RABBITMQ_PORT)
- name: {{ . }}__Username
  value: $(RABBITMQ_USER)
- name: {{ . }}__Password
  value: $(RABBITMQ_PASSWORD)
{{- end }}
{{- end }}

{{- define "relativa.jwtEnv" -}}
{{ include "relativa.secretEnv" (dict "root" .root "name" "Jwt__SecretKey" "key" "JWT_SECRET_KEY") }}
{{ include "relativa.configEnv" (dict "root" .root "name" "Jwt__Issuer" "key" "JWT_ISSUER") }}
{{ include "relativa.configEnv" (dict "root" .root "name" "Jwt__Audience" "key" "JWT_AUDIENCE") }}
{{- end }}

{{- define "relativa.waitForDependencies" -}}
- name: wait-for-dependencies
  image: {{ include "relativa.image" .Values.waitImage }}
  command: ["sh", "-c", "until nc -z \"$DB_HOST\" \"$DB_PORT\" && nc -z \"$RABBITMQ_HOST\" \"$RABBITMQ_PORT\"; do sleep 2; done"]
  envFrom:
    - configMapRef:
        name: {{ include "relativa.configName" . }}
  resources:
    {{- toYaml .Values.waitImage.resources | nindent 4 }}
{{- end }}

{{- define "relativa.migrationJobName" -}}
{{- printf "%s-%d" (include "relativa.componentName" (dict "root" . "component" "migration")) .Release.Revision }}
{{- end }}

{{- define "relativa.migrationReaderName" -}}
{{- include "relativa.componentName" (dict "root" . "component" "migration-reader") }}
{{- end }}

{{- define "relativa.waitForMigration" -}}
- name: wait-for-migration-job
  image: {{ include "relativa.image" .Values.migrationReaderImage }}
  args: ["wait", "--for=create", "job/{{ include "relativa.migrationJobName" . }}", "--timeout={{ .Values.migration.waitTimeout }}"]
  resources:
    {{- toYaml .Values.migrationReaderImage.resources | nindent 4 }}
- name: wait-for-migration
  image: {{ include "relativa.image" .Values.migrationReaderImage }}
  args: ["wait", "--for=condition=complete", "job/{{ include "relativa.migrationJobName" . }}", "--timeout={{ .Values.migration.waitTimeout }}"]
  resources:
    {{- toYaml .Values.migrationReaderImage.resources | nindent 4 }}
{{- end }}

{{- define "relativa.configChecksums" -}}
checksum/config: {{ include (print .Template.BasePath "/configmap.yaml") . | sha256sum }}
checksum/secret: {{ include (print .Template.BasePath "/secret.yaml") . | sha256sum }}
{{- end }}

{{- define "relativa.rollingUpdate" -}}
type: RollingUpdate
rollingUpdate:
  {{- toYaml .Values.rollingUpdate | nindent 2 }}
{{- end }}

{{- define "relativa.appDeployment" -}}
{{- $root := .root }}
{{- $values := index $root.Values .component }}
{{- $probes := mergeOverwrite (deepCopy $root.Values.probes) (default dict $values.probes) }}
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "relativa.componentName" . }}
  labels:
    {{- include "relativa.labels" . | nindent 4 }}
spec:
  replicas: {{ $values.replicaCount }}
  strategy:
    {{- include "relativa.rollingUpdate" $root | nindent 4 }}
  selector:
    matchLabels:
      {{- include "relativa.selectorLabels" . | nindent 6 }}
  template:
    metadata:
      labels:
        {{- include "relativa.labels" . | nindent 8 }}
      annotations:
        {{- include "relativa.configChecksums" $root | nindent 8 }}
    spec:
      {{- with $root.Values.imagePullSecrets }}
      imagePullSecrets:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- if .waitForMigration }}
      serviceAccountName: {{ include "relativa.migrationReaderName" $root }}
      {{- end }}
      {{- if or .waitForDependencies .waitForMigration }}
      initContainers:
        {{- if .waitForDependencies }}
        {{- include "relativa.waitForDependencies" $root | nindent 8 }}
        {{- end }}
        {{- if .waitForMigration }}
        {{- include "relativa.waitForMigration" $root | nindent 8 }}
        {{- end }}
      {{- end }}
      containers:
        - name: {{ .component }}
          image: {{ include "relativa.appImage" . }}
          imagePullPolicy: {{ $root.Values.image.pullPolicy }}
          ports:
            - name: http
              containerPort: {{ $values.port }}
          env:
            {{- .env | nindent 12 }}
          resources:
            {{- toYaml $values.resources | nindent 12 }}
          lifecycle:
            preStop:
              sleep:
                seconds: {{ $root.Values.shutdownDelaySeconds }}
          readinessProbe:
            httpGet:
              path: {{ $values.healthPath }}
              port: http
            {{- toYaml $probes.readiness | nindent 12 }}
          livenessProbe:
            tcpSocket:
              port: http
            {{- toYaml $probes.liveness | nindent 12 }}
{{- end }}

{{- define "relativa.appService" -}}
{{- $values := index .root.Values .component }}
apiVersion: v1
kind: Service
metadata:
  name: {{ include "relativa.componentName" . }}
  labels:
    {{- include "relativa.labels" . | nindent 4 }}
spec:
  type: {{ $values.service.type }}
  selector:
    {{- include "relativa.selectorLabels" . | nindent 4 }}
  ports:
    - name: http
      port: {{ $values.port }}
      targetPort: http
{{- end }}

{{- define "relativa.claimSize" -}}
{{- $existing := lookup "v1" "PersistentVolumeClaim" .root.Release.Namespace .name }}
{{- if $existing }}
{{- $existing.spec.resources.requests.storage }}
{{- else }}
{{- .size }}
{{- end }}
{{- end }}
