#!/usr/bin/env bash

verify_tekton_results_stored() {
  local timeout="${1:-120}"
  local elapsed=0

  echo "Waiting for Tekton Results to store demo-pipeline-run..."
  while (( elapsed < timeout )); do
    if [[ "$(kubectl get pipelinerun demo-pipeline-run -n default -o jsonpath='{.metadata.annotations.results\.tekton\.dev/stored}' 2>/dev/null)" == "true" ]]; then
      echo "Tekton Results stored PipelineRun metadata."
      return 0
    fi
    sleep 5
    elapsed=$((elapsed + 5))
  done

  echo "Timed out waiting for results.tekton.dev/stored=true on demo-pipeline-run." >&2
  return 1
}

verify_dashboard_external_logs_arg() {
  local url
  url="$(
    kubectl get deployment tekton-dashboard -n tekton-pipelines -o json 2>/dev/null \
      | python3 -c "
import json, sys
args = json.load(sys.stdin)['spec']['template']['spec']['containers'][0]['args']
for arg in args:
    if arg.startswith('--external-logs='):
        print(arg.split('=', 1)[1])
        break
" 2>/dev/null || true
  )"

  if [[ -z "${url}" ]]; then
    echo "Tekton Dashboard --external-logs is not configured." >&2
    return 1
  fi

  echo "Dashboard external logs: ${url}"
  return 0
}
