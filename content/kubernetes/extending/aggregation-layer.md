---
title: "The Aggregation Layer"
description: "The aggregation layer is a way to extend the Kubernetes API"
tags: [kubernetes, api, operators]
type: lab
status: complete
source: https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/aggregation-layer.md
license: CC-BY-4.0
upstream_commit: 56563629
upstream_sync: manual
---

# The Aggregation Layer

- The aggregation layer is a way to extend the Kubernetes API

- It is similar to CRDs

  - it lets us define new resource types

  - these resources can then be used with `kubectl` and other clients

- The implementation is very different

  - CRDs are handled within the API server

  - the aggregation layer offloads requests to another process

- They are designed for very different use-cases

## CRDs vs aggregation layer

- The Kubernetes API is a REST-ish API with a hierarchical structure

- It can be extended with Custom Resource Definitions (CRDs)

- Custom resources are managed by the Kubernetes API server

  - we don't need to write code

  - the API server does all the heavy lifting

  - these resources are persisted in Kubernetes' "standard" database
    (for most installations, that's `etcd`)

- We can also define resources that are *not* managed by the API server

  (the API server merely proxies the requests to another server)

## Which one is best?

- For things that "map" well to objects stored in a traditional database:

  *probably CRDs*

- For things that "exist" only in Kubernetes and don't represent external resources:

  *probably CRDs*

- For things that are read-only, at least from Kubernetes' perspective:

  *probably aggregation layer*

- For things that can't be stored in etcd because of size or access patterns:

  *probably aggregation layer*

## How are resources organized?

- Let's have a look at the Kubernetes API hierarchical structure

- We'll ask `kubectl` to show us the exact requests that it's making

> [!example] Hands-on
> - Check the URI for a cluster-scope, "core" resource, e.g. a Node (use one of your
>   node names; `kubectl get nodes` lists them):
>   ```bash
>   kubectl -v6 get node node1
>   ```
>
> - Check the URI for a cluster-scope, "non-core" resource, e.g. a ClusterRole:
>   ```bash
>   kubectl -v6 get clusterrole view
>   ```

## Core vs non-core

- This is the structure of the URIs that we just checked:

  ```
  /api/v1/nodes/node1
       ↑  ↑     ↑
       │  kind  name
       version

  /apis/rbac.authorization.k8s.io/v1/clusterroles/view
        ↑                         ↑  ↑            ↑
        group                     │  kind         name
                                  version
  ```

- There is no group for "core" resources

- Or, we could say that the group, `core`, is implied

## Group-Version-Kind

- In the API server, the Group-Version-Kind triple maps to a Go type

  (look for all the "GVK" occurrences in the source code!)

- In the API server URI router, the GVK is parsed "relatively early"

  (so that the server can know which resource we're talking about)

- "Well, actually ..." Things are a bit more complicated, see next slides!

> [!note]- Extra details
> ## Namespaced resources
>
> - What about namespaced resources?
>
> > [!example] Hands-on
> > - Check the URI for a namespaced, "core" resource, e.g. a Service:
> >   ```bash
> >   kubectl -v6 get service kubernetes --namespace default
> >   ```
>
> - Here are what namespaced resources URIs look like:
>
>   ```
>   /api/v1/namespaces/default/services/kubernetes
>        ↑             ↑       ↑        ↑
>        version       │       kind     name
>                      namespace
>
>   /apis/apps/v1/namespaces/kube-system/daemonsets/kube-proxy
>         ↑    ↑             ↑           ↑          ↑
>         │    version       namespace   kind       name
>         group
>   ```

> [!note]- Extra details
> ## Subresources
>
> - Many resources have *subresources*, for instance:
>
>   - `/status` (decouples status updates from other updates)
>
>   - `/scale` (exposes a consistent interface for autoscalers)
>
>   - `/proxy` (allows access to HTTP resources)
>
>   - `/portforward` (used by `kubectl port-forward`)
>
>   - `/logs` (access pod logs)
>
> - These are added at the end of the URI

> [!note]- Extra details
> ## Accessing a subresource
>
> > [!example] Hands-on
> > - List `kube-proxy` pods:
> >   ```bash
> >     kubectl get pods --namespace=kube-system --selector=k8s-app=kube-proxy
> >     PODNAME=$(
> >       kubectl get pods --namespace=kube-system --selector=k8s-app=kube-proxy \
> >               -o json | jq -r .items[0].metadata.name)
> >   ```
> >
> > - Execute a command in a pod, showing the API requests:
> >   ```bash
> >   kubectl -v6 exec --namespace=kube-system $PODNAME -- echo hello world
> >   ```
>
> The full request looks like:
> ```
> GET https://.../api/v1/namespaces/kube-system/pods/kube-proxy-c7rlw/exec?
> command=echo&command=hello&command=world&container=kube-proxy&stderr=true&stdout=true
> ```
>
> > [!warning] Correction
> > - The original showed a `POST`. Current kubectl opens a WebSocket, so the request is a
> >   `GET` with an upgrade.
> > - The kube-proxy image is now distroless and has no `echo`: the command fails with
> >   `executable file not found in $PATH`. The `-v6` output still shows the request,
> >   which is the point here. To see `hello world`, use a pod with a shell.

## Listing what's supported on the server

- There are at least three useful commands to introspect the API server

> [!example] Hands-on
> - List resources types, their group, kind, short names, and scope:
>   ```bash
>   kubectl api-resources
>   ```
>
> - List API groups + versions:
>   ```bash
>   kubectl api-versions
>   ```
>
> - List APIServices:
>   ```bash
>   kubectl get apiservices
>   ```

🤔 What's the difference between the last two?

## API registration

- `kubectl api-versions` shows all API groups, including `apiregistration.k8s.io`

- `kubectl get apiservices` shows the "routing table" for API requests

- The latter doesn't show `apiregistration.k8s.io`

  (APIServices belong to `apiregistration.k8s.io`)

- Most API groups are `Local` (handled internally by the API server)

- If we're running the `metrics-server`, it should handle `metrics.k8s.io`

- This is an API group handled *outside* of the API server

- This is the *aggregation layer!*

## Finding resources

The following assumes that `metrics-server` is deployed on your cluster.

> [!example] Hands-on
> - Check that the metrics.k8s.io is registered with `metrics-server`:
>   ```bash
>   kubectl get apiservices | grep metrics.k8s.io
>   ```
>
> - Check the resource kinds registered in the metrics.k8s.io group:
>   ```bash
>   kubectl api-resources --api-group=metrics.k8s.io
>   ```

(If the output of either command is empty, install `metrics-server` first.)

## `nodes` vs `nodes`

- We can have multiple resources with the same name

> [!example] Hands-on
> - Look for resources named `node`:
>   ```bash
>   kubectl api-resources | grep -w nodes
>   ```
>
> - Compare the output of both commands:
>   ```bash
>   kubectl get nodes
>   kubectl get nodes.metrics.k8s.io
>   ```

🤔 What are the second kind of nodes? How can we see what's really in them?

## Node vs NodeMetrics

- `nodes.metrics.k8s.io` (aka NodeMetrics) don't have fancy *printer columns*

- But we can look at the raw data (with `-o json` or `-o yaml`)

> [!example] Hands-on
> - Look at NodeMetrics objects with one of these commands:
>   ```bash
>   kubectl get -o yaml nodes.metrics.k8s.io
>   kubectl get -o yaml NodeMetrics
>   ```

💡 Alright, these are the live metrics (CPU, RAM) for our nodes.

## An easier way to consume metrics

- We might have seen these metrics before ... With an easier command!

> [!example] Hands-on
> - Display node metrics:
>   ```bash
>   kubectl top nodes
>   ```
>
> - Check which API requests happen behind the scenes:
>   ```bash
>   kubectl top nodes -v6
>   ```

## Aggregation layer in practice

- We can write an API server to handle a subset of the Kubernetes API

- Then we can register that server by creating an APIService resource

> [!example] Hands-on
> - Check the definition used for the `metrics-server`:
>   ```bash
>   kubectl describe apiservices v1beta1.metrics.k8s.io
>   ```

- Group priority is used when multiple API groups provide similar kinds

  (e.g. `nodes` and `nodes.metrics.k8s.io` as seen earlier)

## Authentication flow

- We have two Kubernetes API servers:

  - "aggregator" (the main one; clients connect to it)

  - "aggregated" (the one providing the extra API; aggregator connects to it)

- Aggregator deals with client authentication

- Aggregator authenticates with aggregated using mutual TLS

- Aggregator passes (/forwards/proxies/...) requests to aggregated

- Aggregated performs authorization by calling back aggregator

  ("can subject X perform action Y on resource Z?")

[This doc page](https://kubernetes.io/docs/tasks/extend-kubernetes/configure-aggregation-layer/#authentication-flow) has very nice swim lanes showing that flow.

## Discussion

- Aggregation layer is great for metrics

  (fast-changing, ephemeral data, that would be outrageously bad for etcd)

- It *could* be a good fit to expose other REST APIs as a pass-thru

  (but it's more common to see CRDs instead)

---

> [!info] Adapted from container.training
> This page is derived from [`slides/k8s/aggregation-layer.md`](https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/aggregation-layer.md)
> in **[container.training](https://github.com/jpetazzo/container.training)** by Jérôme Petazzoni and contributors,
> used under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).
> **Changes were made**: restructured from slides into a single page, remark
> markup converted to Obsidian callouts, referenced files inlined or linked,
> URI diagrams redrawn, exec request updated, tested on kind.

<!-- uplink -->
Part of [[kubernetes/extending/index|Extending Kubernetes]].
