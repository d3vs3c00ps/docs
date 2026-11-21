---
title: "Operators"
description: "Operators are software extensions to Kubernetes that make use of custom resources to manage applications and their components. Operators follow Kubernetes…"
tags: [kubernetes, api, operators]
type: concept
status: complete
source: https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/operators.md
license: CC-BY-4.0
upstream_commit: 56563629
upstream_sync: manual
---

# Operators

> [!note] Not tested locally
> A concept page with no commands. The links were checked in November 2026.

The Kubernetes documentation describes the [Operator pattern] as follows:

*Operators are software extensions to Kubernetes that make use of custom resources to manage applications and their components. Operators follow Kubernetes principles, notably the control loop.*

Another good definition from [CoreOS](https://www.redhat.com/en/blog/introducing-operators-putting-operational-knowledge-into-software):

*An operator represents **human operational knowledge in software,**
to reliably manage an application.*

There are many different use cases spanning different domains; but the general idea is:

*Manage some resources (that reside inside or outside the cluster),
using Kubernetes manifests and tooling.*

[Operator pattern]: https://kubernetes.io/docs/concepts/extend-kubernetes/operator/

## Some uses cases

- Managing external resources ([AWS], [GCP], [KubeVirt]...)

- Setting up database replication or distributed systems
  (Cassandra, Consul, CouchDB, ElasticSearch, etcd, Kafka, MongoDB, MySQL, PostgreSQL, RabbitMQ, Redis, ZooKeeper...)

- Running and configuring CI/CD
  ([ArgoCD], [Flux]), backups ([Velero]), policies ([Gatekeeper], [Kyverno])...

- Automating management of certificates and secrets
  ([cert-manager]), secrets ([External Secrets Operator], [Sealed Secrets]...)

- Configuration of cluster components ([Istio], [Prometheus])

  (the Istio in-cluster operator was removed in Istio 1.24; `istioctl` and Helm remain)

- etc.

[ArgoCD]: https://argoproj.github.io/cd/
[AWS]: https://aws-controllers-k8s.github.io/community/docs/community/services/
[cert-manager]: https://cert-manager.io/
[External Secrets Operator]: https://external-secrets.io/
[Flux]: https://fluxcd.io/
[Gatekeeper]: https://open-policy-agent.github.io/gatekeeper/website/docs/
[GCP]: https://cloud.google.com/config-connector/docs/overview
[Istio]: https://istio.io/latest/docs/setup/
[KubeVirt]: https://kubevirt.io/
[Kyverno]: https://kyverno.io/
[Prometheus]: https://prometheus-operator.dev/
[Sealed Secrets]: https://github.com/bitnami-labs/sealed-secrets
[Velero]: https://velero.io/

## What are they made from?

- Operators combine two things:

  - Custom Resource Definitions

  - controller code watching the corresponding resources and acting upon them

- A given operator can define one or multiple CRDs

- The controller code (control loop) typically runs within the cluster

  (running as a Deployment with 1 replica is a common scenario)

- But it could also run elsewhere

  (nothing mandates that the code run on the cluster, as long as it has API access)

## Operators for e.g. replicated databases

- Kubernetes gives us Deployments, StatefulSets, Services ...

- These mechanisms give us building blocks to deploy applications

- They work great for services that are made of *N* identical containers

  (like stateless ones)

- They also work great for some stateful applications like Consul, etcd ...

  (with the help of highly persistent volumes)

- They're not enough for complex services:

  - where different containers have different roles

  - where extra steps have to be taken when scaling or replacing containers

## How operators work

- An operator creates one or more CRDs

  (i.e., it creates new "Kinds" of resources on our cluster)

- The operator also runs a *controller* that will watch its resources

- Each time we create/update/delete a resource, the controller is notified

  (we could write our own cheap controller with `kubectl get --watch`)

## Operators are not magic

- Look at this ElasticSearch resource definition:

  [`k8s/eck-elasticsearch.yaml`](https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/k8s/eck-elasticsearch.yaml)

- What should happen if we flip the TLS flag? Twice?

- What should happen if we add another group of nodes?

- What if we want different images or parameters for the different nodes?

*Operators can be very powerful.
But we need to know exactly the scenarios that they can handle.*

---

> [!info] Adapted from container.training
> This page is derived from [`slides/k8s/operators.md`](https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/operators.md)
> in **[container.training](https://github.com/jpetazzo/container.training)** by Jérôme Petazzoni and contributors,
> used under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).
> **Changes were made**: restructured from slides into a single page, remark
> markup converted to Obsidian callouts, referenced files inlined or linked,
> dead and moved links updated.

<!-- uplink -->
Part of [[kubernetes/extending/index|Extending Kubernetes]].
