#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export KUBECONFIG="${KUBECONFIG:-${SCRIPT_DIR}/kubeconfig}"

RESULTS_API="${RESULTS_API:-https://tekton-results-api-service.tekton-pipelines.svc:8080}"
EXTERNAL_LOGS_URL="${EXTERNAL_LOGS_URL:-http://tekton-logs-proxy.tekton-pipelines.svc:8080/logs}"

cat <<'EOF' | oc apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: tekton-logs-proxy
  namespace: tekton-pipelines
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: tekton-logs-proxy
rules:
  - apiGroups: ["tekton.dev"]
    resources: ["taskruns"]
    verbs: ["get", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: tekton-logs-proxy
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: tekton-logs-proxy
subjects:
  - kind: ServiceAccount
    name: tekton-logs-proxy
    namespace: tekton-pipelines
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: tekton-logs-proxy-results-readonly
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: tekton-results-readonly
subjects:
  - kind: ServiceAccount
    name: tekton-logs-proxy
    namespace: tekton-pipelines
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: tekton-logs-proxy
  namespace: tekton-pipelines
data:
  server.py: |
    #!/usr/bin/env python3
    import http.server
    import json
    import os
    import re
    import ssl
    import urllib.error
    import urllib.request

    RESULTS_API = os.environ.get("RESULTS_API", "https://tekton-results-api-service.tekton-pipelines.svc:8080")
    TOKEN_PATH = "/var/run/secrets/kubernetes.io/serviceaccount/token"
    CA_PATH = "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"

    def sa_token():
        with open(TOKEN_PATH, "r", encoding="utf-8") as handle:
            return handle.read().strip()

    def k8s_request(path):
        ctx = ssl.create_default_context(cafile=CA_PATH)
        req = urllib.request.Request(
            f"https://kubernetes.default.svc{path}",
            headers={"Authorization": f"Bearer {sa_token()}"},
        )
        with urllib.request.urlopen(req, context=ctx, timeout=30) as resp:
            return json.load(resp)

    def results_request(path):
        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        req = urllib.request.Request(
            f"{RESULTS_API}{path}",
            headers={"Authorization": f"Bearer {sa_token()}"},
        )
        with urllib.request.urlopen(req, context=ctx, timeout=120) as resp:
            return resp.read().decode("utf-8", errors="replace")

    def taskrun_for_pod(namespace, pod):
        taskrun_name = pod[:-4] if pod.endswith("-pod") else pod
        return k8s_request(f"/apis/tekton.dev/v1/namespaces/{namespace}/taskruns/{taskrun_name}")

    def filter_logs(text, container):
        pattern = re.compile(rf"(?:^|\n){re.escape(container)}:-\n(.*?)(?=\n[^:\n]+:-\n|\Z)", re.S)
        match = pattern.search(text)
        if match:
            return match.group(1).strip() + "\n"
        return text

    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, fmt, *args):
            return

        def do_GET(self):
            match = re.match(r"/logs/([^/]+)/([^/]+)/([^/?]+)", self.path)
            if not match:
                self.send_error(404, "expected /logs/<namespace>/<pod>/<container>")
                return

            namespace, pod, container = match.groups()
            try:
                taskrun = taskrun_for_pod(namespace, pod)
                record_id = taskrun["metadata"]["uid"]
                result = taskrun["metadata"]["annotations"].get("results.tekton.dev/result", "")
                result_name = result.rsplit("/", 1)[-1]
                if not result_name:
                    raise RuntimeError("taskrun missing results.tekton.dev/result annotation")

                logs = results_request(
                    f"/apis/results.tekton.dev/v1alpha2/parents/{namespace}/results/{result_name}/logs/{record_id}"
                )
                body = filter_logs(logs, container).encode("utf-8")
                self.send_response(200)
                self.send_header("Content-Type", "text/plain; charset=utf-8")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
            except urllib.error.HTTPError as err:
                self.send_error(err.code, err.reason)
            except Exception as err:  # noqa: BLE001
                self.send_error(500, str(err))

    if __name__ == "__main__":
        http.server.HTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: tekton-logs-proxy
  namespace: tekton-pipelines
  labels:
    app: tekton-logs-proxy
spec:
  replicas: 1
  selector:
    matchLabels:
      app: tekton-logs-proxy
  template:
    metadata:
      labels:
        app: tekton-logs-proxy
    spec:
      serviceAccountName: tekton-logs-proxy
      containers:
      - name: proxy
        image: docker.io/library/python:3.12-alpine
        command: ["python3", "/app/server.py"]
        env:
        - name: RESULTS_API
          value: "RESULTS_API_PLACEHOLDER"
        ports:
        - containerPort: 8080
          name: http
        volumeMounts:
        - name: app
          mountPath: /app
          readOnly: true
      volumes:
      - name: app
        configMap:
          name: tekton-logs-proxy
          defaultMode: 0555
---
apiVersion: v1
kind: Service
metadata:
  name: tekton-logs-proxy
  namespace: tekton-pipelines
spec:
  selector:
    app: tekton-logs-proxy
  ports:
  - name: http
    port: 8080
    targetPort: 8080
EOF

kubectl set env deployment/tekton-logs-proxy -n tekton-pipelines \
  RESULTS_API="${RESULTS_API}" --containers=proxy

echo "Waiting for tekton-logs-proxy..."
kubectl rollout status deployment/tekton-logs-proxy -n tekton-pipelines --timeout=120s

echo "Configuring Tekton Dashboard external logs fallback..."
export EXTERNAL_LOGS_URL
kubectl get deployment tekton-dashboard -n tekton-pipelines -o json | python3 -c "
import json, os, sys
dep = json.load(sys.stdin)
args = dep['spec']['template']['spec']['containers'][0]['args']
external = '--external-logs=' + os.environ['EXTERNAL_LOGS_URL']
replaced = False
for i, arg in enumerate(args):
    if arg.startswith('--external-logs='):
        args[i] = external
        replaced = True
        break
if not replaced:
    args.append(external)
dep['spec']['template']['spec']['containers'][0]['args'] = args
json.dump(dep, sys.stdout)
" | kubectl apply -f -

kubectl rollout status deployment/tekton-dashboard -n tekton-pipelines --timeout=120s

external_logs_url="$(
  kubectl get deployment tekton-dashboard -n tekton-pipelines -o json \
    | python3 -c "
import json, sys
args = json.load(sys.stdin)['spec']['template']['spec']['containers'][0]['args']
for arg in args:
    if arg.startswith('--external-logs='):
        print(arg.split('=', 1)[1])
        break
"
)"

if [[ -z "${external_logs_url}" ]]; then
  echo "Tekton Dashboard --external-logs is empty; external log fallback will not work." >&2
  exit 1
fi

echo "Dashboard external logs configured (${EXTERNAL_LOGS_URL})."
echo "End-to-end log verification runs after ./08-run-pipeline.sh."
