#!/usr/bin/env bash
# Port forward Splunk-HEC UI (login: admin / password changeme)
echo "address 127.0.0.1:8080 login: admin / password changeme"
kubectl port-forward --namespace logging service/splunk-hec 8000:8000 --address 0.0.0.0 >/dev/null 2>&1 &
