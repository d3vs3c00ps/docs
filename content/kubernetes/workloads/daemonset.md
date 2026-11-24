---
title: "Daemon sets"
description: "Running one rng Pod per node with a DaemonSet, then using labels and selectors to take Pods in and out of a Service"
tags: [kubernetes, kubectl]
type: lab
status: complete
source: https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/daemonset.md
license: CC-BY-4.0
upstream_commit: 56563629
upstream_sync: manual
---

# Daemon sets

We want to scale `rng` in a different way than we scaled `worker` (see
[[kubernetes/workloads/scalingdockercoins]]). We want one, and exactly one, instance
of `rng` per node. We *do not want* two instances of `rng` on the same node. A
*daemon set* does that.

## Why not a deployment?

Can't we just run `kubectl scale deployment rng --replicas=...`?

- Nothing guarantees that the `rng` containers are spread evenly across the nodes.
- If we add nodes later, they do not get a copy of `rng` automatically.
- If we remove (or reboot) a node, its `rng` container restarts on another node, and
  we end up with two instances of `rng` on the same node.

A daemon set starts one Pod per node, and keeps it that way as nodes are added or
removed.

## Daemon sets in practice

Daemon sets are great for cluster-wide, per-node processes:

- network components like `kube-proxy`, `calico`, `cilium`;
- storage components (for example CSI plugins);
- monitoring agents;
- hardware management tools (for example SCSI/FC HBA agents);
- and so on.

They can also be restricted to run
[only on some nodes](https://kubernetes.io/docs/concepts/workloads/controllers/daemonset/#running-pods-on-only-some-nodes).

## Creating a daemon set

As of Kubernetes 1.37, `kubectl create` has no subcommand to create a daemon set.
But any kind of resource can be created from a YAML description:

```bash
kubectl apply -f foo.yaml
```

How do we write the YAML file for our daemon set? Option 1:
[read the docs](https://kubernetes.io/docs/concepts/workloads/controllers/daemonset/#create-a-daemonset).
Option 2: start from something close, and edit it.

## Creating the YAML file for our daemon set

DaemonSets and Deployments are quite similar: both describe how to create Pods. Can
we turn a Deployment into a DaemonSet? Let's try.

## Generating a Deployment manifest

We use `kubectl create deployment -o yaml --dry-run=client`.

> [!example] Hands-on
> - Generate the YAML for a Deployment:
>   ```bash
>     kubectl create deployment rng --image=dockercoins/rng:v0.1 \
>             -o yaml --dry-run=client
>   ```
>
> - Save it to a file:
>   ```bash
>   kubectl create deployment rng --image=dockercoins/rng:v0.1 \
>       -o yaml --dry-run=client >rng.yaml
>   ```

## Changing the `kind`

Edit the YAML manifest and replace `Deployment` with `DaemonSet`.

> [!example] Hands-on
> - Edit the YAML file and make the change
>
> - Or, alternatively:
>   ```bash
>   sed -i "s/kind: Deployment/kind: DaemonSet/" rng.yaml
>   ```

## Creating the DaemonSet

Let's see if our DaemonSet manifest is valid.

> [!example] Hands-on
> - Try to `kubectl apply` our new YAML:
>   ```bash
>   kubectl apply -f rng.yaml
>   ```

That does not work.

## Understanding the problem

The core of the error is:

```
unknown field "spec.replicas", unknown field "spec.strategy"
```

A number of replicas makes no sense for a daemon set. The field `spec.strategy` is
also specific to Deployments: DaemonSets have `spec.updateStrategy` instead. The fix
is to remove these fields from the YAML.

## Fixing the problem

Let's remove the `replicas` and `strategy` fields and try again.

> [!warning] Remove `strategy: {}` too
> `kubectl create deployment` also writes `strategy: {}`, and the API server rejects
> it in a DaemonSet (`strict decoding error: unknown field "spec.strategy"`). Remove
> both lines.

> [!example] Hands-on
> - Edit the `rng.yaml` file and remove the `replicas:` and `strategy:` lines, or:
>   ```bash
>   sed -i -e "/replicas:/d" -e "/strategy:/d" rng.yaml
>   ```
>
> - Then try to create the DaemonSet again:
>   ```bash
>   kubectl apply -f rng.yaml
>   ```

This time it works.

## Checking what we've done

Did we turn our `deployment` into a `daemonset`?

> [!example] Hands-on
> - Look at the resources that we have now:
>   ```bash
>   kubectl get all
>   ```

We have two resources called `rng`: the *deployment* that existed before, and the
*daemon set* that we just created. We also have one Pod too many: the Pod of the
*deployment* still exists.

## `deploy/rng` and `ds/rng`

Different resource types can have the same name: here, a *deployment* and a *daemon
set* are both named `rng`.

We still have the old `rng` *deployment*:

```
NAME                       DESIRED   CURRENT   UP-TO-DATE   AVAILABLE   AGE
deployment.apps/rng        1         1         1            1           18m
```

And now we also have the new `rng` *daemon set*:

```
NAME                DESIRED  CURRENT  READY  UP-TO-DATE  AVAILABLE  NODE SELECTOR  AGE
daemonset.apps/rng  2        2        2      2           2          <none>         9s
```

## Too many pods

`kubectl get pods` shows:

- *one pod* for the deployment, named `rng-xxxxxxxxxx-yyyyy`;
- *one pod per node* for the daemon set, named `rng-zzzzz`.

```
NAME                        READY     STATUS    RESTARTS   AGE
rng-54f57d4d49-7pt82        1/1       Running   0          11m
rng-b85tm                   1/1       Running   0          25s
rng-hfbrr                   1/1       Running   0          25s
[...]
```

The daemon set created one Pod per node, except on the control plane node. That is not
an off-by-one error: the control plane node has
[taints](https://kubernetes.io/docs/concepts/configuration/taint-and-toleration/) that
keep Pods away. To run a Pod on it anyway, the Pod needs matching
[tolerations](https://kubernetes.io/docs/concepts/configuration/taint-and-toleration/).

## Is this working?

Look at the web UI. The graph now goes above 10 hashes per second. The new Pods serve
traffic. How did this happen? We did nothing to add them to the `rng` Service's load
balancer.

## Labels and selectors

The `rng` *Service* load balances requests to a set of Pods. The *selector* of the
Service defines that set.

> [!example] Hands-on
> - Check the *selector* in the `rng` service definition:
>   ```bash
>   kubectl describe service rng
>   ```

The selector is `app=rng`. It means "all the Pods that have the label `app=rng`".
They can have other labels as well.

## Selector evaluation

Many `kubectl` commands take a selector: `kubectl get`, `kubectl logs`,
`kubectl delete`, and more.

> [!example] Hands-on
> - Get the list of pods matching selector `app=rng`:
>   ```bash
>   kubectl get pods -l app=rng
>   kubectl get pods --selector app=rng
>   ```

But why do these Pods, and in particular the *new* ones, have the `app=rng` label?

## Where do labels come from?

- `kubectl create deployment rng` gives the Deployment the label `app=rng`.
- The ReplicaSets created by this Deployment also get the label `app=rng`.
- The Pods created by these ReplicaSets also get the label `app=rng`.
- We created the daemon set from the Deployment's YAML, so it has the same Pod
  template. Its Pods get the same labels.

With `kubectl run stuff`, the label is `run=stuff` instead.

## Updating load balancer configuration

We want to remove a Pod from the load balancer.

- If we delete that Pod with `kubectl delete pod ...`, the ReplicaSet or the daemon
  set re-creates it at once.
- If we remove the `app=rng` label from that Pod, a new Pod is *also* created at once.

Why?

## Selectors for replica sets and daemon sets

The "mission" of a ReplicaSet is: "make sure that the right number of Pods match this
spec". The "mission" of a daemon set is: "make sure that a Pod matching this spec runs
on each node".

In fact, ReplicaSets and daemon sets do not check Pod specifications. They have a
*selector*, and they look for Pods that match it. We can even fool them: create a Pod
by hand with the "right" labels, and a controller adopts it, then deletes one of its
own Pods to keep the right count. Here, a Pod with the labels of the `rng`
ReplicaSet also matches the selector of the `rng` daemon set (`app=rng`), so
whichever of the two sees it first adopts it.

So if we remove the `app=rng` label from a Pod, the Pod "disappears" for its parent.
The parent creates another Pod to replace it. The old Pod keeps running, on its own.

> [!note]- Extra details
> ## Isolation of replica sets and daemon sets
>
> The `rng` daemon set and the `rng` ReplicaSet both select `app=rng`. Why don't they
> "find" each other's Pods?
>
> - *ReplicaSets* have a more specific selector, visible with `kubectl describe`. It
>   looks like `app=rng,pod-template-hash=abcd1234`.
> - Each Pod also has an *owner reference* (`metadata.ownerReferences`) to the
>   controller that created it. A controller ignores Pods owned by another
>   controller, even when they match its selector. It only adopts Pods that have no
>   owner.
>
> > [!note] No hidden selector
> > The daemon set's selector is only `app=rng`, not something like
> > `app=rng,controller-revision-hash=abcd1234`. Its Pods do get a `controller-revision-hash` label, but the isolation
> > comes from the owner references.

## Removing a pod from the load balancer

The `rng` Service selects `app=rng`. The only way to remove a Pod from it is to remove
or change the `app` label, and that makes the parent create another Pod.

The solution: change the selector of the `rng` Service. We add another label to it, for
example `active=yes`.

## Selectors with multiple labels

If a selector lists several labels, they are combined with a logical *AND*: the Pods
must match all the labels. A Service selector cannot express a logical *OR*, like
`app=api AND (release=prod OR release=preprod)`.

We can, however, add as many extra labels as we want to our Pods:

- use the selector `app=api AND prod-or-preprod=yes`;
- add `prod-or-preprod=yes` to both sets of Pods.

Other places in the API accept more advanced selectors (see below).

## The plan

1. Add the label `active=yes` to all our `rng` Pods.
2. Update the selector of the `rng` Service to also include `active=yes`.
3. Toggle traffic to a Pod by adding or removing the `active` label by hand.
4. Profit!

> [!note] Order matters
> If we swap steps 1 and 2, there is a short service disruption. For a while, the
> Service selector matches no Pod, and requests to the Service time out. In the order
> above, there is no interruption.

## Adding labels to pods

We want to add the label `active=yes` to all Pods that have `app=rng`. We could edit
each Pod with `kubectl edit`, or label them all at once with `kubectl label`, which
accepts a selector.

> [!example] Hands-on
> - Add `active=yes` to all pods that have `app=rng`:
>   ```bash
>   kubectl label pods -l app=rng active=yes
>   ```

## Updating the service selector

We need to edit the Service specification. In the Service definition, `app: rng`
appears in two places:

- the label of the Service itself (we do not touch it);
- the selector of the Service (that is the one we change).

> [!example] Hands-on
> - Update the service to add `active: yes` to its selector:
>   ```bash
>   kubectl edit service rng
>   ```

And then we get *the weirdest error ever*. `kubectl edit` reopens the file, with this
at the top:

```
# services "rng" was not valid:
# * patch: Invalid value: "map[spec:map[selector:map[active:true]]]": unrecognized type: string
```

The same change in a file given to `kubectl apply` gives another version of it:

```
json: cannot unmarshal bool into Go struct field ServiceSpec.spec.selector of type string
```

> [!note]
> With kubectl 1.37, `kubectl edit` shows the first message.

Why?

## When the YAML parser is being too smart

YAML parsers try to help us:

- `xyz` is the string `"xyz"`;
- `42` is the integer `42`;
- `yes` is the boolean value `true`.

To get the string `"42"` or the string `"yes"`, quote them. So we must write
`active: "yes"`.

For a good laugh: with `ja`, `oui` or `si` as the value, it would have worked.

## Updating the service selector, take 2

> [!example] Hands-on
> - Update the YAML manifest of the service
>
> - Add `active: "yes"` to its selector

This time it works. If we did everything right, the web UI shows no change.

## Updating labels

We want to disable the Pod that was created by the Deployment. All we have to do is
remove the `active` label from that Pod. To find that Pod, we can use its name, or rely
on the fact that it is the only one with a `pod-template-hash` label.

Good to know:

- `kubectl label ... foo=` does not remove a label: it sets it to an empty string;
- to remove the label `foo`, use `kubectl label ... foo-`;
- to change an existing label, add `--overwrite`.

## Removing a pod from the load balancer, in practice

> [!example] Hands-on
> - In one window, check the logs of that pod:
>   ```bash
>   POD=$(kubectl get pod -l app=rng,pod-template-hash -o name)
>   kubectl logs --tail 1 --follow $POD
>   ```
>   (We should see a steady stream of HTTP logs)
>
> - In another window, remove the label from the pod:
>   ```bash
>   kubectl label pod -l app=rng,pod-template-hash active-
>   ```
>   (The stream of HTTP logs should stop immediately)

The web UI may show a small change, since we removed a bit of capacity from the `rng`
Service. If we remove more Pods, the effect is more visible.

> [!note]- Extra details
> ## Updating the daemon set
>
> If we add nodes to the cluster, the daemon set creates more Pods. These Pods do not
> have the `active=yes` label. To give them that label, edit the daemon set spec, for
> example with `kubectl edit daemonset rng`.

> [!note]- Extra details
> ## We've put resources in your resources
>
> A daemon set is a resource that creates more resources. There is a difference
> between:
>
> - the label(s) of a resource (in the `metadata` block at the top);
> - the selector of a resource (in the `spec` block);
> - the label(s) of the resource(s) it creates (in the `template` block).
>
> To give new Pods the `active=yes` label, update the template. Metadata labels are
> not required. The template must match the selector: a resource refuses to create
> resources that it would not select.
>
> > [!warning] The selector is immutable
> > In `apps/v1`, the
> > selector of a DaemonSet, Deployment or ReplicaSet is immutable: the API server
> > rejects the change (`field is immutable`). Adding `active: "yes"` to the template
> > labels is enough; the selector `app=rng` still matches. Changing the template
> > starts a rolling update of the daemon set's Pods.

## Labels and debugging

When a Pod misbehaves, we can delete it, and another one is created. But we can also
change its labels instead:

- it is removed from the load balancer, and gets no more traffic;
- another Pod is created at once;
- the problem Pod is still here, and we can inspect and debug it;
- we can even put it back in rotation if needed.

This is very useful to troubleshoot intermittent and elusive bugs.

## Labels and advanced rollout control

Conversely, we can add Pods that match a Service's selector. These Pods then receive
requests and serve traffic. Examples:

- a one-shot Pod with all debug flags enabled, to collect logs;
- Pods created automatically, but added to the rotation in a second step, by setting
  their label.

These are building blocks for canary and blue/green deployments.

> [!note]- Extra details
> ## Advanced label selectors
>
> Service selectors only support *AND*. But many other places in the Kubernetes API
> (Deployment, ReplicaSet, DaemonSet, NetworkPolicy...) accept richer selectors. They
> can:
>
> - check that a label is present (or absent);
> - check that a label's value is (or is not) in a given set.
>
> Relevant documentation:
> [Service spec](https://kubernetes.io/docs/reference/kubernetes-api/service-resources/service-v1/#ServiceSpec),
> [LabelSelector spec](https://kubernetes.io/docs/reference/kubernetes-api/common-definitions/label-selector/),
> [label selector doc](https://kubernetes.io/docs/concepts/overview/working-with-objects/labels/#label-selectors)

> [!note]- Extra details
> ## Example of advanced selector
>
> ```yaml
>   theSelector:
>     matchLabels:
>       app: portal
>       component: api
>     matchExpressions:
>     - key: release
>       operator: In
>       values: [ production, preproduction ]
>     - key: signed-off-by
>       operator: Exists
> ```
>
> This selector matches Pods that meet *all* the conditions. `operator` can be `In`,
> `NotIn`, `Exists` or `DoesNotExist`. On the command line, the same selector is
> `-l 'app=portal,component=api,release in (production,preproduction),signed-off-by'`.
>
> A `nil` selector matches *nothing*. A `{}` selector matches *everything*, because
> it means "match all Pods that meet at least zero conditions". Some APIs refuse an
> empty selector: a Deployment, ReplicaSet or DaemonSet must have one.

> [!note]- Extra details
> ## Services and EndpointSlices
>
> - For each Service with a selector, the control plane maintains EndpointSlices
>   (`kubectl get endpointslices -l kubernetes.io/service-name=rng`). They list the
>   addresses of the Pods that match the selector.
> - Other controllers use them, for example `kube-proxy` when it sets up the
>   `iptables` or `nftables` rules for ClusterIP Services.
> - We can change these EndpointSlices by hand, but the control plane overwrites our
>   changes. Except if the Service has no selector!
>
> > [!note] EndpointSlices, not Endpoints
> > `kube-proxy` reads
> > EndpointSlices (`discovery.k8s.io/v1`), and since Kubernetes 1.33 the `v1`
> > Endpoints API is deprecated: `kubectl get endpoints` prints a warning. The
> > Endpoints objects are still kept up to date, for compatibility.

> [!note]- Extra details
> ## Empty Service selector
>
> - If a Service has no selector, nothing updates its EndpointSlices automatically.
>   We can create them by hand, with the label `kubernetes.io/service-name` set to the
>   Service's name.
> - This lets us create Services that point to arbitrary destinations: outside the
>   cluster, or to things that are not in Pods.
> - Another use case: the `kubernetes` Service in the `default` namespace. It has no
>   selector, and the API server maintains its endpoints.

---

> [!info] Adapted from container.training
> This page is derived from [`slides/k8s/daemonset.md`](https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/daemonset.md)
> in **[container.training](https://github.com/jpetazzo/container.training)** by Jérôme Petazzoni and contributors,
> used under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).
> **Changes were made**: restructured from slides into a single page, remark
> markup converted to Obsidian callouts, referenced files inlined or linked.
> Rewritten as prose; manifest fix, owner references, immutable selectors and
> EndpointSlices corrected for Kubernetes 1.37.

<!-- uplink -->
Part of [[kubernetes/workloads/index|Workloads]].
