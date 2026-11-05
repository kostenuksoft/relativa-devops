#!/usr/bin/env bash

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

wait_for_canary() {
  local stable="$1" elapsed=0
  printf 'Waiting for rollout %s to start a canary next to stable ReplicaSet %s\n' "$ROLLOUT" "$stable"
  until [[ "$(rollout_field '{.status.currentPodHash}')" != "$stable" ]]; do
    (( elapsed < APP_TIMEOUT_SECONDS )) || fail "rollout $ROLLOUT did not start a canary within ${APP_TIMEOUT_SECONDS}s"
    sleep 2
    elapsed=$((elapsed + 2))
  done
  printf 'Canary ReplicaSet %s started after %ss\n' "$(rollout_field '{.status.currentPodHash}')" "$elapsed"
}
