---
title: "Restricting Pod Permissions"
description: "By default, our pods and containers can do everything"
tags: [kubernetes, security]
type: lab
status: complete
source: https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/pod-security-intro.md
license: CC-BY-4.0
upstream_commit: 56563629
upstream_sync: manual
---

# Restricting Pod Permissions

> [!important] These labs expect the upstream repository
> Commands below reference files by their path in a local clone. Get it with:
>
> ```bash
> git clone https://github.com/jpetazzo/container.training
> ```
>
> The manifests can also be browsed at the pinned commit
> [`56563629`](https://github.com/jpetazzo/container.training/tree/565636291ec03abf1f2ab8bf6b935478e00e69a2).

- By default, our pods and containers can do *everything*

  (including taking over the entire cluster)

- We are going to show an example of a malicious pod

  (which will give us root access to the whole cluster)

- Then we will explain how to avoid this with admission control

  (PodSecurityAdmission, PodSecurityPolicy, or external policy engine)

## Setting up a namespace

- For simplicity, let's work in a separate namespace

- Let's create a new namespace called "green"

> [!example] Hands-on
> - Create the "green" namespace:
>   ```bash
>   kubectl create namespace green
>   ```
>
> - Change to that namespace (`kns` is kubens, from
>   [kubectx](https://github.com/ahmetb/kubectx); without it,
>   `kubectl config set-context --current --namespace=green`):
>   ```bash
>   kns green
>   ```

## Creating a basic Deployment

- Just to check that everything works correctly, deploy NGINX

> [!example] Hands-on
> - Create a Deployment using the official NGINX image:
>   ```bash
>   kubectl create deployment web --image=nginx
>   ```
>
> - Confirm that the Deployment, ReplicaSet, and Pod exist, and that the Pod is running:
>   ```bash
>   kubectl get all
>   ```

## One example of malicious pods

- We will now show an escalation technique in action

- We will deploy a DaemonSet that adds our SSH key to the root account

  (on *each* node of the cluster)

- The Pods of the DaemonSet will do so by mounting `/root` from the host

> [!example] Hands-on
> - Check the file `k8s/hacktheplanet.yaml` with a text editor:
>   ```bash
>   vim ~/container.training/k8s/hacktheplanet.yaml
>   ```
>
> - If you would like, change the SSH key (by changing the GitHub user name)

## Deploying the malicious pods

- Let's deploy our "exploit"!

> [!example] Hands-on
> - Create the DaemonSet:
>   ```bash
>   kubectl create -f ~/container.training/k8s/hacktheplanet.yaml
>   ```
>
> - Check that the pods are running:
>   ```bash
>   kubectl get pods
>   ```
>
> - Confirm that the SSH key was added to the node's root account:
>   ```bash
>   sudo cat /root/.ssh/authorized_keys
>   ```

## Mitigations

- This can be avoided with *admission control*

- Admission control = filter for (write) API requests

- Admission control can use:

  - plugins (compiled in API server; enabled/disabled by reconfiguration)

  - webhooks (registered dynamically)

- Admission control has many other uses

  (enforcing quotas, adding ServiceAccounts automatically, etc.)

## Admission plugins

- [PodSecurityPolicy](https://kubernetes.io/docs/concepts/policy/pod-security-policy/) (was removed in Kubernetes 1.25)

  - create PodSecurityPolicy resources

  - create Role that can `use` a PodSecurityPolicy

  - create RoleBinding that grants the Role to a user or ServiceAccount

- [PodSecurityAdmission](https://kubernetes.io/docs/concepts/security/pod-security-admission/) (alpha since Kubernetes 1.22, stable since 1.25)

  - use pre-defined policies (privileged, baseline, restricted)

  - label namespaces to indicate which policies they can use

  - optionally, define default rules (in the absence of labels)

## Dynamic admission

- Leverage ValidatingWebhookConfigurations

  (to register a validating webhook)

- Examples:

  [Kubewarden](https://www.kubewarden.io/)

  [Kyverno](https://kyverno.io/policies/)

  [OPA Gatekeeper](https://github.com/open-policy-agent/gatekeeper)

- Pros: available today; very flexible and customizable

- Cons: performance and reliability of external webhook

## Validating Admission Policies

- Alternative to validating admission webhooks

- Evaluated in the API server

  (don't require an external server; don't add network latency)

- Written in CEL (Common Expression Language)

- alpha in K8S 1.26; beta in K8S 1.28; GA in K8S 1.30

- Can replace validating webhooks at least in simple cases

- Can extend Pod Security Admission

- Check [the documentation][vapdoc] for examples

[vapdoc]: https://kubernetes.io/docs/reference/access-authn-authz/validating-admission-policy/

## Acronym salad

- PSP = Pod Security Policy **(deprecated)**

  - an admission plugin called PodSecurityPolicy

  - a resource named PodSecurityPolicy (`apiVersion: policy/v1beta1`)

- PSA = Pod Security Admission

  - an admission plugin called PodSecurity, enforcing PSS

- PSS = Pod Security Standards

  - a set of 3 policies (privileged, baseline, restricted)\

---

> [!info] Adapted from container.training
> This page is derived from [`slides/k8s/pod-security-intro.md`](https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/pod-security-intro.md)
> in **[container.training](https://github.com/jpetazzo/container.training)** by Jérôme Petazzoni and contributors,
> used under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).
> **Changes were made**: restructured from slides into a single page, remark
> markup converted to Obsidian callouts, referenced files inlined or linked.

<!-- uplink -->
Part of [[kubernetes/security/index|Security]].
