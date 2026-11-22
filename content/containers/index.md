---
title: "Containers"
description: "What a container actually is, the engines that run them, and how to do it without giving away the host."
tags: [containers]
type: moc
status: complete
---

<!-- generated-moc -->

# Containers

What a container actually is, the engines that run them, and how to do it without giving away the host.

## Sections

- [[containers/containerd/index|containerd]]

## Notes in this section

| Note | | What it covers |
| --- | --- | --- |
| [[containers/buildpacks\|Cloud Native Buildpacks]] | concept | Building images from source with no Dockerfile — how the lifecycle works, rebasing for fast CVE patching, and when it beats writing your own build |
| [[containers/cgroups-v2\|cgroups v2]] | concept | The unified hierarchy — controllers, the interface files that matter, memory and CPU semantics, and what changed from v1 |
| [[containers/concepts\|What a container actually is]] | concept | Namespaces, cgroups, capabilities and layered filesystems — the kernel features a container is assembled from, and why that shapes every security property |
| [[containers/docker\|Docker]] | how-to | Installing Docker, the commands worth knowing, network modes, writing a Dockerfile, and complementary tooling |
| [[containers/podman\|Podman]] | concept | The daemonless, rootless container engine — how it differs from Docker, pods, and running containers under systemd with Quadlet |
| [[containers/security\|Container security]] | reference | Hardening containers — resource exhaustion, running as non-root, image hygiene, logging, healthchecks and restart policies |

Part of [[index|Ops Notes]].
