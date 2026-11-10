#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export KUBECONFIG="${KUBECONFIG:-${SCRIPT_DIR}/kubeconfig}"

echo "Waiting for OpenTelemetry Operator..."
kubectl wait --for=condition=Available \
  deployment/opentelemetry-operator-controller-manager \
  -n opentelemetry-operator-system --timeout=300s

echo "Waiting for log backends..."
kubectl rollout status statefulset/loki -n logging --timeout=300s
kubectl rollout status deployment/splunk-hec -n logging --timeout=600s

if kubectl get deployment tekton-results-api -n tekton-pipelines >/dev/null 2>&1; then
  echo "Waiting for Tekton Results API..."
  kubectl rollout status deployment/tekton-results-api -n tekton-pipelines --timeout=300s
fi

cat <<'EOF' | kubectl apply -f-
apiVersion: opentelemetry.io/v1beta1
kind: OpenTelemetryCollector
metadata:
  name: tekton-logger
  namespace: logging
spec:
  mode: daemonset
  serviceAccount: tekton-collector
  image: docker.io/otel/opentelemetry-collector-contrib:0.158.0
  volumes:
    - name: varlogpods
      hostPath:
        path: /var/log/pods
  volumeMounts:
    - name: varlogpods
      mountPath: /var/log/pods
      readOnly: true
  config:
    receivers:
      file_log/pipelines:
        include:
          - /var/log/pods/default_*/*/*.log
        exclude:
          - /var/log/pods/logging_*/*/*.log
        start_at: beginning
        # Tell file_log to attach the path attribute so the container operator can read it
        include_file_path: true
        operators:
          - type: container

      k8s_events:
        auth_type: serviceAccount
        namespaces:
          - default

      k8s_objects/pipelineruns:
        auth_type: serviceAccount
        objects:
          - group: tekton.dev
            mode: watch
            name: pipelineruns


    processors:
      batch: {}
      k8s_attributes:
        auth_type: serviceAccount
        passthrough: false
        extract:
          metadata:
            - k8s.pod.name
            - k8s.namespace.name
            - k8s.node.name
          annotations:
            - key: results.tekton.dev/result
              tag_name: tekton_results_result
            - key: results.tekton.dev/record
              tag_name: tekton_results_record
            - key: pipeline.openshift.io/started-by
              tag_name: tekton_started_by
          labels:
            - key: tekton.dev/pipeline
              tag_name: tekton_pipeline
            - key: tekton.dev/pipelineRun
              tag_name: tekton_pipelinerun
            - key: tekton.dev/task
              tag_name: tekton_task
            - key: tekton.dev/taskRun
              tag_name: tekton_taskrun
            - key: tekton.dev/pipelineRunUID
              tag_name: tekton_pipelinerunuid
            - key: tekton.dev/taskRunUID
              tag_name: tekton_taskrunuid
        pod_association:
          - sources:
              - from: resource_attribute
                name: k8s.pod.uid
          - sources:
              - from: resource_attribute
                name: k8s.pod.name
              - from: resource_attribute
                name: k8s.namespace.name
      k8s_attributes/events:
        auth_type: serviceAccount
        extract:
          annotations:
            - from: pod
              key: tekton.dev/tags
              tag_name: tekton_tags
            - from: pod
              key: pipeline.openshift.io/started-by
              tag_name: tekton_started-by
            - from: pod
              key: tekton.dev/displayName
              tag_name: tekton_displayname
            - from: pod
              key: results.tekton.dev/record
              tag_name: tekton_results_record
            - from: pod
              key: results.tekton.dev/result
              tag_name: tekton_results_result
            - from: pod
              key: tekton.dev/categories
              tag_name: tekton_categories
            - from: pod
              key: pipeline.tekton.dev/affinity-assistant
              tag_name: tekton_affinity-assistant
          labels:
            - from: pod
              key: tekton.dev/pipeline
              tag_name: tekton_pipeline
            - from: pod
              key: tekton.dev/pipelineRun
              tag_name: tekton_pipelinerun
            - from: pod
              key: tekton.dev/task
              tag_name: tekton_task
            - from: pod
              key: tekton.dev/pipelineTask
              tag_name: tekton_pipelinetask
            - from: pod
              key: tekton.dev/taskRun
              tag_name: tekton_taskrun
            - from: pod
              key: tekton.dev/pipelineRunUID
              tag_name: tekton_pipelinerunuid
            - from: pod
              key: tekton.dev/taskRunUID
              tag_name: tekton_taskrunuid
        passthrough: false
        pod_association:
          - sources:
              - from: resource_attribute
                name: k8s.pod.uid
          - sources:
              - from: resource_attribute
                name: k8s.pod.name
              - from: resource_attribute
                name: k8s.namespace.name

      log_dedup/tekton:
        include_fields:
        - attributes.tekton_taskrunuid
        - attributes.tekton_pipelinerunuid
        - attributes.tekton_pipelinetask
        - attributes.tekton_pipelinerun
        - attributes.tekton_pipeline
        interval: 60s


      transform/k8sattributes:
        error_mode: ignore
        log_statements:
          - merge_maps(log.attributes, resource.attributes, "upsert")
      transform/pipelinerun_status:
        error_mode: ignore
        log_statements:
          - context: log
            statements:
              - set(log.attributes["k8s.namespace.name"], log.body["object"]["metadata"]["namespace"])
              - set(log.attributes["k8s.object.name"], log.body["object"]["metadata"]["name"])
              - set(log.attributes["k8s.object.uid"], log.body["object"]["metadata"]["uid"])
              - set(log.attributes["k8s.object.kind"], "PipelineRun")
              - set(log.attributes["tekton_pipelinerun"], log.body["object"]["metadata"]["name"])
              - set(log.attributes["tekton_pipelinerunuid"], log.body["object"]["metadata"]["uid"])
              - set(log.attributes["tekton_pipeline"], log.body["object"]["metadata"]["labels"]["tekton.dev/pipeline"])
              - set(log.attributes["tekton_tags"], log.body["object"]["metadata"]["annotations"]["tekton.dev/tags"])
              - set(log.attributes["tekton_started-by"], log.body["object"]["metadata"]["annotations"]["pipeline.openshift.io/started-by"])
              - set(log.attributes["tekton_displayname"], log.body["object"]["metadata"]["annotations"]["tekton.dev/displayName"])
              - set(log.attributes["tekton_results_record"], log.body["object"]["metadata"]["annotations"]["results.tekton.dev/record"])
              - set(log.attributes["tekton_results_result"], log.body["object"]["metadata"]["annotations"]["results.tekton.dev/result"])
              - set(log.attributes["tekton_categories"], log.body["object"]["metadata"]["annotations"]["tekton.dev/categories"])
              - set(log.attributes["tekton_affinity-assistant"], log.body["object"]["metadata"]["annotations"]["pipeline.tekton.dev/affinity-assistant"])
              - set(log.body, log.body["object"]["status"])
              - set(log.attributes["otc.node_name"], "${KUBE_NODE_NAME}")
      transform/tekton_assistant:
        error_mode: ignore
        log_statements:
          - set(log.attributes["tekton_task"], "affinity-assistant") where log.attributes["tekton_pipelinerun"]
            != nil and log.attributes["tekton_task"] == nil
          - set(log.attributes["tekton_pipelinetask"], "affinity-assistant") where
            log.attributes["tekton_pipelinerun"] != nil and log.attributes["tekton_pipelinetask"]
            == nil
      transform/tekton_pod_lookup:
        error_mode: ignore
        log_statements:
          - conditions:
              - resource.attributes["k8s.object.kind"] == "Pod"
            context: resource
            statements:
              - set(resource.attributes["k8s.pod.uid"], resource.attributes["k8s.object.uid"])
              - set(resource.attributes["k8s.pod.name"], resource.attributes["k8s.object.name"])
          - conditions:
              - resource.attributes["k8s.object.kind"] == "TaskRun"
            context: resource
            statements:
              - set(resource.attributes["k8s.pod.name"], Concat([resource.attributes["k8s.object.name"],
                "-pod"], ""))
      transform/tekton_splunk_lookup:
        error_mode: ignore
        log_statements:
          - context: log
            statements:
              - set(resource.attributes["kubernetes.labels.tekton_dev_taskRunUID"],
                log.attributes["tekton_taskrunuid"]) where log.attributes["tekton_taskrunuid"]
                != nil
              - set(log.attributes["kubernetes.labels.tekton_dev_taskRunUID"], log.attributes["tekton_taskrunuid"])
                where log.attributes["tekton_taskrunuid"] != nil
              - set(resource.attributes["kubernetes.labels.tekton_dev_pipelineRunUID"],
                log.attributes["tekton_pipelinerunuid"]) where log.attributes["tekton_pipelinerunuid"]
                != nil
              - set(log.attributes["kubernetes.labels.tekton_dev_pipelineRunUID"],
                log.attributes["tekton_pipelinerunuid"]) where log.attributes["tekton_pipelinerunuid"]
                != nil
              - set(log.attributes["kubernetes_namespace_name"], log.attributes["k8s.namespace.name"])
                where log.attributes["k8s.namespace.name"] != nil
              - set(log.attributes["kubernetes.container_name"], log.attributes["k8s.container.name"])
              - set(log.attributes["message"], log.attributes["msg"]) where log.attributes["message"]
                == nil
              - set(log.attributes["message"], log.body) where log.attributes["message"]
                == nil

      transform/clf:
        error_mode: ignore
        log_statements:
          - context: log
            statements:
              - set(log.attributes["openshift.log.type"], "application")
              - set(resource.attributes["openshift.log.type"], "application")
              - set(log.attributes["openshift.log.source"], "tekton")
              - set(resource.attributes["openshift.log.source"], "tekton")
              - set(log.attributes["kubernetes.namespace_name"], log.attributes["k8s.namespace.name"])
              - set(resource.attributes["kubernetes.namespace_name"], log.attributes["k8s.namespace.name"])
              - set(log.attributes["log.type"], log.attributes["application"])
              - set(resource.attributes["log.type"], log.attributes["application"])
              - set(log.attributes["log.source"], log.attributes["tekton"])
              - set(resource.attributes["log.source"], log.attributes["tekton"])
              - set(log.attributes["openshift.cluster.name"], "${CLUSTERNAME}")
              - set(resource.attributes["openshift.cluster.name"], "${CLUSTERNAME}")

      redaction/cc:
        allow_all_keys: true
        redact_all_types: true
        summary: debug
        blocked_values:
          - "4[0-9]{12}(?:[0-9]{3})?"
          - "5[1-5][0-9]{14}"
          - "2(?:2[2-9][1-9]|2[3-9][0-9]|[3-6][0-9]{2}|7[01][0-9]|720)[0-9]{12}"
          - "3[47][0-9]{13}"
          - "6(?:011|5[0-9]{2})[0-9]{12}"
          - "35(?:2[89]|[3-8][0-9])[0-9]{12}"
          - "3(?:0[0-5]|[68][0-9])[0-9]{11}"
          - "62[0-9]{14}"
          - "(?:5018|5020|5038|6304|6759|676[1-3])[0-9]{8,15}"

      redaction/creds:
        allow_all_keys: true
        redact_all_types: true
        summary: debug
        blocked_values:
          - "//.+:.+@"


    exporters:
      splunk_hec:
        token: "11111111-2222-3333-4444-555555555555"
        endpoint: "https://splunk-hec:8088/services/collector/event"
        index: "main"
        source: "openshift-pipelines"
        sourcetype: "tekton:logs"
        tls:
          insecure_skip_verify: true
      otlp_http/loki:
        endpoint: http://loki:3100/otlp
        tls:
          insecure: true
      debug:
        verbosity: basic

    service:
      pipelines:
        logs:
          exporters:
            - splunk_hec
            - otlp_http/loki
          processors:
            - k8s_attributes
            - transform/k8sattributes
            - transform/clf
            - transform/tekton_splunk_lookup
            - transform/tekton_assistant
          receivers:
            - file_log/pipelines
        logs/events:
          exporters:
            - splunk_hec
            - otlp_http/loki
          processors:
            - transform/tekton_pod_lookup
            - k8s_attributes/events
            - transform/k8sattributes
            - transform/clf
            - transform/tekton_splunk_lookup
            - transform/tekton_assistant
            - log_dedup/tekton
          receivers:
            - k8s_events
        logs/pipelineruns:
          exporters:
            - splunk_hec
            - otlp_http/loki
          processors:
            - transform/pipelinerun_status
            - transform/k8sattributes
            - transform/clf
            - transform/tekton_splunk_lookup
            - transform/tekton_assistant
            - log_dedup/tekton
          receivers:
            - k8s_objects/pipelineruns

  env:
    - name: KUBE_NODE_NAME
      valueFrom:
        fieldRef:
          apiVersion: v1
          fieldPath: spec.nodeName
    - name: CLUSTERID
      value: b04bafb8-4d9e-4bb6-bea0-63dfc3953210
    - name: CLUSTERNAME
      value: handsonlab

EOF

echo "Waiting for OpenTelemetry Collector DaemonSet..."
kubectl rollout status daemonset/tekton-logger-collector -n logging --timeout=300s
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=tekton-logger-collector \
  -n logging --timeout=300s
