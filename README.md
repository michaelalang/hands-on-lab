# Hands-on Lab

Local Kubernetes lab on [kind](https://kind.sigs.k8s.io/) with Tekton, Tekton Results, Loki, Splunk HEC, OpenTelemetry, and Tekton Dashboard external logs.

## Architecture

Tekton Pipeline execution through to log storage and retrieval:

![Tekton Pipeline to Logs flow](docs/tekton-to-logs-flow.svg)

1. **PipelineRun** creates TaskRun pods; step output is written to `/var/log/pods` on the node.
2. **OpenTelemetry Collector** (`tekton-logger` DaemonSet) tails those logs, watches PipelineRuns and Kubernetes events, enriches records with Tekton labels / UIDs, and ships to **Splunk HEC** and **Loki**. Day 1 uses a direct HEC export with TLS verify skipped; day 2 adds redaction and mutual TLS in front of Splunk (see [Day-2 operations](#day-2-operations)).
3. **Tekton Results** records run metadata; the Results API is configured to fetch logs from Splunk by TaskRun UID.
4. **Tekton Dashboard** uses the **tekton-logs-proxy** as an external-logs fallback when task pods have been deleted.

## Prerequisites

### Install tools (user-local binaries)

Binaries are installed under `~/lab-bin` (not `/usr/bin` or `/usr/local/bin`). Add that directory to your `PATH` for the current shell and future sessions.

```bash
# Directory for lab CLI tools (non-system path)
export LAB_BIN="${HOME}/lab-bin"
mkdir -p "${LAB_BIN}"
export PATH="${LAB_BIN}:${PATH}"

# Persist for new shells (safe to re-run)
grep -q 'lab-bin' "${HOME}/.bashrc" 2>/dev/null || \
  echo 'export PATH="${HOME}/lab-bin:${PATH}"' >> "${HOME}/.bashrc"

# Map host CPU architecture to upstream release names
case "$(uname -m)" in
  x86_64)  ARCH=amd64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  *) echo "Unsupported architecture: $(uname -m)" >&2; exit 1 ;;
esac

# kubectl (pinned version — do not nest $(curl …) here; it breaks on copy/paste)
# If a previous attempt left a bad value: unset KUBECTL_VERSION
KUBECTL_VERSION=v1.37.0
test -n "${LAB_BIN}" && test -n "${ARCH}" || {
  echo "LAB_BIN and ARCH must be set (run the blocks above first)" >&2
  exit 1
}
echo "Downloading kubectl ${KUBECTL_VERSION} for linux/${ARCH} → ${LAB_BIN}/kubectl"
curl -L --retry 3 --retry-delay 2 \
  -o "${LAB_BIN}/kubectl" \
  "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${ARCH}/kubectl"
curl -L --retry 3 --retry-delay 2 \
  -o /tmp/kubectl.sha256 \
  "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${ARCH}/kubectl.sha256"
echo "$(cat /tmp/kubectl.sha256)  ${LAB_BIN}/kubectl" | sha256sum --check
chmod +x "${LAB_BIN}/kubectl"
rm -f /tmp/kubectl.sha256

# kind
KIND_VERSION="${KIND_VERSION:-v0.29.0}"
curl -sSL -o "${LAB_BIN}/kind" \
  "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-linux-${ARCH}"
chmod +x "${LAB_BIN}/kind"

# helm
HELM_VERSION="${HELM_VERSION:-v3.17.3}"
curl -sSL -o /tmp/helm-${HELM_VERSION}-linux-${ARCH}.tar.gz \
  "https://get.helm.sh/helm-${HELM_VERSION}-linux-${ARCH}.tar.gz"
tar -xzf /tmp/helm-${HELM_VERSION}-linux-${ARCH}.tar.gz -C /tmp
mv "/tmp/linux-${ARCH}/helm" "${LAB_BIN}/helm"
chmod +x "${LAB_BIN}/helm"
rm -rf "/tmp/linux-${ARCH}" "/tmp/helm-${HELM_VERSION}-linux-${ARCH}.tar.gz"

# Lab scripts call `oc`; kubectl is sufficient — symlink for compatibility
ln -sf "${LAB_BIN}/kubectl" "${LAB_BIN}/oc"

# Verify
kubectl version --client
kind version
helm version
oc version --client
```

**Also required** (install with your OS package manager; not placed in `~/lab-bin`):

- **podman** — container runtime for kind on Fedora (`sudo dnf install -y podman`)
- **openssl** — TLS certs for Tekton Results (`sudo dnf install -y openssl`; usually already installed)
- **curl** — downloads above (`sudo dnf install -y curl`)

### Lab environment

**Disk:** at least **40 GiB** root filesystem (25 GiB free). A default ~10 GiB cloud image will fill during Splunk/kind install; podman then fails with `No space left on device`, the API port dies, and `oc`/`kubectl` show `connection refused`.

From the repo directory:

```bash
cd /path/to/hands-on-lab
export KUBECONFIG="$(pwd)/kubeconfig"
export KIND_EXPERIMENTAL_PROVIDER=podman   # Fedora + podman
```

Required tools summary:

- `kind`, `kubectl`, `helm` — from `~/lab-bin` (see above)
- `oc` — symlink to `kubectl` in `~/lab-bin`
- `podman` (or `docker`)
- `openssl`

## Script order

Run these scripts in order:

| Step | Script | What it does |
|------|--------|----------------|
| **1** | `./01-start-local-cluster.sh` | Creates the kind cluster. Also runs `01-configure-node-hosts.sh`, then (on **RHEL 10** only) `01-configure-kube-proxy-nftables.sh`, then `01-configure-cluster-dns.sh` — do **not** run those separately. |
| **2** | `./02-install-cert-manager.sh` | Installs cert-manager (used on day 2 for the mTLS CA and client/server certificates). |
| **3** | `./03-configure-namespace.sh` | Creates the `logging` namespace and `tekton-collector` service account. |
| **4** | `./03-rbac.sh` | RBAC for the OpenTelemetry collector. |
| **5** | `./03-install-loki.sh` | Installs Loki (Helm) into `logging`. |
| **6** | `./04-install-tekton.sh` | Tekton Pipelines, Triggers, Dashboard, and Results. |
| **7** | `./05-install-opentelemetry.sh` | OpenTelemetry Operator. |
| **8** | `./06-install-splunk-hec.sh` | Splunk HEC and Tekton Results → Splunk log backend. |
| **9** | `./07-configure-otel-collector.sh` | OpenTelemetry Collector DaemonSet → Splunk HEC + Loki (defines optional `redaction/*` processors; not enabled until day 2). |
| **10** | `./04-configure-dashboard-logs.sh` | Dashboard external-logs proxy (Results/Splunk fallback after task pods are deleted). |
| **11** | `./08-run-pipeline.sh` | Demo pipeline run (includes sample card number + password URL for the day-2 redaction demo); verifies Tekton Results storage. |

To switch an existing lab from the default Postgres log backend to Splunk (or re-apply Splunk settings) and re-run the demo pipeline:

| Step | Script | What it does |
|------|--------|----------------|
| **update** | `./09-update-tekton-results-splunk.sh` | Configures Tekton Results `LOGS_TYPE=Splunk`, deploys the Dashboard external-logs proxy, and re-runs `./08-run-pipeline.sh`. Requires Splunk HEC and Tekton Results to already be installed. |

Day-2 hardening (run after the demo pipeline has already shipped unredacted logs over the day-1 path):

| Step | Script / action | What it does |
|------|-----------------|--------------|
| **day-2a** | Edit `tekton-logger` (or use day-2b) | Enable `redaction/cc` + `redaction/creds` so card numbers and passwords are masked before long-term storage. |
| **day-2b** | `./10-mtls-log-forwarding.sh` | Issues a lab CA + mTLS certs, injects an OTel sidecar in front of Splunk HEC, and retargets `tekton-logger` to export over OTLP/HTTPS with client certs (also wires redaction into the pipelines). |

## One-liner

From scratch, use `run.sh` (same steps as the table above, with end-to-end verification at the end):

```bash
cd /path/to/hands-on-lab
./run.sh
```

Or run the steps manually:

```bash
cd /path/to/hands-on-lab
export KUBECONFIG="$(pwd)/kubeconfig"
export KIND_EXPERIMENTAL_PROVIDER=podman

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
```

## Do not run manually

These are invoked automatically by step 1:

- `01-configure-node-hosts.sh`
- `01-configure-cluster-dns.sh`
- `01-configure-kube-proxy-nftables.sh` — only when `/etc/redhat-release` reports **Red Hat Enterprise Linux release 10** (nftables-only). Skipped on Fedora and other hosts; run it yourself if you are on another nftables-only kernel with the same ClusterIP failures.

Re-run `01-configure-node-hosts.sh` only if a worker node is stuck `NotReady` after a partial or failed cluster create. Re-run `01-configure-kube-proxy-nftables.sh` if CoreDNS/local-path stay broken on an RHEL 10 / nftables-only host.

## Optional verification

After install:

```bash
./check-tekton.sh    # then port-forward the Dashboard on :9097
./check-loki.sh
./check-splunk.sh
```

## Log UIs

After the demo pipeline completes, logs are visible in all three backends configured by the lab.

### Tekton Dashboard

Pipeline and task step logs in the Tekton UI (including Splunk-backed external logs when task pods are gone):

![Tekton Dashboard logs](docs/Tekton-UI.png)

### Grafana (Loki)

Tekton logs shipped by the OpenTelemetry collector to Loki, explored in Grafana:

![Grafana Loki logs](docs/Grafana-Loki-UI.png)

### Splunk HEC

The same pipeline logs indexed in Splunk (`index=main`, `sourcetype=tekton:logs`), used by Tekton Results for log retrieval:

![Splunk HEC logs](docs/Splunk-Hec-UI.png)

## OpenTelemetry Collector (`tekton-logger`)

Step 9 applies an `OpenTelemetryCollector` CR (`opentelemetry.io/v1beta1`) named `tekton-logger` in the `logging` namespace. The OpenTelemetry Operator turns that CR into a DaemonSet (`tekton-logger-collector`) that runs the **contrib** collector image on every node.

| Spec field | Lab value | Why |
|------------|-----------|-----|
| `mode` | `daemonset` | Each node must read its own `/var/log/pods` host path |
| `serviceAccount` | `tekton-collector` | RBAC for pods, events, and Tekton objects (from `./03-rbac.sh`) |
| `image` | `otel/opentelemetry-collector-contrib:0.158.0` | Needs `file_log`, `k8s_attributes`, `splunk_hec`, `redaction`, etc. |
| host volume | `/var/log/pods` (read-only) | Container runtime log files for TaskRun step containers |
| env | `KUBE_NODE_NAME`, `CLUSTERNAME=handsonlab` | Used by transform processors for node / cluster tags |

### Receivers (three inputs → three log pipelines)

| Receiver | What it collects | Pipeline |
|----------|------------------|----------|
| `file_log/pipelines` | Pod log files under `/var/log/pods/default_*/*/*.log` (excludes `logging_*`). Uses the `container` operator and `include_file_path` so path metadata becomes pod/container attributes. | `logs` |
| `k8s_events` | Kubernetes events in `default` | `logs/events` |
| `k8s_objects/pipelineruns` | Live watch of `pipelineruns.tekton.dev` | `logs/pipelineruns` |

### Processors (enrichment path)

Shared idea: attach Tekton identity (`tekton_pipelinerun`, `tekton_taskrun`, UIDs, Results annotations) and reshape fields so Splunk / Loki / Results can join a log line back to a TaskRun.

- **`k8s_attributes` / `k8s_attributes/events`** — look up the pod and copy Tekton labels/annotations onto the log record. Pod association prefers `k8s.pod.uid`, then name + namespace.
- **`transform/k8sattributes`** — merge resource attributes into log attributes.
- **`transform/clf`** — set OpenShift-style / CLF-ish tags (`openshift.log.type=application`, `openshift.log.source=tekton`, cluster name).
- **`transform/tekton_splunk_lookup`** — copy TaskRun / PipelineRun UIDs into `kubernetes.labels.tekton_dev_*` and ensure a `message` field; this is what Tekton Results’ Splunk search keys on.
- **`transform/tekton_assistant`** — label affinity-assistant sidecar noise when a PipelineRun is present but no task name.
- **`transform/pipelinerun_status`** (pipelineruns pipeline only) — flatten the watched PipelineRun object into attributes + status body.
- **`transform/tekton_pod_lookup`** (events pipeline) — map Pod / TaskRun event objects onto pod name/UID for attribute lookup.
- **`log_dedup/tekton`** (events + pipelineruns) — collapse duplicate status/event noise over a 60s window keyed by Tekton UIDs / names.
- **`batch`** — defined in the CR but **not** attached to any pipeline in this lab (exports go out after the transform chain).
- **`redaction/cc`** and **`redaction/creds`** — processor **definitions** are present after `./07-configure-otel-collector.sh`, but they are **not** listed under `service.pipelines.*.processors` yet. Enabling them is the day-2 exercise below.

### Exporters

| Exporter | Destination | Notes |
|----------|-------------|--------|
| `splunk_hec` | `https://splunk-hec:8088/services/collector/event` | **Day 1:** direct HEC, lab token, `index=main`, `sourcetype=tekton:logs`, TLS verify skipped |
| `otlp_http/splunk_hec` | `https://splunk-hec:4318` | **Day 2b:** replaces direct HEC; OTLP/HTTPS with client cert to the Splunk sidecar |
| `otlp_http/loki` | `http://loki:3100/otlp` | Same enriched logs for Grafana (unchanged on day 2) |
| `debug` | collector stdout | Defined; not attached to the lab pipelines |

All three pipelines export to **both** Splunk and Loki (Splunk via HEC on day 1, via mTLS OTLP on day 2b).

### Day-1 baseline (what you have after `./run.sh`)

Day 1 optimizes for a working end-to-end path, not production hardening:

- **Content:** the demo pipeline prints a sample card number (`4591675271559508`) and a password-bearing URL (`docker://root:changeme@quay.example.com`). Those strings land in Splunk and Loki as plain text.
- **Transport to Splunk:** `tekton-logger` uses the native `splunk_hec` exporter against `https://splunk-hec:8088/...` with `tls.insecure_skip_verify: true` — encrypted to a self-signed HEC endpoint, but **no client identity** and **no server authenticity check**.
- **Redaction processors** exist in the CR (`redaction/cc`, `redaction/creds`) but are **not** listed under `service.pipelines.*.processors` yet.

That before-state is intentional: day 2 is where you harden **what** is stored and **how** it is forwarded.

## Day-2 operations

Day 2 is operations work on the already-running lab — you do **not** tear down the cluster. The audience takeaway is: once logs are flowing, you can still raise the bar for compliance (mask PII/secrets in long-term stores) and for zero-trust networking (authenticate both ends of the collector → Splunk hop).

| Day-2 goal | Problem on day 1 | What you change |
|------------|------------------|-----------------|
| **Redact sensitive values** | Card numbers / passwords are searchable forever in Splunk & Loki | Attach `redaction/*` processors before exporters |
| **mTLS log forwarding** | Any pod that can reach HEC can POST events; HEC cert is not verified by the client | Terminate OTLP with mutual TLS in a sidecar, retarget `tekton-logger` to present a client certificate |

Suggested order: enable redaction first (quick win you can see in the UIs), then run mTLS forwarding. `./10-mtls-log-forwarding.sh` also wires redaction into the pipelines, so you can jump straight to that script if you want both hardening steps in one apply.

### Day-2a: enable redaction (mask card numbers and passwords)

Goal for the audience: show that **pipeline stdout is not a safe long-term store** unless the collector scrubs it. After this change, new log lines still reach Splunk/Loki, but card numbers and URL userinfo are replaced with redacted placeholders.

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

kubectl -n logging edit opentelemetrycollector tekton-logger
# Under spec.config.service.pipelines.logs.processors, append:
#   - redaction/cc
#   - redaction/creds

kubectl rollout status daemonset/tekton-logger-collector -n logging --timeout=300s
kubectl delete pipelinerun demo-pipeline-run -n default --ignore-not-found
./08-run-pipeline.sh
./check-splunk.sh
./check-loki.sh
```

Already-indexed day-1 events stay unredacted; only logs processed **after** the processors are attached are masked.

### Day-2b: mTLS log forwarding (`./10-mtls-log-forwarding.sh`)

Goal for the audience: stop treating Splunk HEC as an open HTTPS sink. Instead of `tekton-logger` talking HEC directly with verify skipped, you introduce an **authenticated OTLP front door** on the Splunk pod and require the node collector to present a client certificate issued by your lab CA.

What the script does, in order:

1. **Lab PKI with cert-manager** (needs step 2)
   - `ClusterIssuer/selfsigned-issuer` → bootstrap
   - `Certificate/local-ca` → private CA secret `local-ca-root-secret`
   - `Issuer/selfsigned-issuer` in `logging` → signs leaf certs from that CA
   - **Client cert** `tekton-logger-collector` (`client auth`, short-lived 60m / renew at 55m) → secret `tekton-logger-collector-certificate`
   - **Server cert** `splunk-hec` (`server auth`, same lifetime) → secret `splunk-hec-certificate`

2. **OTLP mTLS sidecar on Splunk** — creates `OpenTelemetryCollector/splunk-hec-sidecar` (`mode: sidecar`) that:
   - Listens for OTLP HTTP/gRPC on `:4318` / `:4317` with **TLS 1.3**, server cert, and **`client_ca_file`** (rejects clients that do not present a cert signed by the lab CA)
   - Exports onward to Splunk HEC on `https://127.0.0.1:8088` (localhost hop inside the pod; still `insecure_skip_verify` on that last mile because Splunk’s own HEC cert is not the lab CA)
   - Is injected into `deploy/splunk-hec` via `sidecar.opentelemetry.io/inject=splunk-hec-sidecar`
   - Exposes OTLP on `Service/splunk-hec` ports `4317` / `4318`

3. **Retarget `tekton-logger`**
   - Replaces the direct `splunk_hec` exporter with **`otlp_http/splunk_hec`** → `https://splunk-hec:4318`
   - Mounts the client cert secret at `/etc/certs/client` and configures `ca_file` / `cert_file` / `key_file` (TLS 1.3, `insecure: false`)
   - Keeps Loki on plain `otlp_http/loki` (unchanged in this exercise)
   - Attaches **`redaction/cc`** and **`redaction/creds`** on the file-log pipeline so mTLS and scrubbing land together

Path after day 2b:

```text
Task pods → /var/log/pods
  → tekton-logger (DaemonSet, client cert)
    → OTLP/HTTPS mTLS → splunk-hec:4318 (sidecar, server cert + client CA)
      → localhost HEC → Splunk index
    → OTLP/HTTP → Loki (still cleartext inside the cluster in this lab)
```

Run it after day 1 is healthy:

```bash
export KUBECONFIG="$(pwd)/kubeconfig"
./10-mtls-log-forwarding.sh

kubectl -n logging get certificate,secret | grep -E 'local-ca|tekton-logger-collector|splunk-hec'
kubectl -n logging get pod -l app=splunk-hec -o jsonpath='{.items[0].spec.containers[*].name}{"\n"}'
# expect: splunk-hec … otel-collector (injected sidecar)

kubectl rollout status daemonset/tekton-logger-collector -n logging --timeout=300s
kubectl delete pipelinerun demo-pipeline-run -n default --ignore-not-found
./08-run-pipeline.sh
./check-splunk.sh
```

What to tell the room: without a valid client certificate, a random pod can no longer successfully push OTLP logs into the Splunk sidecar; with the cert, the same Tekton → Results → Dashboard path still works because Splunk’s indexed data shape is unchanged — only the **ingest hop** was hardened.

## Remove lab

To tear down the cluster and free local resources:

```bash
cd /path/to/hands-on-lab
export KIND_EXPERIMENTAL_PROVIDER=podman   # Fedora + podman

kind delete cluster --name openshift-dev
```

The repo `kubeconfig` will point at a cluster that no longer exists. Remove it or regenerate it on the next install:

```bash
rm -f kubeconfig
```

## Notes

- **Splunk (step 8)** must run after **Tekton Results (step 6)** — it configures Results to use Splunk for log retrieval.
- **OTel collector (step 9)** depends on Loki, Splunk, and the OpenTelemetry Operator. See [OpenTelemetry Collector](#opentelemetry-collector-tekton-logger) for receivers, processors, and exporters.
- **Dashboard logs (step 10)** should be last among install scripts so Results and Splunk are ready.
- Step 8 can take several minutes while Splunk KV Store starts.
- **Tekton Results** still stores run metadata in Postgres; Splunk is only the log retrieval backend (`LOGS_TYPE=Splunk`). Use `./09-update-tekton-results-splunk.sh` to apply or refresh that configuration on an existing cluster.
- The demo pipeline prints a **sample card number** and a **password in a registry URL** so you can prove redaction later. Those values are intentional lab fixtures, not real secrets — still avoid copying them into shared screenshots without masking.
- **Day-2 operations** (see [Day-2 operations](#day-2-operations)): (a) attach `redaction/cc` + `redaction/creds`; (b) `./10-mtls-log-forwarding.sh` for cert-manager PKI, Splunk OTLP mTLS sidecar, and `otlp_http/splunk_hec` client-cert export (script also enables redaction).
- **cert-manager (step 2)** is required before day-2b; leaf certificates use duration: 60m and renewBefore: 55m, so they renew about every 5 minutes and you can demo renewal under load.
- **RHEL 10:** step 1 auto-runs the nftables kube-proxy / kindnet fix only when the host is RHEL 10; other distros skip that script unless you invoke it manually.
- For a clean redeploy, remove the lab (see above), then start again from step 1.

## Troubleshooting

### CoreDNS / kindnet / local-path fail on RHEL 10 cloud images

Symptoms:

- CoreDNS readiness `503` / `Still waiting on: "kubernetes"`
- local-path-provisioner `CrashLoopBackOff` with `dial tcp 10.96.0.1:443: i/o timeout`
- kindnet `CrashLoopBackOff` with `Extension comment/MASQUERADE ... missing kernel module` / `KIND-MASQ-AGENT`
- kube-proxy logs `RULE_INSERT failed`

RHEL 10 kernels are nftables-only (no legacy `ip_tables` / `xt_*` compat modules). kind’s default kube-proxy `mode: iptables` and kindnet’s iptables MASQ both break.

Fix on a running cluster:

```bash
export KUBECONFIG="$(pwd)/kubeconfig"
export KIND_EXPERIMENTAL_PROVIDER=podman
./01-configure-kube-proxy-nftables.sh
```

That script switches kube-proxy to `nftables`, installs native nft MASQ for the pod CIDR, and wraps kindnet’s iptables binary. `01-start-local-cluster.sh` runs it automatically only when `/etc/redhat-release` matches **Red Hat Enterprise Linux release 10** (before CoreDNS readiness waits). On other hosts, run the script manually if you hit the same symptoms.

### CoreDNS `plugin/forward: no nameservers found`

`kind-node-resolv.conf` is mounted as the node kubelet resolv-conf. If it has only `options` and no `nameserver` lines, CoreDNS’s default `forward . /etc/resolv.conf` crashes until `01-configure-cluster-dns.sh` rewrites the Corefile to `8.8.8.8` / `1.1.1.1`.

Fix on a running cluster:

```bash
export KUBECONFIG="$(pwd)/kubeconfig"
./01-configure-cluster-dns.sh
```

New clusters use a `kind-node-resolv.conf` that includes upstream nameservers so CoreDNS can start before that script runs.

### Worker node stuck `NotReady`

The worker may be missing the control-plane entry in `/etc/hosts`, which prevents kindnet from installing CNI:

```bash
export KUBECONFIG="$(pwd)/kubeconfig"
export KIND_EXPERIMENTAL_PROVIDER=podman
./01-configure-node-hosts.sh
kubectl wait --for=condition=Ready node --all --timeout=120s
```

### `oc` / `kubectl` connection refused / Splunk rollout timeout

Usually the VM disk filled up (common on 10 GiB cloud images). kind volumes + images exhaust space/inodes; the API listen port dies and Splunk never becomes Ready.

```bash
df -h /
export KIND_EXPERIMENTAL_PROVIDER=podman
kind delete cluster --name openshift-dev
podman system prune -af --volumes
```

Grow the disk to **≥40 GiB**, then recreate with `./run.sh`. `01-start-local-cluster.sh` now refuses to start if fewer than 25 GiB are free.

### Broken or empty `kubeconfig`

`01-configure-node-hosts.sh` refreshes kubeconfig from kind when it is missing or invalid. You can also regenerate it manually:

```bash
export KIND_EXPERIMENTAL_PROVIDER=podman
kind get kubeconfig --name openshift-dev > kubeconfig
chmod 600 kubeconfig
```

### Dashboard shows "Unable to fetch log" / "no logs found" after deleting task pods

The Dashboard only falls back to Splunk when **external logs** are configured. By default the Dashboard ships with an empty `--external-logs=` flag and no `tekton-logs-proxy` deployment.

Install or refresh the fallback path:

```bash
export KUBECONFIG="$(pwd)/kubeconfig"
./04-configure-dashboard-logs.sh
```

Verify:

```bash
./check-tekton.sh
```

The Dashboard `--external-logs` URL must point at `tekton-logs-proxy`, which calls Tekton Results (`LOGS_TYPE=Splunk`) to search Splunk by TaskRun UID. Task pods can be deleted; TaskRuns must still exist and have `results.tekton.dev/stored=true`.

Quick test (pods deleted, logs still returned):

```bash
kubectl delete pods -n default --all
kubectl run logs-proxy-check --rm -i --restart=Never -n tekton-pipelines \
  --image=curlimages/curl:latest -- \
  curl -sf "http://tekton-logs-proxy.tekton-pipelines.svc:8080/logs/default/demo-pipeline-run-prepare-pod/step-prepare" | head
```

### Dashboard external logs hang for ~60s then return nothing

On Fedora + podman, kind nodes default to `pids_limit=2048`. systemd then applies `DefaultTasksMax` (~15% ≈ **307 PIDs per container**). Splunk needs more than that for search jobs; they stick in `PARSING`, Tekton Results logs `timeout reached for splunk search job`, and the UI eventually shows no logs.

Fix on a running cluster:

```bash
export KUBECONFIG="$(pwd)/kubeconfig"
export KIND_EXPERIMENTAL_PROVIDER=podman
source ./lib/raise-kind-pids.sh
raise_kind_node_pids
```

`01-start-local-cluster.sh`, `06-install-splunk-hec.sh`, and `09-update-tekton-results-splunk.sh` call this automatically. New clusters also set unlimited PIDs via `kind-config.yaml`.
