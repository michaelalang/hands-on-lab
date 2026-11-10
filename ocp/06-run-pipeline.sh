#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export KUBECONFIG="${KUBECONFIG:-${SCRIPT_DIR}/kubeconfig}"

# shellcheck source=lib/verify-external-logs.sh
source "${SCRIPT_DIR}/../lib/verify-external-logs.sh"

kubectl -n default delete pipeline,pipelinerun,tasks --all --ignore-not-found=true

cat <<'EOF' | kubectl apply -f-
apiVersion: tekton.dev/v1beta1
kind: Task
metadata:
  name: prepare
  namespace: default
spec:
  steps:
    - name: prepare
      image: bash
      script: |
        #!/usr/bin/env bash
        set -euo pipefail
        echo "Task prepare: checking workspace..."
        echo "Workspace ready."
---
apiVersion: tekton.dev/v1beta1
kind: Task
metadata:
  name: build
  namespace: default
spec:
  steps:
    - name: build
      image: bash
      script: |
        #!/usr/bin/env bash
        set -euo pipefail
        echo "Task build: compiling application..."
        echo "User information 4591675271559508"
        sleep 2
        echo "Build finished successfully."
---
apiVersion: tekton.dev/v1beta1
kind: Task
metadata:
  name: test
  namespace: default
spec:
  steps:
    - name: test
      image: bash
      script: |
        #!/usr/bin/env bash
        set -euo pipefail
        echo "Task test: running unit tests..."
        echo "  PASS test_logging"
        echo "  PASS test_pipeline"
        echo "All tests passed."
---
apiVersion: tekton.dev/v1beta1
kind: Task
metadata:
  name: publish
  namespace: default
spec:
  results:
    - name: release-tag
      description: Published release tag
  steps:
    - name: publish
      image: bash
      script: |
        #!/usr/bin/env bash
        set -euo pipefail
        TAG="v1.0.0-$(date +%s)"
        echo "Task publish: pushing release ${TAG}... docker://root:changeme@quay.example.com"
        echo -n "${TAG}" > "$(results.release-tag.path)"
        echo "Release ${TAG} published."
---
apiVersion: tekton.dev/v1beta1
kind: Pipeline
metadata:
  name: demo-pipeline
  namespace: default
spec:
  tasks:
    - name: prepare
      taskRef:
        name: prepare
    - name: build
      taskRef:
        name: build
      runAfter:
        - prepare
    - name: test
      taskRef:
        name: test
      runAfter:
        - build
    - name: publish
      taskRef:
        name: publish
      runAfter:
        - test
EOF

cat <<'EOF' | kubectl -n default create -f-
apiVersion: tekton.dev/v1beta1
kind: PipelineRun
metadata:
  generateName: demo-pipeline-run-
  namespace: default
  labels:
    tekton.dev/pipeline: demo-pipeline
  annotations:
    tekton.dev/displayName: Demo multi-task pipeline
    tekton.dev/tags: demo,logging
    results.tekton.dev/result: "default/results/demo-pipeline-run"
    pipeline.openshift.io/started-by: hands-on-lab
spec:
  pipelineRef:
    name: demo-pipeline
EOF

echo "PipelineRun demo-pipeline-run created. Waiting for completion..."
kubectl wait --for=condition=Succeeded pipelinerun -l tekton.dev/pipeline=demo-pipeline -n default --timeout=300s
kubectl get pipelinerun -l tekton.dev/pipeline=demo-pipeline -n default

echo "Demo pipeline complete."
