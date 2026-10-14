#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

RELEASE=relativa
NAMESPACE=relativa
CHART=helm/relativa
INGRESS_PORT=8088
RENDERED="$(mktemp -d)"
trap 'rm -rf "$RENDERED"; kill $(jobs -p) 2>/dev/null' EXIT

PS4=$'\n\033[1;36m$\033[0m '
set -x

helm version

minikube start --driver=docker --cpus=4 --memory=8g
minikube addons enable ingress
minikube addons enable metrics-server
kubectl get nodes

kubectl delete -f k8s/ --ignore-not-found --wait

helm lint "$CHART"
helm lint "$CHART" -f "$CHART/values-prod.yaml" \
  --set secrets.dbPassword=x,secrets.rabbitmqPassword=x,secrets.jwtSecretKey=x

helm template "$RELEASE" "$CHART" -f "$CHART/values-dev.yaml" > "$RENDERED/dev.yaml"
helm template "$RELEASE" "$CHART" -f "$CHART/values-prod.yaml" \
  --set secrets.dbPassword=x,secrets.rabbitmqPassword=x,secrets.jwtSecretKey=x > "$RENDERED/prod.yaml"
diff "$RENDERED/dev.yaml" "$RENDERED/prod.yaml" || true

helm template "$RELEASE" "$CHART" -s templates/gateway-deployment.yaml | grep replicas
helm template "$RELEASE" "$CHART" -f "$CHART/values-prod.yaml" \
  --set secrets.dbPassword=x,secrets.rabbitmqPassword=x,secrets.jwtSecretKey=x \
  -s templates/gateway-deployment.yaml | grep replicas
helm template "$RELEASE" "$CHART" -f "$CHART/values-prod.yaml" \
  --set secrets.dbPassword=x,secrets.rabbitmqPassword=x,secrets.jwtSecretKey=x \
  --set gateway.replicaCount=3 \
  -s templates/gateway-deployment.yaml | grep replicas

grep -h '^kind:' k8s/*.yaml | sort | uniq -c
grep -h '^kind:' "$RENDERED/prod.yaml" | sort | uniq -c

helm install "$RELEASE" "$CHART" -n "$NAMESPACE" --create-namespace \
  -f "$CHART/values-dev.yaml" --wait --timeout 10m

helm list -n "$NAMESPACE"
helm status "$RELEASE" -n "$NAMESPACE"
helm get values "$RELEASE" -n "$NAMESPACE"
kubectl -n "$NAMESPACE" get pods
kubectl -n "$NAMESPACE" get secrets -l owner=helm

helm upgrade "$RELEASE" "$CHART" -n "$NAMESPACE" --reuse-values \
  --set image.tag=1.2.0 --wait --timeout 10m
kubectl -n "$NAMESPACE" get deployments -o wide

kubectl -n "$NAMESPACE" get secret "$RELEASE-secrets" -o jsonpath='{.data.DB_PASSWORD}' | base64 -d > "$RENDERED/db-password"
kubectl -n "$NAMESPACE" get secret "$RELEASE-secrets" -o jsonpath='{.data.RABBITMQ_PASSWORD}' | base64 -d > "$RENDERED/rabbitmq-password"
kubectl -n "$NAMESPACE" get secret "$RELEASE-secrets" -o jsonpath='{.data.JWT_SECRET_KEY}' | base64 -d > "$RENDERED/jwt-secret-key"
helm upgrade "$RELEASE" "$CHART" -n "$NAMESPACE" -f "$CHART/values-prod.yaml" \
  --set-file secrets.dbPassword="$RENDERED/db-password" \
  --set-file secrets.rabbitmqPassword="$RENDERED/rabbitmq-password" \
  --set-file secrets.jwtSecretKey="$RENDERED/jwt-secret-key" \
  --set ingress.port="$INGRESS_PORT" \
  --wait --timeout 10m
kubectl -n "$NAMESPACE" get deployments,ingress

kubectl -n ingress-nginx port-forward service/ingress-nginx-controller "$INGRESS_PORT":80 >/dev/null &
{ set +x; } 2>/dev/null
read -r -p $'\nOpen http://relativa.local:'"$INGRESS_PORT"' and http://api.relativa.local:'"$INGRESS_PORT"$'/scalar, then press Enter to continue ' || true
set -x

helm history "$RELEASE" -n "$NAMESPACE"
helm get values "$RELEASE" -n "$NAMESPACE" --revision 1
helm get values "$RELEASE" -n "$NAMESPACE" --revision 3

helm rollback "$RELEASE" 1 -n "$NAMESPACE" --wait --timeout 10m
helm history "$RELEASE" -n "$NAMESPACE"
kubectl -n "$NAMESPACE" get deployments -o wide

helm get hooks "$RELEASE" -n "$NAMESPACE"
kubectl -n "$NAMESPACE" get events --field-selector involvedObject.kind=Job
kubectl -n "$NAMESPACE" get jobs,pvc

helm test "$RELEASE" -n "$NAMESPACE" --logs

{ set +x; } 2>/dev/null
read -r -p $'\nUninstall release '"$RELEASE"$'? [y/N] ' answer || answer=""
[[ "$answer" == [yY] ]] || exit 0
set -x

helm uninstall "$RELEASE" -n "$NAMESPACE" --wait
kubectl -n "$NAMESPACE" wait --for=delete pods --all --timeout=5m
kubectl -n "$NAMESPACE" get all,pvc,ingress
