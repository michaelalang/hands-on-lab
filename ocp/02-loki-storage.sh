#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export KUBECONFIG="${KUBECONFIG:-${SCRIPT_DIR}/kubeconfig}"

echo "creating namespace openshift-logging"
cat <<'EOF' | kubectl apply -f-
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-logging
EOF

echo "creating objectBucketClaim for LokiStack"
cat <<'EOF' | kubectl -n openshift-logging apply -f-
apiVersion: objectbucket.io/v1alpha1
kind: ObjectBucketClaim
metadata:
  name: lokistack-s3-claim
  namespace: openshift-logging
  labels:
    app: noobaa
    bucket-provisioner: openshift-storage.noobaa.io-obc
    noobaa-domain: openshift-storage.noobaa.io
spec:
  additionalConfig:
    bucketclass: noobaa-default-bucket-class
  generateBucketName: lokistack
  objectBucketName: obc-openshift-logging-lokistack
  storageClassName: openshift-storage.noobaa.io
EOF

echo "Waiting for BucketClaim to be ready"
kubectl -n openshift-logging wait --for=jsonpath='{.status.phase}'=Bound objectBucketClaim lokistack-s3-claim

BUCKETNAME=$(kubectl -n openshift-logging get ObjectBucketClaim lokistack-s3-claim -o jsonpath='{.spec.bucketName}')
ACCESS_KEY=$(kubectl -n openshift-logging get secret lokistack-s3-claim -o jsonpath='{.data.AWS_ACCESS_KEY_ID}' | base64 -d)
SECRET_KEY=$(kubectl -n openshift-logging get secret lokistack-s3-claim -o jsonpath='{.data.AWS_SECRET_ACCESS_KEY}' | base64 -d)

kubectl -n openshift-logging delete secret lokistack-s3 --ignore-not-found

kubectl -n openshift-logging create secret generic lokistack-s3 \
  --from-literal=access_key_id="${ACCESS_KEY}" \
  --from-literal=access_key_secret="${SECRET_KEY}" \
  --from-literal=bucketnames="${BUCKETNAME}" \
  --from-literal=endpoint="https://s3.openshift-storage.svc"
