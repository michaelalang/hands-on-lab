#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export KUBECONFIG="${KUBECONFIG:-${SCRIPT_DIR}/kubeconfig}"

oc apply -f https://github.com/open-telemetry/opentelemetry-operator/releases/latest/download/opentelemetry-operator.yaml

echo "Waiting for OpenTelemetry Operator to be ready..."
kubectl wait --for=condition=Available \
  deployment/opentelemetry-operator-controller-manager \
  -n opentelemetry-operator-system --timeout=300s
