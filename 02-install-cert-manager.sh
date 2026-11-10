#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export KUBECONFIG="${KUBECONFIG:-${SCRIPT_DIR}/kubeconfig}"

kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.13.1/cert-manager.yaml

echo "Waiting for cert-manager to be ready..."
kubectl wait --for=condition=Available deployment/cert-manager \
  -n cert-manager --timeout=300s
kubectl wait --for=condition=Available deployment/cert-manager-webhook \
  -n cert-manager --timeout=300s
kubectl wait --for=condition=Available deployment/cert-manager-cainjector \
  -n cert-manager --timeout=300s
