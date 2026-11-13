#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export KUBECONFIG="${KUBECONFIG:-${SCRIPT_DIR}/kubeconfig}"

kubectl create namespace logging --dry-run=client -o yaml | kubectl apply -f -

cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: tekton-collector
  namespace: logging
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: tekton-collector-role
rules:
- apiGroups: [""]
  resources: ["pods", "namespaces", "nodes"]
  verbs: ["get", "watch", "list"]
- apiGroups: ["apps"]
  resources: ["replicasets"]
  verbs: ["get", "watch", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: tekton-collector-rolebinding
subjects:
- kind: ServiceAccount
  name: tekton-collector
  namespace: logging
roleRef:
  kind: ClusterRole
  name: tekton-collector-role
  apiGroup: rbac.authorization.k8s.io
EOF

echo "Waiting for logging namespace resources..."
kubectl wait --for=jsonpath='{.metadata.name}'=logging namespace/logging --timeout=60s
kubectl wait --for=jsonpath='{.metadata.name}'=tekton-collector \
  serviceaccount/tekton-collector -n logging --timeout=60s
