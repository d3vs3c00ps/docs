---
title: "Exposing containers"
description: "Exposing Pods with Services: kubectl expose, ClusterIP, load balancing and DNS names"
tags: [kubernetes, kubectl]
type: lab
status: complete
source: https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/kubectlexpose.md
license: CC-BY-4.0
upstream_commit: 56563629
upstream_sync: manual
---

# Exposing containers

We can connect to our Pods using their IP address. But then we must solve many
problems:

- How do we look up the IP address of the Pod(s)?
- How do we connect from outside the cluster?
- How do we load balance traffic?
- What if a Pod fails?

Kubernetes has a resource type named *Service*. Services answer all these questions.

## Heads up!

Below, we connect directly to Pods and Services, using internal addresses. This only
works in the course's lab environments (a live class, or the course's dev containers
in Codespaces).

On a "normal" Kubernetes cluster (including minikube, kind, etc.), *you cannot reach
these internal addresses directly!* In that case, run an interactive container, for
example:
```bash
kubectl run --rm -ti --image=archlinux myshell
```

Then, each time you see a `curl` or `ping` command, run it in that container instead.

> [!note] The `archlinux` image is amd64 only
> On a cluster with arm64 nodes (Apple Silicon, Graviton...), it fails with
> `exec format error`. Use a multi-arch image with a shell and `curl` instead, for
> example `nicolaka/netshoot` (`kubectl run --rm -ti --image=nicolaka/netshoot myshell`).

> [!note]- Extra details
> ## But, why?
>
> Internal addresses can only be reached from inside the cluster: from a Pod, or when
> logged in on a node. The course's lab environments and dev containers allow it
> anyway, because it is convenient when learning Kubernetes. But it does not work on
> "normal" Kubernetes clusters.
>
> On those clusters, use [`kubectl port-forward`][kubectl-port-forward] instead.
>
> [kubectl-port-forward]: https://kubernetes.io/docs/reference/kubectl/generated/kubectl_port-forward/

## Running containers with open ports

Let's run a small web server in a container. We use `jpetazzo/color`, a tiny HTTP
server written in Go. It listens on port 80, and serves a page that shows the Pod's
name. This helps to check load balancing.

We could use the official `nginx` image instead, but then we could not tell the
backends from each other.

## Running our HTTP server

We create a Deployment with `kubectl create deployment`. It creates a Pod running our
HTTP server.

> [!example] Hands-on
> - Create a deployment named `blue`:
>   ```bash
>   kubectl create deployment blue --image=jpetazzo/color
>   ```

## Connecting to the HTTP server

Let's connect to the HTTP server directly, to make sure that everything works. We add
the Service later.

> [!example] Hands-on
> - Get the IP address of the Pod:
>   ```bash
>   kubectl get pods -o wide
>   ```
>
> - Send an HTTP request to the Pod (replace `IP-ADDRESS`):
>   ```bash
>   curl http://IP-ADDRESS
>   ```

You should see a response from the Pod.

## The Pod doesn't have a "stable identity"

The IP address that we used above is not "stable". If the Pod is deleted, the
replacement Pod gets a different address.

> [!example] Hands-on
> - Check the IP addresses of the running Pods:
>   ```bash
>   watch kubectl get pods -o wide
>   ```
>
> - Delete the Pod (use its real name):
>   ```bash
>   kubectl delete pod blue-xxxxxxxx-yyyyy
>   ```
>
> - Check that the replacement Pod has a different IP address.

## Services in a nutshell

Services give us a *stable endpoint* to connect to a Pod or a group of Pods. An easy way
to create a Service is `kubectl expose`. If we have a Deployment named
`my-little-deploy`, we can run:

`kubectl expose deployment my-little-deploy --port=80`

This creates a Service with the same name (`my-little-deploy`).

Services are added to an internal DNS zone automatically. In the example above, our
code can now connect to `http://my-little-deploy/`.

## Exposing our deployment

Let's create a Service for our Deployment.

> [!example] Hands-on
> - Expose the HTTP port of our server:
>   ```bash
>   kubectl expose deployment blue --port=80
>   ```
>
> - Look up which IP address was allocated:
>   ```bash
>   kubectl get service
>   ```

By default, this creates a `ClusterIP` Service. (The other types of Services are in
[[kubernetes/networking/service-types|Service types]].)

> [!note]- Extra details
> ## Services are layer 4 constructs
>
> Services can have IP addresses, but they are still *layer 4*: a Service is not just
> an IP address, it is an IP address + protocol + port. So you *must* give the port
> number of your Service. (There are exceptions, like `ExternalName` or headless
> Services, covered later.)

## Testing our service

We now send a few HTTP requests to our Pod. (Right after `kubectl expose`, the Service
can take a second or two to answer: `Could not connect to server` means "try again".)

> [!example] Hands-on
> - Get the IP address that was allocated for our Service, *programmatically:*
>   ```bash
>   CLUSTER_IP=$(kubectl get svc blue -o go-template='{{ .spec.clusterIP }}')
>   ```
>
> - Send a few requests:
>   ```bash
>   for i in $(seq 10); do curl http://$CLUSTER_IP; done
>   ```

## A *stable* endpoint

Let's see what happens when the Pod has a problem.

> [!example] Hands-on
> - Keep sending requests to the Service address:
>   ```bash
>   while sleep 0.3; do curl -m1 http://$CLUSTER_IP; done
>   ```
>
> - Meanwhile, delete the Pod:
>   ```bash
>   kubectl delete pod blue-xxxxxxxx-yyyyy
>   ```

There might be a short interruption when we delete the Pod. But after that, requests
keep flowing, with no manual action. The `-m1` option sets a 1-second timeout.

## Load balancing

The Service also acts as a load balancer, when there are several Pods in the
Deployment.

> [!example] Hands-on
> - Scale up the Deployment:
>   ```bash
>   kubectl scale deployment blue --replicas=3
>   ```
>
> - Send a bunch of requests to the Service:
>   ```bash
>   for i in $(seq 20); do curl http://$CLUSTER_IP; done
>   ```

Our requests are load balanced across the Pods!

## DNS integration

Kubernetes provides an internal DNS resolver. It maps Service names to their internal
addresses. By default, this only works *inside Pods*, not on the nodes themselves.

> [!example] Hands-on
> - Get a shell in a Pod:
>   ```bash
>   kubectl run --rm -it --image=archlinux test-dns-integration
>   ```
>
> - Try to resolve the `blue` Service from the Pod:
>   ```bash
>   curl blue
>   ```

> [!note]- Extra details
> ## Under the hood...
>
> Let's check the content of `/etc/resolv.conf` inside a Pod. It looks roughly like
> this:
> ```
> search default.svc.cluster.local svc.cluster.local cluster.local ...
> nameserver 10.96.0.10
> options ndots:5
> ```
>
> Let's break down what these lines mean.

> [!note]- Extra details
> ## `nameserver 10.96.0.10`
>
> This is the address of the DNS server used by programs running in the Pod. The exact
> address may be different: this one is the default when the cluster is set up with
> `kubeadm`. This address belongs to a Service on our cluster.
>
> - Check what we have in `kube-system`:
>   ```bash
>   kubectl get services --namespace=kube-system
>   ```
>
> There is usually a Service named `kube-dns` with that exact address. That is
> Kubernetes' internal DNS service. (Its Pods run CoreDNS, but the Service kept the
> old name.)

> [!note]- Extra details
> ## `search default.svc.cluster.local ...`
>
> This is the "search list". When a program tries to resolve `foo`, the resolver tries:
>
> - `foo.default.svc.cluster.local` (if the Pod is in the `default` Namespace);
> - `foo.svc.cluster.local`;
> - `foo.cluster.local`;
> - ...the other entries in the search list...;
> - `foo`.
>
> So if there is a Service named `foo` in the Pod's Namespace, we get its address!
>
> `options ndots:5` means that a name with fewer than five dots goes through the search
> list first.

> [!note]- Extra details
> ## Do You Want To Know More?
>
> For even more details about DNS resolution on Kubernetes and Linux, read
> [this blog post][dnsblog].
>
> [dnsblog]: https://jpetazzo.github.io/2024/05/12/understanding-kubernetes-dns-hostnetwork-dnspolicy-dnsconfigforming/

## Advantages of services

- We do not need to look up the IP address of the Pod(s): we resolve the address of
  the Service with DNS.
- There are several Service types. Some of them accept external traffic (for example
  `LoadBalancer` and `NodePort`).
- Services do load balancing, for both internal and external traffic.
- Service addresses do not depend on Pod addresses. When a Pod fails, the Service
  sends traffic to its replacement, with no action from us.

---

> [!info] Adapted from container.training
> This page is derived from [`slides/k8s/kubectlexpose.md`](https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/kubectlexpose.md)
> in **[container.training](https://github.com/jpetazzo/container.training)** by Jérôme Petazzoni and contributors,
> used under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).
> **Changes were made**: restructured from slides into a single page, remark
> markup converted to Obsidian callouts, referenced files inlined or linked.
> Rewritten as prose; notes on multi-arch images and the `kube-dns` name added.

<!-- uplink -->
Part of [[kubernetes/workloads/index|Workloads]].
