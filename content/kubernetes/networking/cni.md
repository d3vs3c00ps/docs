---
title: "The Container Network Interface"
description: "How kubelet and the runtime find and invoke CNI plugins, conf vs conflist, and a kube-router walkthrough with BGP routing"
tags: [kubernetes, networking, cni]
type: lab
status: complete
source: https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/cni.md
license: CC-BY-4.0
upstream_commit: 56563629
upstream_sync: manual
---

# The Container Network Interface

CNI decouples network configuration from Kubernetes. It is implemented by
*plugins*: executables invoked by the container runtime (historically by kubelet
directly) each time a pod sandbox is created or deleted. The plugins are
responsible for allocating the pod's IP address and configuring its network
interface. Plugins can be combined and chained when it makes sense:

- the interface is created by, say, the `bridge` or `vlan` plugin;
- the address is allocated by `host-local` or `dhcp`;
- parameters like MTU or sysctls are tweaked by the `tuning` plugin.

The [reference plugins][cni-reference-plugins] each document themselves in their
own directory.

[cni-reference-plugins]: https://github.com/containernetworking/plugins/tree/master/plugins

## How the plugins are found

The plugin, or list of plugins, is set in the CNI configuration: a **single
file** in `/etc/cni/net.d`. With several files in that directory, the first one
in lexicographic order wins. (The path is configurable — kubelet's old
`--cni-conf-dir`, now the runtime's config, such as containerd's
`conf_dir`.)

When you install a "pod network" — Calico, Cilium, kube-router — it ships its
CNI configuration, and sometimes custom plugins. Both usually get installed by a
DaemonSet with an initContainer writing through hostPath volumes. Examples:
Calico's [CNI config](https://github.com/projectcalico/calico/blob/1372b56e3bfebe2b9c9cbf8105d6a14764f44159/v2.6/getting-started/kubernetes/installation/hosted/calico.yaml#L25)
and [volume](https://github.com/projectcalico/calico/blob/1372b56e3bfebe2b9c9cbf8105d6a14764f44159/v2.6/getting-started/kubernetes/installation/hosted/calico.yaml#L219);
kube-router's [CNI config](https://github.com/cloudnativelabs/kube-router/blob/c2f893f64fd60cf6d2b6d3fee7191266c0fc0fe5/daemonset/generic-kuberouter.yaml#L10)
and [volume](https://github.com/cloudnativelabs/kube-router/blob/c2f893f64fd60cf6d2b6d3fee7191266c0fc0fe5/daemonset/generic-kuberouter.yaml#L73).

### Conf vs conflist

Two slightly different formats exist:

| | `.conf` | `.conflist` |
| --- | --- | --- |
| Holds | one plugin | several chained plugins |
| Top-level marker | a `type` string field | a `plugins` list field |
| Spec examples | [here](https://github.com/containernetworking/cni/blob/master/SPEC.md#example-configurations) | [here](https://github.com/containernetworking/cni/blob/master/SPEC.md#network-configuration-lists) |

### How plugins are invoked

Parameters come in as environment variables:

- `CNI_COMMAND` — the operation: `ADD`, `DEL`, `CHECK` or `VERSION`
- `CNI_CONTAINERID` — the container ID
- `CNI_NETNS` — path to the network namespace file
- `CNI_IFNAME` — the name the interface should get

The network configuration itself is fed to the plugin **on stdin** — passing a
file path instead would invite race conditions. You can drive a plugin by hand:

```bash
echo '{"cniVersion": "1.0.0"}' | CNI_COMMAND=VERSION /opt/cni/bin/ptp
```

## In practice: kube-router

> [!warning] A training-VM lab, frozen in time
> The walkthrough below comes from the upstream course and needs its multi-VM
> environment (`kuberouter1..3`). It also predates the dockershim removal:
> kubelet's `--network-plugin=cni` flag **no longer exists** since Kubernetes
> 1.24 (the runtime handles CNI now), and `docker-compose` v1 is EOL. Keep it
> for the architecture it demonstrates — routed pod networking over BGP — not as
> commands to replay on a current cluster.

kube-router has a deliberately simple architecture. It introduces no new CNI
plugins — it uses `bridge` with `host-local` IPAM. Pod traffic is **routed**
between nodes: no tunnel, no new protocol. Internal service connectivity is
implemented with IPVS, replacing kube-proxy. One kube-router daemon runs per
node, and each daemon:

1. connects to the API server and obtains the local node's `podCIDR`;
2. injects it into the CNI configuration file
   (`/etc/cni/net.d/10-kuberouter.conflist`);
3. obtains the addresses of all other nodes;
4. establishes a *full mesh* BGP peering with them and exchanges routes.

> [!note]- What's BGP?
> The Border Gateway Protocol is what internet routers speak between themselves.
> It [scales well](https://www.cidr-report.org/as2.0/) — it announces the
> 700k+ prefixes of the internet — and is implemented by hardware routers and by
> software (Quagga, Bird, FRR...). Calico uses it too. Speaking BGP lets the pod
> network interconnect with the rest of the network infrastructure, and
> experienced network folks already know how to operate it.

### The plan

Work on a fresh cluster named `kuberouter`: a simple control plane, with the
controller manager allocating `podCIDR` subnets (`--allocate-node-cidrs` and
`--cluster-cidr`), a DaemonSet for kube-router, then nodes joining.

> [!example] Hands-on
> - Log into node `kuberouter1`, clone the workshop repository and move to the
>   control-plane Compose project:
>   ```bash
>   git clone https://github.com/jpetazzo/container.training
>   cd container.training/compose/kube-router-k8s-control-plane
>   ```
> - Edit the Compose file to set the cluster CIDR (`10.C.0.0/16`, where `C` is
>   your cluster number), then start the control plane:
>   ```bash
>   vim docker-compose.yaml
>   docker-compose up
>   ```

At this point `/etc/cni/net.d` does not even exist on the nodes.

### The kube-router DaemonSet

`kuberouter.yaml`, in the same directory, defines the DaemonSet and a ConfigMap.
kube-router needs the API server's address (`http://A.B.C.D:8080`, the public
address of `kuberouter1`):

> [!example] Hands-on
> - Set the API server address, then create the DaemonSet:
>   ```bash
>   vim kuberouter.yaml
>   kubectl create -f kuberouter.yaml
>   ```

The DaemonSet creates no pods yet — there are no nodes yet.

### Joining nodes

> [!example] Hands-on
> - Generate a kubeconfig (replacing `X.X.X.X` with the address of
>   `kuberouter1`) and copy it to the other nodes:
>   ```bash
>   kubectl config set-cluster cni --server http://X.X.X.X:8080
>   kubectl config set-context cni --cluster cni
>   kubectl config use-context cni
>   cp ~/.kube/config ~/kubeconfig
>   for N in 2 3; do scp ~/kubeconfig kuberouter$N: ; done
>   ```
> - Join the nodes (`--pod-cidr` is no longer needed — the controller manager
>   allocates the subnets):
>   ```bash
>   sudo kubelet --kubeconfig ~/kubeconfig --network-plugin=cni
>   ssh kuberouter2 sudo kubelet --kubeconfig ~/kubeconfig --network-plugin=cni
>   ssh kuberouter3 sudo kubelet --kubeconfig ~/kubeconfig --network-plugin=cni
>   ```

Once a node joins, kube-router writes its CNI configuration into
`/etc/cni/net.d`, containing that node's podCIDR.

### Testing it

> [!example] Hands-on
> - Create a web deployment, spread it across nodes, and expose it:
>   ```bash
>   kubectl create deployment blue --image=jpetazzo/color
>   kubectl scale deployment blue --replicas=5
>   kubectl expose deployment blue --port=8888
>   ```
> - Get the service's ClusterIP and send a few requests:
>   ```bash
>   kubectl get svc blue
>   curl X.X.X.X:8888
>   ```

> [!note] Correction
> The original read `kubectl get svc web`, but the service created above is
> named `blue`.

Repeated requests are load-balanced **round robin** — visible proof that IPVS is
doing the service routing, where iptables picks random endpoints.

> [!note]- Troubleshooting the routed network
> `kubectl get pods -o wide` shows the pod addresses; `ip route` (or the legacy
> `route -n`) should show the local pod CIDR connected to `kube-bridge`, and one
> route per remote node's CIDR with that node as gateway.
>
> `kubectl logs` / `kubectl exec` on the kube-router pods may fail with
> `dial tcp: lookup kuberouterX ... no such host`: the API server connects to
> kubelets **by node name** by default, so the names must resolve in DNS — or
> set `--kubelet-preferred-address-types=InternalIP` on the API server. As a
> fallback, ask the container engine directly:
> ```bash
> CID=$(docker ps -q \
>       --filter label=io.kubernetes.pod.namespace=kube-system \
>       --filter label=io.kubernetes.container.name=kube-router)
> docker logs $CID
> ```

> [!note]- Other ways to distribute routing tables
> BGP is not required to distribute routes: the nodes and their `podCIDR`
> subnets are all in the API. This snippet prints the route commands a node
> would need — useful for embedded platforms or lab environments:
>
> ```bash
> NODES=$(kubectl get nodes -o name | cut -d/ -f2)
> for DESTNODE in $NODES; do
>   if [ "$DESTNODE" != "$HOSTNAME" ]; then
>     echo $(kubectl get node $DESTNODE -o go-template="
>       route add -net {{.spec.podCIDR}} gw {{(index .status.addresses 0).address}}")
>   fi
> done
> ```

---

> [!info] Adapted from container.training
> This page is derived from [`slides/k8s/cni.md`](https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/cni.md)
> in **[container.training](https://github.com/jpetazzo/container.training)** by Jérôme Petazzoni and contributors,
> used under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).
> **Changes were made**: restructured from slides into a single page, rewritten as
> prose, remark markup converted to Obsidian callouts, the kube-router lab marked
> as historical (pre-1.24 kubelet flags), the service-name typo fixed, referenced
> files inlined or linked.

<!-- uplink -->
Part of [[kubernetes/networking/index|Networking]].
