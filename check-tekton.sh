#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export KUBECONFIG="${KUBECONFIG:-${SCRIPT_DIR}/kubeconfig}"

echo "Tekton Pipelines pods:"
oc get pods -n tekton-pipelines

echo
echo "Dashboard external logs:"
external_logs_url="$(
  kubectl get deployment tekton-dashboard -n tekton-pipelines -o json 2>/dev/null \
    | python3 -c "
import json, sys
try:
    args = json.load(sys.stdin)['spec']['template']['spec']['containers'][0]['args']
except Exception:
    print('(dashboard not found)')
    sys.exit(0)
for arg in args:
    if arg.startswith('--external-logs='):
        value = arg.split('=', 1)[1]
        print(value if value else '(not configured)')
        break
else:
    print('(not configured)')
" 2>/dev/null || echo "(dashboard not found)"
)"
echo "${external_logs_url}"

if [[ -z "${external_logs_url}" || "${external_logs_url}" == "(not configured)" ]]; then
  echo "Run ./04-configure-dashboard-logs.sh to enable Splunk log fallback when task pods are deleted." >&2
fi

echo
echo "tekton-logs-proxy:"
kubectl get deployment,svc tekton-logs-proxy -n tekton-pipelines 2>/dev/null || \
  echo "Not deployed. Run ./04-configure-dashboard-logs.sh"

echo
echo "Port forward the Dashboard UI: address 127.0.0.1 port: 9097"
oc port-forward -n tekton-pipelines service/tekton-dashboard 9097:9097 --address 0.0.0.0 >/dev/null 2>&1  &
