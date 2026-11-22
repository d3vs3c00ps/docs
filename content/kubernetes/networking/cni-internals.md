---
title: "CNI internals"
description: "How CNI plugins are really invoked — environment variables, JSON on stdin and stdout, plugin chains, and instrumenting a plugin to watch it happen"
tags: [kubernetes, networking, cni]
type: lab
status: complete
source: https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/cni-internals.md
license: CC-BY-4.0
upstream_commit: 56563629
upstream_sync: manual
---

# CNI internals

The container runtime looks for a CNI configuration file, by default in
`/etc/cni/net.d`. With several files, the first in lexicographic order wins.
While no configuration exists, the node creates no containers — except
`hostNetwork` pods, which need no CNI. (The node then reports `NotReady` with
`cni plugin not initialized` — see [[containers/containerd/troubleshooting]].)

## General principle

A plugin is an executable program. It is invoked to set up or tear down the
networking of one container. It takes **no command-line arguments**: environment
variables say what to do and to which container, the configuration arrives as
JSON on **stdin**, and the result leaves as JSON on **stdout** (the allocated
address, routes, DNS...). Usually several plugins run in a row — at least IPAM
plus network setup.

> [!note] Who does the invoking
> The slides said "invoked by kubelet", and that was true in the dockershim era.
> Since the CRI runtimes took over CNI (Kubernetes 1.24), **the runtime** —
> containerd or CRI-O — execs the plugins. The lab below proves it: the
> recorded parent process is containerd, not kubelet.

## Environment variables

| Variable | Contents |
| --- | --- |
| `CNI_COMMAND` | `ADD`, `DEL`, `CHECK` or `VERSION` |
| `CNI_CONTAINERID` | opaque ID of the "sandbox" — the container running the `pause` image |
| `CNI_NETNS` | path to the network namespace pseudo-file, e.g. `/var/run/netns/cni-0376f625-...` |
| `CNI_IFNAME` | the interface name to create, usually `eth0` |
| `CNI_PATH` | where plugin executables live, e.g. `/opt/cni/bin` |
| `CNI_ARGS` | extra `key=value` pairs from "the user" — which here means Kubernetes |

`CNI_ARGS` is how the pod's identity reaches the plugin, as a `;`-separated
list:

```text
CNI_ARGS=IgnoreUnknown=1;K8S_POD_NAMESPACE=default;K8S_POD_NAME=web-96d5df5c8-jcn72;K8S_POD_INFRA_CONTAINER_ID=016493dbff152641d334d9828dab6136c1ff...
```

## Conf vs conflist, and plugin chains

The CNI configuration can be a single plugin configuration — a `type` field at
the top level, passed to the plugin as-is. Or it can be a **conflist**, a
`plugins` list forming a chain. Chained plugins run in order (reverse order for
`DEL`), and each receives as input:

- its own configuration from the list,
- augmented with `name` (the conflist's name),
- augmented with `prevResult` — the output of the previous plugin.

Conceptually, the first plugin does the main setup, and the others refine it:
firewalling, traffic shaping, tuning. Mind that "plugin configuration" is
therefore **not** the same thing as "CNI configuration".

## Analyzing plugins

To see exactly what goes in and out, wrap a real plugin in a fake one that
records everything:

```bash
#!/bin/sh
PLUGIN=$(basename $0)
cat > /tmp/cni.$$.$PLUGIN.in
env | sort > /tmp/cni.$$.$PLUGIN.env
echo "PPID=$PPID, $(readlink /proc/$PPID/exe)" > /tmp/cni.$$.$PLUGIN.parent
$0.real < /tmp/cni.$$.$PLUGIN.in > /tmp/cni.$$.$PLUGIN.out
EXITSTATUS=$?
cat /tmp/cni.$$.$PLUGIN.out
exit $EXITSTATUS
```

> [!example] Hands-on
> - Save the script as `/opt/cni/bin/debug` and make it executable.
> - For each plugin to instrument (say `ptp`): rename `ptp` to `ptp.real`, and
>   symlink `ptp` to `debug`. No CNI configuration change, no kubelet restart.
> - Create a pod, then look in `/tmp` for each instrumented plugin:
>   `cni.PID.ptp.in` (JSON input), `.env` (environment), `.parent` (what called
>   it), `.out` (JSON output).

The `.in` file shows the injected `name` and, for plugins later in the chain,
`prevResult`. The `.env` file shows `CNI_COMMAND=ADD`, the netns path and the
`CNI_ARGS` with the pod's name and namespace. And `.parent` answers the
question the slides left open — the caller is the container runtime.

---

> [!info] Adapted from container.training
> This page is derived from [`slides/k8s/cni-internals.md`](https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/cni-internals.md)
> in **[container.training](https://github.com/jpetazzo/container.training)** by Jérôme Petazzoni and contributors,
> used under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).
> **Changes were made**: restructured from slides into a single page, rewritten
> as prose, remark markup converted to Obsidian callouts, updated for the
> post-dockershim invocation path, referenced files inlined or linked.

<!-- uplink -->
Part of [[kubernetes/networking/index|Networking]].
