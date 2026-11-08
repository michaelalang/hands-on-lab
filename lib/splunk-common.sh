#!/usr/bin/env bash

splunk_pod() {
  kubectl get pod -n logging -l app=splunk-hec \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null
}

splunk_curl() {
  local pod
  pod="$(splunk_pod)"
  [[ -n "${pod}" ]] || return 1
  kubectl exec -n logging "${pod}" -- \
    /usr/bin/curl -sk -u "admin:${SPLUNK_PASSWORD}" "$@"
}

splunk_http_code() {
  splunk_curl -o /dev/null -w "%{http_code}" "$1" 2>/dev/null || echo "000"
}

splunk_ensure_token_user() {
  if ! splunk_curl "https://127.0.0.1:8089/services/authentication/users/tekton-results?output_mode=json" \
    | grep -q '"name":"tekton-results"'; then
    splunk_curl -X POST "https://127.0.0.1:8089/services/authentication/users?output_mode=json" \
      -d "name=tekton-results" \
      -d "password=${SPLUNK_PASSWORD}" \
      -d "roles=user" >/dev/null
  fi
}
