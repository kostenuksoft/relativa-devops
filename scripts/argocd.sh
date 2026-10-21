#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

GITOPS_DIR="${GITOPS_DIR:-$(cd "$REPO_ROOT/.." && pwd)/relativa-gitops}"
GITOPS_BRANCH="${GITOPS_BRANCH:-main}"
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-argocd}"
ARGOCD_PORT="${ARGOCD_PORT:-8443}"
ROOT_APP="${ROOT_APP:-root}"
APP="${APP:-relativa}"
NAMESPACE="${NAMESPACE:-relativa}"
SECRET_NAME="${SECRET_NAME:-relativa-secrets}"
VALUES_FILE="${VALUES_FILE:-charts/relativa/values-minikube.yaml}"
APP_MANIFEST="${APP_MANIFEST:-argocd-apps/relativa.yaml}"
DRIFT_DEPLOYMENT="${DRIFT_DEPLOYMENT:-gateway}"
DRIFT_REPLICAS="${DRIFT_REPLICAS:-3}"
BROKEN_COMPONENT="${BROKEN_COMPONENT:-client}"
MISSING_TAG="${MISSING_TAG:-0.0.0-missing}"
APP_TIMEOUT_SECONDS="${APP_TIMEOUT_SECONDS:-900}"
CLIENT_PORT="${CLIENT_PORT:-3000}"
GATEWAY_PORT="${GATEWAY_PORT:-8080}"

source "$SCRIPT_DIR/lib/cluster.sh"

PORT_FORWARDS=()
trap 'for pid in "${PORT_FORWARDS[@]}"; do kill "$pid" 2>/dev/null || true; done' EXIT

gitops() {
  git -C "$GITOPS_DIR" "$@"
}

run() {
  printf '\033[1;33m$ %s\033[0m\n' "$*"
  "$@"
}

port_forward() {
  local namespace="$1" target="$2" ports="$3" local_port="${3%%:*}"
  if port_open "$local_port"; then
    return
  fi
  kubectl --namespace "$namespace" port-forward "$target" "$ports" >/dev/null 2>&1 &
  PORT_FORWARDS+=("$!")
  until port_open "$local_port"; do
    sleep 1
  done
}

port_open() {
  curl -sk -o /dev/null "http://127.0.0.1:$1" || curl -sk -o /dev/null "https://127.0.0.1:$1"
}

app_state() {
  kubectl --namespace "$ARGOCD_NAMESPACE" get application "$1" \
    -o jsonpath='{.status.sync.status}/{.status.health.status}/{.status.sync.revision}' 2>/dev/null || true
}

wait_app() {
  local app="$1" sync="$2" health="$3" revision="${4:-}" state elapsed=0
  printf 'Waiting for %s to be %s/%s%s\n' "$app" "$sync" "$health" "${revision:+ at ${revision:0:7}}"
  while true; do
    state="$(app_state "$app")"
    if [[ "$state" == "$sync/$health/"* && ( -z "$revision" || "${state##*/}" == "$revision" ) ]]; then
      printf '%s is %s/%s at %s after %ss\n' "$app" "$sync" "$health" "${state##*/}" "$elapsed"
      return
    fi
    (( elapsed < APP_TIMEOUT_SECONDS )) || fail "$app stayed at $state for ${APP_TIMEOUT_SECONDS}s"
    sleep 5
    elapsed=$((elapsed + 5))
  done
}

wait_sync_status() {
  local app="$1" sync="$2" elapsed=0
  until [[ "$(app_state "$app")" == "$sync/"* ]]; do
    (( elapsed < APP_TIMEOUT_SECONDS )) || fail "$app did not become $sync within ${APP_TIMEOUT_SECONDS}s"
    sleep 5
    elapsed=$((elapsed + 5))
  done
  printf '%s became %s after %ss\n' "$app" "$sync" "$elapsed"
}

publish() {
  local message="$1" file="$2"
  {
    run gitops diff -- "$file"
    run gitops add -- "$file"
    run gitops commit -m "$message"
    run gitops push origin "$GITOPS_BRANCH"
  } >&2
  gitops rev-parse HEAD
}

set_value() {
  local file="$1" path="$2" value="$3"
  VALUE="$value" yq -i "$path = env(VALUE)" "$GITOPS_DIR/$file"
}

argocd_login() {
  local password="${ARGOCD_ADMIN_PASSWORD:-}"
  if [[ -n "${ARGOCD_LOGGED_IN:-}" ]]; then
    return
  fi
  port_forward "$ARGOCD_NAMESPACE" service/argocd-server "$ARGOCD_PORT:443"
  if [[ -z "$password" ]]; then
    read -r -s -p "Argo CD admin password: " password
    printf '\n'
  fi
  argocd login "localhost:$ARGOCD_PORT" --insecure --grpc-web --username admin --password "$password" >/dev/null
  ARGOCD_LOGGED_IN=1
  printf 'Logged in to Argo CD at https://localhost:%s as admin\n' "$ARGOCD_PORT"
}

health_of() {
  in_cluster "curl -fsS http://$APP-gateway:$GATEWAY_PORT/health"
  printf '\n'
}

cmd_install() {
  require minikube kubectl argocd gh openssl
  ensure_cluster

  step "Install Argo CD into namespace $ARGOCD_NAMESPACE"
  kubectl create namespace "$ARGOCD_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
  run kubectl apply -k "$GITOPS_DIR/bootstrap/argocd" --server-side --force-conflicts >/dev/null
  for deployment in $(kubectl --namespace "$ARGOCD_NAMESPACE" get deployments -o jsonpath='{.items[*].metadata.name}'); do
    kubectl --namespace "$ARGOCD_NAMESPACE" rollout status "deployment/$deployment" --timeout="$ROLLOUT_TIMEOUT"
  done
  kubectl --namespace "$ARGOCD_NAMESPACE" rollout status statefulset/argocd-application-controller --timeout="$ROLLOUT_TIMEOUT"
  run kubectl --namespace "$ARGOCD_NAMESPACE" get pods
  run argocd version --client --short

  step "Change the initial admin password"
  port_forward "$ARGOCD_NAMESPACE" service/argocd-server "$ARGOCD_PORT:443"
  if kubectl --namespace "$ARGOCD_NAMESPACE" get secret argocd-initial-admin-secret >/dev/null 2>&1; then
    local initial new_password="${ARGOCD_ADMIN_PASSWORD:-}"
    initial="$(kubectl --namespace "$ARGOCD_NAMESPACE" get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)"
    if [[ -z "$new_password" ]]; then
      read -r -s -p "New Argo CD admin password: " new_password
      printf '\n'
    fi
    argocd login "localhost:$ARGOCD_PORT" --insecure --grpc-web --username admin --password "$initial" >/dev/null
    run argocd account update-password --account admin --current-password "$initial" --new-password "$new_password" >/dev/null
    run kubectl --namespace "$ARGOCD_NAMESPACE" delete secret argocd-initial-admin-secret
    ARGOCD_ADMIN_PASSWORD="$new_password"
  fi
  argocd_login
  run argocd account get-user-info

  step "Connect the private configuration repository"
  local repo_url
  repo_url="$(gitops remote get-url origin)"
  argocd repo add "$repo_url" --username "$(gh api user --jq .login)" --password "$(gh auth token)" --upsert >/dev/null
  run argocd repo list
}

cmd_bootstrap() {
  require kubectl argocd openssl

  step "Application credentials outside Git"
  kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
  if ! kn get secret "$SECRET_NAME" >/dev/null 2>&1; then
    kn create secret generic "$SECRET_NAME" \
      --from-literal=DB_PASSWORD="$(openssl rand -hex 16)" \
      --from-literal=RABBITMQ_PASSWORD="$(openssl rand -hex 16)" \
      --from-literal=JWT_SECRET_KEY="$(openssl rand -hex 32)"
  fi
  run kn get secret "$SECRET_NAME"
  run grep -niE 'password|secret' "$GITOPS_DIR/$VALUES_FILE"

  step "Apply the root application (the only manual apply)"
  run kubectl apply -f "$GITOPS_DIR/bootstrap/root-app.yaml"
  wait_app "$ROOT_APP" Synced Healthy
  wait_app "$APP" Synced Healthy
  argocd_login
  run argocd app list
  run argocd app get "$APP"
  health_of
}

cmd_ui() {
  require kubectl
  argocd_login
  port_forward "$NAMESPACE" "service/$APP-gateway" "$GATEWAY_PORT:$GATEWAY_PORT"
  port_forward "$NAMESPACE" "service/$APP-client" "$CLIENT_PORT:$CLIENT_PORT"
  printf '\nArgo CD:  https://localhost:%s/applications/%s/%s?view=tree\n' "$ARGOCD_PORT" "$ARGOCD_NAMESPACE" "$APP"
  printf 'Client:   http://localhost:%s\n' "$CLIENT_PORT"
  printf 'Gateway:  http://localhost:%s/health\n' "$GATEWAY_PORT"
  read -r -p $'\nPress Enter to close the port-forwards ' || true
}

cmd_release() {
  local tag="${1:?usage: release <image tag>}" revision
  require kubectl argocd yq

  step "Release $tag through Git"
  run kn get deployments -o custom-columns='NAME:.metadata.name,IMAGE:.spec.template.spec.containers[0].image'
  health_of
  set_value "$VALUES_FILE" .image.tag "$tag"
  revision="$(publish "release $tag" "$VALUES_FILE")"
  wait_app "$APP" Synced Healthy "$revision"
  argocd_login
  run argocd app get "$APP"
  run kn get deployments -o custom-columns='NAME:.metadata.name,IMAGE:.spec.template.spec.containers[0].image'
  health_of
}

cmd_drift() {
  local deployment="$APP-$DRIFT_DEPLOYMENT" desired revision
  require kubectl argocd yq
  desired="$(kn get deployment "$deployment" -o jsonpath='{.spec.replicas}')"

  if [[ "$(yq '.spec.syncPolicy.automated.selfHeal' "$GITOPS_DIR/$APP_MANIFEST")" == "true" ]]; then
    step "Turn selfHeal off in Git"
    set_value "$APP_MANIFEST" .spec.syncPolicy.automated.selfHeal false
    revision="$(publish "disable self heal for $APP" "$APP_MANIFEST")"
    wait_app "$ROOT_APP" Synced Healthy "$revision"
    wait_app "$APP" Synced Healthy "$revision"
  fi

  step "Manual change without selfHeal"
  run yq '.spec.syncPolicy' "$GITOPS_DIR/$APP_MANIFEST"
  run kn scale "deployment/$deployment" --replicas="$DRIFT_REPLICAS"
  wait_sync_status "$APP" OutOfSync
  argocd_login
  run argocd app get "$APP"
  run argocd app diff "$APP" || true
  run kn get deployment "$deployment"

  step "Turn selfHeal on in Git"
  set_value "$APP_MANIFEST" .spec.syncPolicy.automated.selfHeal true
  revision="$(publish "enable self heal for $APP" "$APP_MANIFEST")"
  wait_app "$ROOT_APP" Synced Healthy "$revision"
  wait_app "$APP" Synced Healthy "$revision"
  run kn get deployment "$deployment"

  step "Manual change with selfHeal"
  run kn scale "deployment/$deployment" --replicas="$DRIFT_REPLICAS"
  run kn get deployment "$deployment"
  until [[ "$(kn get deployment "$deployment" -o jsonpath='{.spec.replicas}')" == "$desired" ]]; do
    sleep 2
  done
  wait_app "$APP" Synced Healthy
  run kn get deployment "$deployment"
  run argocd app get "$APP"
}

cmd_degraded() {
  local revision
  require kubectl argocd yq

  step "Point $BROKEN_COMPONENT at missing tag $MISSING_TAG in Git"
  set_value "$VALUES_FILE" ".$BROKEN_COMPONENT.image.tag" "$MISSING_TAG"
  revision="$(publish "deploy $BROKEN_COMPONENT $MISSING_TAG" "$VALUES_FILE")"
  wait_app "$APP" Synced Degraded "$revision"
  argocd_login
  run argocd app get "$APP"
  run kn get pods -l "app.kubernetes.io/component=$BROKEN_COMPONENT"
}

cmd_revert() {
  local revision
  require kubectl argocd

  step "Roll back with git revert"
  run gitops revert --no-edit HEAD
  run gitops push origin "$GITOPS_BRANCH"
  revision="$(gitops rev-parse HEAD)"
  wait_app "$APP" Synced Healthy "$revision"
  run gitops log --oneline -n 8
  argocd_login
  run argocd app history "$APP"
  run argocd app get "$APP"
}

cmd_set() {
  local path="${1:?usage: set <values path> <value>}" value="${2:?usage: set <values path> <value>}" revision
  require kubectl argocd yq

  step "Change .$path to $value in Git"
  set_value "$VALUES_FILE" ".$path" "$value"
  revision="$(publish "set $path to $value" "$VALUES_FILE")"
  wait_app "$APP" Synced Healthy "$revision"
  argocd_login
  run argocd app get "$APP"
  run kn get deployments,configmaps -o wide
}

cmd_all() {
  cmd_install
  cmd_bootstrap
  cmd_ui
  cmd_release "${1:?usage: all <release image tag>}"
  cmd_drift
  cmd_degraded
  cmd_revert
}

usage() {
  printf 'Usage: %s <install|bootstrap|ui|release TAG|drift|degraded|revert|set PATH VALUE|all TAG>\n' "$(basename "$0")"
}

case "${1:-}" in
  install) cmd_install ;;
  bootstrap) cmd_bootstrap ;;
  ui) cmd_ui ;;
  release) cmd_release "${2:-}" ;;
  drift) cmd_drift ;;
  degraded) cmd_degraded ;;
  revert) cmd_revert ;;
  set) cmd_set "${2:-}" "${3:-}" ;;
  all) cmd_all "${2:-}" ;;
  *) usage; exit 1 ;;
esac
