#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export KUBECONFIG="${KUBECONFIG:-${SCRIPT_DIR}/kubeconfig}"
export NAMESPACE=openshift-logging
export NAMESPACE_PIPELINE=openshift-pipelines

kubectl apply -f instance-configurations/lokistack.yml ; echo 
kubectl apply -f instance-configurations/coo-uiplugin.yml
kubectl apply -f instance-configurations/tekton.yml
