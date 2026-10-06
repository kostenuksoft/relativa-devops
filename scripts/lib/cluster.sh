#!/usr/bin/env bash

MINIKUBE_DRIVER="${MINIKUBE_DRIVER:-docker}"
MINIKUBE_CPUS="${MINIKUBE_CPUS:-4}"
MINIKUBE_MEMORY="${MINIKUBE_MEMORY:-8g}"
ROLLOUT_TIMEOUT="${ROLLOUT_TIMEOUT:-300s}"
ENDPOINTS_TIMEOUT_SECONDS="${ENDPOINTS_TIMEOUT_SECONDS:-120}"
PROBE_IMAGE="${PROBE_IMAGE:-curlimages/curl:8.16.0}"

step() {
  printf '\n\033[1;36m==> %s\033[0m\n' "$*"
}

fail() {
  printf '\033[1;31m%s\033[0m\n' "$*" >&2
  exit 1
}

require() {
  local tool
  for tool in "$@"; do
    command -v "$tool" >/dev/null 2>&1 || fail "$tool is not installed or not on PATH"
  done
}

kn() {
  kubectl --namespace "$NAMESPACE" "$@"
}

ensure_cluster() {
  require minikube kubectl
  step "Cluster"
  if ! minikube status >/dev/null 2>&1; then
    minikube start --driver="$MINIKUBE_DRIVER" --cpus="$MINIKUBE_CPUS" --memory="$MINIKUBE_MEMORY"
  fi
  minikube addons enable metrics-server
  minikube addons enable ingress
  kubectl --namespace ingress-nginx rollout status deployment/ingress-nginx-controller --timeout="$ROLLOUT_TIMEOUT"
  kubectl get nodes -o wide
  kubectl --namespace kube-system get pods
}

ingress_address() {
  case "$(uname -s)" in
    Linux) minikube ip ;;
    *) printf '127.0.0.1' ;;
  esac
}

print_ingress_hosts() {
  local address host hosts
  hosts="$(kn get ingress -o jsonpath='{.items[*].spec.rules[*].host}')"
  [[ -n "$hosts" ]] || return 0
  step "Browser access"
  printf 'Run "minikube tunnel" in a separate terminal and add to the hosts file:\n'
  address="$(ingress_address)"
  for host in $hosts; do
    printf '  %s %s\n' "$address" "$host"
  done
}

in_cluster() {
  local script="$1" overrides="${2:-}" name phase=""
  name="probe-$RANDOM$RANDOM"
  kn run "$name" --image="$PROBE_IMAGE" --restart=Never ${overrides:+"--overrides=$overrides"} \
    --command -- sh -c "$script" >/dev/null
  until [[ "$phase" == Succeeded || "$phase" == Failed ]]; do
    sleep 1
    phase="$(kn get pod "$name" -o jsonpath='{.status.phase}')"
  done
  kn logs "$name"
  kn delete pod "$name" --wait=false >/dev/null
  [[ "$phase" == Succeeded ]]
}

wait_for_endpoints() {
  local service="$1" expected="$2" ready=0 elapsed=0
  while (( ready < expected )); do
    (( elapsed < ENDPOINTS_TIMEOUT_SECONDS )) || fail "service $service has $ready of $expected ready endpoints"
    ready="$(kn get endpointslices -l "kubernetes.io/service-name=$service" \
      -o jsonpath='{range .items[*].endpoints[?(@.conditions.ready==true)]}x{end}')"
    ready="${#ready}"
    sleep 1
    elapsed=$((elapsed + 1))
  done
}

wait_for_rollouts() {
  local deployment
  for deployment in $(kn get deployments -o jsonpath='{.items[*].metadata.name}'); do
    kn rollout status "deployment/$deployment" --timeout="$ROLLOUT_TIMEOUT"
  done
}

open_headlamp() {
  local headlamp="${HEADLAMP_BIN:-}"
  if [[ -z "$headlamp" ]]; then
    if command -v headlamp >/dev/null 2>&1; then
      headlamp="$(command -v headlamp)"
    elif [[ -n "${LOCALAPPDATA:-}" && -x "$LOCALAPPDATA/Programs/Headlamp/Headlamp.exe" ]]; then
      headlamp="$LOCALAPPDATA/Programs/Headlamp/Headlamp.exe"
    elif [[ -d /Applications/Headlamp.app ]]; then
      open -a Headlamp
      return
    else
      fail "Headlamp not found; install it from https://headlamp.dev or set HEADLAMP_BIN"
    fi
  fi
  "$headlamp" >/dev/null 2>&1 &
  disown
}
