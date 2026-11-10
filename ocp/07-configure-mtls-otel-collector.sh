#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export KUBECONFIG="${KUBECONFIG:-${SCRIPT_DIR}/kubeconfig}"
NAMESPACE=openshift-logging
NAMESPACE_PIPELINE=openshift-pipelines
NAMESPACE_OTEL=openshift-opentelemetry-operator

echo "Waiting for OpenTelemetry Operator..."
kubectl wait --for=condition=Available \
  deployment/opentelemetry-operator-controller-manager \
  -n ${NAMESPACE_OTEL} --timeout=300s

cat <<'EOF' | kubectl apply -f-
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: selfsigned-issuer
spec:
  selfSigned: {}
EOF

cat <<'EOF' | kubectl -n openshift-logging apply -f-
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: local-ca
  namespace: openshift-logging
spec:
  commonName: logging-ca
  isCA: true
  issuerRef:
    group: cert-manager.io
    kind: ClusterIssuer
    name: selfsigned-issuer
  privateKey:
    algorithm: ECDSA
    size: 256
  secretName: local-ca-root-secret
  subject:
    countries:
      - US
    organizationalUnits:
      - Logging Lab
    organizations:
      - Example
EOF

cat <<'EOF' | kubectl -n openshift-logging apply -f-
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: selfsigned-issuer
  namespace: openshift-logging
spec:
  ca:
    secretName: local-ca-root-secret
EOF

cat <<'EOF' | kubectl -n openshift-logging apply -f-
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: selfsigned-issuer
  namespace: openshift-logging
spec:
  ca:
    secretName: local-ca-root-secret
EOF

cat <<'EOF' | kubectl -n openshift-logging apply -f-
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: tekton-logger-collector
  namespace: openshift-logging
spec:
  commonName: OTC client
  dnsNames:
    - tekton-logger-collector.openshift-logging.svc.cluster.local
    - tekton-logger-collector.openshift-logging.svc
    - tekton-logger-collector
  isCA: false
  issuerRef:
    group: cert-manager.io
    kind: Issuer
    name: selfsigned-issuer
  privateKey:
    algorithm: ECDSA
    size: 256
  secretName: tekton-logger-collector-certificate
  duration: 60m
  renewBefore: 55m
  subject:
    countries:
      - US
    organizationalUnits:
      - Logging Lab
    organizations:
      - Example
      - OTC Client
  usages:
    - "client auth"
EOF

cat <<'EOF' | kubectl -n openshift-logging apply -f-
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: splunk-hec
  namespace: openshift-logging
spec:
  commonName: Splunk HEC
  dnsNames:
    - splunk-hec.openshift-logging.svc.cluster.local
    - splunk-hec.openshift-logging.svc
    - splunk-hec
  isCA: false
  issuerRef:
    group: cert-manager.io
    kind: Issuer
    name: selfsigned-issuer
  privateKey:
    algorithm: ECDSA
    size: 256
  secretName: splunk-hec-certificate
  duration: 60m
  renewBefore: 55m
  subject:
    countries:
      - US
    organizationalUnits:
      - Logging Lab
    organizations:
      - Example
      - Splunk HEC
  usages:
    - "server auth"
EOF

cat <<'EOF' | kubectl -n openshift-logging apply -f-
apiVersion: opentelemetry.io/v1beta1
kind: OpenTelemetryCollector
metadata:
  name: splunk-hec-sidecar
  namespace: openshift-logging
spec:
  config:
    exporters:
      debug:
        verbosity: detailed
      splunk_hec:
        endpoint: https://127.0.0.1:8088/services/collector/event
        index: main
        source: openshift-pipelines
        sourcetype: tekton:logs
        tls:
          insecure_skip_verify: true
        token: 11111111-2222-3333-4444-555555555555
    receivers:
      otlp:
        protocols:
          http:
            endpoint: "0.0.0.0:4318"
            tls:
              ca_file: /etc/certs/server/ca.crt
              cert_file: /etc/certs/server/tls.crt
              client_ca_file: /etc/certs/server/ca.crt
              key_file: /etc/certs/server/tls.key
              max_version: '1.3'
              min_version: '1.3'
              reload_interval: 1m
          grpc:
            endpoint: "0.0.0.0:4317"
            tls:
              ca_file: /etc/certs/server/ca.crt
              cert_file: /etc/certs/server/tls.crt
              client_ca_file: /etc/certs/server/ca.crt
              key_file: /etc/certs/server/tls.key
              max_version: '1.3'
              min_version: '1.3'
              reload_interval: 1m
    service:
      pipelines:
        logs:
          exporters:
            - splunk_hec
          receivers:
            - otlp
      telemetry:
        metrics:
          readers:
            - pull:
                exporter:
                  prometheus:
                    host: 0.0.0.0
                    port: 8888
  configVersions: 3
  httpRoute:
    enabled: false
    gateway: ''
  image: docker.io/otel/opentelemetry-collector-contrib:0.158.0
  managementState: managed
  mode: sidecar
  replicas: 1
  upgradeStrategy: automatic
  serviceAccount: default
  volumeMounts:
    - mountPath: /etc/certs/server
      name: server-certs
      readOnly: true
  volumes:
    - name: server-certs
      secret:
        defaultMode: 256
        items:
          - key: ca.crt
            path: ca.crt
          - key: tls.crt
            path: tls.crt
          - key: tls.key
            path: tls.key
        secretName: splunk-hec-certificate
        defaultMode: 420
EOF

oc -n openshift-logging patch deploy/splunk-hec --type=merge -p '{"spec":{"template":{"metadata":{"annotations":{"sidecar.opentelemetry.io/inject":"splunk-hec-sidecar"}}}}}'
oc -n openshift-logging patch service splunk-hec --type merge -p '{"spec":{"ports":[{"name":"otlp-grpc","port":4317,"targetPort":4317},{"name":"otlp-http","port":4318,"targetPort":4318},{"name":"splunk-http","port":8000,"targetPort":8000},{"name":"api","port":8089,"targetPort":8089}]}}'

cat <<'EOF' | oc apply -f-
apiVersion: opentelemetry.io/v1beta1
kind: OpenTelemetryCollector
metadata:
  name: tekton-logger
  namespace: openshift-logging
spec:
  mode: daemonset
  image: docker.io/otel/opentelemetry-collector-contrib:0.158.0
  # OpenShift: host /var/log/pods is root:root 0750 + container_var_lib_t.
  # Need UID 0 and SELinux type spc_t (allowed by our custom SCC).
  podAnnotations:
    openshift.io/required-scc: otel-clusterlogs-collector-scc
  securityContext:
    runAsUser: 0
    seLinuxOptions:
      type: spc_t
    readOnlyRootFilesystem: true
    allowPrivilegeEscalation: false
    seccompProfile:
      type: RuntimeDefault
    capabilities:
      drop:
        - ALL
  volumes:
    - name: varlogpods
      hostPath:
        path: /var/log/pods
    - name: client-certs
      secret:
        defaultMode: 420
        items:
          - key: ca.crt
            path: ca.crt
          - key: tls.crt
            path: tls.crt
          - key: tls.key
            path: tls.key
        secretName: tekton-logger-collector-certificate
  volumeMounts:
    - name: varlogpods
      mountPath: /var/log/pods
      readOnly: true
    - mountPath: /etc/certs/client
      name: client-certs
      readOnly: true

  config:
    receivers:
      file_log/pipelines:
        include:
          - /var/log/pods/default_*/*/*.log
        exclude:
          - /var/log/pods/openshift-logging_*/*/*.log
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
        auth:
          authenticator: bearertokenauth
        endpoint: https://lokistack-gateway-http.openshift-logging.svc.cluster.local:8080/api/logs/v1/application/otlp
        tls:
          ca_file: /var/run/secrets/kubernetes.io/serviceaccount/service-ca.crt
      otlp_http/splunk_hec:
        endpoint: https://splunk-hec:4318
        tls:
          ca_file: /etc/certs/client/ca.crt
          cert_file: /etc/certs/client/tls.crt
          insecure: false
          key_file: /etc/certs/client/tls.key
          max_version: '1.3'
          min_version: '1.3'
          reload_interval: 1m
      debug:
        verbosity: detailed

    extensions:
      bearertokenauth:
        filename: /var/run/secrets/kubernetes.io/serviceaccount/token

    service:
      extensions:
        - bearertokenauth
      pipelines:
        logs:
          exporters:
            - otlp_http/splunk_hec
            - otlp_http/loki
          processors:
            - k8s_attributes
            - transform/k8sattributes
            - transform/clf
            - transform/tekton_splunk_lookup
            - transform/tekton_assistant
            - redaction/cc
            - redaction/creds
          receivers:
            - file_log/pipelines
        logs/events:
          exporters:
            - otlp_http/splunk_hec
            - otlp_http/loki
          processors:
            - transform/tekton_pod_lookup
            - k8s_attributes/events
            - transform/k8sattributes
            - transform/clf
            - transform/tekton_splunk_lookup
            - transform/tekton_assistant
            - redaction/cc
            - redaction/creds
            - log_dedup/tekton
          receivers:
            - k8s_events
        logs/pipelineruns:
          exporters:
            - otlp_http/splunk_hec
            - otlp_http/loki
          processors:
            - transform/pipelinerun_status
            - transform/k8sattributes
            - transform/clf
            - transform/tekton_splunk_lookup
            - transform/tekton_assistant
            - redaction/cc
            - redaction/creds
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
kubectl rollout status daemonset/tekton-logger-collector -n ${NAMESPACE} --timeout=300s
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=tekton-logger-collector \
  -n ${NAMESPACE} --timeout=300s
