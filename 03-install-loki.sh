#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export KUBECONFIG="${KUBECONFIG:-${SCRIPT_DIR}/kubeconfig}"

helm repo add grafana https://grafana.github.io/helm-charts
helm repo update

cat <<'EOF' > /tmp/loki-values.yaml
deploymentMode: SingleBinary

loki:
  auth_enabled: false
  commonConfig:
    replication_factor: 1
  useTestSchema: true
  storage:
    type: filesystem
    bucketNames:
      chunks: chunks
      ruler: ruler
      admin: admin
  limits_config:
    allow_structured_metadata: true

singleBinary:
  replicas: 1

gateway:
  enabled: false

test:
  enabled: false

lokiCanary:
  enabled: false

chunksCache:
  enabled: false

resultsCache:
  enabled: false

backend:
  replicas: 0
read:
  replicas: 0
write:
  replicas: 0
ingester:
  replicas: 0
querier:
  replicas: 0
queryFrontend:
  replicas: 0
queryScheduler:
  replicas: 0
distributor:
  replicas: 0
compactor:
  replicas: 0
indexGateway:
  replicas: 0
bloomCompactor:
  replicas: 0
bloomGateway:
  replicas: 0
EOF

helm upgrade --install loki grafana/loki \
  --namespace logging \
  --create-namespace \
  --values /tmp/loki-values.yaml

cat <<'EOF' > /tmp/grafana-values.yaml
adminPassword: admin

datasources:
  datasources.yaml:
    apiVersion: 1
    datasources:
      - name: Loki
        type: loki
        url: http://loki:3100
        access: proxy
EOF

helm upgrade --install grafana grafana/grafana \
  --namespace logging \
  --values /tmp/grafana-values.yaml

echo "Waiting for Loki to be ready..."
kubectl rollout status statefulset/loki -n logging --timeout=300s
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=loki,app.kubernetes.io/component=single-binary \
  -n logging --timeout=300s

echo "Waiting for Grafana to be ready..."
kubectl rollout status deployment/grafana -n logging --timeout=300s
