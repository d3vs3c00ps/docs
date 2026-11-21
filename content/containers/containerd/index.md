---
title: "containerd"
description: "The runtime underneath both Docker and Kubernetes — configuring it, driving it, and debugging a node when it misbehaves."
tags: [containerd]
type: moc
status: complete
---

<!-- generated-moc -->

# containerd

The runtime underneath both Docker and Kubernetes — configuring it, driving it, and debugging a node when it misbehaves.


| Note | | What it covers |
| --- | --- | --- |
| [[containers/containerd/advanced\|containerd advanced configuration]] | reference | Snapshotters, registry mirrors and authentication, runtime classes for gVisor and Kata, lazy pulling, and plugin architecture |
| [[containers/containerd/basics\|containerd basics]] | how-to | Installing it, the config.toml that matters, the SystemdCgroup setting everyone gets wrong, and where its state lives on disk |
| [[containers/containerd/cli\|containerd command line tools]] | reference | ctr, crictl and nerdctl — which to reach for, the namespace flag everyone forgets, and the commands worth knowing on a node |
| [[containers/containerd/hardening\|containerd hardening]] | reference | Protecting the socket, default seccomp and AppArmor, user namespaces, restricting runtimes and registries, and what CIS actually asks for |
| [[containers/containerd/introduction\|What containerd is]] | concept | Where containerd sits between Docker, Kubernetes and runc — the CRI, shims, and why the Docker shim removal mattered |
| [[containers/containerd/troubleshooting\|containerd troubleshooting]] | reference | Disk filling up, image pull failures, pods stuck in ContainerCreating, cgroup driver mismatches, and reading containerd's logs |

Part of [[containers/index|Containers]].
