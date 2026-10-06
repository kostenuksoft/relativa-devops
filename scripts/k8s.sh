#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

MANIFESTS_DIR="${MANIFESTS_DIR:-$REPO_ROOT/k8s}"
NAMESPACE="${NAMESPACE:-relativa}"
DEMO_DEPLOYMENT="${DEMO_DEPLOYMENT:-gateway}"
CONFIG_DEPLOYMENT="${CONFIG_DEPLOYMENT:-auth}"
HEALTH_PATH="${HEALTH_PATH:-/health}"
SCALE_REPLICAS="${SCALE_REPLICAS:-4}"
TRAFFIC_REQUESTS="${TRAFFIC_REQUESTS:-40}"
UPDATE_TAG="${UPDATE_TAG:-1.1.0}"
MISSING_TAG="${MISSING_TAG:-0.0.0-missing}"
PULL_FAILURE_TIMEOUT="${PULL_FAILURE_TIMEOUT:-180}"

source "$SCRIPT_DIR/lib/cluster.sh"

selector() {
  printf 'app.kubernetes.io/name=%s' "$1"
}

container_of() {
  kn get deployment "$1" -o jsonpath='{.spec.template.spec.containers[0].name}'
}

image_of() {
  kn get deployment "$1" -o jsonpath='{.spec.template.spec.containers[0].image}'
}

replicas_of() {
  kn get deployment "$1" -o jsonpath='{.spec.replicas}'
}

service_url() {
  local port
  port="$(kn get service "$1" -o jsonpath='{.spec.ports[0].port}')"
  printf 'http://%s:%s%s' "$1" "$port" "$HEALTH_PATH"
}

record_change() {
  kn annotate deployment "$1" "kubernetes.io/change-cause=$2" --overwrite >/dev/null
}

set_tag() {
  local deployment="$1" tag="$2" image
  image="$(image_of "$deployment")"
  kn set image "deployment/$deployment" "$(container_of "$deployment")=${image%:*}:$tag"
  record_change "$deployment" "set image tag $tag"
}

health_of() {
  in_cluster "curl -fsS $(service_url "$1")"
  printf '
'
}

cmd_up() {
  ensure_cluster

  step "Apply $MANIFESTS_DIR"
  kubectl apply -f "$MANIFESTS_DIR"
  wait_for_rollouts
  if [[ -n "$(kn get jobs -o name)" ]]; then
    kn wait --for=condition=complete jobs --all --timeout="$ROLLOUT_TIMEOUT"
  fi

  step "Objects in namespace $NAMESPACE"
  kn get pods,deployments,replicasets,services,ingress,pvc,jobs -o wide

  step "In-cluster request to $DEMO_DEPLOYMENT"
  health_of "$DEMO_DEPLOYMENT"

  print_ingress_hosts
}

cmd_config() {
  local env_names secret_names
  env_names="$(kn get deployment "$CONFIG_DEPLOYMENT" -o jsonpath='{.spec.template.spec.containers[0].env[*].name}')"
  secret_names="$(kn get deployment "$CONFIG_DEPLOYMENT" \
    -o jsonpath='{.spec.template.spec.containers[0].env[?(@.valueFrom.secretKeyRef)].name}')"

  step "Environment of $CONFIG_DEPLOYMENT from ConfigMap and Secret"
  kn exec "deployment/$CONFIG_DEPLOYMENT" -- printenv \
    | awk -v names="$env_names" -v secrets="$secret_names" '
        function replace_all(text, find, replacement,    out, at) {
          out = ""
          while ((at = index(text, find)) > 0) {
            out = out substr(text, 1, at - 1) replacement
            text = substr(text, at + length(find))
          }
          return out text
        }
        BEGIN {
          count = split(names, ordered, " ")
          split(secrets, secretList, " ")
          for (i in secretList) isSecret[secretList[i]] = 1
        }
        {
          eq = index($0, "=")
          if (eq == 0) next
          values[substr($0, 1, eq - 1)] = substr($0, eq + 1)
        }
        END {
          for (name in isSecret) if (name in values && values[name] != "") masked[values[name]] = 1
          width = 0
          for (i = 1; i <= count; i++) if (length(ordered[i]) > width) width = length(ordered[i])
          format = "  %-" width "s  %s\n"
          for (i = 1; i <= count; i++) {
            name = ordered[i]
            if (!(name in values)) continue
            value = values[name]
            if (name in isSecret) value = "<secret, " length(value) " chars>"
            else for (secret in masked) value = replace_all(value, secret, "****")
            printf format, name, value
          }
        }'
}

cmd_demo() {
  require kubectl

  local deployment="$DEMO_DEPLOYMENT" label original_replicas original_tag victim url bad_pod pod reason elapsed
  label="$(selector "$deployment")"
  original_replicas="$(replicas_of "$deployment")"
  original_tag="$(image_of "$deployment")"
  original_tag="${original_tag##*:}"
  url="$(service_url "$deployment")"

  cmd_config

  step "Self-healing: delete a $deployment pod"
  victim="$(kn get pods -l "$label" -o jsonpath='{.items[0].metadata.name}')"
  kn delete pod "$victim" --wait=false
  kn rollout status "deployment/$deployment" --timeout="$ROLLOUT_TIMEOUT"
  kn get pods -l "$label" -o wide

  step "Scaling: $deployment to $SCALE_REPLICAS replicas"
  kn scale "deployment/$deployment" --replicas="$SCALE_REPLICAS"
  kn rollout status "deployment/$deployment" --timeout="$ROLLOUT_TIMEOUT"
  wait_for_endpoints "$deployment" "$SCALE_REPLICAS"
  kn get pods -l "$label" -o wide
  printf 'Responses per instance over %s requests:\n' "$TRAFFIC_REQUESTS"
  in_cluster "i=0; while [ \$i -lt $TRAFFIC_REQUESTS ]; do curl -fsS $url; echo; i=\$((i+1)); done" \
    | grep -o '"instance":"[^"]*"' | sort | uniq -c

  step "Rolling update: $deployment to $UPDATE_TAG while probing availability"
  record_change "$deployment" "set image tag $original_tag"
  kn run availability-probe --image="$PROBE_IMAGE" --restart=Never --command -- sh -c \
    "ok=0; failed=0; while [ ! -f /tmp/stop ]; do if curl -fsS -m 2 $url >/dev/null; then ok=\$((ok+1)); else failed=\$((failed+1)); fi; sleep 0.2; done; echo \"succeeded=\$ok failed=\$failed\""
  kn wait --for=condition=Ready pod/availability-probe --timeout="$ROLLOUT_TIMEOUT"
  set_tag "$deployment" "$UPDATE_TAG"
  kn rollout status "deployment/$deployment" --timeout="$ROLLOUT_TIMEOUT"
  kn exec availability-probe -- sh -c 'touch /tmp/stop'
  kn wait --for=jsonpath='{.status.phase}'=Succeeded pod/availability-probe --timeout=60s
  printf 'Availability during rollout: '
  kn logs availability-probe
  kn delete pod availability-probe --wait=false
  health_of "$deployment"

  step "Rollout history and rollback"
  kn rollout history "deployment/$deployment"
  kn rollout undo "deployment/$deployment"
  kn rollout status "deployment/$deployment" --timeout="$ROLLOUT_TIMEOUT"
  kn rollout history "deployment/$deployment"
  health_of "$deployment"

  step "Diagnostics: deploy missing tag $MISSING_TAG"
  set_tag "$deployment" "$MISSING_TAG"
  elapsed=0
  bad_pod=""
  while [[ -z "$bad_pod" ]]; do
    (( elapsed < PULL_FAILURE_TIMEOUT )) || fail "no pod reached ImagePullBackOff within ${PULL_FAILURE_TIMEOUT}s"
    for pod in $(kn get pods -l "$label" -o jsonpath='{.items[*].metadata.name}'); do
      reason="$(kn get pod "$pod" -o jsonpath='{.status.containerStatuses[0].state.waiting.reason}')"
      if [[ "$reason" == "ImagePullBackOff" ]]; then
        bad_pod="$pod"
      fi
    done
    sleep 3
    elapsed=$((elapsed + 3))
  done
  kn get pods -l "$label"
  step "Describe $bad_pod"
  kn describe pod "$bad_pod" | sed -n '/^Events:/,$p'
  step "Events for $bad_pod"
  kn get events --field-selector "involvedObject.name=$bad_pod" --sort-by=.lastTimestamp
  step "Logs of a healthy $deployment pod"
  kn logs "deployment/$deployment" --tail=20
  step "Exec into a healthy $deployment pod"
  kn exec "deployment/$deployment" -- sh -c 'hostname && whoami && ls'
  printf 'Interactive shell: kubectl --namespace %s exec -it deployment/%s -- sh\n' "$NAMESPACE" "$deployment"
  step "Fix: roll back to the last working revision"
  kn rollout undo "deployment/$deployment"
  kn rollout status "deployment/$deployment" --timeout="$ROLLOUT_TIMEOUT"
  kn get pods -l "$label"

  step "Restore $deployment to $original_replicas replicas"
  kn scale "deployment/$deployment" --replicas="$original_replicas"
  kn rollout status "deployment/$deployment" --timeout="$ROLLOUT_TIMEOUT"
  health_of "$deployment"
}

cmd_down() {
  require kubectl
  kubectl delete -f "$MANIFESTS_DIR" --ignore-not-found
}

usage() {
  printf 'Usage: %s <up|config|demo|ui|down>\n' "$(basename "$0")"
}

case "${1:-}" in
  up) cmd_up ;;
  config) cmd_config ;;
  demo) cmd_demo ;;
  ui) open_headlamp ;;
  down) cmd_down ;;
  *) usage; exit 1 ;;
esac
