---
title: CNI plugin internals
description: How the container runtime invokes CNI plugins — the environment-variable contract, conf versus conflist, and plugin chaining
tags: [kubernetes, networking, cni, containers]
type: concept
status: complete
---

# CNI plugin internals

The Container Network Interface decouples networking from Kubernetes. It is
implemented by *plugins*, which are executables invoked by the **container runtime**
(containerd or CRI-O).

> [!note] Who calls the plugins
> kubelet asks the runtime, through the Container Runtime Interface (CRI), to create
> the pod sandbox, and the runtime calls the plugins. kubelet called them itself only
> with dockershim, which was removed in Kubernetes 1.24.

Plugins are responsible for:

- allocating IP addresses for pods
- configuring the network for containers

Plugins can be combined and chained where that makes sense.

These are my own notes, going a level below
[[kubernetes/networking/cni]] into the plugin contract itself.

## Combining plugins

- Interfaces can be created by, for example, the `vlan` or `bridge` plugins
- IP addresses can be allocated by, for example, the `dhcp` or `host-local` plugins
- Interface parameters (MTU, sysctls) can be adjusted by the `tuning` plugin

The reference plugins are
[here](https://github.com/containernetworking/plugins).

See virtual-interfaces for what `bridge`, `vlan` and `macvlan`
actually do at the kernel level.

## How does the runtime know which plugin to use?

The list of plugins is given in the **CNI configuration**, a single file on each node
in `/etc/cni/net.d`.

> [!warning] Only one file is used
> If several files are present, the **first in lexicographic order** wins. This is a
> reliable source of confusion when a CNI upgrade leaves an old configuration file
> behind — the cluster keeps using the stale one.

The directory is set in the runtime's configuration. For containerd, it is `conf_dir`
(and `bin_dirs` for the plugins) in the CRI plugin section of
`/etc/containerd/config.toml`. Check it with `containerd config dump`. Kubelet's old
`--cni-conf-dir` flag was removed with dockershim.

## CNI configuration in practice

When we install a CNI — Calico, Weave, Cilium — it ships its configuration, and
sometimes its own CNI plugins. Most often these are installed automatically by a
**DaemonSet** with an **initContainer** and a **hostPath** volume, which is how a pod
manages to write files onto the host's `/etc/cni/net.d`.

## General principles

- A plugin is an executable program.
- It is invoked by the container runtime to set up or tear down networking for a container.
- It takes **no command line arguments**.
- It reads **environment variables** to know what to do.
- It reads JSON on stdin and replies with JSON on stdout — the allocated address,
  routes, DNS, and so on.

That contract is the whole of CNI. It is deliberately small enough that a plugin can
be a shell script.

## Plugin invocation

Parameters arrive as environment variables:

| Variable | Meaning |
| --- | --- |
| `CNI_COMMAND` | `ADD`, `DEL`, `CHECK` or `VERSION` |
| `CNI_CONTAINERID` | the container ID |
| `CNI_NETNS` | path to the network namespace pseudo-file |
| `CNI_IFNAME` | name of the network interface to create |
| `CNI_PATH` | where to find plugin executables (default `/opt/cni/bin`) |
| `CNI_ARGS` | semicolon-separated key/value pairs from the runtime — used to pass the pod and namespace names |

```text
CNI_ARGS=IgnoreUnknown=1;K8S_POD_NAMESPACE=default;K8S_POD_NAME=web-96d...
```

The network configuration itself must be supplied to the plugin on **stdin**.

For example, on a kind node, this runs the `ptp` plugin by hand, in a new network
namespace. It prints the JSON result, with the address that `host-local` allocated:

```bash
ip netns add demo
echo '{"cniVersion":"1.0.0","name":"mynet","type":"ptp",
       "ipam":{"type":"host-local","subnet":"10.22.0.0/16"}}' |
  CNI_COMMAND=ADD CNI_CONTAINERID=demo CNI_NETNS=/var/run/netns/demo \
  CNI_IFNAME=eth0 CNI_PATH=/opt/cni/bin /opt/cni/bin/ptp
```

Run the same command with `CNI_COMMAND=DEL` to remove the interface.

## conf versus conflist

Two configuration formats exist:

| | Basic configuration | Configuration list |
| --- | --- | --- |
| File suffix | `.conf` | `.conflist` |
| Plugins supported | exactly one | several, chained |
| Distinguishing field | a `type` string in the top-level object | a `plugins` **array** |

Plugins in a `.conflist` are invoked in file order for `ADD`, and in **reverse
order** for `DEL` — teardown unwinds the chain.

> [!note] `.conf` versus `.conflist`
> A `.conf` has a top-level **`type`** naming its single plugin and no `plugins` field
> at all. A `.conflist` has a **`plugins` array**. That is what tells the two formats
> apart.

A minimal `.conf`:

```json
{
  "cniVersion": "1.0.0",
  "name": "mynet",
  "type": "bridge",
  "bridge": "cni0",
  "ipam": { "type": "host-local", "subnet": "10.22.0.0/16" }
}
```

And the equivalent as a `.conflist` with a second plugin chained on:

```json
{
  "cniVersion": "1.0.0",
  "name": "mynet",
  "plugins": [
    {
      "type": "bridge",
      "bridge": "cni0",
      "ipam": { "type": "host-local", "subnet": "10.22.0.0/16" }
    },
    {
      "type": "tuning",
      "mtu": 1400
    }
  ]
}
```

## Plugin lists

When a plugin list is invoked, the JSON given to each plugin is:

- that plugin's own configuration
- augmented with the previous plugin's output, as `prevResult`

In order, the first plugin does most of the configuration and the following plugins
add capabilities — firewalling, traffic shaping, and so on.

That is why order matters and why `DEL` runs backwards: a plugin that added a
firewall rule for an interface must remove it before the plugin that created the
interface destroys it.

<!-- uplink -->
Part of [[kubernetes/my-notes/index|My own Kubernetes notes]].
