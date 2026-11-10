#!/usr/bin/env bash

NAMESPACE_PIPELINE=${NAMESPACE_PIPELINE:-tekton-pipelines}

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
    --dry-run=client -o yaml | kubectl apply -f -

  echo "Configuring Tekton Results API for Splunk log retrieval..."
  local results_api_config results_api_config_new line key
  results_api_config="$(mktemp)"
  results_api_config_new="$(mktemp)"
  kubectl get configmap tekton-results-api-config -n ${NAMESPACE_PIPELINE} \
    -o jsonpath='{.data.config}' > "${results_api_config}"
  if [[ ! -s "${results_api_config}" ]]; then
    echo "tekton-results-api-config ConfigMap data.config is empty" >&2
    rm -f "${results_api_config}" "${results_api_config_new}"
    return 1
  fi

  # Pure bash rewrite — avoid sed portability traps on scratch/cloud images.
  while IFS= read -r line || [[ -n "${line}" ]]; do
    key="${line%%=*}"
    case "${key}" in
      DB_HOST) echo "DB_HOST=tekton-results-postgres-service" ;;
      LOGS_API) echo "LOGS_API=true" ;;
      LOGS_TYPE) echo "LOGS_TYPE=Splunk" ;;
      LOGGING_PLUGIN_API_URL) echo "LOGGING_PLUGIN_API_URL=https://splunk-hec.${NAMESPACE_PIPELINE}:8089/" ;;
      LOGGING_PLUGIN_QUERY_PARAMS) echo "LOGGING_PLUGIN_QUERY_PARAMS=index=main" ;;
      LOGGING_PLUGIN_TLS_VERIFICATION_DISABLE) echo "LOGGING_PLUGIN_TLS_VERIFICATION_DISABLE=true" ;;
      LOGGING_PLUGIN_PROXY_PATH) echo "LOGGING_PLUGIN_PROXY_PATH=" ;;
      SQL_LOG_LEVEL) echo "SQL_LOG_LEVEL=debug" ;;
      *) echo "${line}" ;;
    esac
  done < "${results_api_config}" > "${results_api_config_new}"

  kubectl create configmap tekton-results-api-config \
    --from-file=config="${results_api_config_new}" \
    -n ${NAMESPACE_PIPELINE} \
    --dry-run=client -o yaml | kubectl apply -f -
  rm -f "${results_api_config}" "${results_api_config_new}"

  kubectl set env deployment/tekton-results-api -n ${NAMESPACE_PIPELINE} \
    SPLUNK_SEARCH_TOKEN="$(kubectl get secret tekton-results-splunk -n ${NAMESPACE_PIPELINE} -o jsonpath='{.data.token}' | base64 -d)"

  echo "Waiting for Tekton Results API to reload Splunk configuration..."
  kubectl rollout status deployment/tekton-results-api -n ${NAMESPACE_PIPELINE} --timeout=300s
}
