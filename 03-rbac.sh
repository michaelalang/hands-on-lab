#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export KUBECONFIG="${KUBECONFIG:-${SCRIPT_DIR}/kubeconfig}"

cat <<'EOF' | oc apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: tekton-collector
rules:
  - apiGroups:
      - ''
    resources:
      - pods
      - namespaces
      - nodes
      - events
    verbs:
      - get
      - watch
      - list
  - apiGroups:
      - apps
    resources:
      - replicasets
      - deployments
      - statefulsets
      - daemonsets
    verbs:
      - get
      - list
      - watch
  - apiGroups:
      - batch
    resources:
      - jobs
    verbs:
      - get
      - list
      - watch
  - apiGroups:
      - tekton.dev
    resources:
      - pipelineruns
    verbs:
      - get
      - list
      - watch
  - apiGroups:
      - extensions
    resources:
      - replicasets
    verbs:
      - get
      - list
      - watch
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: tekton-collector
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: tekton-collector
subjects:
  - kind: ServiceAccount
    name: tekton-collector
    namespace: logging
EOF

echo "Waiting for tekton-collector RBAC..."
kubectl wait --for=jsonpath='{.metadata.name}'=tekton-collector \
  clusterrole/tekton-collector --timeout=60s
kubectl wait --for=jsonpath='{.metadata.name}'=tekton-collector \
  clusterrolebinding/tekton-collector --timeout=60s
