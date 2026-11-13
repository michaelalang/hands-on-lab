#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export KUBECONFIG="${KUBECONFIG:-${SCRIPT_DIR}/kubeconfig}"
export NAMESPACE=openshift-logging
export NAMESPACE_PIPELINE=openshift-pipelines

kubectl apply -f instance-configurations/lokistack.yml ; echo 
kubectl apply -f instance-configurations/coo-uiplugin.yml
kubectl apply -f instance-configurations/tekton.yml

echo "WAIT !! before executing the next tasks if you are on OCP UI"
echo "We just modified the UI Plugin list which will log us out of this pod terminal"
sleep 60
