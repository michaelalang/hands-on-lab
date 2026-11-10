#!/usr/bin/env bash

NAMESPACE_PIPELINE=openshift-pipelines

configure_tekton_results_splunk() {
  if ! kubectl get deployment tekton-results-api -n ${NAMESPACE_PIPELINE} >/dev/null 2>&1; then
    echo "Tekton Results API not found; skipping Splunk log plugin configuration." >&2
    return 1
  fi

  if ! kubectl get deployment splunk-hec -n ${NAMESPACE} >/dev/null 2>&1; then
    echo "Splunk HEC deployment not found in ${NAMESPACE} namespace." >&2
    return 1
  fi

  echo "Creating Splunk search token for Tekton Results..."
  splunk_ensure_token_user
  local splunk_token
  splunk_token="$(
    splunk_curl -X POST \
      "https://127.0.0.1:8089/services/authorization/tokens?output_mode=json" \
      --data "name=tekton-results" \
      --data "audience=tekton-results" \
      --data "type=static" \
      | sed -n 's/.*"token":"\([^"]*\)".*/\1/p' | head -1
  )"

  if [[ -z "${splunk_token}" ]]; then
    echo "Failed to create Splunk search token for Tekton Results." >&2
    return 1
  fi

  kubectl create secret generic tekton-results-splunk -n ${NAMESPACE_PIPELINE} \
    --from-literal=token="${splunk_token}" \
    --dry-run=client -o yaml | oc apply -f -

  for seq in $(seq 1 10) ; do 
    kubectl -n ${NAMESPACE_PIPELINE} get secret tekton-results-splunk && break
    sleep 3 
  done

  echo "Waiting for Tekton Results API to reload Splunk configuration..."
  kubectl rollout status deployment/tekton-results-api -n ${NAMESPACE_PIPELINE} --timeout=300s
}
