## Introduction
This repo is the demo for the Kubecon EU 23 talk: "Sustainability Through Accountability in a CNCF Ecosystem" by Yuval Lifshitz (IBM) & Huamin Chen (Red Hat).

Abstract:
Carbon footprint and energy consumption accounting is essential to sustainable Cloud native computing. 
However, such capability is quite challenging in multi-tenant services such as compute and storage. 
This session explains how to use CNCF projects to achieve this goal. Specifically, the Rook operator provides cloud-native storage to applications, orchestrating the Ceph storage system. 
Recently, tracing was added to Ceph, using an Open Telemetry client and Jaeger backend. 
In this talk, we would show how we combine per pod energy consumption data coming from Kepler, together with the tracing information coming from Jaeger to estimate the energy consumption of each user in the storage system, 
even when the consumption is spread among multiple pods. This solution highlights the feasibility of building sustainable computing futures in the CNCF ecosystems. 
It will benefit both end users and developers and inspire more innovations.

See: https://events.linuxfoundation.org/kubecon-cloudnativecon-europe/program/schedule/

## K8s Setup
install [minikube](https://minikube.sigs.k8s.io/docs/). 
minikube requires lots of storage in rootfs. So I moved it to a data partition that is on `/dev/vdd`:
```
$ export MINIKUBE_HOME=/data/minikube
$ mount /dev/vdd /data
$ minikube addons disable storage-provisioner
```
run minikube with enough CPUs, cri-o container runtime, and 2 extra disks (for 2 OSDs):
```
$ minikube start --cpus 10 --memory 32GB --disk-size=400g --extra-disks=2 --driver=kvm2 --force --container-runtime cri-o
```
install [kubectl](https://kubernetes.io/docs/tasks/tools/install-kubectl-linux/) and use from from the host:
```
$ eval $(minikube docker-env)
```

## Install Kepler
> TODO

## Install Jaeger
* install cert-manager:
```
$ kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.11.0/cert-manager.yaml
```
* install jaeger in the observability namespace:
```
$ kubectl create namespace observability
$ kubectl apply -f https://github.com/jaegertracing/jaeger-operator/releases/download/v1.42.0/jaeger-operator.yaml -n observability
```
## Create Jaeger Instance
* create a simple all-in-one pod:
```
$ cat << EOF | kubectl apply -f -
apiVersion: jaegertracing.io/v1
kind: Jaeger
metadata:
  name: simplest
  namespace: observability
EOF
```
* expose the query api as a `NodePort` service:
```
$ cat << EOF | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: simplest-query-external
  namespace: observability
  labels:
    app: jaeger
    app.kubernetes.io/component: service-query
    app.kubernetes.io/instance: simplest
    app.kubernetes.io/name: simplest-query
    app.kubernetes.io/part-of: jaeger
spec:
  ports:
  - name: http-query
    port: 16686
    protocol: TCP
    targetPort: 16686
  selector:
    app.kubernetes.io/component: all-in-one
    app.kubernetes.io/instance: simplest
    app.kubernetes.io/name: simplest
    app.kubernetes.io/part-of: jaeger
    app: jaeger
  sessionAffinity: None
  type: NodePort
EOF
```

## Install Rook
* make sure there are disks without a filesystem:
```
$ minikube ssh lsblk
```
* download and install rook operator (use v1.10):
```
$ git clone -b release-1.10 https://github.com/rook/rook.git
$ cd rook/deploy/examples
$ kubectl create -f crds.yaml -f common.yaml
```
in `operator.yaml` increase debug level:
```yaml
data:
  # The logging level for the operator: ERROR | WARNING | INFO | DEBUG
  ROOK_LOG_LEVEL: "DEBUG"
```
then apply the oprator:
```
$ kubectl create -f operator.yaml
```
## Start a Ceph Cluster with Object Store
use a developer build of ceph that supports tracing. to do that edit `cluster-test.yaml` and replace the line:
```yaml
image: quay.io/ceph/ceph:v17
```
with:
```yaml
image: quay.ceph.io/ceph-ci/ceph:wip-yuval-full-putobj-trace
```
add the following jaeger argumnets in the `ConfigMap` in `cluster-test.yaml` under the `[global]` section:
```yaml
jaeger_tracing_enable = true
jaeger_agent_port = 6831
```
add annotations to the cluster. so that jaeger will inject an agent side-car to OSD pods:
```yaml
spec:
  annotations:
    osd:
      sidecar.jaegertracing.io/inject: "true"
```
and apply the cluster:
```
$ kubectl create -f cluster-test.yaml
```
start the object store:
```
kubectl create -f object-test.yaml
```
* add annotations to the object store. so that jaeger will inject an agent side-car to RGW pods:
```yaml
gateway:
  annotations:
    sidecar.jaegertracing.io/inject: "true"
```
## Test
* we will create storage class and a bucket:
```
$ kubectl create -f storageclass-bucket-delete.yaml
$ kubectl create -f object-bucket-claim-delete.yaml
```
* create a service so that it could be accessed from outside of k8s:
```
$ cat << EOF | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: rook-ceph-rgw-my-store-external
  namespace: rook-ceph
  labels:
    app: rook-ceph-rgw
    rook_cluster: rook-ceph
    rook_object_store: my-store
spec:
  ports:
  - name: rgw
    port: 80
    protocol: TCP
    targetPort: 8080
  selector:
    app: rook-ceph-rgw
    rook_cluster: rook-ceph
    rook_object_store: my-store
  sessionAffinity: None
  type: NodePort
EOF
```
* fetch the URL that allow access to the RGW service from the host running the minikube VM:
```
$ export AWS_URL=$(minikube service --url rook-ceph-rgw-my-store-external -n rook-ceph)
```
* user credentials and bucket name:
```
$ export AWS_ACCESS_KEY_ID=$(kubectl -n default get secret ceph-delete-bucket -o jsonpath='{.data.AWS_ACCESS_KEY_ID}' | base64 --decode)
$ export AWS_SECRET_ACCESS_KEY=$(kubectl -n default get secret ceph-delete-bucket -o jsonpath='{.data.AWS_SECRET_ACCESS_KEY}' | base64 --decode)
$ export BUCKET_NAME=$(kubectl get objectbucketclaim ceph-delete-bucket -o jsonpath='{.spec.bucketName}')
```
* now use them to upload an object:
```
$ echo "hello world" > hello.txt
$ aws --endpoint-url "$AWS_URL" s3 cp hello.txt s3://"$BUCKET_NAME"
```
* fetch the URL that allow access to the jaeger query service from the host running the minikube VM:
```
$ export JAEGER_URL=$(minikube service --url simplest-query-external -n observability)
```
* query traces:
```
$ curl "$JAEGER_URL/api/traces?service=rgw&limit=20&lookback=1h" | jq
```

## Demo
* install python dependencies:
```
$ pip3 install --user tabulate
```
* run the demo:
```
$ ./run-demo.sh
```
* output should contain a table with buckets and their consumed energy across the Ceph pods. e.g.
```
╒═══════════════════════════════════════════════════════════════╤═══════════════╕
│ bucket name                                                   │   energy (KJ) │
╞═══════════════════════════════════════════════════════════════╪═══════════════╡
│ internal                                                      │   23520.2     │
├───────────────────────────────────────────────────────────────┼───────────────┤
│ ceph-bkt-medium-6d4b93dc-1bff-4d64-a265-5a09a02c896b          │     111.789   │
├───────────────────────────────────────────────────────────────┼───────────────┤
│ ceph-bkt-heavy-add7d77f-e70e-4ed8-81fc-743e590e9058           │     375.454   │
├───────────────────────────────────────────────────────────────┼───────────────┤
│ ceph-bkt-light-40a72c91-a3a3-4790-bebc-b9621c653921           │      47.1053  │
├───────────────────────────────────────────────────────────────┼───────────────┤
│ rook-ceph-bucket-checker-690ed6e1-8728-4846-9a05-4ceb6f499a93 │       3.82984 │
╘═══════════════════════════════════════════════════════════════╧═══════════════╛
```

