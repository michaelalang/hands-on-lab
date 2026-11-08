#!/usr/bin/env bash
# RHEL 10 / EL10 (and some cloud images) ship nftables-only kernels with no
# legacy ip_tables / xt_* compatibility modules.
#
# Effects on kind:
# 1) kube-proxy mode=iptables cannot program ClusterIP → CoreDNS / local-path
#    fail with dial tcp 10.96.0.1:443 i/o timeout.
# 2) kindnet's ip-masq-agent uses iptables -m comment / -j MASQUERADE and panics
#    ("Extension ... missing kernel module").
#
# This script switches kube-proxy to nftables, installs native nft MASQ for the
# pod CIDR, and wraps kindnet's iptables binary so MASQ sync no-ops.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export KUBECONFIG="${KUBECONFIG:-${SCRIPT_DIR}/kubeconfig}"

CLUSTER_NAME="${CLUSTER_NAME:-openshift-dev}"
POD_SUBNET="${POD_SUBNET:-10.244.0.0/16}"

host_needs_nftables_networking() {
  # Prefer an explicit probe: can this kernel load legacy iptables?
  if modprobe ip_tables >/dev/null 2>&1; then
    return 1
  fi
  if [[ -e "/lib/modules/$(uname -r)/kernel/net/ipv4/netfilter/ip_tables.ko" ]] \
    || [[ -e "/lib/modules/$(uname -r)/kernel/net/ipv4/netfilter/ip_tables.ko.xz" ]] \
    || [[ -e "/lib/modules/$(uname -r)/kernel/net/ipv4/netfilter/ip_tables.ko.zst" ]]; then
    return 1
  fi
  return 0
}

node_runtime() {
  if command -v podman >/dev/null 2>&1 && podman inspect "${CLUSTER_NAME}-control-plane" >/dev/null 2>&1; then
    echo podman
  elif command -v docker >/dev/null 2>&1 && docker inspect "${CLUSTER_NAME}-control-plane" >/dev/null 2>&1; then
    echo docker
  else
    echo ""
  fi
}

each_kind_node() {
  KIND_EXPERIMENTAL_PROVIDER="${KIND_EXPERIMENTAL_PROVIDER:-}" \
    kind get nodes --name "${CLUSTER_NAME}" 2>/dev/null
}

switch_nodes_to_iptables_nft() {
  local runtime node
  runtime="$(node_runtime)"
  [[ -n "${runtime}" ]] || return 0

  while IFS= read -r node; do
    [[ -n "${node}" ]] || continue
    "${runtime}" exec "${node}" sh -c '
      if command -v update-alternatives >/dev/null 2>&1; then
        update-alternatives --set iptables /usr/sbin/iptables-nft >/dev/null 2>&1 || true
        update-alternatives --set ip6tables /usr/sbin/ip6tables-nft >/dev/null 2>&1 || true
      fi
    ' || true
  done < <(each_kind_node)
}

install_nft_pod_masq() {
  local runtime node
  runtime="$(node_runtime)"
  [[ -n "${runtime}" ]] || return 0

  echo "Installing native nft MASQ for ${POD_SUBNET} on kind nodes..."
  while IFS= read -r node; do
    [[ -n "${node}" ]] || continue
    "${runtime}" exec "${node}" env POD_SUBNET="${POD_SUBNET}" sh -c '
      nft delete table ip kind-masq 2>/dev/null || true
      nft -f - <<EOF
table ip kind-masq {
  chain postrouting {
    type nat hook postrouting priority srcnat; policy accept;
    ip saddr ${POD_SUBNET} ip daddr != ${POD_SUBNET} masquerade comment "kind-masq-agent"
  }
}
EOF
    ' || echo "Warning: could not install nft MASQ on ${node}" >&2
  done < <(each_kind_node)
}

configure_kube_proxy_nftables_mode() {
  local current
  current="$(
    kubectl get configmap kube-proxy -n kube-system \
      -o jsonpath='{.data.config\.conf}' 2>/dev/null \
      | sed -n 's/^mode: //p' | head -1
  )"
  if [[ "${current}" == "nftables" ]]; then
    echo "kube-proxy already in nftables mode."
    return 0
  fi

  echo "Setting kube-proxy mode=nftables..."
  kubectl get configmap kube-proxy -n kube-system -o json > /tmp/kube-proxy-cm.json
  python3 - <<'PY'
import json, re
with open("/tmp/kube-proxy-cm.json") as f:
    doc = json.load(f)
cfg = doc["data"]["config.conf"]
cfg = re.sub(r"(?m)^mode: .*$", "mode: nftables", cfg)
doc["data"]["config.conf"] = cfg
with open("/tmp/kube-proxy-cm.json", "w") as f:
    json.dump(doc, f)
PY
  kubectl apply -f /tmp/kube-proxy-cm.json
  kubectl rollout restart daemonset/kube-proxy -n kube-system
  kubectl rollout status daemonset/kube-proxy -n kube-system --timeout=180s
}

patch_kindnet_iptables_wrapper() {
  echo "Patching kindnet to no-op broken iptables MASQ (nft handles it)..."
  kubectl apply -f - <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: kindnet-iptables-wrapper
  namespace: kube-system
data:
  iptables: |
    #!/bin/sh
    for a in "$@"; do
      case "$a" in
        -V|--version)
          echo "iptables v1.8.9 (nf_tables)"
          exit 0
          ;;
      esac
    done
    exit 0
  ip6tables: |
    #!/bin/sh
    for a in "$@"; do
      case "$a" in
        -V|--version)
          echo "ip6tables v1.8.9 (nf_tables)"
          exit 0
          ;;
      esac
    done
    exit 0
EOF

  kubectl get daemonset kindnet -n kube-system -o json > /tmp/kindnet-ds.json
  python3 - <<'PY'
import json, subprocess

with open("/tmp/kindnet-ds.json") as f:
    ds = json.load(f)

pod = ds["spec"]["template"]["spec"]
vols = [v for v in pod.get("volumes", [])
        if v.get("name") not in ("kindnet-iptables-wrapper", "kindnet-iptables-bin")]
vols += [
    {"name": "kindnet-iptables-wrapper",
     "configMap": {"name": "kindnet-iptables-wrapper", "defaultMode": 0o555}},
    {"name": "kindnet-iptables-bin", "emptyDir": {}},
]
pod["volumes"] = vols

init = {
    "name": "install-iptables-wrapper",
    "image": "docker.io/library/busybox:1.36",
    "command": ["sh", "-c",
                "cp /wrapper/iptables /wrapper/ip6tables /out/ && "
                "chmod 755 /out/iptables /out/ip6tables"],
    "volumeMounts": [
        {"name": "kindnet-iptables-wrapper", "mountPath": "/wrapper"},
        {"name": "kindnet-iptables-bin", "mountPath": "/out"},
    ],
}
pod["initContainers"] = [
    c for c in pod.get("initContainers", [])
    if c.get("name") != "install-iptables-wrapper"
]
pod["initContainers"].insert(0, init)

c = pod["containers"][0]
mounts = [
    m for m in c.get("volumeMounts", [])
    if m.get("name") not in ("kindnet-iptables-wrapper", "kindnet-iptables-bin")
    and m.get("mountPath") not in ("/usr/sbin/iptables", "/usr/sbin/ip6tables")
]
mounts += [
    {"name": "kindnet-iptables-bin", "mountPath": "/usr/sbin/iptables", "subPath": "iptables"},
    {"name": "kindnet-iptables-bin", "mountPath": "/usr/sbin/ip6tables", "subPath": "ip6tables"},
]
c["volumeMounts"] = mounts

subprocess.run(["kubectl", "replace", "-f", "-"], input=json.dumps(ds), text=True, check=True)
PY

  kubectl rollout status daemonset/kindnet -n kube-system --timeout=180s
}

configure_nftables_networking() {
  if ! host_needs_nftables_networking; then
    echo "Host kernel supports legacy iptables; leaving kind networking unchanged."
    return 0
  fi

  echo "Host kernel has no legacy ip_tables module; applying nftables-friendly kind networking..."
  switch_nodes_to_iptables_nft
  configure_kube_proxy_nftables_mode
  install_nft_pod_masq
  patch_kindnet_iptables_wrapper

  # Do NOT wait for CoreDNS here: the default Corefile may still forward to a
  # nameserver-less resolv.conf until 01-configure-cluster-dns.sh runs next.
  echo "Waiting for local-path-provisioner (ClusterIP smoke test)..."
  kubectl delete pod -n local-path-storage -l app=local-path-provisioner \
    --force --grace-period=0 2>/dev/null || true
  kubectl wait --for=condition=Ready pod -l app=local-path-provisioner \
    -n local-path-storage --timeout=180s || true
  echo "nftables networking configuration complete."
}

configure_nftables_networking
