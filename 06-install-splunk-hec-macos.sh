#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export KUBECONFIG="${KUBECONFIG:-${SCRIPT_DIR}/kubeconfig}"

SPLUNK_PASSWORD="${SPLUNK_PASSWORD:-changeme}"
podman pull docker.io/splunk/splunk:9.3.9 --arch amd64 --os linux
podman save -o splunk.tar docker.io/splunk/splunk:9.3.9
kind load image-archive splunk.tar --name openshift-dev
# Splunk 10.x bundles MongoDB 8, which fails on Linux kernel 6.19+ (Fedora 44 / kind).
# 9.3.x uses MongoDB 4.2 and works for KV Store token auth in this lab.
SPLUNK_IMAGE="${SPLUNK_IMAGE:-docker.io/splunk/splunk:9.3.9}"

# shellcheck source=lib/splunk-common.sh
source "${SCRIPT_DIR}/lib/splunk-common.sh"
# shellcheck source=lib/configure-tekton-results-splunk.sh
source "${SCRIPT_DIR}/lib/configure-tekton-results-splunk.sh"
# shellcheck source=lib/raise-kind-pids.sh
source "${SCRIPT_DIR}/lib/raise-kind-pids.sh"

# Ensure kind/podman PID limits are high enough before Splunk starts forking
# search workers (otherwise Results→Splunk log retrieval hangs).
raise_kind_node_pids openshift-dev

splunk_enable_remote_login() {
  splunk_curl -X POST \
    "https://127.0.0.1:8089/servicesNS/nobody/system/configs/conf-server/general" \
    -d "allowRemoteLogin=always" >/dev/null
}

cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: splunk-hec
  namespace: logging
  labels:
    app: splunk-hec
spec:
  replicas: 1
  selector:
    matchLabels:
      app: splunk-hec
  template:
    metadata:
      labels:
        app: splunk-hec
    spec:
      containers:
      - name: splunk-hec
        image: ${SPLUNK_IMAGE}
        imagePullPolicy: IfNotPresent
        env:
        - name: SPLUNK_GENERAL_TERMS
          value: "--accept-sgt-current-at-splunk-com"
        - name: SPLUNK_START_ARGS
          value: "--accept-license"
        - name: SPLUNK_PASSWORD
          value: "${SPLUNK_PASSWORD}"
        - name: SPLUNK_HEC_TOKEN
          value: "11111111-2222-3333-4444-555555555555"
        - name: SPLUNK_HEC_PORT
          value: "8088"
        ports:
        - containerPort: 8000
          name: http-web
        - containerPort: 8088
          name: http-hec
        - containerPort: 8089
          name: http-api
        resources:
          requests:
            cpu: 500m
            memory: 2Gi
          limits:
            cpu: "2"
            memory: 6Gi
---
apiVersion: v1
kind: Service
metadata:
  name: splunk-hec
  namespace: logging
spec:
  selector:
    app: splunk-hec
  ports:
  - name: web
    port: 8000
    targetPort: 8000
  - name: hec
    port: 8088
    targetPort: 8088
  - name: api
    port: 8089
    targetPort: 8089
EOF

echo "Waiting for Splunk HEC to be ready (this can take several minutes)..."
kubectl rollout status deployment/splunk-hec -n logging --timeout=900s
kubectl wait --for=condition=ready pod -l app=splunk-hec \
  -n logging --timeout=900s

echo "Waiting for Splunk management API..."
ready=false
for _ in $(seq 1 120); do
  code="$(splunk_http_code "https://127.0.0.1:8089/services/server/info" 2>/dev/null || true)"
  if [[ "${code}" == "200" ]]; then
    ready=true
    break
  fi
  sleep 10
done
if [[ "${ready}" != "true" ]]; then
  echo "Splunk management API did not become ready (last HTTP ${code})." >&2
  exit 1
fi

echo "Enabling remote Splunk management API login..."
splunk_enable_remote_login

echo "Waiting for Splunk KV Store..."
kv_ready=false
for _ in $(seq 1 120); do
  status="$(
    splunk_curl "https://127.0.0.1:8089/services/kvstore/status/status?output_mode=json" 2>/dev/null \
      | sed -n 's/.*"status":"\([^"]*\)".*/\1/p' | head -1
  )"
  if [[ "${status}" == "ready" ]]; then
    kv_ready=true
    break
  fi
  if [[ "${status}" == "failed" ]]; then
    echo "KV Store status is failed; check mongod.log in the Splunk pod." >&2
  fi
  sleep 10
done
if [[ "${kv_ready}" != "true" ]]; then
  echo "Splunk KV Store did not become ready (last status: ${status:-unknown})." >&2
  exit 1
fi

echo "Verifying remote Splunk management API access..."
remote_code="$(
  kubectl run splunk-api-check --rm -i --restart=Never -n logging \
    --image=curlimages/curl:latest --quiet -- \
    curl -sk -o /dev/null -w "%{http_code}" \
    -u "admin:${SPLUNK_PASSWORD}" \
    "https://splunk-hec:8089/services/server/info" 2>/dev/null \
    | tr -cd '0-9'
)"
if [[ "${remote_code}" != "200" ]]; then
  echo "Remote Splunk API check failed (HTTP ${remote_code:-none}); Tekton Results cannot reach Splunk." >&2
  exit 1
fi

configure_tekton_results_splunk
check_splunk_pids || true
