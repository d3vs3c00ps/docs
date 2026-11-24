---
title: "An ElasticSearch Operator"
description: "We will install Elastic Cloud on Kubernetes, an ElasticSearch operator"
tags: [kubernetes, api, operators, elasticsearch]
type: lab
status: complete
source: https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/eck.md
license: CC-BY-4.0
upstream_commit: 56563629
upstream_sync: manual
---

# An ElasticSearch Operator

> [!important] These labs expect the upstream repository
> Commands below reference files by their path in a local clone. Get it with:
>
> ```bash
> git clone https://github.com/jpetazzo/container.training
> ```
>
> The manifests can also be browsed at the pinned commit
> [`56563629`](https://github.com/jpetazzo/container.training/tree/565636291ec03abf1f2ab8bf6b935478e00e69a2).

- We will install [Elastic Cloud on Kubernetes](https://www.elastic.co/guide/en/cloud-on-k8s/current/k8s-quickstart.html), an ElasticSearch operator

- This operator requires PersistentVolumes

- We will install Rancher's [local path storage provisioner](https://github.com/rancher/local-path-provisioner) to automatically create these

- Then, we will create an ElasticSearch resource

- The operator will detect that resource and provision the cluster

- We will integrate that ElasticSearch cluster with other resources

  (Kibana, Filebeat, Cerebro ...)

> [!warning] ECK 3.5.0, not the upstream files
> This page installs ECK 3.5.0 from Elastic, and writes the Elasticsearch and Kibana
> resources inline, for version 9.5.5. Tested on kind 1.37 (arm64). Do not use the
> files `k8s/eck-*.yaml` from the upstream repository (ECK 1.0.0, Elasticsearch and
> Filebeat 7.5.1): the operator file defines its CRDs with
> `apiextensions.k8s.io/v1beta1` (removed in Kubernetes 1.22), and the 7.5.1 images
> are amd64 only. The Filebeat and Cerebro steps are not tested.

## Installing a Persistent Volume provisioner

(This step can be skipped if you already have a dynamic volume provisioner. kind
has one: its `standard` StorageClass uses the same local path provisioner.)

- This provisioner creates Persistent Volumes backed by `hostPath`

  (local directories on our nodes)

- It doesn't require anything special ...

- ... But losing a node = losing the volumes on that node!

> [!example] Hands-on
> - Install the local path storage provisioner:
>   ```bash
>   kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.37/deploy/local-path-storage.yaml
>   ```

## Making sure we have a default StorageClass

- The ElasticSearch operator will create StatefulSets

- These StatefulSets will instantiate PersistentVolumeClaims

- These PVCs need to be explicitly associated with a StorageClass

- Or we need to tag a StorageClass to be used as the default one

> [!example] Hands-on
> - List StorageClasses:
>   ```bash
>   kubectl get storageclasses
>   ```

We should see the `local-path` StorageClass.

## Setting a default StorageClass

- This is done by adding an annotation to the StorageClass:

  `storageclass.kubernetes.io/is-default-class: true`

> [!example] Hands-on
> - Tag the StorageClass so that it's the default one:
>   ```bash
>   kubectl annotate storageclass local-path \
>             storageclass.kubernetes.io/is-default-class=true
>   ```
>
> - Check the result:
>   ```bash
>   kubectl get storageclasses
>   ```

Now, the StorageClass should have `(default)` next to its name. (If another
StorageClass is also marked as default, as on kind, new PVCs get the most recent one.)

## Install the ElasticSearch operator

- The operator provides:

  - a few CustomResourceDefinitions
  - a Namespace for its other resources
  - a ValidatingWebhookConfiguration for type checking
  - a StatefulSet for its controller and webhook code
  - a ServiceAccount, ClusterRole, ClusterRoleBinding for permissions

- Elastic publishes them in two YAML files: the CRDs, and the operator

> [!example] Hands-on
> - Install the operator:
>   ```bash
>   kubectl create -f https://download.elastic.co/downloads/eck/3.5.0/crds.yaml
>   kubectl apply -f https://download.elastic.co/downloads/eck/3.5.0/operator.yaml
>   ```

## Check our new custom resources

- Let's see which CRDs were created

> [!example] Hands-on
> - List all CRDs:
>   ```bash
>   kubectl get crds
>   ```

This operator supports ElasticSearch, but also Kibana, APM Server, Beats, Elastic Agent,
Logstash and more. Cool!

## Create the `eck-demo` namespace

- For clarity, we will create everything in a new namespace, `eck-demo`

- This namespace is hard-coded in the YAML that we are going to use

- We need to create that namespace

> [!example] Hands-on
> - Create the `eck-demo` namespace:
>   ```bash
>   kubectl create namespace eck-demo
>   ```
>
> - Switch to that namespace:
>   ```bash
>   kubectl config set-context --current --namespace eck-demo
>   ```

## Create an ElasticSearch resource

- We can now create a resource with `kind: Elasticsearch`

- The YAML for that resource will specify all the desired parameters:

  - how many nodes we want
  - which version to run
  - whether to use TLS or not
  - resources, configuration, etc.

> [!example] Hands-on
> - Create our ElasticSearch cluster:
>   ```bash
>   kubectl apply -f- <<EOF
>   apiVersion: elasticsearch.k8s.elastic.co/v1
>   kind: Elasticsearch
>   metadata:
>     name: demo
>     namespace: eck-demo
>   spec:
>     version: 9.5.5
>     http:
>       tls:
>         selfSignedCertificate:
>           disabled: true
>     nodeSets:
>     - name: default
>       count: 1
>       config:
>         node.store.allow_mmap: false
>       podTemplate:
>         spec:
>           containers:
>           - name: elasticsearch
>             resources:
>               requests: {memory: 1Gi}
>               limits: {memory: 1Gi}
>   EOF
>   ```

- `node.store.allow_mmap: false` avoids the `vm.max_map_count` kernel setting (fine for
  a lab, not for production)

- 1 GiB of memory per node is small, but enough for a lab (the default is 2 GiB)

## Operator in action

- Over the next minutes, the operator will create our ES cluster

- It will report our cluster status through the CRD

> [!example] Hands-on
> - Check the logs of the operator:
>   ```bash
>   stern --namespace=elastic-system operator
>   ```
>
> - Watch the status of the cluster through the CRD:
>   ```bash
>   kubectl get es -w
>   ```

## Connecting to our cluster

- It's not easy to use the ElasticSearch API from the shell

- But let's check at least if ElasticSearch is up!

> [!example] Hands-on
> - Get the ClusterIP of our ES instance:
>   ```bash
>   kubectl get services
>   CLUSTERIP=$(kubectl get service demo-es-http -o jsonpath={.spec.clusterIP})
>   ```
>
> - Issue a request with `curl`:
>   ```bash
>   curl http://$CLUSTERIP:9200
>   ```

We get an authentication error. Our cluster is protected!

## Obtaining the credentials

- The operator creates a user named `elastic`

- It generates a random password and stores it in a Secret

> [!example] Hands-on
> - Extract the password:
>   ```bash
>   PASSWORD=$(kubectl get secret demo-es-elastic-user \
>             -o go-template="{{ .data.elastic | base64decode }}")
>   ```
>
> - Use it to connect to the API:
>   ```bash
>   curl -u elastic:$PASSWORD http://$CLUSTERIP:9200
>   ```

We should see a JSON payload with the `"You Know, for Search"` tagline.

## Sending data to the cluster

> [!note] Not updated
> These steps use the upstream `k8s/eck-filebeat.yaml` (Filebeat 7.5.1). It was not
> updated or tested. With current ECK, a `kind: Beat` resource with `type: filebeat`
> and `elasticsearchRef` does the same job.

- Let's send some data to our brand new ElasticSearch cluster!

- We'll deploy a filebeat DaemonSet to collect node logs

> [!example] Hands-on
> - Deploy filebeat:
>   ```bash
>   kubectl apply -f ~/container.training/k8s/eck-filebeat.yaml
>   ```
>
> - Wait until some pods are up:
>   ```bash
>   watch kubectl get pods -l k8s-app=filebeat
>   ```
>
> - Check that a filebeat index was created:
>   ```bash
>   curl -u elastic:$PASSWORD http://$CLUSTERIP:9200/_cat/indices
>   ```

## Deploying an instance of Kibana

- Kibana can visualize the logs injected by filebeat

- The ECK operator can also manage Kibana

- Let's give it a try!

> [!example] Hands-on
> - Deploy a Kibana instance:
>   ```bash
>   kubectl apply -f- <<EOF
>   apiVersion: kibana.k8s.elastic.co/v1
>   kind: Kibana
>   metadata:
>     name: demo
>     namespace: eck-demo
>   spec:
>     version: 9.5.5
>     count: 1
>     elasticsearchRef:
>       name: demo
>     http:
>       service:
>         spec:
>           type: NodePort
>       tls:
>         selfSignedCertificate:
>           disabled: true
>   EOF
>   ```
>
> - Wait for it to be ready:
>   ```bash
>   kubectl get kibana -w
>   ```

## Connecting to Kibana

- Kibana is automatically set up to connect to ElasticSearch

  (this is arranged by `elasticsearchRef`)

- However, it will ask for authentication

- It's using the same user/password as ElasticSearch

> [!example] Hands-on
> - Get the NodePort allocated to Kibana:
>   ```bash
>   kubectl get services
>   ```
>
> - Connect to it with a web browser
>
> - Use the same user/password as before

## Setting up Kibana

After the Kibana UI loads, we need to click around a bit. (The menus change between
Kibana versions; this was not checked with 9.5.)

> [!example] Hands-on
> - Pick "explore on my own"
>
> - Click on "Use Elasticsearch data" / "Connect to your Elasticsearch index"
>
> - Enter `filebeat-*` for the index pattern and click "Next step"
>
> - Select `@timestamp` as time filter field name
>
> - Click on "discover" (the small icon looking like a compass on the left bar)
>
> - Play around!

## Scaling up the cluster

- At this point, we have only one node

- We are going to scale up

- But first, we'll deploy Cerebro, a UI for ElasticSearch

- This will let us see the state of the cluster, how indexes are sharded, etc.

## Deploying Cerebro

> [!note] Not updated
> `k8s/eck-cerebro.yaml` uses `lmenezes/cerebro`, last released in 2021. It was not
> tested. `curl -u elastic:$PASSWORD http://$CLUSTERIP:9200/_cat/health` shows the
> cluster health without it.

- Cerebro is stateless, so it's fairly easy to deploy

  (one Deployment + one Service)

- However, it needs the address and credentials for ElasticSearch

- We prepared yet another manifest for that!

> [!example] Hands-on
> - Deploy Cerebro:
>   ```bash
>   kubectl apply -f ~/container.training/k8s/eck-cerebro.yaml
>   ```
>
> - Lookup the NodePort number and connect to it:
>   ```bash
>   kubectl get services
>   ```

## Scaling up the cluster

- With indices that have replicas, a single-node cluster is "yellow"

  (the replicas cannot be placed on another node)

- Let's change that!

> [!example] Hands-on
> - Edit the ElasticSearch cluster manifest:
>   ```bash
>   kubectl edit es demo
>   ```
>
> - Find the field `count: 1` and change it to 3
>
> - Save and quit

---

> [!info] Adapted from container.training
> This page is derived from [`slides/k8s/eck.md`](https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/eck.md)
> in **[container.training](https://github.com/jpetazzo/container.training)** by Jérôme Petazzoni and contributors,
> used under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).
> **Changes were made**: restructured from slides into a single page, remark
> markup converted to Obsidian callouts, referenced files inlined or linked,
> updated to ECK 3.5.0 and Elasticsearch 9.5.5, tested on kind.

<!-- uplink -->
Part of [[kubernetes/extending/index|Extending Kubernetes]].
