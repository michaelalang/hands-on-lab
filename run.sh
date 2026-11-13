#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

export KUBECONFIG="${KUBECONFIG:-${SCRIPT_DIR}/kubeconfig}"
export KIND_EXPERIMENTAL_PROVIDER="${KIND_EXPERIMENTAL_PROVIDER:-podman}"

./01-start-local-cluster.sh && \
./02-install-cert-manager.sh && \
./03-configure-namespace.sh && \
./03-rbac.sh && \
./03-install-loki.sh && \
./04-install-tekton.sh && \
./05-install-opentelemetry.sh && \
./06-install-splunk-hec.sh && \
./07-configure-otel-collector.sh && \
./04-configure-dashboard-logs.sh && \
./08-run-pipeline.sh

cat <<EOF

Hands-on lab is ready.

Verify:
  ./check-tekton.sh    # Dashboard on http://localhost:9097 after port-forward
  ./check-loki.sh
  ./check-splunk.sh

Demo scenario:
  - PipelineRun demo-pipeline-run completed with Tekton Results stored
  - Logs shipped to Splunk/Loki via OpenTelemetry
  - Dashboard external logs work after deleting task pods:
      kubectl delete pods -n default --all

EOF
