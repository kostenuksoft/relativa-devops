#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

GITOPS_DIR="${GITOPS_DIR:-$(cd "$REPO_ROOT/.." && pwd)/relativa-gitops}"
GITOPS_BRANCH="${GITOPS_BRANCH:-main}"
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-argocd}"
ARGOCD_PORT="${ARGOCD_PORT:-8443}"
APP="${APP:-relativa}"
CONTROLLER_APP="${CONTROLLER_APP:-argo-rollouts}"
CONTROLLER_MANIFEST="${CONTROLLER_MANIFEST:-argocd-apps/argo-rollouts.yaml}"
ROLLOUTS_NAMESPACE="${ROLLOUTS_NAMESPACE:-argo-rollouts}"
NAMESPACE="${NAMESPACE:-relativa}"
COMPONENT="${COMPONENT:-gateway}"
TAG_PATH="${TAG_PATH:-.$COMPONENT.image.tag}"
ROLLOUT="${ROLLOUT:-$APP-$COMPONENT}"
VALUES_FILE="${VALUES_FILE:-charts/relativa/values-minikube.yaml}"
GATEWAY_PORT="${GATEWAY_PORT:-8080}"
DASHBOARD_PORT="${DASHBOARD_PORT:-3100}"
TRAFFIC_REQUESTS="${TRAFFIC_REQUESTS:-40}"
APP_TIMEOUT_SECONDS="${APP_TIMEOUT_SECONDS:-900}"

source "$SCRIPT_DIR/lib/cluster.sh"
source "$SCRIPT_DIR/lib/gitops.sh"

rollout_field() {
  kn get rollout "$ROLLOUT" -o jsonpath="$1"
}

manual_pause_index() {
  kn get rollout "$ROLLOUT" -o json \
    | jq '.spec.strategy.canary.steps | map(has("pause") and (.pause | has("duration") | not)) | index(true)'
}

show_rollout() {
  run kubectl argo rollouts get rollout "$ROLLOUT" --namespace "$NAMESPACE"
}

traffic() {
  step "Responses of $TRAFFIC_REQUESTS in-cluster requests to service $ROLLOUT"
  in_cluster "i=0; while [ \$i -lt $TRAFFIC_REQUESTS ]; do curl -fsS http://$ROLLOUT:$GATEWAY_PORT/health; echo; i=\$((i+1)); done" \
    | grep -o '"version":"[^"]*"' | sort | uniq -c
}

wait_for_image() {
  local tag="$1" elapsed=0
  printf 'Waiting for Argo CD to apply tag %s to rollout %s\n' "$tag" "$ROLLOUT"
  until [[ "$(rollout_field '{.spec.template.spec.containers[0].image}')" == *":$tag" ]]; do
    (( elapsed < APP_TIMEOUT_SECONDS )) || fail "rollout $ROLLOUT did not get tag $tag within ${APP_TIMEOUT_SECONDS}s"
    sleep 2
    elapsed=$((elapsed + 2))
  done
  printf 'Rollout %s points at tag %s after %ss\n' "$ROLLOUT" "$tag" "$elapsed"
}

wait_for_rollout() {
  local phase="$1" step_index="${2:-}" elapsed=0 current
  printf 'Waiting for rollout %s to be %s%s\n' "$ROLLOUT" "$phase" "${step_index:+ at step $step_index}"
  while true; do
    current="$(rollout_field '{.status.phase}/{.status.currentStepIndex}')"
    if [[ "${current%%/*}" == "$phase" && ( -z "$step_index" || "${current##*/}" == "$step_index" ) ]]; then
      printf 'Rollout %s is %s at step %s after %ss\n' "$ROLLOUT" "$phase" "${current##*/}" "$elapsed"
      return
    fi
    (( elapsed < APP_TIMEOUT_SECONDS )) || fail "rollout $ROLLOUT stayed at $current for ${APP_TIMEOUT_SECONDS}s"
    sleep 2
    elapsed=$((elapsed + 2))
  done
}

live_pods() {
  kn get pods -l "app.kubernetes.io/component=$COMPONENT" -o json \
    | jq -r '[.items[] | select(.metadata.deletionTimestamp == null)]'
}

wait_for_stable_pods() {
  local stable replicas pods elapsed=0
  stable="$(rollout_field '{.status.stableRS}')"
  replicas="$(rollout_field '{.spec.replicas}')"
  printf 'Waiting for all %s pods of %s to run the stable ReplicaSet %s\n' "$replicas" "$ROLLOUT" "$stable"
  while true; do
    pods="$(live_pods)"
    if [[ "$(jq -r '[.[].metadata.labels["rollouts-pod-template-hash"]] | unique | join(",")' <<<"$pods")" == "$stable" \
      && "$(jq '[.[] | select(any(.status.conditions[]?; .type == "Ready" and .status == "True"))] | length' <<<"$pods")" == "$replicas" ]]; then
      printf 'All %s pods run the stable ReplicaSet after %ss\n' "$replicas" "$elapsed"
      return
    fi
    (( elapsed < APP_TIMEOUT_SECONDS )) || fail "pods of $ROLLOUT did not return to $stable within ${APP_TIMEOUT_SECONDS}s"
    sleep 2
    elapsed=$((elapsed + 2))
  done
}

pause_for_demo() {
  { set +e; read -r -p $'\n'"$1"$' ' _; set -e; } || true
}

start_release() {
  local tag="$1" message="$2"
  set_value "$VALUES_FILE" "$TAG_PATH" "$tag"
  publish "$message" "$VALUES_FILE" >/dev/null
  wait_for_image "$tag"
}

cmd_install() {
  require kubectl argocd
  step "Argo Rollouts controller managed by Argo CD"
  run cat "$GITOPS_DIR/$CONTROLLER_MANIFEST"
  wait_app "$CONTROLLER_APP" Synced Healthy
  argocd_login
  run argocd app list
  run kubectl --namespace "$ROLLOUTS_NAMESPACE" get deployments,pods,services
  run kubectl get crd rollouts.argoproj.io analysisruns.argoproj.io

  step "kubectl argo rollouts plugin"
  run kubectl argo rollouts version
}

cmd_strategy() {
  require kubectl yq
  step "Rollout settings in $VALUES_FILE"
  run yq ".$COMPONENT | {\"replicaCount\": .replicaCount, \"rollout\": .rollout}" "$GITOPS_DIR/$VALUES_FILE"
  run kn get rollout,deployments
  show_rollout
}

cmd_ui() {
  require kubectl
  argocd_login
  port_forward "$ROLLOUTS_NAMESPACE" service/argo-rollouts-dashboard "$DASHBOARD_PORT:$DASHBOARD_PORT"
  printf '\nArgo CD:   https://localhost:%s/applications/%s/%s?view=tree\n' "$ARGOCD_PORT" "$ARGOCD_NAMESPACE" "$APP"
  printf 'Rollouts:  http://localhost:%s/rollouts/rollout/%s/%s\n' "$DASHBOARD_PORT" "$NAMESPACE" "$ROLLOUT"
  read -r -p $'\nPress Enter to close the port-forwards ' || true
}

cmd_release() {
  local tag="${1:?usage: release <image tag>}" pause_index
  require kubectl argocd yq jq
  pause_index="$(manual_pause_index)"

  step "Release $tag through Git"
  show_rollout
  start_release "$tag" "release $COMPONENT $tag"

  step "Canary steps before the manual pause"
  wait_for_rollout Paused 1
  show_rollout

  step "Manual pause at step $pause_index"
  wait_for_rollout Paused "$pause_index"
  show_rollout
  traffic
  argocd_login
  run argocd app get "$APP"
  pause_for_demo "Rollout paused for review. Press Enter to promote"

  step "Promote"
  run kubectl argo rollouts promote "$ROLLOUT" --namespace "$NAMESPACE"
  wait_for_rollout Healthy
  show_rollout
  traffic
  wait_app "$APP" Synced Healthy
  run argocd app get "$APP"
}

cmd_abort() {
  local tag="${1:?usage: abort <image tag>}" pause_index revision
  require kubectl argocd yq jq
  pause_index="$(manual_pause_index)"

  step "Start release $tag through Git"
  start_release "$tag" "release $COMPONENT $tag"
  wait_for_rollout Paused "$pause_index"
  show_rollout
  traffic

  step "Abort at step $pause_index"
  run kubectl argo rollouts abort "$ROLLOUT" --namespace "$NAMESPACE"
  wait_for_rollout Degraded
  wait_for_stable_pods
  show_rollout
  traffic
  wait_app "$APP" Synced Degraded
  argocd_login
  run argocd app get "$APP"
  pause_for_demo "Release aborted, stable version serves all traffic. Press Enter to finish the rollback through Git"

  step "Finish the rollback with git revert"
  run gitops revert --no-edit HEAD
  run gitops push origin "$GITOPS_BRANCH"
  revision="$(gitops rev-parse HEAD)"
  wait_app "$APP" Synced Healthy "$revision"
  show_rollout
  traffic
  run gitops log --oneline -n 6
  run argocd app history "$APP"
}

cmd_all() {
  cmd_install
  cmd_strategy
  cmd_release "${1:?usage: all <release tag> <aborted tag>}"
  cmd_abort "${2:?usage: all <release tag> <aborted tag>}"
}

usage() {
  printf 'Usage: %s <install|strategy|ui|release TAG|abort TAG|all RELEASE_TAG ABORTED_TAG>\n' "$(basename "$0")"
}

case "${1:-}" in
  install) cmd_install ;;
  strategy) cmd_strategy ;;
  ui) cmd_ui ;;
  release) cmd_release "${2:-}" ;;
  abort) cmd_abort "${2:-}" ;;
  all) cmd_all "${2:-}" "${3:-}" ;;
  *) usage; exit 1 ;;
esac
