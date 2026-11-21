---
title: "First contact with `kubectl`"
description: "First contact with kubectl: get, describe, output formats, jq, namespaces and the kubernetes Service"
tags: [kubernetes, kubectl]
type: lab
status: complete
source: https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/kubectlget.md
license: CC-BY-4.0
upstream_commit: 56563629
upstream_sync: manual
---

# First contact with `kubectl`

`kubectl` is (almost) the only tool we need to talk to Kubernetes. It is a rich
command-line tool around the Kubernetes API. Everything you can do with `kubectl`, you
can also do directly with the API.

`kubectl` reads its configuration from `~/.kube/config`. That file holds:

- the address of the Kubernetes API;
- the credentials used to authenticate, for example the paths to our TLS certificates
  (or the certificates themselves).

The `--kubeconfig` flag (or the `KUBECONFIG` variable) points to another file. You can
also give the details directly, with `--server`, `--user` and so on.

`kubectl` can be pronounced "Cube C T L", "Cube cuttle", "Cube cuddle"...

> [!note]- Extra details
> ## `kubectl` is the new SSH
>
> We often start to manage servers with SSH: we install packages, we troubleshoot.
> At scale, this becomes tedious, repetitive and error-prone. Instead, we use
> configuration management, central logging, and so on.
>
> In many cases, we still need SSH:
>
> - as the underlying access method (for example, Ansible uses it);
> - to debug tricky problems;
> - to inspect and poke at things.

> [!note]- Extra details
> ## The parallel with `kubectl`
>
> We often start to manage Kubernetes clusters with `kubectl`: we deploy applications,
> we troubleshoot. At scale (many applications or many clusters), this becomes tedious,
> repetitive and error-prone. Instead, we use automated pipelines, observability
> tools, and so on.
>
> In many cases, we still need `kubectl`:
>
> - to debug tricky problems;
> - to inspect and poke at things.
>
> The Kubernetes API is always the underlying access method.

## `kubectl get`

Let's look at our `Node` resources with `kubectl get`.

> [!example] Hands-on
> - Look at the composition of our cluster:
>   ```bash
>   kubectl get node
>   ```
>
> - These commands are equivalent:
>   ```bash
>   kubectl get no
>   kubectl get node
>   kubectl get nodes
>   ```

## Obtaining machine-readable output

`kubectl get` can print JSON or YAML, or format its output in other ways.

> [!example] Hands-on
> - Give us more information about the nodes:
>   ```bash
>   kubectl get nodes -o wide
>   ```
>
> - Let's have some YAML:
>   ```bash
>   kubectl get no -o yaml
>   ```
>   See the `kind: List` at the end? It is the type of our result.

## (Ab)using `kubectl` and `jq`

It is easy to build custom reports with `jq`.

> [!example] Hands-on
> - Show the capacity of all our nodes as a stream of JSON objects:
>   ```bash
>     kubectl get nodes -o json |
>             jq ".items[] | {name:.metadata.name} + .status.capacity"
>   ```

> [!note]- Extra details
> ## Exploring types and definitions
>
> - `kubectl api-resources` lists all the resource types that the cluster knows.
>   (In Kubernetes 1.10 and older, `kubectl get` did this.)
>
> - `kubectl explain` shows the definition of a resource type:
>   ```bash
>   kubectl explain type
>   ```
>
> - It can also show the definition of one field, for instance:
>   ```bash
>   kubectl explain node.spec
>   ```
>
> - Or the full definition of all fields and sub-fields:
>   ```bash
>   kubectl explain node --recursive
>   ```

> [!note]- Extra details
> ## Introspection vs. documentation
>
> The [API documentation](https://kubernetes.io/docs/reference/#api-reference) has
> the same information. It is usually easier to read, but:
>
> - it does not show custom types (like Custom Resource Definitions);
> - we must make sure that we read the version that matches our cluster.
>
> `kubectl api-resources` and `kubectl explain` do *introspection*: they ask the API
> server for the exact type definitions.

## Type names

Most common resource names have three forms:

- singular (for example `node`, `service`, `deployment`);
- plural (for example `nodes`, `services`, `deployments`);
- short (for example `no`, `svc`, `deploy`).

Some resources have no short name.

`Endpoints` only has a plural form (and the short name `ep`), because even a single
`Endpoints` resource is a list of endpoints.

> [!note] Endpoints are deprecated
> Since Kubernetes 1.33, the `v1` Endpoints API is deprecated, and `kubectl get
> endpoints` prints a warning. Use EndpointSlices (`kubectl get endpointslices`)
> instead.

## Viewing details

`kubectl get -o yaml` shows all the details of a resource. But YAML output is often
too much and not enough at the same time. For instance, `kubectl get node node1 -o yaml`:

- has too much information (for example, the list of images present on the node);
- does not have enough (for example, it does not show the Pods running on the node);
- is hard to read for a human.

For an overview, use `kubectl describe` instead.

## `kubectl describe`

`kubectl describe` needs a resource type and, optionally, a resource name. The name can
be a *prefix*: then all the matching objects are shown (unless one object has exactly
that name: then only that one is shown). `kubectl describe` also fetches
extra information about the resource, such as related events or, for a node, its Pods.

> [!example] Hands-on
> - Look at the information about `node1` with one of these commands (use a node name
>   from `kubectl get nodes`):
>   ```bash
>   kubectl describe node/node1
>   kubectl describe node node1
>   ```

On a control plane node, we should see a number of control plane Pods.

## Listing running containers

We handle containers through *Pods*. A Pod is a group of containers that:

- run together, on the same node;
- share resources: RAM and CPU, but also network and volumes.

> [!example] Hands-on
> - List the Pods on our cluster:
>   ```bash
>   kubectl get pods
>   ```

*Where are the Pods that we saw a moment ago?*

## Namespaces

Namespaces let us separate resources from each other.

> [!example] Hands-on
> - List the namespaces on our cluster with one of these commands:
>   ```bash
>   kubectl get namespaces
>   kubectl get namespace
>   kubectl get ns
>   ```

*This `kube-system` namespace looks suspicious. In fact, it showed up earlier, when we
ran `kubectl describe node node1`.*

## Accessing namespaces

By default, `kubectl` uses the `default` namespace (or the namespace set in the current
context of the kubeconfig). `--all-namespaces` shows resources in all namespaces.

> [!example] Hands-on
> - List the Pods in all namespaces:
>   ```bash
>   kubectl get pods --all-namespaces
>   ```
>
> - Since Kubernetes 1.14, `-A` is a shorter form:
>   ```bash
>   kubectl get pods -A
>   ```

*Here are our system Pods!*

## What are all these control plane pods?

- `etcd` is our etcd server.
- `kube-apiserver` is the API server.
- `kube-controller-manager` and `kube-scheduler` are other control plane components.
- `coredns` gives DNS-based service discovery
  ([it replaced kube-dns in 1.11](https://kubernetes.io/blog/2018/07/10/coredns-ga-for-kubernetes-cluster-dns/)).
- `kube-proxy` is the per-node component that handles access to Services.
- The network plugin (CNI) runs one Pod per node and manages the Pod network. Its name
  depends on the cluster: `cilium` on the course's clusters, `kindnet` on kind,
  `calico-node`, `flannel`...
- The `READY` column shows how many containers of each Pod are ready. For most Pods,
  there is only one.

## Scoping another namespace

We can also look at one namespace other than `default`.

> [!example] Hands-on
> - List only the Pods in the `kube-system` namespace:
>   ```bash
>   kubectl get pods --namespace=kube-system
>   kubectl get pods -n kube-system
>   ```

## Namespaces and other `kubectl` commands

We can use `-n`/`--namespace` with almost every `kubectl` command. For example,
`kubectl create --namespace=X` creates something in namespace X.

We can use `-A`/`--all-namespaces` with most commands that act on many objects. For
example:

- `kubectl delete` can delete resources across many namespaces;
- `kubectl label` can add, remove or update labels across many namespaces.

> [!note]- Extra details
> ## What about `kube-public`?
>
> > [!example] Hands-on
> > - List the Pods in the `kube-public` namespace:
> >   ```bash
> >   kubectl -n kube-public get pods
> >   ```
>
> Nothing!
>
> kubeadm creates `kube-public` and [uses it for security bootstrapping](https://kubernetes.io/blog/2017/01/stronger-foundation-for-creating-and-managing-kubernetes-clusters).

> [!note]- Extra details
> ## Exploring `kube-public`
>
> The only interesting object in `kube-public` is a ConfigMap named `cluster-info`.
> (There is also `kube-root-ca.crt`, but every namespace has that one.)
>
> > [!example] Hands-on
> > - List ConfigMap objects:
> >   ```bash
> >   kubectl -n kube-public get configmaps
> >   ```
> >
> > - Inspect `cluster-info`:
> >   ```bash
> >   kubectl -n kube-public get configmap cluster-info -o yaml
> >   ```
>
> The path of this object in the API is
> `/api/v1/namespaces/kube-public/configmaps/cluster-info`. We can use that!
>
> > [!warning] Correction
> > The original said to note the `selfLink` URI in the output. The `selfLink` field
> > is no longer filled since Kubernetes 1.20, so it does not appear. The path above
> > follows the usual pattern `/api/v1/namespaces/NAMESPACE/RESOURCE/NAME`.

> [!note]- Extra details
> ## Accessing `cluster-info`
>
> Earlier, when we tried to access the API server, we got a `Forbidden` message. But
> everyone can read `cluster-info`, even without authentication.
>
> > [!example] Hands-on
> > - Get `cluster-info` (from inside the cluster; use the ClusterIP of the
> >   `kubernetes` Service):
> >   ```bash
> >   curl -k https://10.96.0.1/api/v1/namespaces/kube-public/configmaps/cluster-info
> >   ```
>
> We could read `cluster-info` without authentication. It contains a `kubeconfig` file.

> [!note]- Extra details
> ## Retrieving `kubeconfig`
>
> We can extract the `kubeconfig` file from this ConfigMap.
>
> > [!example] Hands-on
> > - Show the content of `kubeconfig`:
> >   ```bash
> >     curl -sk https://10.96.0.1/api/v1/namespaces/kube-public/configmaps/cluster-info \
> >          | jq -r .data.kubeconfig
> >   ```
>
> - This file holds the canonical address of the API server, and the public
>   certificate of the CA.
> - It *does not* hold client keys or tokens.
> - It is not sensitive information, but it lets a new node establish trust with the
>   cluster.

> [!note]- Extra details
> ## What about `kube-node-lease`?
>
> Since Kubernetes 1.14, there is a `kube-node-lease` namespace (in 1.13, it needed the
> NodeLease feature gate). It contains one Lease object per node.
>
> *Node leases* implement node heartbeats: each node regularly tells the control plane
> "I'm alive!" by renewing its Lease. They are cheaper than updating the whole Node
> status each time.
>
> For more details, see the [Efficient Node Heartbeats KEP] or the
> [node controller documentation].
>
> [Efficient Node Heartbeats KEP]: https://github.com/kubernetes/enhancements/blob/master/keps/sig-node/589-efficient-node-heartbeats/README.md
> [node controller documentation]: https://kubernetes.io/docs/concepts/architecture/nodes/#node-controller

## Services

A *Service* is a stable endpoint to connect to "something". (In the first proposal,
they were called "portals".)

> [!example] Hands-on
> - List the Services on our cluster with one of these commands:
>   ```bash
>   kubectl get services
>   kubectl get svc
>   ```

There is already one Service in the `default` namespace: `kubernetes`, the Kubernetes
API itself.

## ClusterIP services

A `ClusterIP` Service is internal: it can only be reached from inside the cluster. It
is useful for introspection from inside containers.

> [!example] Hands-on
> - Try to connect to the API:
>   ```bash
>   curl -k https://10.96.0.1
>   ```
>
>   - `-k` skips certificate verification.
>   - Replace 10.96.0.1 with the CLUSTER-IP shown by `kubectl get svc`.

The command above either times out, or shows an authentication error. Why?

## Time out

Connections to ClusterIP Services only work *from inside the cluster*. From outside the
cluster, the `curl` command will probably time out, because the address (for example
10.96.0.1) is not routed outside the cluster. This is the case with most "real"
Kubernetes clusters, and with kind.

To try the connection from inside the cluster, run a Pod with `curl` in it, for example
[shpod](https://github.com/jpetazzo/shpod) (amd64 only), or:

```bash
kubectl run curl --rm -i --restart=Never --image=quay.io/curl/curl -- curl -sk https://10.96.0.1
```

If it prints nothing, run it again: `kubectl` sometimes attaches to the Pod after
`curl` has already finished.

## Authentication error

This is what we see when we connect from inside the cluster:
```json
$ curl -k https://10.96.0.1
{
  "kind": "Status",
  "apiVersion": "v1",
  "metadata": {

  },
  "status": "Failure",
  "message": "forbidden: User \"system:anonymous\" cannot get path \"/\"",
  "reason": "Forbidden",
  "details": {

  },
  "code": 403
}
```

## Explanations

- We see `kind`, `apiVersion` and `metadata`. They are typical of a Kubernetes API
  reply, because we *are* talking to the Kubernetes API.
- The Kubernetes API tells us "Forbidden", because it requires authentication.
- The Kubernetes API can be reached from inside the cluster. Many applications that
  integrate with Kubernetes use this.

## DNS integration

Each Service also gets a DNS record. The Kubernetes DNS resolver is available *from
inside Pods* (and sometimes from the nodes, depending on the configuration). Code
running in Pods can connect to Services by name. A short name like `kubernetes` only
works from the Service's own namespace (here, `default`). From any namespace, add the
namespace: `https://kubernetes.default/...`.

---

> [!info] Adapted from container.training
> This page is derived from [`slides/k8s/kubectlget.md`](https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/kubectlget.md)
> in **[container.training](https://github.com/jpetazzo/container.training)** by Jérôme Petazzoni and contributors,
> used under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).
> **Changes were made**: restructured from slides into a single page, remark
> markup converted to Obsidian callouts, referenced files inlined or linked.
> Rewritten as prose; `selfLink`, Endpoints and CNI details updated for current
> Kubernetes, and a way to run `curl` from inside the cluster added.

<!-- uplink -->
Part of [[kubernetes/workloads/index|Workloads]].
