#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export KUBECONFIG="${KUBECONFIG:-${SCRIPT_DIR}/kubeconfig}"

SPLUNK_PASSWORD="${SPLUNK_PASSWORD:-changeme}"

# shellcheck source=lib/splunk-common.sh
source "${SCRIPT_DIR}/lib/splunk-common.sh"
# shellcheck source=lib/configure-tekton-results-splunk.sh
source "${SCRIPT_DIR}/lib/configure-tekton-results-splunk.sh"
# shellcheck source=lib/raise-kind-pids.sh
source "${SCRIPT_DIR}/lib/raise-kind-pids.sh"

echo "Checking prerequisites..."
kubectl get deployment tekton-results-api -n tekton-pipelines >/dev/null
kubectl get deployment splunk-hec -n logging >/dev/null

raise_kind_node_pids openshift-dev
check_splunk_pids || true


current_logs_type="$(
  kubectl get configmap tekton-results-api-config -n tekton-pipelines \
    -o jsonpath='{.data.config}' \
    | sed -n 's/^LOGS_TYPE=//p' | head -1
)"

if [[ "${current_logs_type}" == "Splunk" ]]; then
  echo "Tekton Results is already configured for Splunk log retrieval; re-applying settings."
else
  echo "Updating Tekton Results log backend from ${current_logs_type:-Postgres} to Splunk..."
fi

configure_tekton_results_splunk

echo "Configuring Dashboard external logs fallback (tekton-logs-proxy -> Results -> Splunk)..."
"${SCRIPT_DIR}/04-configure-dashboard-logs.sh"

echo "Re-running demo pipeline to refresh Tekton Results records..."
kubectl delete pipelinerun demo-pipeline-run -n default --ignore-not-found --wait=true
"${SCRIPT_DIR}/08-run-pipeline.sh"

echo "Tekton Results Splunk update complete."
