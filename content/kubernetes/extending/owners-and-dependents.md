---
title: "Owners and dependents"
description: "Some objects are created by other objects"
tags: [kubernetes, api, operators]
type: lab
status: complete
source: https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/owners-and-dependents.md
license: CC-BY-4.0
upstream_commit: 56563629
upstream_sync: manual
---

# Owners and dependents

- Some objects are created by other objects

  (example: pods created by replica sets, themselves created by deployments)

- When an *owner* object is deleted, its *dependents* are deleted

  (this is the default behavior; it can be changed)

- We can delete a dependent directly if we want

  (but generally, the owner will recreate another right away)

- An object can have multiple owners

## Finding out the owners of an object

- The owners are recorded in the field `ownerReferences` in the `metadata` block

> [!example] Hands-on
> - Let's create a deployment running `nginx`:
>   ```bash
>   kubectl create deployment yanginx --image=nginx
>   ```
>
> - Scale it to a few replicas:
>   ```bash
>   kubectl scale deployment yanginx --replicas=3
>   ```
>
> - Once it's up, check the corresponding pods:
>   ```bash
>   kubectl get pods -l app=yanginx -o yaml | head -n 25
>   ```

These pods are owned by a ReplicaSet named yanginx-xxxxxxxxxx.

## Listing objects with their owners

- This is a good opportunity to try the `custom-columns` output!

> [!example] Hands-on
> - Show all pods with their owners:
>   ```bash
>   kubectl get pod -o custom-columns=\
>   NAME:.metadata.name,\
>   OWNER-KIND:.metadata.ownerReferences[0].kind,\
>   OWNER-NAME:.metadata.ownerReferences[0].name
>   ```

Note: the `custom-columns` option should be one long option (without spaces),
so the lines should not be indented (otherwise the indentation will insert spaces).

## Deletion policy

- When deleting an object through the API, three policies are available:

  - foreground (API call returns after all dependents are deleted)

  - background (API call returns immediately; dependents are scheduled for deletion)

  - orphan (the dependents are not deleted)

- When deleting an object with `kubectl`, this is selected with `--cascade`:

  - `--cascade=background` (the default) or `--cascade=foreground` deletes the
    dependent objects

  - `--cascade=orphan` orphans dependent objects

> [!note] `--cascade=true` and `--cascade=false`
> These boolean values are deprecated since Kubernetes 1.20. `--cascade=false` still
> works, but kubectl prints a warning and asks for `--cascade=orphan`.

## What happens when an object is deleted

- It is removed from the list of owners of its dependents

- If, for one of these dependents, the list of owners becomes empty ...

  - if the policy is "orphan", the object stays

  - otherwise, the object is deleted

## Orphaning pods

- We are going to delete the Deployment and Replica Set that we created

- ... without deleting the corresponding pods!

> [!example] Hands-on
> - Delete the Deployment:
>   ```bash
>   kubectl delete deployment -l app=yanginx --cascade=orphan
>   ```
>
> - Delete the Replica Set:
>   ```bash
>   kubectl delete replicaset -l app=yanginx --cascade=orphan
>   ```
>
> - Check that the pods are still here:
>   ```bash
>   kubectl get pods
>   ```

> [!note]- Extra details
> ## When and why would we have orphans?
>
> - If we remove an owner and explicitly instruct the API to orphan dependents
>
>   (like on the previous slide)
>
> - If we change the labels on a dependent, so that it's not selected anymore
>
>   (e.g. change the `app: yanginx` in the pods of the previous example)
>
> - If a deployment tool that we're using does these things for us
>
> - If there is a serious problem within API machinery or other components
>
>   (i.e. "this should not happen")

## Finding orphan objects

- We're going to output all pods in JSON format

- Then we will use `jq` to keep only the ones *without* an owner

- And we will display their name

> [!example] Hands-on
> - List all pods that *do not* have an owner:
>   ```bash
>   kubectl get pod -o json | jq -r "
>           .items[]
>           | select(.metadata.ownerReferences|not)
>           | .metadata.name"
>   ```

## Deleting orphan pods

- Now that we can list orphan pods, deleting them is easy

> [!example] Hands-on
> - Add `| xargs kubectl delete pod` to the previous command:
>   ```bash
>   kubectl get pod -o json | jq -r "
>           .items[]
>           | select(.metadata.ownerReferences|not)
>           | .metadata.name" | xargs kubectl delete pod
>   ```

As always, the [documentation](https://kubernetes.io/docs/concepts/workloads/controllers/garbage-collection/) has useful extra information and pointers.

---

> [!info] Adapted from container.training
> This page is derived from [`slides/k8s/owners-and-dependents.md`](https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/owners-and-dependents.md)
> in **[container.training](https://github.com/jpetazzo/container.training)** by Jérôme Petazzoni and contributors,
> used under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).
> **Changes were made**: restructured from slides into a single page, remark
> markup converted to Obsidian callouts, referenced files inlined or linked,
> deprecated `--cascade=false` replaced by `--cascade=orphan`.

<!-- uplink -->
Part of [[kubernetes/extending/index|Extending Kubernetes]].
