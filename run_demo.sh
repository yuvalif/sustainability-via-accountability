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

# fetch the kepler stats before we start to upload objects
kubectl exec -ti -n monitoring prometheus-k8s-0 -- sh -c 'wget -O- -q "localhost:9090/api/v1/query?query=kepler_container_joules_total{container_namespace=~\"rook-ceph\",mode=~\"dynamic\"}"[3s]' > kepler_start.json

i=0

AWS_URL=$(minikube service --url rook-ceph-rgw-my-store-external -n rook-ceph)

echo uploading objects to: $AWS_URL

while [ $i -lt 2000 ]; do
  # object size between 1MB and 10MB
  obj_size=$((1 + $RANDOM % 10))
  head -c "$obj_size"M /dev/urandom > tmp.txt
  obc_id=$((1 + $RANDOM % 100))
  if [ $obc_id -lt 10 ]; then
    # 10% of objects go to "light" bucket/user
    obc_name="ceph-bucket-light"
  elif [ $obc_id -lt 40 ]; then
    # 30% of objects go to "medium" bucket/user
    obc_name="ceph-bucket-medium"
  else
    # 60% of objects got to "heavy" bucket/user
    obc_name="ceph-bucket-heavy"
  fi

  bucket_name=$(kubectl get objectbucketclaim $obc_name -o jsonpath='{.spec.bucketName}')
  access_key=$(kubectl -n default get secret $obc_name -o jsonpath='{.data.AWS_ACCESS_KEY_ID}' | base64 --decode)
  secret_key=$(kubectl -n default get secret $obc_name -o jsonpath='{.data.AWS_SECRET_ACCESS_KEY}' | base64 --decode)
  ((i++))
  AWS_ACCESS_KEY_ID=$access_key AWS_SECRET_ACCESS_KEY=$secret_key aws --endpoint-url $AWS_URL s3 cp tmp.txt s3://$bucket_name/tmp$i.txt
done

# fetch the kepler stats after we done uploading objects
kubectl exec -ti -n monitoring prometheus-k8s-0 -- sh -c 'wget -O- -q "localhost:9090/api/v1/query?query=kepler_container_joules_total{container_namespace=~\"rook-ceph\",mode=~\"dynamic\"}"[3s]' > kepler_end.json

# fetch the ceph traces
JAEGER_URL=$(minikube service --url simplest-query-external -n observability)
curl "$JAEGER_URL/api/traces?service=rgw&limit=2000&lookback=1h" > rgw_traces.json 

# calculate the energy
python calculate_energy.py



