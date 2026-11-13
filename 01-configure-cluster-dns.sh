#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export KUBECONFIG="${KUBECONFIG:-${SCRIPT_DIR}/kubeconfig}"

# Comma-separated list for CoreDNS forward plugin, e.g. "8.8.8.8,1.1.1.1"
UPSTREAM_DNS="${UPSTREAM_DNS:-8.8.8.8,1.1.1.1}"

IFS=',' read -r -a UPSTREAM_DNS_ARRAY <<< "${UPSTREAM_DNS}"
if [[ "${#UPSTREAM_DNS_ARRAY[@]}" -eq 0 || -z "${UPSTREAM_DNS_ARRAY[0]}" ]]; then
  echo "UPSTREAM_DNS must contain at least one resolver." >&2
  exit 1
fi

FORWARD_TO="${UPSTREAM_DNS_ARRAY[*]}"

NAMESERVERS_JSON="["
for i in "${!UPSTREAM_DNS_ARRAY[@]}"; do
  [[ "${i}" -eq 0 ]] || NAMESERVERS_JSON+=","
  NAMESERVERS_JSON+="\"${UPSTREAM_DNS_ARRAY[i]}\""
done
NAMESERVERS_JSON+="]"

echo "Configuring CoreDNS (upstream: ${FORWARD_TO})..."
cat > /tmp/coredns-Corefile <<EOF
.:53 {
    errors
    health {
       lameduck 5s
    }
    ready
    kubernetes cluster.local in-addr.arpa ip6.arpa {
       pods insecure
       fallthrough in-addr.arpa ip6.arpa
       ttl 30
    }
    prometheus :9153
    forward . ${FORWARD_TO} {
       max_concurrent 1000
    }
    cache 30 {
       disable success cluster.local
       disable denial cluster.local
    }
    loop
    reload
    loadbalance
}
EOF

kubectl create configmap coredns \
  --from-file=Corefile=/tmp/coredns-Corefile \
  -n kube-system \
  --dry-run=client -o yaml | kubectl apply -f -

# Default dnsPolicy inherits the node resolver (often 127.0.0.11 on podman kind),
# which can point back at cluster DNS and trigger plugin/loop fatal errors.
kubectl patch deployment coredns -n kube-system --type=strategic -p "$(cat <<EOF
{
  "spec": {
    "template": {
      "spec": {
        "dnsPolicy": "None",
        "dnsConfig": {
          "nameservers": ${NAMESERVERS_JSON},
          "searches": ["svc.cluster.local", "cluster.local"],
          "options": [
            {"name": "ndots", "value": "5"}
          ]
        }
      }
    }
  }
}
EOF
)"

kubectl rollout restart deployment/coredns -n kube-system
kubectl rollout status deployment/coredns -n kube-system --timeout=180s
kubectl wait --for=condition=ready pod -l k8s-app=kube-dns -n kube-system \
  --field-selector=status.phase=Running --timeout=180s

if kubectl wait --for=condition=Ready node --all --timeout=60s 2>/dev/null; then
  echo "Verifying in-cluster DNS for Kubernetes service FQDNs..."
  kubectl run dns-verify --rm -i --restart=Never --image=busybox:1.36 -- \
    sh -c '
      set -e
      echo "=== /etc/resolv.conf ==="
      cat /etc/resolv.conf
      echo "=== cluster service FQDN ==="
      nslookup kubernetes.default.svc.cluster.local
    ' || echo "DNS verification pod failed; CoreDNS is running — retry once nodes are Ready."
else
  echo "Nodes not fully Ready yet; skipped DNS verification pod."
fi

echo "Cluster DNS configuration complete."
