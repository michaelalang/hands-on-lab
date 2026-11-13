#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export KUBECONFIG="${KUBECONFIG:-${SCRIPT_DIR}/kubeconfig}"

cat <<'EOF' | kubectl apply -f-
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-operators-redhat
EOF

cat <<'EOF' | kubectl apply -f-
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: global-operators
  namespace: openshift-operators-redhat
spec:
  upgradeStrategy: Default
EOF

kubectl apply -f operators

kubectl patch console.operator.openshift.io cluster --type=json -p '[{"op": "add", "path": "/spec/plugins/-", "value": "pipelines-console-plugin"}]'
