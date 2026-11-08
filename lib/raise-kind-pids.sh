#!/usr/bin/env bash
# Podman defaults kind node containers to pids_limit=2048. Inside the node,
# systemd DefaultTasksMax (~15% of that) caps every Kubernetes container at
# ~307 PIDs. Splunk needs hundreds of processes for search jobs; when the
# limit is hit, Results API Splunk polls hang in PARSING and the Dashboard
# external-logs path times out with "no logs found".

raise_kind_node_pids() {
  local cluster="${1:-openshift-dev}"
  local provider="${KIND_EXPERIMENTAL_PROVIDER:-}"
  local node

  if [[ -z "${provider}" ]]; then
    if command -v podman >/dev/null 2>&1 && podman info >/dev/null 2>&1; then
      provider=podman
    else
      provider=docker
    fi
  fi

  if [[ "${provider}" != "podman" ]]; then
    return 0
  fi

  if ! command -v kind >/dev/null 2>&1; then
    echo "kind not found; skipping PID limit raise." >&2
    return 0
  fi

  echo "Raising podman PID limits on kind nodes (required for Splunk search)..."
  while IFS= read -r node; do
    [[ -n "${node}" ]] || continue
    if ! podman update --pids-limit=-1 "${node}" >/dev/null 2>&1; then
      echo "Warning: could not set --pids-limit=-1 on ${node}." >&2
      continue
    fi
    podman exec "${node}" sh -c '
      echo max > /sys/fs/cgroup/pids.max 2>/dev/null || true
      mkdir -p /etc/systemd/system.conf.d
      printf "[Manager]\nDefaultTasksMax=infinity\n" > /etc/systemd/system.conf.d/99-pids.conf
      # Raise existing container scopes that inherited DefaultTasksMax (~307).
      find /sys/fs/cgroup/kubelet.slice -name pids.max 2>/dev/null | while read -r f; do
        cur="$(cat "${f}" 2>/dev/null || true)"
        if [[ -n "${cur}" && "${cur}" != "max" ]]; then
          echo max > "${f}" 2>/dev/null || true
        fi
      done
    ' >/dev/null 2>&1 || true
    echo "  ${node}: pids_limit=$(podman inspect "${node}" --format '{{.HostConfig.PidsLimit}}')"
  done < <(KIND_EXPERIMENTAL_PROVIDER=podman kind get nodes --name "${cluster}" 2>/dev/null)
}

check_splunk_pids() {
  local pod max cur
  pod="$(kubectl get pod -n logging -l app=splunk-hec -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  [[ -n "${pod}" ]] || return 0

  max="$(kubectl exec -n logging "${pod}" -- sh -c 'cat /sys/fs/cgroup/pids.max 2>/dev/null' 2>/dev/null || true)"
  cur="$(kubectl exec -n logging "${pod}" -- sh -c 'cat /sys/fs/cgroup/pids.current 2>/dev/null' 2>/dev/null || true)"
  if [[ -z "${max}" || -z "${cur}" ]]; then
    return 0
  fi

  echo "Splunk cgroup PIDs: ${cur}/${max}"
  if [[ "${max}" != "max" && "${max}" =~ ^[0-9]+$ ]]; then
    if (( cur * 100 / max >= 85 )); then
      echo "WARNING: Splunk is near its PID limit (${cur}/${max}). Search jobs will hang and Dashboard external logs will time out." >&2
      echo "Run: source lib/raise-kind-pids.sh && raise_kind_node_pids" >&2
      return 1
    fi
  fi
  return 0
}
