#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export KUBECONFIG="${SCRIPT_DIR}/kubeconfig"

if [[ -z "${KIND_EXPERIMENTAL_PROVIDER:-}" ]]; then
  if command -v podman >/dev/null 2>&1 && podman info >/dev/null 2>&1; then
    export KIND_EXPERIMENTAL_PROVIDER=podman
  elif command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    :
  fi
fi

if [[ ! -f "${SCRIPT_DIR}/kind-node-resolv.conf" ]]; then
  echo "kind-node-resolv.conf is missing; recreate it from the repo." >&2
  exit 1
fi

# kind node volumes + Splunk/Loki images fill small cloud-image disks and exhaust
# inodes; the API then dies with "connection refused" on the kubeconfig port.
MIN_DISK_GB="${MIN_DISK_GB:-25}"
avail_kb="$(df -Pk "${SCRIPT_DIR}" | awk 'NR==2 {print $4}')"
avail_gb="$((avail_kb / 1024 / 1024))"
if (( avail_gb < MIN_DISK_GB )); then
  echo "Only ${avail_gb}GiB free under ${SCRIPT_DIR}; need at least ${MIN_DISK_GB}GiB." >&2
  echo "This lab pulls large images and stores kind node filesystems in podman volumes." >&2
  echo "Resize/grow the VM disk (cloud images are often ~10GiB) and retry." >&2
  df -h "${SCRIPT_DIR}" >&2
  exit 1
fi

kind create cluster \
  --config "${SCRIPT_DIR}/kind-config.yaml" \
  --name openshift-dev \
  --kubeconfig "${KUBECONFIG}"

# shellcheck source=lib/raise-kind-pids.sh
source "${SCRIPT_DIR}/lib/raise-kind-pids.sh"
raise_kind_node_pids openshift-dev

echo "Waiting for API server..."
kubectl wait --for=condition=Ready node/openshift-dev-control-plane --timeout=300s

# Worker /etc/hosts sometimes lacks the control-plane entry after join. Without it,
# kindnet/kube-proxy cannot resolve openshift-dev-control-plane and CNI never installs.
"${SCRIPT_DIR}/01-configure-node-hosts.sh"

# RHEL 10 / nftables-only hosts: kube-proxy + kindnet iptables MASQ break ClusterIP.
# Must run BEFORE CoreDNS readiness waits in 01-configure-cluster-dns.sh, otherwise
# that script times out and run.sh never reaches this fix.
if grep -sq "Red Hat Enterprise Linux release 10" /etc/redhat-release ; then
"${SCRIPT_DIR}/01-configure-kube-proxy-nftables.sh"
fi

# CoreDNS loops if it forwards to /etc/resolv.conf while the node resolver points back
# at cluster DNS. Patch it before waiting for the worker node.
"${SCRIPT_DIR}/01-configure-cluster-dns.sh"

echo "Waiting for all nodes to be ready..."
kubectl wait --for=condition=Ready node --all --timeout=300s
