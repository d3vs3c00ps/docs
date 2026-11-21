---
title: "Pod Security Admission"
description: "(available in alpha since Kubernetes 1.22, and GA since Kubernetes 1.25)"
tags: [kubernetes, security]
type: lab
status: complete
source: https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/pod-security-admission.md
license: CC-BY-4.0
upstream_commit: 56563629
upstream_sync: manual
---

# Pod Security Admission

> [!important] These labs expect the upstream repository
> Commands below reference files by their path in a local clone. Get it with:
>
> ```bash
> git clone https://github.com/jpetazzo/container.training
> ```
>
> The manifests can also be browsed at the pinned commit
> [`56563629`](https://github.com/jpetazzo/container.training/tree/565636291ec03abf1f2ab8bf6b935478e00e69a2).

- "New" policies

  (available in alpha since Kubernetes 1.22, and GA since Kubernetes 1.25)

- Easier to use

  (doesn't require complex interaction between policies and RBAC)

## PSA in theory

- Leans on PSS (Pod Security Standards)

- Defines three policies:

  - `privileged` (can do everything; for system components)

  - `restricted` (no root user; almost no capabilities)

  - `baseline` (in-between with reasonable defaults)

- Label namespaces to indicate which policies are allowed there

- Also supports setting global defaults

- Supports `enforce`, `audit`, and `warn` modes

## Pod Security Standards

- `privileged`

  - can do everything

- `baseline`

  - disables hostNetwork, hostPID, hostIPC, hostPorts, hostPath volumes
  - limits which SELinux/AppArmor profiles can be used
  - containers can still run as root and use most capabilities

- `restricted`

  - limits volumes to configMap, emptyDir, ephemeral, secret, PVC
  - containers can't run as root, only capability is NET_BIND_SERVICE
  - `baseline` (can't do privileged pods, hostPath, hostNetwork...)

> [!note]- Extra details
> ## Why `baseline` ≠ `restricted` ?
>
> - `baseline` = should work for that vast majority of images
>
> - `restricted` = better, but might break / require adaptation
>
> - Many images run as root by default
>
> - Some images use CAP_CHOWN (to `chown` files)
>
> - Some programs use CAP_NET_RAW (e.g. `ping`)

## Namespace labels

- Three optional labels can be added to namespaces:

  `pod-security.kubernetes.io/enforce`

  `pod-security.kubernetes.io/audit`

  `pod-security.kubernetes.io/warn`

- The values can be: `baseline`, `restricted`, `privileged`

  (setting it to `privileged` doesn't really do anything)

## `enforce`, `audit`, `warn`

- `enforce` = prevents creation of pods

- `warn` = allow creation but include a warning in the API response

  (will be visible e.g. in `kubectl` output)

- `audit` = allow creation but generate an API audit event

  (will be visible if API auditing has been enabled and configured)

## Blocking privileged pods

- Let's block `privileged` pods everywhere

- And issue warnings and audit for anything above the `restricted` level

> [!example] Hands-on
> - Set up the default policy for all namespaces:
>   ```bash
>   kubectl label namespaces \
>       pod-security.kubernetes.io/enforce=baseline \
>       pod-security.kubernetes.io/audit=restricted \
>       pod-security.kubernetes.io/warn=restricted \
>       --all
>   ```

Note: warnings will be issued for infringing pods, but they won't be affected yet.

> [!note]- Extra details
> ## Check before you apply
>
> - When adding an `enforce` policy, we see warnings
>
>   (for the pods that would infringe that policy)
>
> - It's possible to do a `--dry-run=server` to see these warnings
>
>   (without applying the label)
>
> - It will only show warnings for `enforce` policies
>
>   (not `warn` or `audit`)

## Relaxing `kube-system`

- We have many system components in `kube-system`

- These pods aren't affected yet, but if there is a rolling update or something like that, the new pods won't be able to come up

> [!example] Hands-on
> - Let's allow `privileged` pods in `kube-system`:
>   ```bash
>   kubectl label namespace kube-system \
>       pod-security.kubernetes.io/enforce=privileged \
>       pod-security.kubernetes.io/audit=privileged \
>       pod-security.kubernetes.io/warn=privileged \
>       --overwrite
>   ```

## What about new namespaces?

- If new namespaces are created, they will get default permissions

- What can we do about this?

  - make sure that whoever/whatever creates namespaces sets labels correctly?

  - use mutating policies to automatically add labels when namespaces are created?

  - change default permissions with an *admission configuration* file?

  - something else?

- Question: is one of these options better/safer?

## Access control

- Kubernetes RBAC has a separate `create` permission

- It is possible to let someone create a Namespace, but not change its labels

  (the latter would require `patch` or `update` permissions)

- However, if someone can create a Namespace, they can set any labels at creation time

- We can't control specific labels with RBAC, but we can do it with admission control

  (CEL policies, Kyverno...)

- Conclusion: it's possible to let users create namespaces, but it requires tight controls

## Alternative solution

- Don't let users create namespaces directly

- Delegate that to our CI/CD, gitops, ... and make sure *that* sets labels correctly

- Or use a controller to create namespaces on our behalf

  (Example: https://github.com/jpetazzo/nsplease)

## Admission configuration

- Step 1: write an "admission configuration file"

- Step 2: make sure that file is available to the API server

- Step 3: add a flag to the API server to use that file

*Note: this is done out of the box on some high-end, hardened distribution like Talos.*

*If you are attending a live class, it might also have been done on your clusters.*

*The next slides assume that you're using a vanilla kubeadm cluster.*

## Admission Configuration

Let's use [`k8s/admission-configuration.yaml`](https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/k8s/admission-configuration.yaml):

```yaml
apiVersion: apiserver.config.k8s.io/v1
kind: AdmissionConfiguration
plugins:
- name: PodSecurity
  configuration:
    apiVersion: pod-security.admission.config.k8s.io/v1alpha1
    kind: PodSecurityConfiguration
    defaults:
      enforce: baseline
      audit: baseline
      warn: baseline
    exemptions:
      usernames:
      - cluster-admin
      namespaces:
      - kube-system
```
<small>Source: [`k8s/admission-configuration.yaml`](https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/k8s/admission-configuration.yaml)</small>

## Copy the file to the API server

- We need the file to be available from the API server pod

- For convenience, let's copy it do `/etc/kubernetes/pki`

  (it's definitely not where it *should* be, but that'll do!)

> [!example] Hands-on
> - Copy the file:
>   ```bash
>     sudo cp ~/container.training/k8s/admission-configuration.yaml \
>             /etc/kubernetes/pki
>   ```

## Reconfigure the API server

- We need to add a flag to the API server to use that file

> [!example] Hands-on
> - Make a backup copy of `/etc/kubernetes/manifests/kube-apiserver.yaml`
>
>   (safety first!)
>
> - Edit the file; in the list of `command` parameters, add:
>
>   `--admission-control-config-file=/etc/kubernetes/pki/admission-configuration.yaml`
>
> - Save the new file and wait until the API server comes back online

## Test the new default policy

- Create a new Namespace

- Try to create the "hacktheplanet" DaemonSet in the new namespace

- We get a warning when creating the DaemonSet

- The DaemonSet is created

- But the Pods don't get created

## So, which solution is the best?

- It depends!

- If namespaces are exclusively created by admins and deployment pipelines:

  *make sure the pipelines set the labels properly*

- If users need to be able to create arbitrary namespaces:

  *enable admission configuration and a validation rule to block security labels*

- If you can't enable admission configuration (e.g. some managed clusters):

  *you can work around it with more complex mutation/validation rules*

---

> [!info] Adapted from container.training
> This page is derived from [`slides/k8s/pod-security-admission.md`](https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/pod-security-admission.md)
> in **[container.training](https://github.com/jpetazzo/container.training)** by Jérôme Petazzoni and contributors,
> used under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).
> **Changes were made**: restructured from slides into a single page, remark
> markup converted to Obsidian callouts, referenced files inlined or linked.

<!-- uplink -->
Part of [[kubernetes/security/index|Security]].
