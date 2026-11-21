---
title: "Events"
description: "Kubernetes has an internal structured log of events"
tags: [kubernetes, api, operators]
type: lab
status: complete
source: https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/events.md
license: CC-BY-4.0
upstream_commit: 56563629
upstream_sync: manual
---

# Events

- Kubernetes has an internal structured log of *events*

- These events are ordinary resources:

  - we can view them with `kubectl get events`

  - they can be viewed and created through the Kubernetes API

  - they are stored in Kubernetes default database (e.g. etcd)

- Most components will generate events to let us know what's going on

- Events can be *related* to other resources

## Reading events

- `kubectl get events` (or `kubectl get ev`)

  (`ev` works, but kubectl warns that it could also mean `events.events.k8s.io`)

- Can use `--watch`

  ⚠️ Looks like `tail -f`, but events aren't necessarily sorted!

- Can use `--all-namespaces`

- Cluster events (e.g. related to nodes) are in the `default` namespace

- Viewing all "non-normal" events:
  ```bash
  kubectl get ev -A --field-selector=type!=Normal
  ```

  (as of Kubernetes 1.19, `type` can be either `Normal` or `Warning`)

## Reading events (take 2)

- When we use `kubectl describe` on an object, `kubectl` retrieves the associated events

> [!example] Hands-on
> - See the API requests happening when we use `kubectl describe`:
>   ```bash
>   kubectl describe service kubernetes --namespace=default -v6 >/dev/null
>   ```

## Generating events

- This is rarely (if ever) done manually

  (i.e. by crafting some YAML)

- But controllers (e.g. operators) need this!

- It's not mandatory, but it helps with *operability*

  (e.g. when we `kubectl describe` a CRD, we will see associated events)

## ⚠️ Work in progress

- "Events" can be :

  - "old-style" events (in core API group, aka `v1`)

  - "new-style" events (in API group `events.k8s.io`)

- See [KEP 383](https://github.com/kubernetes/enhancements/blob/master/keps/sig-instrumentation/383-new-event-api-ga-graduation/README.md) in particular this [comparison between old and new APIs](https://github.com/kubernetes/enhancements/blob/master/keps/sig-instrumentation/383-new-event-api-ga-graduation/README.md#comparison-between-old-and-new-apis)

## Experimenting with events

- Let's create an event related to a Node, based on [`k8s/event-node.yaml`](https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/k8s/event-node.yaml)

> [!example] Hands-on
> - Edit `k8s/event-node.yaml`
>
> - Update the `name` and `uid` of the `involvedObject`
>
> - Create the event with `kubectl create -f`
>
> - Look at the Node with `kubectl describe`

> [!note]
> A comment in `k8s/event-node.yaml` says that the `uid` must be the Node name. With
> current kubectl, `kubectl describe node` shows the event with either the Node name
> or the real uid of the Node (tested with kind).

## Experimenting with events

- Let's create an event related to a Pod, based on [`k8s/event-pod.yaml`](https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/k8s/event-pod.yaml)

> [!example] Hands-on
> - Create a pod
>
> - Edit `k8s/event-pod.yaml`
>
> - Edit the `involvedObject` section (don't forget the `uid`)
>
> - Create the event with `kubectl create -f`
>
> - Look at the Pod with `kubectl describe`

## Generating events in practice

- In Go, use an `EventRecorder` provided by the `kubernetes/client-go` library

  - [EventRecorder interface](https://github.com/kubernetes/client-go/blob/release-1.19/tools/record/event.go#L87)

  - [kubebuilder book example](https://book-v1.book.kubebuilder.io/beyond_basics/creating_events.html)

- It will take care of formatting / aggregating events

- To get an idea of what to put in the `reason` field, check [kubelet events](
https://github.com/kubernetes/kubernetes/blob/release-1.19/pkg/kubelet/events/event.go)

## Cluster operator perspective

- Events are kept 1 hour by default

- This can be changed with the `--event-ttl` flag on the API server

- On very busy clusters, events can be kept on a separate etcd cluster

- This is done with the `--etcd-servers-overrides` flag on the API server

- Example:
  ```
  --etcd-servers-overrides=/events#http://127.0.0.1:12379
  ```

---

> [!info] Adapted from container.training
> This page is derived from [`slides/k8s/events.md`](https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/events.md)
> in **[container.training](https://github.com/jpetazzo/container.training)** by Jérôme Petazzoni and contributors,
> used under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).
> **Changes were made**: restructured from slides into a single page, remark
> markup converted to Obsidian callouts, referenced files inlined or linked,
> notes on the `ev` short name and the Node event `uid` added.

<!-- uplink -->
Part of [[kubernetes/extending/index|Extending Kubernetes]].
