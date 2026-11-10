# Hands-on Lab (OpenShift)

OpenShift lab with **Operator-based** deployments of OpenShift Pipelines (Tekton + Results), LokiStack, Splunk HEC, OpenTelemetry, and OpenShift console logging UI. Components are installed via OLM Subscriptions and configured with CRs (`LokiStack`, `TektonConfig`, `OpenTelemetryCollector`, `UIPlugin`).

## Architecture

Tekton Pipeline execution through to log storage and retrieval:

![Tekton Pipeline to Logs flow](../docs/tekton-to-logs-flow.svg)

1. **PipelineRun** creates TaskRun pods; step output is written to `/var/log/pods` on the node.
2. **OpenTelemetry Collector** (`tekton-logger` DaemonSet in `openshift-logging`) tails those logs, watches PipelineRuns and Kubernetes events, enriches records with Tekton labels / UIDs, and ships to **Splunk HEC** and **LokiStack** (via the gateway OTLP path). Day 1 uses a direct HEC export with TLS verify skipped; day 2 adds redaction and mutual TLS in front of Splunk (see [Day-2 operations](#day-2-operations)).
3. **Tekton Results** (OpenShift Pipelines Operator) records run metadata; the Results API is configured to fetch logs from Splunk by TaskRun UID.
4. **OpenShift Pipelines / Tekton Dashboard** can surface Splunk-backed logs after task pods are gone; the **Cluster Observability Operator** logging `UIPlugin` exposes LokiStack in the OpenShift console.

## Prerequisites

- An **OpenShift** cluster with:
  - **OLM** and access to `redhat-operators` in `openshift-marketplace`
  - **OpenShift Data Foundation / NooBaa** (or equivalent) so `ObjectBucketClaim` can provision S3 storage for LokiStack
  - Cluster-admin (or equivalent) to install Operators, SCCs, and cluster-scoped RBAC
- `kubectl` configured for that cluster (`oc login` is fine if you use it to obtain the kubeconfig)
- From this directory:

```bash
cd /path/to/hands-on-lab/ocp
export KUBECONFIG="$(pwd)/kubeconfig"   # or your cluster kubeconfig
```
- Using the instructions lab Pod deployment approach, the Pod runs with a Kubernetes Token bound to Cluster-Admin role. No Kubernetes configuration is necessary if you choose this method.


**Day-2b** also needs **cert-manager** (cert-manager Operator). A Subscription manifest is provided as `operators/cert-manager.disabled` — rename/apply it (or install cert-manager another way) before [Day-2b](#day-2b-mtls-log-forwarding-07-configure-mtls-otel-collectorsh).

## Script order

Run these scripts in order from this directory:

| Step | Script | What it does |
|------|--------|----------------|
| **1** | `./01-operators.sh` | Creates `openshift-operators-redhat` OperatorGroup, applies OLM Subscriptions under `operators/` (Loki Operator, OpenShift Pipelines, OpenTelemetry Operator, Cluster Observability Operator), and enables the Pipelines console plugin. |
| **2** | `./02-loki-storage.sh` | Creates `openshift-logging`, provisions an `ObjectBucketClaim` for LokiStack object storage, and builds the `lokistack-s3` secret. |
| **3** | `./03-install-splunk-hec.sh` | Deploys Splunk HEC into `openshift-logging` (anyuid SCC) and configures Tekton Results → Splunk when Results is present. |
| **4** | `./04-configure-openshift-pipelines.sh` | Applies instance CRs: `LokiStack`, logging `UIPlugin`, and `TektonConfig` (Pipelines + Results with Splunk log backend). |
| **5** | `./05-configure-otel-collector.sh` | SCC + RBAC for the collector; deploys `OpenTelemetryCollector/tekton-logger` DaemonSet → Splunk HEC + LokiStack gateway (defines optional `redaction/*` processors; not enabled until day 2). |
| **6** | `./06-run-pipeline.sh` | Demo pipeline run (includes sample card number + password URL for the day-2 redaction demo). |

Day-2 hardening (run after the demo pipeline has already shipped unredacted logs over the day-1 path):

| Step | Script / action | What it does |
|------|-----------------|--------------|
| **day-2a** | Edit `tekton-logger` (or use day-2b) | Enable `redaction/cc` + `redaction/creds` so card numbers and passwords are masked before long-term storage. |
| **day-2b** | `./07-configure-mtls-otel-collector.sh` | Issues a lab CA + mTLS certs (cert-manager), injects an OTel sidecar in front of Splunk HEC, and retargets `tekton-logger` to export over OTLP/HTTPS with client certs (also wires redaction into the pipelines). |
| **day-2c** | Verify mTLS with `curl` | Prove the Splunk OTLP front door rejects plaintext, unverified, and unauthenticated clients, then succeed with lab CA + client cert + correct hostname. |

## OpenShift instructions pod Setup

**NOTE** cloning this repo expects it to be named `hands-on-lab`. If you change this please adjust the base path cd accordingly.

browse to the pod (instructions-...) in namespace `lab` and execeute the following commands in the Terminal.

```bash
git clone https://github.com/michaelalang/hands-on-lab.git
cd hands-on-lab/ocp
```

* First install the mandatory operators be executing following command

```
./01-operators.sh
```

* Second, configure S3 Buckets space in OpenShift DataFoundation for the Loki Stack

```
./02-loki-storage.sh
```

* Third, install Splun-HEC as long-term compliance storage solution.

```
./03-install-splunk-hec.sh
```

* Fourth, configure OpenShift Pipelines to utilize the Results in API to retrieve reconciled pod logs from the long-term Storage.

```
./04-configure-openshift-pipelines.sh
```

* Fifth, configure OpenTelemetryCollector as log and event collector feeding both the Loki Stack as well as the Splunk-Hec long-term store.

```
./05-configure-otel-collector.sh
```

* Sixth, (repeatable) run a Demo Pipeline creating logs and events accordingly.

```
./06-run-pipeline.sh
```

* Seven, open the OpenShift UI on `Observe` Logs and search for the Pipeline run using following Query prompt

```
{ openshift_log_type="application" } | tekton_pipelinerun=~"demo-pipeline-run-.+" # or explicit pipelinerun name as returned in ./06-run-pipeline.sh
```

* Eight, open the OpenShift UI on `Pipelines`. Switch `Project` to `default` and open the `Last run` item. Open the Logs of the PipelineRun.

* Nine, delete all pods in the PipelineRun by executing following command in the `instructions` Pod in the `lab` namespace.

```
kubectl -n default delete pod --all
```

* Ten, revisit the PipelineRun logs and check that the Task logs return 

```
Unable to access log for build task
```

* Eleven, execute the following command in the `instructions` Pod in namespace `lab` to enable the admin accessToken

```
./03-install-splunk-hec.sh
```

* Twelve, execute the following command to update the TektonResults cluster config with the value

```
kubectl -n openshift-pipelines delete pod -l app.kubernetes.io/name=tekton-results-api
```

* Thirteen, execute another PipelineRun by executing following command

```
./06-run-pipeline.sh
```

* Fourteen, wait the pipeline run to finish and re-evaluate the Logs with the pods present and after deleting.

```
kubectl -n default delete pod --all
```

* Fifthteen, you should now be able to still retrieve the Task logs even though the pods have been reconciled.


After step 1, wait until Operator CSVs are Succeeded and related pods are Ready before continuing (especially Pipelines, Loki, OpenTelemetry, and COO).

## Operators and instance CRs

| Operator (OLM) | Namespace / location | Instance CR(s) |
|----------------|----------------------|----------------|
| Loki Operator | `openshift-operators-redhat` | `LokiStack/lokistack` in `openshift-logging` |
| OpenShift Pipelines | `openshift-operators` | `TektonConfig/config` → `openshift-pipelines` |
| Red Hat build of OpenTelemetry | `openshift-opentelemetry-operator` | `OpenTelemetryCollector/tekton-logger` (+ day-2 sidecar) |
| Cluster Observability Operator | `openshift-cluster-observability-operator` | `UIPlugin/logging` |
| cert-manager (day 2) | optional; see `operators/cert-manager.disabled` | ClusterIssuer / Certificate / Issuer for mTLS |

Splunk HEC is a lab Deployment (not an Operator) in `openshift-logging`.

## Log UIs

After the demo pipeline completes, logs are visible in the backends configured by the lab. Day-2 screenshots (redacted values) are under [Day-2 operations](#day-2-operations).

### OpenShift Pipelines UI

Pipeline and task step logs in the OpenShift Pipelines console (including Splunk-backed retrieval when task pods are gone):

![OpenShift Pipelines UI](../docs/OpenShift-Pipeline-UI.png)

### OpenShift Logs UI (LokiStack)

Tekton logs shipped by the OpenTelemetry collector to LokiStack, explored via the COO logging plugin:

![OpenShift Logs UI](../docs/OpenShift-Logs-UI.png)

### Splunk HEC

The same pipeline logs indexed in Splunk (`index=main`, `sourcetype=tekton:logs`), used by Tekton Results for log retrieval:

![OpenShift Splunk UI](../docs/OpenShift-Splunk-UI.png)

## OpenTelemetry Collector (`tekton-logger`)

Step 5 applies an `OpenTelemetryCollector` CR (`opentelemetry.io/v1beta1`) named `tekton-logger` in `openshift-logging`. The OpenTelemetry Operator turns that CR into a DaemonSet (`tekton-logger-collector`) that runs the **contrib** collector image on every node. On OpenShift it uses a custom SCC (`otel-clusterlogs-collector-scc`) so the DaemonSet can read host `/var/log/pods` (UID 0 + `spc_t`).

| Spec field | Lab value | Why |
|------------|-----------|-----|
| `mode` | `daemonset` | Each node must read its own `/var/log/pods` host path |
| service account | `tekton-logger-collector` | RBAC for pods, events, Tekton objects, and LokiStack application write |
| `image` | `otel/opentelemetry-collector-contrib:0.158.0` | Needs `file_log`, `k8s_attributes`, `splunk_hec`, `redaction`, etc. |
| host volume | `/var/log/pods` (read-only) | Container runtime log files for TaskRun step containers |
| env | `KUBE_NODE_NAME`, `CLUSTERNAME=handsonlab` | Used by transform processors for node / cluster tags |

### Receivers (three inputs → three log pipelines)

| Receiver | What it collects | Pipeline |
|----------|------------------|----------|
| `file_log/pipelines` | Pod log files under `/var/log/pods/default_*/*/*.log` (excludes `openshift-logging_*`). Uses the `container` operator and `include_file_path` so path metadata becomes pod/container attributes. | `logs` |
| `k8s_events` | Kubernetes events in `default` | `logs/events` |
| `k8s_objects/pipelineruns` | Live watch of `pipelineruns.tekton.dev` | `logs/pipelineruns` |

### Processors (enrichment path)

Shared idea: attach Tekton identity (`tekton_pipelinerun`, `tekton_taskrun`, UIDs, Results annotations) and reshape fields so Splunk / LokiStack / Results can join a log line back to a TaskRun.

- **`k8s_attributes` / `k8s_attributes/events`** — look up the pod and copy Tekton labels/annotations onto the log record.
- **`transform/k8sattributes`** — merge resource attributes into log attributes.
- **`transform/clf`** — set OpenShift-style / CLF-ish tags (`openshift.log.type=application`, `openshift.log.source=tekton`, cluster name).
- **`transform/tekton_splunk_lookup`** — copy TaskRun / PipelineRun UIDs into `kubernetes.labels.tekton_dev_*` and ensure a `message` field; this is what Tekton Results’ Splunk search keys on.
- **`transform/tekton_assistant`** — label affinity-assistant sidecar noise when a PipelineRun is present but no task name.
- **`transform/pipelinerun_status`** (pipelineruns pipeline only) — flatten the watched PipelineRun object into attributes + status body.
- **`transform/tekton_pod_lookup`** (events pipeline) — map Pod / TaskRun event objects onto pod name/UID for attribute lookup.
- **`log_dedup/tekton`** (events + pipelineruns) — collapse duplicate status/event noise over a 60s window keyed by Tekton UIDs / names.
- **`batch`** — defined in the CR but **not** attached to any pipeline in this lab.
- **`redaction/cc`** and **`redaction/creds`** — processor **definitions** are present after `./05-configure-otel-collector.sh`, but they are **not** listed under `service.pipelines.*.processors` yet. Enabling them is the day-2 exercise below.

### Exporters

| Exporter | Destination | Notes |
|----------|-------------|--------|
| `splunk_hec` | `https://splunk-hec:8088/services/collector/event` | **Day 1:** direct HEC, lab token, `index=main`, `sourcetype=tekton:logs`, TLS verify skipped |
| `otlp_http/splunk_hec` | `https://splunk-hec:4318` | **Day 2b:** replaces direct HEC; OTLP/HTTPS with client cert to the Splunk sidecar |
| `otlp_http/loki` | LokiStack gateway OTLP (`…/api/logs/v1/application/otlp`) | Bearer token auth + OpenShift service CA; unchanged on day 2 |
| `debug` | collector stdout | Defined; not attached to the lab pipelines |

All three pipelines export to **both** Splunk and LokiStack (Splunk via HEC on day 1, via mTLS OTLP on day 2b).

### Day-1 baseline (what you have after steps 1–6)

Day 1 optimizes for a working end-to-end path, not production hardening:

- **Content:** the demo pipeline prints a sample card number (`4591675271559508`) and a password-bearing URL (`docker://root:changeme@quay.example.com`). Those strings land in Splunk and LokiStack as plain text.
- **Transport to Splunk:** `tekton-logger` uses the native `splunk_hec` exporter against `https://splunk-hec:8088/...` with `tls.insecure_skip_verify: true` — encrypted to a self-signed HEC endpoint, but **no client identity** and **no server authenticity check**.
- **Redaction processors** exist in the CR (`redaction/cc`, `redaction/creds`) but are **not** listed under `service.pipelines.*.processors` yet.

That before-state is intentional: day 2 is where you harden **what** is stored and **how** it is forwarded.

## Day-2 operations

Day 2 is operations work on the already-running lab — you do **not** tear down the cluster. The audience takeaway is: once logs are flowing, you can still raise the bar for compliance (mask PII/secrets in long-term stores) and for zero-trust networking (authenticate both ends of the collector → Splunk hop).

| Day-2 goal | Problem on day 1 | What you change |
|------------|------------------|-----------------|
| **Redact sensitive values** | Card numbers / passwords are searchable forever in Splunk & LokiStack | Attach `redaction/*` processors before exporters |
| **mTLS log forwarding** | Any pod that can reach HEC can POST events; HEC cert is not verified by the client | Terminate OTLP with mutual TLS in a sidecar, retarget `tekton-logger` to present a client certificate |
| **Verify mTLS** | Easy to assume the sidecar is locked down without proving it | Negative tests (HTTP / no client cert / wrong hostname) then a successful authenticated OTLP POST |

Suggested order: enable redaction first (quick win you can see in the UIs), then run mTLS forwarding, then verify the OTLP front door with `curl`. `./07-configure-mtls-otel-collector.sh` also wires redaction into the pipelines, so you can jump straight to that script if you want both hardening steps in one apply.

### Day-2a: enable redaction (mask card numbers and passwords)

Goal for the audience: show that **pipeline stdout is not a safe long-term store** unless the collector scrubs it. After this change, new log lines still reach Splunk/LokiStack, but card numbers and URL userinfo are replaced with redacted placeholders.

The install already defines:

- **`redaction/cc`** — regexes for common card brands (Visa, Mastercard, Amex, Discover, JCB, Diners, UnionPay, Maestro, …); `summary: debug` records what was blocked.
- **`redaction/creds`** — blocks URL userinfo of the form `//user:password@` (covers the demo `docker://root:changeme@…` line).

They do nothing until they appear in a pipeline’s `processors` list. Wire them in **after** enrichment / Splunk-lookup transforms and **before** export — at minimum on the file-log `logs` pipeline (step stdout):

```yaml
processors:
  - k8s_attributes
  # ... existing transforms ...
  - redaction/cc
  - redaction/creds
```

```bash
export KUBECONFIG="$(pwd)/kubeconfig"

kubectl -n openshift-logging edit opentelemetrycollector tekton-logger
# Under spec.config.service.pipelines.logs.processors, append:
#   - redaction/cc
#   - redaction/creds

kubectl rollout status daemonset/tekton-logger-collector -n openshift-logging --timeout=300s
kubectl delete pipelinerun -l tekton.dev/pipeline=demo-pipeline -n default --ignore-not-found
./06-run-pipeline.sh
```

Already-indexed day-1 events stay unredacted; only logs processed **after** the processors are attached are masked.

Confirm in the UIs that the new run still appears, and that sensitive values are scrubbed in Splunk:

![OpenShift Pipelines UI](../docs/OpenShift-Pipeline-UI.png)

![OpenShift Logs UI](../docs/OpenShift-Logs-UI.png)

![OpenShift Splunk UI with redacted values](../docs/OpenShift-Splunk-UI.png)

### Day-2b: mTLS log forwarding (`./07-configure-mtls-otel-collector.sh`)

Goal for the audience: stop treating Splunk HEC as an open HTTPS sink. Instead of `tekton-logger` talking HEC directly with verify skipped, you introduce an **authenticated OTLP front door** on the Splunk pod and require the node collector to present a client certificate issued by your lab CA.

What the script does, in order:

1. **Lab PKI with cert-manager**
   - `ClusterIssuer/selfsigned-issuer` → bootstrap
   - `Certificate/local-ca` → private CA secret `local-ca-root-secret`
   - `Issuer/selfsigned-issuer` in `openshift-logging` → signs leaf certs from that CA
   - **Client cert** `tekton-logger-collector` (`client auth`, `duration: 60m` / `renewBefore: 55m` → renews about every **5m**) → secret `tekton-logger-collector-certificate`
   - **Server cert** `splunk-hec` (`server auth`, same lifetime) → secret `splunk-hec-certificate`

2. **OTLP mTLS sidecar on Splunk** — creates `OpenTelemetryCollector/splunk-hec-sidecar` (`mode: sidecar`) that:
   - Listens for OTLP HTTP/gRPC on `:4318` / `:4317` with **TLS 1.3**, server cert, and **`client_ca_file`** (rejects clients that do not present a cert signed by the lab CA)
   - Exports onward to Splunk HEC on `https://127.0.0.1:8088` (localhost hop inside the pod; still `insecure_skip_verify` on that last mile because Splunk’s own HEC cert is not the lab CA)
   - Is injected into `deploy/splunk-hec` via `sidecar.opentelemetry.io/inject=splunk-hec-sidecar`
   - Exposes OTLP on `Service/splunk-hec` ports `4317` / `4318`

3. **Retarget `tekton-logger`**
   - Replaces the direct `splunk_hec` exporter with **`otlp_http/splunk_hec`** → `https://splunk-hec:4318`
   - Mounts the client cert secret at `/etc/certs/client` and configures `ca_file` / `cert_file` / `key_file` (TLS 1.3, `insecure: false`)
   - Keeps LokiStack on `otlp_http/loki` (unchanged in this exercise)
   - Attaches **`redaction/cc`** and **`redaction/creds`** on the pipelines so mTLS and scrubbing land together

Path after day 2b:

```text
Task pods → /var/log/pods
  → tekton-logger (DaemonSet, client cert)
    → OTLP/HTTPS mTLS → splunk-hec:4318 (sidecar, server cert + client CA)
      → localhost HEC → Splunk index
    → OTLP/HTTPS → LokiStack gateway (service-account token + service CA)
```

Run it after day 1 is healthy:

```bash
export KUBECONFIG="$(pwd)/kubeconfig"
./07-configure-mtls-otel-collector.sh

kubectl -n openshift-logging get certificate,secret | grep -E 'local-ca|tekton-logger-collector|splunk-hec'
kubectl -n openshift-logging get pod -l app=splunk-hec -o jsonpath='{.items[0].spec.containers[*].name}{"\n"}'
# expect: splunk-hec … otel-collector (injected sidecar)

kubectl rollout status daemonset/tekton-logger-collector -n openshift-logging --timeout=300s
kubectl delete pipelinerun -l tekton.dev/pipeline=demo-pipeline -n default --ignore-not-found
./06-run-pipeline.sh
```

What to tell the room: without a valid client certificate, a random pod can no longer successfully push OTLP logs into the Splunk sidecar; with the cert, the same Tekton → Results path still works because Splunk’s indexed data shape is unchanged — only the **ingest hop** was hardened.

### Day-2c: verify mTLS on the Splunk OTLP front door

Goal for the audience: **prove** the sidecar is not just “HTTPS with a self-signed cert,” but that it requires TLS, a trusted server name, and a client certificate from the lab CA. Run these from a directory where you can write the extracted PEM files (for example your home directory or this `ocp/` folder).

**1. Extract the collector client certificate**

Evaluates that day-2b issued usable client material (`tls.crt` / `tls.key` / `ca.crt`) for the same identity `tekton-logger` presents.

```bash
for f in tls.crt tls.key ca.crt; do
  kubectl -n openshift-logging get secret tekton-logger-collector-certificate -o "jsonpath={.data.${f}}" | base64 -d > "$f"
done
```

**2.1. Running inside OpenShift lab pod**

browse to the pod (instructions-..) in namespace `lab` Terminal and execute the following commands.

**2.1.2. Plain HTTP to the OTLP endpoint**

Evaluates that the listener is TLS-only (cleartext HTTP must not be accepted as a log ingest path).

```bash
curl http://splunk-hec.openshift-logging.svc:4318/v1/logs -d '{}' -H 'Content-Type: application/json'
```

**2.1.3. HTTPS without trusting the lab CA**

Evaluates server authenticity: the sidecar presents a cert whose SANs are `splunk-hec…` but CA is not trusted.

```bash
curl https://splunk-hec.openshift-logging.svc:4318/v1/logs -d '{}' -H 'Content-Type: application/json'
```

**2.1.4. HTTPS with verify skipped, still no client cert**

Evaluates mutual TLS: even after skipping server verification (`-k`), the sidecar demands a client certificate (`certificate required`).

```bash
curl https://splunk-hec.openshift-logging.svc:4318/v1/logs -d '{}' -H 'Content-Type: application/json' -k
```

**2.1.5. Full mTLS success**

Evaluates the intended production-shaped client: trust the lab CA, present the client cert/key, and resolve `splunk-hec` to the port-forward so the server name matches. Expected response:

```bash
curl https://splunk-hec.openshift-logging.svc:4318/v1/logs -d '{}' -H 'Content-Type: application/json' \
  --cacert ca.crt --cert tls.crt --key tls.key
```

```text
{"partialSuccess":{}}
```
###

**2.2.2. Port-forward the OTLP HTTP port**

Evaluates that the Splunk Service exposes the sidecar’s `:4318` and that you can reach it from the workstation without leaving the cluster network open.

```bash
kubectl -n openshift-logging port-forward service/splunk-hec 4318:4318 &
```

**2.2.3. Plain HTTP to the OTLP endpoint**

Evaluates that the listener is TLS-only (cleartext HTTP must not be accepted as a log ingest path).

```bash
curl http://127.0.0.1:4318/v1/logs -d '{}' -H 'Content-Type: application/json'
```

**2.2.4. HTTPS without trusting the lab CA**

Evaluates server authenticity: the sidecar presents a cert whose SANs are `splunk-hec…`, not `127.0.0.1`, so a default `curl` to the IP fails hostname verification.

```bash
curl https://127.0.0.1:4318/v1/logs -d '{}' -H 'Content-Type: application/json'
```

**2.2.5. HTTPS with verify skipped, still no client cert**

Evaluates mutual TLS: even after skipping server verification (`-k`), the sidecar demands a client certificate (`certificate required`).

```bash
curl https://127.0.0.1:4318/v1/logs -d '{}' -H 'Content-Type: application/json' -k
```

**2.2.6. Client cert present, but still dialing by IP**

Evaluates that presenting the client keypair is not enough by itself — hostname / SNI must still match the server certificate SAN (`splunk-hec`).

```bash
curl https://127.0.0.1:4318/v1/logs -d '{}' -H 'Content-Type: application/json' \
  --cacert ca.crt --cert tls.crt --key tls.key
```

**2.2.7. Full mTLS success**

Evaluates the intended production-shaped client: trust the lab CA, present the client cert/key, and resolve `splunk-hec` to the port-forward so the server name matches. Expected response:

```bash
curl https://splunk-hec:4318/v1/logs -d '{}' -H 'Content-Type: application/json' \
  --cacert ca.crt --cert tls.crt --key tls.key \
  --resolve splunk-hec:4318:127.0.0.1
```

```text
{"partialSuccess":{}}
```

That empty `partialSuccess` is the OTLP HTTP success body for an accepted (if empty) logs export — enough to show the TLS handshake and authorization path worked. Stop the background port-forward when finished (`kill %1` or the `kubectl port-forward` PID).

## Notes

- This lab targets an **existing OpenShift** cluster; it does not create a kind/local cluster.
- **Operators (step 1)** must be Ready before instance CRs and the collector will succeed.
- **Loki storage (step 2)** needs a working object-bucket provisioner (NooBaa / ODF) before `LokiStack` (step 4) can become Ready.
- **Splunk (step 3)** can take several minutes while the KV Store starts; Results Splunk settings are also reflected in `instance-configurations/tekton.yml`.
- **OTel collector (step 5)** depends on LokiStack, Splunk, and the OpenTelemetry Operator. See [OpenTelemetry Collector](#opentelemetry-collector-tekton-logger) for receivers, processors, and exporters.
- The demo pipeline prints a **sample card number** and a **password in a registry URL** so you can prove redaction later. Those values are intentional lab fixtures, not real secrets — still avoid copying them into shared screenshots without masking.
- **Day-2 operations** (see [Day-2 operations](#day-2-operations)): (a) attach `redaction/cc` + `redaction/creds`; (b) `./07-configure-mtls-otel-collector.sh` for cert-manager PKI, Splunk OTLP mTLS sidecar, and `otlp_http/splunk_hec` client-cert export (script also enables redaction); (c) `curl` negative/positive tests against `splunk-hec:4318`.
- **cert-manager** is required before day-2b; leaf certificates use `duration: 60m` and `renewBefore: 55m`, so they renew about every **5 minutes** and you can demo renewal under load.
