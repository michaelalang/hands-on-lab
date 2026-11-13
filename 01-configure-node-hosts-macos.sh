#!/opt/homebrew/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -z "${KUBECONFIG:-}" ]]; then
  export KUBECONFIG="${SCRIPT_DIR}/kubeconfig"
fi

CLUSTER_NAME="${CLUSTER_NAME:-openshift-dev}"
CONTROL_PLANE_NODE="${CONTROL_PLANE_NODE:-${CLUSTER_NAME}-control-plane}"

ensure_kind_provider() {
  if [[ -n "${KIND_EXPERIMENTAL_PROVIDER:-}" ]]; then
    return
  fi
  if podman container exists "${CONTROL_PLANE_NODE}" 2>/dev/null; then
    export KIND_EXPERIMENTAL_PROVIDER=podman
  fi
}

ensure_kubeconfig() {
  if kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null | grep -q . \
    && kubectl cluster-info >/dev/null 2>&1; then
    return
  fi

  ensure_kind_provider
  echo "Refreshing ${KUBECONFIG} from kind cluster ${CLUSTER_NAME}..."
  local tmp="${KUBECONFIG}.tmp.$$"
  if ! kind get kubeconfig --name "${CLUSTER_NAME}" > "${tmp}" 2>/dev/null; then
    rm -f "${tmp}"
    echo "Could not export kubeconfig for cluster '${CLUSTER_NAME}'." >&2
    echo "Is the cluster running? Check: kind get clusters" >&2
    exit 1
  fi
  mv "${tmp}" "${KUBECONFIG}"
  chmod 600 "${KUBECONFIG}"
}

kind_node_exec() {
  local node=$1
  shift
  if podman container exists "$node" 2>/dev/null; then
    podman exec "$node" "$@"
  elif docker container inspect "$node" >/dev/null 2>&1; then
    docker exec "$node" "$@"
  else
    echo "kind node container ${node} not found (podman or docker)" >&2
    return 1
  fi
}

ensure_kubeconfig

CP_IP="$(kubectl get node "${CONTROL_PLANE_NODE}" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || true)"
if [[ -z "${CP_IP}" ]]; then
  CP_IP="$(kind_node_exec "${CONTROL_PLANE_NODE}" awk '$2 == "'"${CONTROL_PLANE_NODE}"'" && $1 !~ /^fc00:/ { print $1; exit }' /etc/hosts 2>/dev/null || true)"
fi
if [[ -z "${CP_IP}" ]]; then
  ensure_kind_provider
  if podman container exists "${CONTROL_PLANE_NODE}" 2>/dev/null; then
    CP_IP="$(podman inspect "${CONTROL_PLANE_NODE}" --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')"
  elif docker container inspect "${CONTROL_PLANE_NODE}" >/dev/null 2>&1; then
    CP_IP="$(docker inspect "${CONTROL_PLANE_NODE}" --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')"
  fi
fi
if [[ -z "${CP_IP}" ]]; then
  echo "Could not determine control-plane InternalIP for ${CONTROL_PLANE_NODE}" >&2
  exit 1
fi

CP_IP6="$(kubectl get node "${CONTROL_PLANE_NODE}" -o jsonpath='{.status.addresses[?(@.type=="InternalIPv6")].address}' 2>/dev/null || true)"
if [[ -z "${CP_IP6}" ]]; then
  CP_IP6="$(kind_node_exec "${CONTROL_PLANE_NODE}" awk "\$2 == \"${CONTROL_PLANE_NODE}\" && \$1 ~ /^fc00:/ { print \$1; exit }" /etc/hosts 2>/dev/null || true)"
fi

echo "Ensuring worker nodes resolve ${CONTROL_PLANE_NODE} (${CP_IP})..."

WORKER_NODES=()
for _ in $(seq 1 60); do
  mapfile -t WORKER_NODES < <(
    kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' \
      | grep -v "${CONTROL_PLANE_NODE}" || true
  )
  if [[ "${#WORKER_NODES[@]}" -gt 0 ]]; then
    break
  fi
  sleep 2
done

if [[ "${#WORKER_NODES[@]}" -eq 0 ]]; then
  mapfile -t WORKER_NODES < <(
    { podman ps --format '{{.Names}}' 2>/dev/null; docker ps --format '{{.Names}}' 2>/dev/null; } \
      | grep "^${CLUSTER_NAME}-" | grep -v control-plane | sort -u || true
  )
fi

if [[ "${#WORKER_NODES[@]}" -eq 0 ]]; then
  echo "No worker nodes registered after 120s." >&2
  exit 1
fi

for node in "${WORKER_NODES[@]}"; do
  if kind_node_exec "${node}" grep -qE "[[:space:]]${CONTROL_PLANE_NODE}([[:space:]]|$)" /etc/hosts; then
    echo "  ${node}: ${CONTROL_PLANE_NODE} already in /etc/hosts"
    continue
  fi

  echo "  ${node}: adding ${CONTROL_PLANE_NODE} to /etc/hosts"
  kind_node_exec "${node}" sh -c "echo '${CP_IP} ${CONTROL_PLANE_NODE}' >> /etc/hosts"
  if [[ -n "${CP_IP6}" ]]; then
    kind_node_exec "${node}" sh -c "echo '${CP_IP6} ${CONTROL_PLANE_NODE}' >> /etc/hosts"
  fi

  kubectl delete pod -n kube-system -l k8s-app=kindnet --field-selector "spec.nodeName=${node}" --wait=false
  kubectl delete pod -n kube-system -l k8s-app=kube-proxy --field-selector "spec.nodeName=${node}" --wait=false
done

echo "Node host entries configured."
