#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

CHART_DIR="${CHART_DIR:-$REPO_ROOT/helm/relativa}"
MANIFESTS_DIR="${MANIFESTS_DIR:-$REPO_ROOT/k8s}"
NAMESPACE="${NAMESPACE:-relativa}"
RELEASE="${RELEASE:-relativa}"
INSTALL_ENV="${INSTALL_ENV:-dev}"
UPGRADE_ENV="${UPGRADE_ENV:-prod}"
SET_TAG="${SET_TAG:-1.0.0}"
PRECEDENCE_KEY="${PRECEDENCE_KEY:-gateway.replicaCount}"
PRECEDENCE_VALUE="${PRECEDENCE_VALUE:-3}"

source "$SCRIPT_DIR/lib/cluster.sh"

values_file() {
  printf '%s/values-%s.yaml' "$CHART_DIR" "$1"
}

helm_ns() {
  helm --namespace "$NAMESPACE" "$@"
}

release_exists() {
  helm_ns status "$RELEASE" >/dev/null 2>&1
}

release_secret_name() {
  kn get secret -l "app.kubernetes.io/instance=$RELEASE,app.kubernetes.io/managed-by=Helm" -o jsonpath='{.items[0].metadata.name}'
}

release_secret_args() {
  local directory="$1" secret key value
  secret="$(release_secret_name)"
  for key in dbPassword:DB_PASSWORD rabbitmqPassword:RABBITMQ_PASSWORD jwtSecretKey:JWT_SECRET_KEY; do
    value="${key#*:}"
    kn get secret "$secret" -o jsonpath="{.data.$value}" | base64 -d > "$directory/$value"
    printf -- '--set-file\nsecrets.%s=%s\n' "${key%%:*}" "$directory/$value"
  done
}

render() {
  helm template "$RELEASE" "$CHART_DIR" --namespace "$NAMESPACE" "$@"
}

placeholder_secrets() {
  printf -- '--set\nsecrets.dbPassword=render,secrets.rabbitmqPassword=render,secrets.jwtSecretKey=render\n'
}

rendered_value() {
  local kind="$1" name="$2" path="$3"
  shift 3
  render "$@" | awk -v kind="$kind" -v name="$name" -v path="$path" '
    /^---/ { inKind = 0; inName = 0 }
    $0 == "kind: " kind { inKind = 1 }
    inKind && $0 == "  name: " name { inName = 1 }
    inKind && inName && $1 == path ":" { print $2; exit }'
}

list_backups() {
  local claim
  claim="$(kn get pvc -l "app.kubernetes.io/instance=$RELEASE,app.kubernetes.io/component=backup" -o jsonpath='{.items[0].metadata.name}')"
  if [[ -z "$claim" ]]; then
    printf 'Backups are disabled for %s
' "$RELEASE"
    return 0
  fi
  in_cluster "ls -lh /backups" "$(printf '{"spec":{"containers":[{"name":"probe","image":"%s","command":["sh","-c","ls -lh /backups"],"volumeMounts":[{"name":"backups","mountPath":"/backups"}]}],"volumes":[{"name":"backups","persistentVolumeClaim":{"claimName":"%s"}}]}}' "$PROBE_IMAGE" "$claim")"
}

cmd_lint() {
  require helm
  local environment args
  step "Lint $CHART_DIR"
  mapfile -t args < <(placeholder_secrets)
  helm lint "$CHART_DIR" --strict
  for environment in dev prod; do
    helm lint "$CHART_DIR" --strict -f "$(values_file "$environment")" "${args[@]}"
  done
}

cmd_envs() {
  require helm
  local args gateway
  mapfile -t args < <(placeholder_secrets)
  gateway="$RELEASE-gateway"
  [[ "$RELEASE" == *relativa* ]] || gateway="$RELEASE-relativa-gateway"

  step "Difference between dev and prod manifests"
  diff -u \
    --label "values-dev.yaml" <(render -f "$(values_file dev)" "${args[@]}") \
    --label "values-prod.yaml" <(render -f "$(values_file prod)" "${args[@]}") || true

  step "Value precedence for $PRECEDENCE_KEY"
  printf '  %-45s %s\n' "values.yaml" \
    "$(rendered_value Deployment "$gateway" replicas "${args[@]}")"
  printf '  %-45s %s\n' "values.yaml + -f values-prod.yaml" \
    "$(rendered_value Deployment "$gateway" replicas -f "$(values_file prod)" "${args[@]}")"
  printf '  %-45s %s\n' "values.yaml + -f values-prod.yaml + --set" \
    "$(rendered_value Deployment "$gateway" replicas -f "$(values_file prod)" "${args[@]}" --set "$PRECEDENCE_KEY=$PRECEDENCE_VALUE")"
}

cmd_compare() {
  require helm
  local args
  mapfile -t args < <(placeholder_secrets)
  step "Objects per kind: $MANIFESTS_DIR vs chart ($UPGRADE_ENV values)"
  diff -y --width=70 \
    <(cat "$MANIFESTS_DIR"/*.yaml | awk '/^kind:/ { print $2 }' | sort | uniq -c) \
    <(render -f "$(values_file "$UPGRADE_ENV")" "${args[@]}" | awk '/^kind:/ { print $2 }' | sort | uniq -c) || true
}

cmd_up() {
  require helm
  ensure_cluster
  cmd_lint

  if kubectl get namespace "$NAMESPACE" >/dev/null 2>&1 && ! release_exists; then
    step "Remove plain-manifest deployment from $MANIFESTS_DIR"
    kubectl delete -f "$MANIFESTS_DIR" --ignore-not-found --wait
    kubectl wait --for=delete "namespace/$NAMESPACE" --timeout="$ROLLOUT_TIMEOUT" 2>/dev/null || true
  fi

  if release_exists; then
    step "Release $RELEASE already installed"
  else
    step "Install $RELEASE with values-$INSTALL_ENV.yaml"
    helm_ns install "$RELEASE" "$CHART_DIR" --create-namespace \
      -f "$(values_file "$INSTALL_ENV")" --wait --timeout "$ROLLOUT_TIMEOUT"
  fi
  cmd_status
}

cmd_status() {
  require helm kubectl
  step "Releases"
  helm_ns list
  step "Status"
  helm_ns status "$RELEASE"
  step "Values supplied to $RELEASE"
  helm_ns get values "$RELEASE"
  step "Release state stored by Helm"
  kn get secrets -l "owner=helm,name=$RELEASE"
  local latest
  latest="$(kn get secrets -l "owner=helm,name=$RELEASE" --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1:].metadata.name}')"
  printf '\n%s decoded (base64 -> base64 -> gzip -> JSON):\n' "$latest"
  kn get secret "$latest" -o jsonpath='{.data.release}' | base64 -d | base64 -d | gzip -d \
    | head -c 400
  printf '...\n'
  step "Objects in namespace $NAMESPACE"
  kn get pods,deployments,services,ingress,pvc,jobs
  print_ingress_hosts
}

cmd_demo() {
  require helm kubectl
  release_exists || fail "release $RELEASE is not installed; run: $(basename "$0") up"

  local secrets_dir secret_args
  secrets_dir="$(mktemp -d)"
  trap 'rm -rf "$secrets_dir"' EXIT

  step "Upgrade: image tag $SET_TAG through --set"
  helm_ns upgrade "$RELEASE" "$CHART_DIR" --reuse-values --set "image.tag=$SET_TAG" \
    --wait --timeout "$ROLLOUT_TIMEOUT"
  kn get deployments -o custom-columns='NAME:.metadata.name,IMAGE:.spec.template.spec.containers[0].image,REPLICAS:.spec.replicas'

  step "Upgrade: values-$UPGRADE_ENV.yaml"
  mapfile -t secret_args < <(release_secret_args "$secrets_dir")
  helm_ns upgrade "$RELEASE" "$CHART_DIR" -f "$(values_file "$UPGRADE_ENV")" "${secret_args[@]}" \
    --wait --timeout "$ROLLOUT_TIMEOUT"
  kn get deployments -o custom-columns='NAME:.metadata.name,IMAGE:.spec.template.spec.containers[0].image,REPLICAS:.spec.replicas'
  kn get ingress

  step "Revision history"
  helm_ns history "$RELEASE"
  step "Changes between revision 1 and the current revision"
  diff -u --label "revision 1" <(helm_ns get values "$RELEASE" --revision 1 -a) \
    --label "current" <(helm_ns get values "$RELEASE" -a) \
    | grep -v -E 'Password|SecretKey' || true

  step "Rollback to revision 1"
  helm_ns rollback "$RELEASE" 1 --wait --timeout "$ROLLOUT_TIMEOUT"
  helm_ns history "$RELEASE"
  kn get deployments -o custom-columns='NAME:.metadata.name,IMAGE:.spec.template.spec.containers[0].image,REPLICAS:.spec.replicas'

  step "Hooks: database backup before every upgrade and rollback"
  helm_ns get hooks "$RELEASE" | grep -E '^(kind|  name|    helm.sh/hook):' || true
  list_backups
  step "Migration job per revision"
  kn get jobs -l "app.kubernetes.io/instance=$RELEASE,app.kubernetes.io/component=migration"

  step "Release test"
  helm_ns test "$RELEASE" --logs
}

cmd_down() {
  require helm kubectl
  step "Uninstall $RELEASE"
  helm_ns uninstall "$RELEASE" --wait --timeout "$ROLLOUT_TIMEOUT"
  kn wait --for=delete pods -l "app.kubernetes.io/instance=$RELEASE" --timeout="$ROLLOUT_TIMEOUT" 2>/dev/null || true
  step "Remaining objects in namespace $NAMESPACE"
  kn get all,ingress,pvc,configmap,secret -l "app.kubernetes.io/instance=$RELEASE" 2>&1
  kn get all,ingress,pvc 2>&1
}

usage() {
  printf 'Usage: %s <up|lint|envs|compare|status|demo|ui|down>\n' "$(basename "$0")"
}

case "${1:-}" in
  up) cmd_up ;;
  lint) cmd_lint ;;
  envs) cmd_envs ;;
  compare) cmd_compare ;;
  status) cmd_status ;;
  demo) cmd_demo ;;
  ui) open_headlamp ;;
  down) cmd_down ;;
  *) usage; exit 1 ;;
esac
