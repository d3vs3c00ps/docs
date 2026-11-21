---
title: "Painting pods"
description: "Kyverno lab: making a Pod label optional, restricted to three values, then immutable and impossible to remove"
tags: [kubernetes, security, policy, kyverno]
type: lab
status: complete
source: https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/kyverno-colors.md
license: CC-BY-4.0
upstream_commit: 56563629
upstream_sync: manual
---

# Painting pods

> [!important] These labs expect the upstream repository
> Commands below reference files by their path in a local clone. Get it with:
>
> ```bash
> git clone https://github.com/jpetazzo/container.training
> ```
>
> The manifests can also be browsed at the pinned commit
> [`56563629`](https://github.com/jpetazzo/container.training/tree/565636291ec03abf1f2ab8bf6b935478e00e69a2).

> [!warning] Needs Kyverno 1.19 or older
> These policies are `kyverno.io/v1` `ClusterPolicy` objects. Kyverno 1.20 no
> longer accepts them; the lab is tested on Kyverno 1.19 (chart 3.9.2). See the
> correction at the top of [[kubernetes/security/kyverno]].

## Painting pods

- As an example, we'll implement a policy regarding "Pod color"

- The color of a Pod is the value of the label `color`

- Example: `kubectl label pod hello color=yellow` to paint a Pod in yellow

- We want to implement the following policies:

  - color is optional (i.e. the label is not required)

  - if color is set, it *must* be `red`, `green`, or `blue`

  - once the color has been set, it cannot be changed

  - once the color has been set, it cannot be removed

## Immutable primary colors, take 1

- First, we will add a policy to block forbidden colors

  (i.e. only allow `red`, `green`, or `blue`)

- One possible approach:

  - *match* all pods that have a `color` label that is not `red`, `green`, or `blue`

  - *deny* these pods

- We could also *match* all pods, then *deny* with a condition

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: pod-color-policy-1
spec:
  rules:
  - name: ensure-pod-color-is-valid
    match:
      resources:
        kinds:
        - Pod
        selector:
          matchExpressions:
          - key: color
            operator: Exists
          - key: color
            operator: NotIn
            values: [ red, green, blue ]
    validate:
      failureAction: Enforce
      message: "If it exists, the label color must be red, green, or blue."
      deny: {}
```
<small>Source: [`k8s/kyverno-pod-color-1.yaml`](https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/k8s/kyverno-pod-color-1.yaml)</small>

## Testing without the policy

- First, let's create a pod with an "invalid" label

  (while we still can!)

- We will use this later

> [!example] Hands-on
> - Create a pod:
>   ```bash
>   kubectl run test-color-0 --image=nginx
>   ```
>
> - Apply a color label:
>   ```bash
>   kubectl label pod test-color-0 color=purple
>   ```

## Load and try the policy

> [!example] Hands-on
> - Load the policy:
>   ```bash
>   kubectl apply -f ~/container.training/k8s/kyverno-pod-color-1.yaml
>   ```
>
> - Create a pod:
>   ```bash
>   kubectl run test-color-1 --image=nginx
>   ```
>
> - Try to apply a few color labels:
>   ```bash
>   kubectl label pod test-color-1 color=purple
>   kubectl label pod test-color-1 color=red
>   kubectl label pod test-color-1 color-
>   ```

## Immutable primary colors, take 2

- Next rule: once a `color` label has been added, it cannot be changed

  (i.e. if `color=red`, we can't change it to `color=blue`)

- Our approach:

  - *match* all pods

  - add a *precondition* matching pods that have a `color` label
    <br/>
    (both in their "before" and "after" states)

  - *deny* these pods if their `color` label has changed

- Again, other approaches are possible!

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: pod-color-policy-2
spec:
  background: false
  rules:
  - name: prevent-color-change
    match:
      resources:
        kinds:
        - Pod
    preconditions:
    - key: "{{ request.operation }}"
      operator: Equals
      value: UPDATE
    - key: "{{ request.oldObject.metadata.labels.color || '' }}"
      operator: NotEquals
      value: ""
    - key: "{{ request.object.metadata.labels.color || '' }}"
      operator: NotEquals
      value: ""
    validate:
      failureAction: Enforce
      message: "Once label color has been added, it cannot be changed."
      deny:
        conditions:
        - key: "{{ request.object.metadata.labels.color }}"
          operator: NotEquals
          value: "{{ request.oldObject.metadata.labels.color }}"
```
<small>Source: [`k8s/kyverno-pod-color-2.yaml`](https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/k8s/kyverno-pod-color-2.yaml)</small>

## Comparing "old" and "new"

- The fields of the webhook payload are available through `{{ request }}`

- For UPDATE requests, we can access:

  `{{ request.oldObject }}` → the object as it is right now (before the request)

  `{{ request.object }}` → the object with the changes made by the request

## Missing labels

- We can access the `color` label through `{{ request.object.metadata.labels.color }}`

- If we reference a label (or any field) that doesn't exist, the policy fails

  (with an error similar to `JMESPAth query failed: Unknown key ... in path`)

- If a precondition fails, the policy will be skipped altogether (and ignored!)

- To work around that, [use an OR expression][non-existence-checks]:

  `{{ request.object.metadata.labels.color || '' }}`

[non-existence-checks]: https://kyverno.io/docs/policy-types/cluster-policy/jmespath/#non-existence-checks

## Load and try the policy

> [!example] Hands-on
> - Load the policy:
>   ```bash
>   kubectl apply -f ~/container.training/k8s/kyverno-pod-color-2.yaml
>   ```
>
> - Create a pod:
>   ```bash
>   kubectl run test-color-2 --image=nginx
>   ```
>
> - Try to apply a few color labels:
>   ```bash
>   kubectl label pod test-color-2 color=purple
>   kubectl label pod test-color-2 color=red
>   kubectl label pod test-color-2 color=blue --overwrite
>   ```

## Immutable primary colors, take 3

- Last rule: once a `color` label has been added, it cannot be removed

- Our approach is to match all pods that:

  - *had* a `color` label (in `request.oldObject`)

  - *don't have* a `color` label (in `request.object`)

- And *deny* these pods

- Again, other approaches are possible!

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: pod-color-policy-3
spec:
  background: false
  rules:
  - name: prevent-color-change
    match:
      resources:
        kinds:
        - Pod
    preconditions:
    - key: "{{ request.operation }}"
      operator: Equals
      value: UPDATE
    - key: "{{ request.oldObject.metadata.labels.color || '' }}"
      operator: NotEquals
      value: ""
    - key: "{{ request.object.metadata.labels.color || '' }}"
      operator: Equals
      value: ""
    validate:
      failureAction: Enforce
      message: "Once label color has been added, it cannot be removed."
      deny: {}
```
<small>Source: [`k8s/kyverno-pod-color-3.yaml`](https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/k8s/kyverno-pod-color-3.yaml)</small>

## Load and try the policy

> [!example] Hands-on
> - Load the policy:
>   ```bash
>   kubectl apply -f ~/container.training/k8s/kyverno-pod-color-3.yaml
>   ```
>
> - Create a pod:
>   ```bash
>   kubectl run test-color-3 --image=nginx
>   ```
>
> - Try to apply a few color labels:
>   ```bash
>   kubectl label pod test-color-3 color=purple
>   kubectl label pod test-color-3 color=red
>   kubectl label pod test-color-3 color-
>   ```

## Background checks

- What about the `test-color-0` pod that we create initially?

  (remember: we did set `color=purple`)

- We can see the infringing Pod in a PolicyReport

> [!example] Hands-on
> - Check that the pod still has an "invalid" color:
>   ```bash
>   kubectl get pods -L color
>   ```
>
> - List PolicyReports:
>   ```bash
>   kubectl get policyreports
>   kubectl get polr
>   ```

(Sometimes it takes a little while for the infringement to show up, though.)

---

> [!info] Adapted from container.training
> This page is derived from [`slides/k8s/kyverno-colors.md`](https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/kyverno-colors.md)
> in **[container.training](https://github.com/jpetazzo/container.training)** by Jérôme Petazzoni and contributors,
> used under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).
> **Changes were made**: restructured from slides into a single page, remark
> markup converted to Obsidian callouts, referenced files inlined or linked.

<!-- uplink -->
Part of [[kubernetes/security/index|Security]].
