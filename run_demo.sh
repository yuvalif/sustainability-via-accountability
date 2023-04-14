#!/bin/bash

# generate 3 buckets
cat << EOF | kubectl apply -f -
apiVersion: objectbucket.io/v1alpha1
kind: ObjectBucketClaim
metadata:
  name: ceph-bucket-heavy
spec:
  generateBucketName: ceph-bkt-heavy
  storageClassName: rook-ceph-delete-bucket
---
apiVersion: objectbucket.io/v1alpha1
kind: ObjectBucketClaim
metadata:
  name: ceph-bucket-medium
spec:
  generateBucketName: ceph-bkt-medium
  storageClassName: rook-ceph-delete-bucket
---
apiVersion: objectbucket.io/v1alpha1
kind: ObjectBucketClaim
metadata:
  name: ceph-bucket-light
spec:
  generateBucketName: ceph-bkt-light
  storageClassName: rook-ceph-delete-bucket
EOF


echo "generating files for parallel uploads (may take a while)"

mkdir -p ceph-bucket-light
mkdir -p ceph-bucket-medium
mkdir -p ceph-bucket-heavy

i=0

while [ $i -lt 500 ]; do
  # object size between 1MB and 10MB
  obj_size=$((1 + $RANDOM % 10))
  obc_id=$((1 + $RANDOM % 100))
  if [ $obc_id -lt 10 ]; then
    # 10% of objects go to "light" bucket/user
    head -c "$obj_size"M /dev/urandom > ceph-bucket-light/obj$i
  elif [ $obc_id -lt 40 ]; then
    # 30% of objects go to "medium" bucket/user
    head -c "$obj_size"M /dev/urandom > ceph-bucket-medium/obj$i
  else
    # 60% of objects got to "heavy" bucket/user
    head -c "$obj_size"M /dev/urandom > ceph-bucket-heavy/obj$i
  fi
  ((i++))
done

AWS_URL=$(minikube service --url rook-ceph-rgw-my-store-external -n rook-ceph)

echo "uploading objects to: $AWS_URL"

# fetch the kepler stats before we start to upload objects
kubectl exec -ti -n monitoring prometheus-k8s-0 -- sh -c 'wget -O- -q "localhost:9090/api/v1/query?query=kepler_container_joules_total{container_namespace=~\"rook-ceph\",mode=~\"dynamic\"}"[3s]' > kepler_start.json

for obc_name in ceph-bucket-light ceph-bucket-medium ceph-bucket-heavy; do
  bucket_name=$(kubectl get objectbucketclaim $obc_name -o jsonpath='{.spec.bucketName}')
  access_key=$(kubectl -n default get secret $obc_name -o jsonpath='{.data.AWS_ACCESS_KEY_ID}' | base64 --decode)
  secret_key=$(kubectl -n default get secret $obc_name -o jsonpath='{.data.AWS_SECRET_ACCESS_KEY}' | base64 --decode)
  AWS_ACCESS_KEY_ID=$access_key AWS_SECRET_ACCESS_KEY=$secret_key aws --endpoint-url $AWS_URL s3 sync $obc_name s3://$bucket_name/
done

# fetch the kepler stats after we done uploading objects
kubectl exec -ti -n monitoring prometheus-k8s-0 -- sh -c 'wget -O- -q "localhost:9090/api/v1/query?query=kepler_container_joules_total{container_namespace=~\"rook-ceph\",mode=~\"dynamic\"}"[3s]' > kepler_end.json

# fetch the ceph traces
JAEGER_URL=$(minikube service --url simplest-query-external -n observability)
curl "$JAEGER_URL/api/traces?service=rgw&limit=5000&lookback=1h" > rgw_traces.json 

# calculate the energy
python calculate_energy.py

