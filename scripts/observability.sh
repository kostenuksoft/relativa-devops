#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

GITOPS_DIR="${GITOPS_DIR:-$(cd "$REPO_ROOT/.." && pwd)/relativa-gitops}"
GITOPS_BRANCH="${GITOPS_BRANCH:-main}"
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-argocd}"
ARGOCD_PORT="${ARGOCD_PORT:-8443}"
APP="${APP:-relativa}"
MONITORING_APPS="${MONITORING_APPS:-kube-prometheus-stack loki alloy}"
MONITORING_NAMESPACE="${MONITORING_NAMESPACE:-monitoring}"
NAMESPACE="${NAMESPACE:-relativa}"
COMPONENT="${COMPONENT:-gateway}"
ROLLOUT="${ROLLOUT:-$APP-$COMPONENT}"
SERVICE="${SERVICE:-$ROLLOUT}"
VALUES_FILE="${VALUES_FILE:-charts/relativa/values-minikube.yaml}"
FAIL_RATE_PATH="${FAIL_RATE_PATH:-.$COMPONENT.failRate}"
REPLICAS_PATH="${REPLICAS_PATH:-.$COMPONENT.replicaCount}"
GATEWAY_PORT="${GATEWAY_PORT:-8080}"
METRICS_PATH="${METRICS_PATH:-/metrics}"
METRIC_PREFIX="${METRIC_PREFIX:-relativa_gateway_http_request}"
GRAFANA_SERVICE="${GRAFANA_SERVICE:-kube-prometheus-stack-grafana}"
GRAFANA_SERVICE_PORT="${GRAFANA_SERVICE_PORT:-80}"
GRAFANA_PORT="${GRAFANA_PORT:-3200}"
GRAFANA_SECRET="${GRAFANA_SECRET:-grafana-admin}"
DASHBOARD_UID="${DASHBOARD_UID:-relativa-gateway}"
PROMETHEUS_DATASOURCE="${PROMETHEUS_DATASOURCE:-prometheus}"
LOKI_DATASOURCE="${LOKI_DATASOURCE:-loki}"
EXPLORE_FROM="${EXPLORE_FROM:-now-30m}"
PROMETHEUS_SERVICE="${PROMETHEUS_SERVICE:-kube-prometheus-stack-prometheus}"
PROMETHEUS_PORT="${PROMETHEUS_PORT:-9090}"
ALERTMANAGER_SERVICE="${ALERTMANAGER_SERVICE:-kube-prometheus-stack-alertmanager}"
ALERTMANAGER_PORT="${ALERTMANAGER_PORT:-9093}"
LOKI_SERVICE="${LOKI_SERVICE:-loki}"
LOKI_SERVICE_PORT="${LOKI_SERVICE_PORT:-3100}"
LOKI_PORT="${LOKI_PORT:-3101}"
LOKI_SINCE="${LOKI_SINCE:-15m}"
LOKI_LIMIT="${LOKI_LIMIT:-10}"
ROLLOUTS_NAMESPACE="${ROLLOUTS_NAMESPACE:-argo-rollouts}"
ROLLOUTS_DASHBOARD_PORT="${ROLLOUTS_DASHBOARD_PORT:-3100}"
ALERT_NAME="${ALERT_NAME:-RelativaGatewayHighErrorRate}"
LOAD_NAME="${LOAD_NAME:-$APP-loadgen}"
LOAD_IMAGE="${LOAD_IMAGE:-grafana/k6:2.3.0}"
LOAD_SCRIPT="${LOAD_SCRIPT:-$SCRIPT_DIR/load/gateway.js}"
LOAD_RATE="${LOAD_RATE:-20}"
LOAD_VUS="${LOAD_VUS:-10}"
LOAD_DURATION="${LOAD_DURATION:-24h}"
LOAD_PATHS="${LOAD_PATHS:-/health,/core/health,/auth/health,/core/api/v1/entity-types}"
BAD_FAIL_RATE="${BAD_FAIL_RATE:-0.8}"
APP_TIMEOUT_SECONDS="${APP_TIMEOUT_SECONDS:-900}"

source "$SCRIPT_DIR/lib/cluster.sh"
source "$SCRIPT_DIR/lib/gitops.sh"
source "$SCRIPT_DIR/lib/rollout.sh"

forward_monitoring() {
  port_forward "$MONITORING_NAMESPACE" "service/$GRAFANA_SERVICE" "$GRAFANA_PORT:$GRAFANA_SERVICE_PORT"
  port_forward "$MONITORING_NAMESPACE" "service/$PROMETHEUS_SERVICE" "$PROMETHEUS_PORT:$PROMETHEUS_PORT"
  port_forward "$MONITORING_NAMESPACE" "service/$ALERTMANAGER_SERVICE" "$ALERTMANAGER_PORT:$ALERTMANAGER_PORT"
  port_forward "$MONITORING_NAMESPACE" "service/$LOKI_SERVICE" "$LOKI_PORT:$LOKI_SERVICE_PORT"
}

grafana_field() {
  kubectl --namespace "$MONITORING_NAMESPACE" get secret "$GRAFANA_SECRET" -o "jsonpath={.data.$1}" | base64 -d
}

grafana_credentials() {
  printf '%s:%s' "$(grafana_field admin-user)" "$(grafana_field admin-password)"
}

promql() {
  local query="$1"
  printf '\033[1;35mPromQL> %s\033[0m\n' "$query"
  curl -fsS "http://127.0.0.1:$PROMETHEUS_PORT/api/v1/query" --data-urlencode "query=$query" \
    | jq -r '.data.result[] | "\(.value[1])\t\(.metric | to_entries | map("\(.key)=\(.value)") | join(", "))"'
}

logql() {
  local query="$1"
  printf '\033[1;35mLogQL> %s\033[0m\n' "$query"
  curl -fsS -G "http://127.0.0.1:$LOKI_PORT/loki/api/v1/query_range" \
    --data-urlencode "query=$query" --data-urlencode "since=$LOKI_SINCE" --data-urlencode "limit=$LOKI_LIMIT" \
    | jq -r 'if .data.resultType == "streams"
        then [.data.result[] | .stream as $s | .values[] | {t: .[0], line: "\($s.pod)  \(.[1] | rtrimstr("\n"))"}] | sort_by(.t) | reverse | .[].line
        else .data.result[] | "\(.values[-1][1])\t\(.metric | to_entries | map("\(.key)=\(.value)") | join(", "))" end'
}

show_spec() {
  printf '[1;33m$ kubectl --namespace %s get %s -o yaml | yq .spec[0m
' "$NAMESPACE" "$1"
  kn get "$1" -o yaml | yq '.spec'
}

gateway_selector() {
  printf 'namespace="%s", job="%s"' "$NAMESPACE" "$SERVICE"
}

log_selector() {
  printf '{namespace="%s", container="%s"}' "$NAMESPACE" "$COMPONENT"
}

prometheus_targets() {
  step "Prometheus targets of job $SERVICE (Status -> Targets)"
  curl -fsS "http://127.0.0.1:$PROMETHEUS_PORT/api/v1/targets?state=active" \
    | jq -r --arg job "$SERVICE" '.data.activeTargets[] | select(.labels.job == $job)
        | "\(.health | ascii_upcase)\t\(.labels.pod)\trs=\(.labels.rollouts_pod_template_hash)\t\(.scrapeUrl)\tlast scrape \(.lastScrape)"'
}

gateway_alerts() {
  curl -fsS "http://127.0.0.1:$PROMETHEUS_PORT/api/v1/alerts" \
    | jq -r --arg name "$ALERT_NAME" '.data.alerts[] | select(.labels.alertname == $name)
        | "\(.state | ascii_upcase)\tactive since \(.activeAt)\tvalue \(.value)\t\(.annotations.description)"'
}

wait_for_alert() {
  local state="$1" elapsed=0
  printf 'Waiting for alert %s to be %s\n' "$ALERT_NAME" "$state"
  until [[ "$(gateway_alerts)" == "${state^^}"* ]]; do
    (( elapsed < APP_TIMEOUT_SECONDS )) || fail "alert $ALERT_NAME did not become $state within ${APP_TIMEOUT_SECONDS}s"
    sleep 5
    elapsed=$((elapsed + 5))
  done
  printf 'Alert %s is %s after %ss\n' "$ALERT_NAME" "$state" "$elapsed"
}

latest_analysis_run() {
  kn get analysisruns -l "rollouts-pod-template-hash=$1" --sort-by=.metadata.creationTimestamp \
    -o jsonpath='{.items[-1:].metadata.name}'
}

show_analysis_run() {
  local name="$1"
  step "AnalysisRun $name"
  run kubectl --namespace "$NAMESPACE" get analysisrun "$name"
  kn get analysisrun "$name" -o json | jq -r '
    "phase: \(.status.phase)  message: \(.status.message // "-")",
    (.status.metricResults[] | "metric \(.name): \(.phase)  successful=\(.successful // 0) failed=\(.failed // 0)",
      (.measurements[] | "  \(.finishedAt // .startedAt)  \(.phase)\tvalue=\(.value // "-")"))'
}

load_manifest() {
  local rate="$1"
  cat <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $LOAD_NAME
  namespace: $NAMESPACE
  labels:
    app.kubernetes.io/name: $LOAD_NAME
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: $LOAD_NAME
  template:
    metadata:
      labels:
        app.kubernetes.io/name: $LOAD_NAME
    spec:
      containers:
        - name: k6
          image: $LOAD_IMAGE
          args: ["run", "--quiet", "/scripts/$(basename "$LOAD_SCRIPT")"]
          env:
            - name: BASE_URL
              value: http://$SERVICE:$GATEWAY_PORT
            - name: PATHS
              value: "$LOAD_PATHS"
            - name: RATE
              value: "$rate"
            - name: VUS
              value: "$LOAD_VUS"
            - name: DURATION
              value: $LOAD_DURATION
          volumeMounts:
            - name: scripts
              mountPath: /scripts
          resources:
            requests:
              cpu: 100m
              memory: 64Mi
            limits:
              memory: 256Mi
      volumes:
        - name: scripts
          configMap:
            name: $LOAD_NAME
EOF
}

load_running() {
  [[ "$(kn get deployment "$LOAD_NAME" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)" == 1 ]]
}

show_traffic() {
  local selector
  selector="$(gateway_selector)"
  promql "sum(rate(${METRIC_PREFIX}s_total{$selector}[1m]))"
  promql "1 - sum by (rollouts_pod_template_hash) (rate(${METRIC_PREFIX}s_total{$selector, status!~\"5..\"}[1m])) / sum by (rollouts_pod_template_hash) (rate(${METRIC_PREFIX}s_total{$selector}[1m]))"
  promql "histogram_quantile(0.95, sum by (le) (rate(${METRIC_PREFIX}_duration_seconds_bucket{$selector}[1m])))"
  promql "sum by (pod) (rate(container_cpu_usage_seconds_total{namespace=\"$NAMESPACE\", container=\"$COMPONENT\"}[1m]))"
}

cmd_stack() {
  local app
  require kubectl argocd
  step "Monitoring stack described in Git"
  for app in $MONITORING_APPS; do
    run cat "$GITOPS_DIR/argocd-apps/$app.yaml"
  done
  for app in $MONITORING_APPS; do
    wait_app "$app" Synced Healthy
  done
  argocd_login
  run argocd app list
  run kubectl --namespace "$MONITORING_NAMESPACE" get pods

  step "Grafana answers"
  forward_monitoring
  run curl -fsS "http://127.0.0.1:$GRAFANA_PORT/api/health"
  printf '\nGrafana: http://localhost:%s (user and password in secret %s/%s)\n' "$GRAFANA_PORT" "$MONITORING_NAMESPACE" "$GRAFANA_SECRET"
}

cmd_metrics() {
  local selector
  require kubectl jq
  selector="$(gateway_selector)"
  step "$METRICS_PATH of service $SERVICE"
  in_cluster "curl -fsS http://$SERVICE:$GATEWAY_PORT$METRICS_PATH" | grep "^$METRIC_PREFIX" | grep -v _bucket

  step "ServiceMonitor from the chart"
  show_spec "servicemonitor/$SERVICE"

  forward_monitoring
  prometheus_targets

  step "Query the gateway metrics"
  promql "sum by (route, status) (rate(${METRIC_PREFIX}s_total{$selector}[5m]))"
  promql "histogram_quantile(0.95, sum by (le, route) (rate(${METRIC_PREFIX}_duration_seconds_bucket{$selector}[5m])))"
}

cmd_logs() {
  local pod selector
  require kubectl jq
  selector="$(log_selector)"
  pod="$(kn get pods -l "app.kubernetes.io/component=$COMPONENT" -o jsonpath='{.items[0].metadata.name}')"
  step "JSON logs on stdout of $pod"
  run kubectl --namespace "$NAMESPACE" logs "$pod" --tail=5

  forward_monitoring
  step "Gateway logs in Loki"
  logql "$selector | json"
  step "Only 5xx requests"
  logql "$selector | json | status >= 500"
  logql "sum by (route, status) (count_over_time($selector | json | status >= 500 [$LOKI_SINCE]))"
}

cmd_dashboard() {
  require kubectl jq
  step "Dashboard ConfigMap delivered by Argo CD"
  run kubectl --namespace "$NAMESPACE" get configmap -l grafana_dashboard --show-labels
  forward_monitoring
  step "Dashboard loaded by Grafana"
  curl -fsS -u "$(grafana_credentials)" "http://127.0.0.1:$GRAFANA_PORT/api/dashboards/uid/$DASHBOARD_UID" \
    | jq -r '"\(.dashboard.title) (uid \(.dashboard.uid))", (.dashboard.panels[] | "  [\(.type)] \(.title)")'
  printf '\nOpen: http://localhost:%s/d/%s\n' "$GRAFANA_PORT" "$DASHBOARD_UID"
}

cmd_load() {
  local action="${1:-}" rate="${2:-$LOAD_RATE}"
  require kubectl
  case "$action" in
    start)
      step "Load generator: $rate requests/s to http://$SERVICE:$GATEWAY_PORT"
      kn create configmap "$LOAD_NAME" --from-file="$LOAD_SCRIPT" --dry-run=client -o yaml | kn apply -f -
      load_manifest "$rate" | kn apply -f -
      run kubectl --namespace "$NAMESPACE" rollout status "deployment/$LOAD_NAME" --timeout="$ROLLOUT_TIMEOUT"
      ;;
    stop)
      step "Stop load generator"
      run kubectl --namespace "$NAMESPACE" delete deployment "$LOAD_NAME" --ignore-not-found
      run kubectl --namespace "$NAMESPACE" delete configmap "$LOAD_NAME" --ignore-not-found
      ;;
    status)
      forward_monitoring
      run kubectl --namespace "$NAMESPACE" get deployment "$LOAD_NAME" -o wide
      step "Current traffic"
      show_traffic
      ;;
    *) fail "usage: load <start [RATE]|stop|status>" ;;
  esac
}

cmd_scale() {
  local replicas="${1:?usage: scale <replicas>}" revision
  require kubectl argocd yq
  forward_monitoring
  load_running || fail "start the load generator first: load start"
  step "Before: $(rollout_field '{.spec.replicas}') gateway replicas"
  show_traffic

  step "Scale $COMPONENT to $replicas replicas through Git"
  set_value "$VALUES_FILE" "$REPLICAS_PATH" "$replicas"
  revision="$(publish "scale $COMPONENT to $replicas replicas" "$VALUES_FILE")"
  wait_app "$APP" Synced Healthy "$revision"
  wait_for_endpoints "$SERVICE" "$replicas"
  run kubectl --namespace "$NAMESPACE" get pods -l "app.kubernetes.io/component=$COMPONENT" -o wide
  pause_for_demo "Watch the CPU by pod panel spread over $replicas pods. Press Enter to show the traffic split"
  show_traffic
  pause_for_demo "Press Enter to revert the scale change through Git"

  step "Revert the scale change"
  run gitops revert --no-edit HEAD
  run gitops push origin "$GITOPS_BRANCH"
  wait_app "$APP" Synced Healthy "$(gitops rev-parse HEAD)"
  run kubectl --namespace "$NAMESPACE" get pods -l "app.kubernetes.io/component=$COMPONENT"
}

cmd_analysis() {
  require kubectl yq
  step "AnalysisTemplate from the chart"
  show_spec "analysistemplate/$ROLLOUT-success-rate"
  step "Canary steps in $VALUES_FILE"
  run yq ".$COMPONENT.rollout" "$GITOPS_DIR/$VALUES_FILE"
  show_rollout
}

cmd_bad_release() {
  local fail_rate="${1:-$BAD_FAIL_RATE}" stable canary run_name selector logs revision
  require kubectl argocd yq jq
  forward_monitoring
  load_running || fail "start the load generator first: load start"
  selector="$(gateway_selector)"
  logs="$(log_selector)"
  stable="$(rollout_field '{.status.stableRS}')"

  step "Release $COMPONENT with FAIL_RATE=$fail_rate through Git"
  show_rollout
  set_value "$VALUES_FILE" "$FAIL_RATE_PATH" "$fail_rate"
  publish "release $COMPONENT with fail rate $fail_rate" "$VALUES_FILE" >/dev/null
  wait_for_canary "$stable"
  canary="$(rollout_field '{.status.currentPodHash}')"

  step "Canary $canary under analysis, stable $stable"
  wait_for_rollout Progressing
  show_rollout

  step "PrometheusRule $ALERT_NAME fires on the error spike"
  wait_for_alert firing
  gateway_alerts
  printf 'Alertmanager:\n'
  curl -fsS "http://127.0.0.1:$ALERTMANAGER_PORT/api/v2/alerts?filter=alertname=%22$ALERT_NAME%22" \
    | jq -r '.[] | "\(.status.state)\t\(.labels.alertname)\tstarts \(.startsAt)\t\(.annotations.summary)"'

  step "Analysis fails and the rollout aborts by itself"
  wait_for_rollout Degraded
  run_name="$(latest_analysis_run "$canary")"
  show_analysis_run "$run_name"
  wait_for_stable_pods
  show_rollout
  wait_app "$APP" Synced Degraded
  argocd_login
  run argocd app get "$APP"

  step "Error spike on the dashboard data"
  promql "sum by (rollouts_pod_template_hash) (increase(${METRIC_PREFIX}s_total{$selector, status=~\"5..\"}[5m]))"
  promql "sum(rate(${METRIC_PREFIX}s_total{$selector, status=~\"5..\"}[5m])) / sum(rate(${METRIC_PREFIX}s_total{$selector}[5m]))"

  step "5xx logs in Loki come only from canary pods ($canary)"
  logql "sum by (rollouts_pod_template_hash) (count_over_time($logs | json | status >= 500 [$LOKI_SINCE]))"
  logql "{namespace=\"$NAMESPACE\", container=\"$COMPONENT\", rollouts_pod_template_hash=\"$canary\"} | json | status >= 500"

  pause_for_demo "Bad release aborted automatically. Press Enter to finish the rollback through Git"

  step "Finish the rollback with git revert"
  run gitops revert --no-edit HEAD
  run gitops push origin "$GITOPS_BRANCH"
  revision="$(gitops rev-parse HEAD)"
  wait_app "$APP" Synced Healthy "$revision"
  show_rollout
  run gitops log --oneline -n 4
  run argocd app history "$APP"
}

cmd_ui() {
  require kubectl
  argocd_login
  forward_monitoring
  port_forward "$ROLLOUTS_NAMESPACE" service/argo-rollouts-dashboard "$ROLLOUTS_DASHBOARD_PORT:$ROLLOUTS_DASHBOARD_PORT"
  printf '\nGrafana:       http://localhost:%s/d/%s   (%s)\n' "$GRAFANA_PORT" "$DASHBOARD_UID" "$(grafana_credentials)"
  printf 'Explore Loki:  http://localhost:%s/explore\n' "$GRAFANA_PORT"
  printf 'Prometheus:    http://localhost:%s/targets   http://localhost:%s/alerts\n' "$PROMETHEUS_PORT" "$PROMETHEUS_PORT"
  printf 'Alertmanager:  http://localhost:%s\n' "$ALERTMANAGER_PORT"
  printf 'Argo CD:       https://localhost:%s/applications\n' "$ARGOCD_PORT"
  printf 'Rollouts:      http://localhost:%s/rollouts/rollout/%s/%s\n' "$ROLLOUTS_DASHBOARD_PORT" "$NAMESPACE" "$ROLLOUT"
  read -r -p $'\nPress Enter to close the port-forwards ' || true
}

cmd_query() {
  local language="$1" query="${2:?usage: $1 '<query>'}"
  require kubectl jq
  forward_monitoring
  "$language" "$query"
}

open_url() {
  case "$(uname -s)" in
    Darwin) open "$1" ;;
    Linux) xdg-open "$1" >/dev/null 2>&1 ;;
    *) explorer.exe "$1" || true ;;
  esac
}

explore_url() {
  local datasource="$1" query="$2" panes
  panes="$(jq -rn --arg ds "$datasource" --arg expr "$query" --arg from "$EXPLORE_FROM" \
    '{a: {datasource: $ds, queries: [{refId: "A", expr: $expr, datasource: {uid: $ds}}], range: {from: $from, to: "now"}}} | tojson | @uri')"
  printf 'http://localhost:%s/explore?schemaVersion=1&orgId=1&panes=%s' "$GRAFANA_PORT" "$panes"
}

cmd_explore() {
  local language="${1:-}" query="${2:-}" datasource url
  case "$language" in
    promql) datasource="$PROMETHEUS_DATASOURCE" ;;
    logql) datasource="$LOKI_DATASOURCE" ;;
    *) fail "usage: explore <promql|logql> ['<query>']" ;;
  esac
  require kubectl jq
  forward_monitoring
  load_running || printf '\033[1;31mLoad generator is stopped: rates over the last minutes can be empty. Start it with: %s load start\033[0m\n' "$(basename "$0")"
  if [[ -n "$query" ]]; then
    "$language" "$query"
  fi
  url="$(explore_url "$datasource" "$query")"
  open_url "$url"
  printf '\nGrafana Explore (%s): %s\n' "$datasource" "$url"
  printf 'Login: %s\n' "$(grafana_credentials)"
  read -r -p $'\nPress Enter to close the port-forwards ' || true
}

usage() {
  printf 'Usage: %s <command>\n' "$(basename "$0")"
  printf '  stack | metrics | logs | dashboard | analysis | ui\n'
  printf '  load start [RATE] | load stop | load status\n'
  printf '  scale REPLICAS | bad-release [FAIL_RATE]\n'
  printf "  promql '<query>' | logql '<query>'\n"
  printf "  explore promql ['<query>'] | explore logql ['<query>']\n"
}

case "${1:-}" in
  stack) cmd_stack ;;
  metrics) cmd_metrics ;;
  logs) cmd_logs ;;
  dashboard) cmd_dashboard ;;
  analysis) cmd_analysis ;;
  load) cmd_load "${2:-}" "${3:-$LOAD_RATE}" ;;
  scale) cmd_scale "${2:-}" ;;
  bad-release) cmd_bad_release "${2:-$BAD_FAIL_RATE}" ;;
  ui) cmd_ui ;;
  promql | logql) cmd_query "$1" "${2:-}" ;;
  explore) cmd_explore "${2:-}" "${3:-}" ;;
  *) usage; exit 1 ;;
esac
