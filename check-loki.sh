#!/usr/bin/env bash
# Get Grafana admin password
password=$(oc get secret --namespace logging grafana -o jsonpath="{.data.admin-password}" | base64 --decode)

# Port forward Grafana UI (login: admin / password above)
echo "Login: address: 127.0.0.1 port: 3000 user: admin password: ${password}"
oc port-forward --namespace logging service/grafana 3000:80 --address 0.0.0.0 >/dev/null 2>&1 &
