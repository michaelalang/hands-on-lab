#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export KUBECONFIG="${KUBECONFIG:-${SCRIPT_DIR}/kubeconfig}"

TEKTON_RESULTS_VERSION="${TEKTON_RESULTS_VERSION:-v0.20.0}"

# Install core pipeline engine
oc apply --filename https://storage.googleapis.com/tekton-releases/pipeline/latest/release.yaml

# Install Tekton Triggers (used for webhooks and events)
oc apply --filename https://storage.googleapis.com/tekton-releases/triggers/latest/release.yaml

oc apply --filename https://storage.googleapis.com/tekton-releases/dashboard/latest/release-full.yaml

echo "Waiting for Tekton Pipelines to be ready..."
kubectl wait --for=condition=Available deployment --all \
  -n tekton-pipelines --timeout=600s

if kubectl get deployment -n tekton-triggers --no-headers 2>/dev/null | grep -q .; then
  echo "Waiting for Tekton Triggers to be ready..."
  kubectl wait --for=condition=Available deployment --all \
    -n tekton-triggers --timeout=600s
fi

echo "Configuring Tekton Pipelines for Results..."
kubectl patch configmap feature-flags -n tekton-pipelines --type merge \
  -p '{"data":{"results-from":"termination-message"}}' 2>/dev/null || true

echo "Installing Tekton Results ${TEKTON_RESULTS_VERSION} prerequisites..."
kubectl create namespace tekton-pipelines --dry-run=client -o yaml | oc apply -f -

kubectl create secret generic tekton-results-postgres -n tekton-pipelines \
  --from-literal=POSTGRES_USER=postgres \
  --from-literal=POSTGRES_PASSWORD="${TEKTON_RESULTS_DB_PASSWORD:-$(openssl rand -base64 20)}" \
  --dry-run=client -o yaml | oc apply -f -

if ! kubectl get secret tekton-results-tls -n tekton-pipelines >/dev/null 2>&1; then
  TLS_DIR="$(mktemp -d)"
  openssl req -x509 \
    -newkey rsa:4096 \
    -keyout "${TLS_DIR}/tls.key" \
    -out "${TLS_DIR}/tls.crt" \
    -days 365 \
    -nodes \
    -subj "/CN=tekton-results-api-service.tekton-pipelines.svc.cluster.local" \
    -addext "subjectAltName=DNS:tekton-results-api-service.tekton-pipelines.svc.cluster.local,DNS:tekton-results-api.tekton-pipelines.svc.cluster.local"
  kubectl create secret tls tekton-results-tls -n tekton-pipelines \
    --cert="${TLS_DIR}/tls.crt" \
    --key="${TLS_DIR}/tls.key"
  rm -rf "${TLS_DIR}"
fi

echo "Installing Tekton Results..."
oc apply -f "https://infra.tekton.dev/tekton-releases/results/previous/${TEKTON_RESULTS_VERSION}/release.yaml"

echo "Patching Tekton Results database host for in-cluster DNS..."
RESULTS_API_CONFIG="$(mktemp)"
RESULTS_API_CONFIG_NEW="$(mktemp)"
trap 'rm -f "${RESULTS_API_CONFIG}" "${RESULTS_API_CONFIG_NEW}"' EXIT
kubectl get configmap tekton-results-api-config -n tekton-pipelines \
  -o jsonpath='{.data.config}' > "${RESULTS_API_CONFIG}"
if [[ ! -s "${RESULTS_API_CONFIG}" ]]; then
  echo "tekton-results-api-config ConfigMap data.config is empty" >&2
  exit 1
fi
# Pure bash rewrite — do not use sed here (some images' sed -i treats the
# expression as a filename and fails with: can't read s|^DB_HOST=...|).
while IFS= read -r line || [[ -n "${line}" ]]; do
  case "${line}" in
    DB_HOST=*) echo "DB_HOST=tekton-results-postgres-service" ;;
    *) echo "${line}" ;;
  esac
done < "${RESULTS_API_CONFIG}" > "${RESULTS_API_CONFIG_NEW}"
kubectl create configmap tekton-results-api-config \
  --from-file=config="${RESULTS_API_CONFIG_NEW}" \
  -n tekton-pipelines \
  --dry-run=client -o yaml | oc apply -f -
rm -f "${RESULTS_API_CONFIG}" "${RESULTS_API_CONFIG_NEW}"
trap - EXIT
kubectl set env deployment/tekton-results-watcher -n tekton-pipelines \
  TEKTON_RESULTS_API_SERVICE=tekton-results-api-service.tekton-pipelines.svc.cluster.local.:8080

kubectl rollout restart deployment/tekton-results-api -n tekton-pipelines
kubectl rollout restart deployment/tekton-results-watcher -n tekton-pipelines

echo "Waiting for Tekton Results PostgreSQL..."
kubectl rollout status statefulset/tekton-results-postgres -n tekton-pipelines --timeout=600s

echo "Waiting for Tekton Results API..."
kubectl rollout status deployment/tekton-results-api -n tekton-pipelines --timeout=600s

echo "Waiting for Tekton Results Watcher..."
kubectl rollout status deployment/tekton-results-watcher -n tekton-pipelines --timeout=600s
