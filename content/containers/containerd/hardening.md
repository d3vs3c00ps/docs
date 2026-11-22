---
title: containerd hardening
description: Protecting the socket, default seccomp and AppArmor, user namespaces, restricting runtimes and registries, and what CIS actually asks for
tags: [containers, containerd, security, hardening, cis]
type: reference
status: complete
---

# containerd hardening

containerd runs as root and can start any container on the node. Most of its attack
surface is configuration.

## The socket is the whole security boundary

```bash
ls -l /run/containerd/containerd.sock
# srw-rw---- 1 root root
```

> [!warning] The Kyverno policy below needs Kyverno 1.19 or older
> It is a `kyverno.io/v1` `ClusterPolicy`, which Kyverno 1.20 no longer accepts. See
> the correction at the top of [[kubernetes/security/kyverno]]. Tested on Kyverno
> 1.19: it denies Pods that mount either socket.

> [!danger] Access to the socket is equivalent to root on the node
> Anything that can talk to it can start a privileged container with `/` mounted and
> `hostPID`, which is a complete host compromise in one API call. No amount of pod
> hardening matters if the socket is reachable.
>
> The realistic exposure is not a hostile actor — it is a monitoring agent, a CI
> runner or a build tool whose documentation says "mount the container socket". Treat
> every such request as a request for root on every node in the cluster, and evaluate
> it that way.

Enforce it with policy so it cannot be done by accident:

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: block-container-socket-mounts
spec:
  validationFailureAction: Enforce
  rules:
    - name: no-socket-hostpath
      match:
        any:
          - resources:
              kinds: [Pod]
      validate:
        message: "Mounting the container runtime socket is not permitted."
        pattern:
          spec:
            =(volumes):
              - =(hostPath):
                  path: "!/run/containerd/containerd.sock & !/var/run/docker.sock"
```

See [[kubernetes/security/kyverno]].

## Keep the default restrictions on

```toml
[plugins."io.containerd.grpc.v1.cri"]
  disable_apparmor = false
  restrict_oom_score_adj = true
  enable_unprivileged_ports = false
  enable_unprivileged_icmp = false

[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc.options]
  SystemdCgroup = true
  NoPivotRoot = false
  NoNewKeyring = false
```

| Setting | Why |
| --- | --- |
| `disable_apparmor = false` | Keeps the default AppArmor profile applied where the distribution supports it |
| `restrict_oom_score_adj = true` | Stops a container making itself less likely to be OOM-killed than host processes |
| `enable_unprivileged_ports = false` | Binding below 1024 continues to require `NET_BIND_SERVICE` |
| `NoPivotRoot = false` | `pivot_root` genuinely detaches the old root. `chroot` fallback is escapable |

`NoPivotRoot = true` appears in guides for running containers inside containers. It
weakens filesystem isolation meaningfully — prefer fixing the nesting.

> [!note] On containerd 2.x
> These are containerd 1.x section names. In 2.x the keys above sit under
> `plugins.'io.containerd.cri.v1.runtime'` (see the table in
> [[containers/containerd/basics]]), with the same names and meanings. One
> exception: containerd 2.3 has no `NoPivotRoot` runc option at all (its default
> configuration, which lists every option, does not show it), so there is nothing to
> leave at `false`.

## Seccomp

containerd applies runc's default seccomp profile through the CRI, blocking roughly 40
dangerous syscalls. In Kubernetes, make it explicit rather than relying on the
default:

```yaml
securityContext:
  seccompProfile:
    type: RuntimeDefault
```

Cluster-wide, via the kubelet:

```yaml
seccompDefault: true
```

That makes `RuntimeDefault` apply to every pod that does not specify otherwise, which
is the single highest-value kubelet flag for container security.

## SELinux

```toml
[plugins."io.containerd.grpc.v1.cri"]
  enable_selinux = true
  selinux_category_range = 1024
```

With SELinux enforcing, containerd labels each container with a unique MCS category,
so two containers cannot read each other's files even if the discretionary permissions
would allow it. See selinux.

## User namespaces

Remapping container root to an unprivileged host UID means an escape lands as nobody:

```yaml
apiVersion: v1
kind: Pod
spec:
  hostUsers: false
  containers:
    - name: app
      image: myapp:1.0
```

This needs `UserNamespacesSupport` enabled on the kubelet and a recent containerd and
kernel. It is the structural version of "do not run as root" described in
[[containers/concepts]] — worth adopting where your workloads tolerate it.

## Restrict which runtimes exist

Only configure runtimes you intend to allow. A `RuntimeClass` cannot select a handler
that is not present, so omitting one is a real control.

Where multiple runtimes exist, restrict who may use the permissive ones:

```yaml
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: kata
handler: kata
scheduling:
  nodeSelector:
    workload-isolation: strong
```

## Restrict registries

Prevent images from arbitrary sources. containerd can be pointed at an internal mirror
only (see [[containers/containerd/advanced]]), and admission policy should enforce it:

```yaml
      validate:
        message: "Images must come from the internal registry."
        pattern:
          spec:
            containers:
              - image: "registry.example.com/*"
```

Combine with signature verification — cosign — so the
registry restriction cannot be bypassed by pushing to it.

## Audit it

containerd operations show up in the audit log if you watch the
right paths:

```text
-w /etc/containerd/config.toml -p wa -k containerd_config
-w /run/containerd/containerd.sock -p rwa -k containerd_socket
-w /usr/bin/runc -p x -k runc_exec
```

The socket watch is the valuable one — it records every process that opens it, which
answers "what is talking to the runtime on this node?"

## CIS checks worth knowing

`kube-bench` covers the runtime alongside the cluster. The recurring findings:

| Check | Expected |
| --- | --- |
| `config.toml` ownership | `root:root`, mode `600` |
| Socket ownership | `root:root`, not group- or world-writable |
| Default seccomp | Applied, not `unconfined` |
| AppArmor or SELinux | Enabled |
| Privileged containers | None outside documented exemptions |
| `hostPID`, `hostIPC`, `hostNetwork` | Not used without justification |

```bash
sudo chown root:root /etc/containerd/config.toml
sudo chmod 600 /etc/containerd/config.toml
```

The last two rows are policy rather than configuration — see
[[kubernetes/security/pod-security-admission]].

## Keep it patched

Container escapes are runtime bugs, and both containerd and runc have had them.
`runc` CVE-2019-5736 — overwriting the host `runc` binary from inside a container —
remains the canonical example of why this component is not one to leave stale.

```bash
containerd --version
runc --version
```

Track both, and remember that upgrading containerd does **not** upgrade `runc`; they
are separate packages.

## Where to go next

- [[containers/security]] — hardening at the workload level
- secure-container-images — what goes into the images this runs
- [[kubernetes/security/pod-security-admission]] — enforcing the pod-level rules
- auditd — persisting the audit rules above

<!-- uplink -->
Part of [[containers/containerd/index|containerd]].
