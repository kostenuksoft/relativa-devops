#!/usr/bin/env bash

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
