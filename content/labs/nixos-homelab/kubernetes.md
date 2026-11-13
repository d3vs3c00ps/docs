---
title: Kubernetes on NixOS with Cilium
description: A three-node cluster on vfkit with services.kubernetes and Cilium instead of flannel — the CNI directories NixOS owns, privileged pods, pod CIDRs, the certmgr loop, the resolved stub and CoreDNS, and one script to join and install
tags: [homelab, nixos, kubernetes, cilium, cni]
type: lab
status: draft
---

# Kubernetes on NixOS with Cilium

> [!note] Not tested locally
> The lab runs on a Mac with vfkit. The test harness cannot run it. On vfkit, 3 nodes
> are Ready, 10 pods run, pod DNS works, and the Cilium connectivity test passes
> (82 tests, 708 actions, 48 skipped by design).

Three VMs (2 vCPU, 4 GB each), one control plane and two workers, with the upstream components run
by the NixOS `services.kubernetes` module — not k3s. The module's default network
plugin is flannel; this cluster uses **Cilium** instead, which needed six changes
to the module's defaults, a fix for a certificate renewal loop, and more
changes once Cilium replaced kube-proxy. On vfkit, one more was needed for DNS. See [[labs/nixos-homelab/overview]], and
Cilium for what Cilium does.

| Host | IP | Role |
| --- | --- | --- |
| k8s-01 | 192.168.64.20 | Control plane: API server, etcd, scheduler, controller manager, cfssl. Also a tainted kubelet |
| k8s-02 | 192.168.64.21 | Worker |
| k8s-03 | 192.168.64.22 | Worker |

Cilium 1.20.2 and CoreDNS 1.48.2 (Helm), all `arm64`.

> [!note] services.kubernetes or k3s
> The NixOS wiki suggests k3s for beginners: fewer parts, better maintained in
> nixpkgs. `services.kubernetes` runs the real components as separate systemd
> units, which is the point here — every piece is visible. Its automatic
> certificates (`easyCerts`) support **one** control-plane node only.

## One module, one option per host

```nix
# hosts/k8s-02/default.nix
{
  imports = [
    ./hardware-configuration.nix
    ../../modules/server.nix
    ../../modules/disk-vm.nix
    ../../modules/k8s.nix
  ];
  networking.hostName = "k8s-02";
  lab.server.address = "192.168.64.21";
  lab.k8s.role = "node";             # or "master" on k8s-01
  system.stateVersion = "26.05";
}
```

The shared part of `modules/k8s.nix`:

```nix
services.kubernetes = {
  roles = [ cfg.role ];
  masterAddress = "k8s-01.lab.home.arpa";
  apiserverAddress = "https://k8s-01.lab.home.arpa:6443";
  easyCerts = true;
  flannel.enable = false;
  clusterCidr = "10.1.0.0/16";
  kubelet.cni.configDir = "/var/lib/cni/net.d";
  kubelet.extraConfig.resolvConf = "/run/systemd/resolve/resolv.conf";   # see below
};
```

## Six changes for Cilium

Read the module source before replacing a default it was built around:
`nix eval --raw .#nixosConfigurations.k8s-01.pkgs.path` gives the nixpkgs tree;
the module is in `nixos/modules/services/cluster/kubernetes/`.

### 1. `/etc/cni/net.d` is read-only

```nix
# kubelet.nix, in the module
environment.etc."cni/net.d".source = cniConfig;
```

NixOS links the directory into the store. Cilium's agent writes its own config
file there at start, which would fail. Point the kubelet at a writable directory
— `/etc/cni/net.d` then becomes a link to it — and tell Cilium the same:

```nix
services.kubernetes.kubelet.cni.configDir = "/var/lib/cni/net.d";
systemd.tmpfiles.rules = [ "d /var/lib/cni/net.d 0755 root root -" ];
```

### 2. `/opt/cni/bin` is emptied at every kubelet start

```nix
# kubelet.nix, preStart
rm /opt/cni/bin/* || true
ln -fs ${package}/bin/* /opt/cni/bin     # for each cni.packages
```

Cilium copies its `cilium-cni` binary into the CNI bin directory once, when its
pod starts. The next kubelet restart — any `nixos-rebuild switch` that touches it
— deletes it, and new pods on that node get no network. Install it somewhere
persistent and link it back after the `rm`:

```nix
systemd.tmpfiles.rules = [ "d /var/lib/cni/bin 0755 root root -" ];
systemd.services.kubelet.preStart = lib.mkAfter ''
  ln -sfn /var/lib/cni/bin/cilium-cni /opt/cni/bin/cilium-cni
'';
```

`lib.mkAfter` appends to the module's script instead of replacing it, so image
seeding and the standard plugins keep working. The link may dangle until Cilium
installs the binary; that is fine.

Tested: `systemctl restart kubelet` on a worker, then a new pod there still got
an address.

### 3. Privileged pods are forbidden

The first `helm install` failed halfway:

```text
DaemonSet.apps "cilium" is invalid: spec.template.spec.initContainers[3]
.securityContext.privileged: Forbidden: disallowed by cluster policy
```

The module starts the API server with `--allow-privileged=false`. Flannel never
noticed, as it runs as a systemd service; Cilium's agent is a privileged pod
(eBPF programs, BPF filesystem):

```nix
services.kubernetes.apiserver.allowPrivileged = true;     # master only
```

Helm had already created the operator, envoy and the relay, so the symptom was
pods `Pending` and **no** `cilium` DaemonSet at all. `helm history` shows the
reason. After the fix, `helm upgrade` with the same arguments finished the
release.

### 4. Pod CIDR overlaps the service range

The module's service range is `10.0.0.0/24`. Cilium's default IPAM hands out pod
addresses from `10.0.0.0/8` — which contains it. Use the per-node ranges the
controller manager assigns from `clusterCidr` instead:

```nix
services.kubernetes.controllerManager.allocateNodeCIDRs = true;   # master
```

```yaml
# k8s/cilium-values.yaml
ipam:
  mode: kubernetes
```

Pods then get `10.1.<node>.x`.

### 5. The firewall opens only flannel's ports

```nix
networking.firewall.allowedTCPPorts = [ 10250 4240 4244 ];   # kubelet, cilium health, hubble
networking.firewall.allowedUDPPorts = [ 8472 ];              # cilium VXLAN
# master also: 6443 (API server), 8888 (cfssl — workers fetch certificates)
```

### 6. The NixOS reverse-path filter

```nix
networking.firewall.checkReversePath = false;
```

The first version of this note said `"loose"`. That was the bug behind every
failing proxy test, found last — see
[[#Cilium's proxies and the reverse-path filter]].

## The outage every 30 minutes

The cluster looked healthy. The first `cilium connectivity test` (an earlier run) failed
35 of 82 tests, and the errors were not about the network:

```text
dial tcp 192.168.64.20:6443: connect: connection refused
```

The API server was **down** during the test. `NRestarts=0` ruled out a crash;
the journal showed who stopped it:

```text
certmgr: spec .../kubeletClient.json is needs refresh: spec DNS name has changed
certmgr: invoking command notification of systemctl restart kube-apiserver.service
systemd: Stopping Kubernetes APIServer Service...
systemd: Stopped Kubernetes APIServer Service.        # 60 s later
```

Every 30 minutes, since the install, certmgr reissued seven certificates and
restarted the API server, controller manager, scheduler, kube-proxy and kubelet.

The cause is one line in the module's `pki.nix`:

```nix
request = {
  hosts = [ cert.CN ] ++ cert.hosts;
  ...
};
```

The CN goes into the host list of every certificate. For server certificates it
is a name (`kubernetes`, `k8s-01.lab.home.arpa`). For client certificates it is
a Kubernetes identity — `system:node:k8s-01`, `system:kube-scheduler`. cfssl
leaves non-DNS names out of the certificate; certmgr 3 compares the request's
hosts with the certificate's names, finds a difference, and reissues. Forever.

```bash
journalctl -u certmgr -o cat | grep -oE "[A-Za-z]+.json is needs refresh: .*" | sort | uniq -c
#  20 kubeletClient.json is needs refresh: spec DNS name has changed
#  20 schedulerClient.json is needs refresh: spec DNS name has changed
#  ...
```

The fix rebuilds those requests without the identity names:

```nix
services.certmgr.specs =
  let
    isIdentity = h: h != null && lib.hasInfix ":" h;
    hostsOf = cert: [ cert.CN ] ++ cert.hosts;
  in
  lib.mapAttrs
    (_: cert: {
      request = lib.mkForce {
        hosts = lib.filter (h: !isIdentity h) (hostsOf cert);
        inherit (cert) CN;
        key = { algo = "rsa"; size = 2048; };
        names = [ cert.fields ];
      };
    })
    (lib.filterAttrs (_: cert: lib.any isIdentity (hostsOf cert)) config.services.kubernetes.pki.certs);
```

> [!warning] `mkForce` only works on declared options
> The first attempt was `request.hosts = lib.mkForce [ ];`. It evaluated and
> built — and wrote `"hosts": {"_type": "override", ...}` into the spec JSON.
> `request` is an option of type `attrs`; what is *inside* it is plain data,
> where `mkForce` is just an attribute set. Override the whole `request`
> instead, and read the generated file before deploying:
>
> ```bash
> jq .request /nix/store/...-certmgr.d/kubeletClient.json
> ```

Checking the fix does not need 30 minutes — a restart runs a full check:

```bash
t=$(date +%H:%M:%S); systemctl restart certmgr; sleep 25
journalctl -u certmgr --since $t -o cat | grep -c "needs refresh"   # 0
```

## Cilium values

```yaml
ipam:
  mode: kubernetes
kubeProxyReplacement: true         # services.kubernetes.proxy.enable = false
k8sServiceHost: k8s-01.lab.home.arpa
k8sServicePort: 6443
routingMode: tunnel
tunnelProtocol: vxlan
cni:
  confPath: /var/lib/cni/net.d
  binPath: /var/lib/cni/bin
operator:
  replicas: 1
hubble:
  enabled: true
  relay:
    enabled: true
```

The file lives in the repository and is linked to `/etc/cilium/values.yaml` on
k8s-01 by `environment.etc`. CoreDNS values are in `/etc/coredns/values.yaml`.

Images come from `quay.io/cilium` and are multi-arch. CoreDNS also comes from
Helm — see [[#Replacing kube-proxy]] for why the module's DNS addon had to go.

## Bring the cluster up

```bash
lab/lab.sh up k8s-01 k8s-02 k8s-03
lab/k8s-bootstrap.sh
```

The script is safe to run again. It does this:

1. **Joins the workers.** After the install, the workers' `kubelet` sits in
   **activating**: with `easyCerts`, it waits for certificates from the master's
   cfssl, which signs only for clients holding its API token. The script pipes the
   token from k8s-01 to `nixos-kubernetes-node-join` on each worker. The token is
   never printed.
2. Installs **Cilium 1.20.2** and **CoreDNS 1.48.2** with `helm upgrade --install` on
   k8s-01, and waits for `cilium status` and for the nodes to be Ready.
3. Runs a pod DNS test: a pod on k8s-02 resolves
   `kubernetes.default.svc.cluster.local`.

Before the join and before Cilium, the cluster looks broken and is not: nodes
`NotReady` (no network plugin), CoreDNS `Pending` (the only node is the tainted
master). Both resolve once Cilium runs and workers exist.

Use `kubectl` on k8s-01, where `KUBECONFIG` is set:

```bash
lab/lab.sh ssh k8s-01 kubectl get nodes -o wide
```

## The 127.0.0.53 stub and CoreDNS

On vfkit, CoreDNS pods died with `Loop detected`. The servers use systemd-networkd,
which turns systemd-resolved on. `/etc/resolv.conf` is then the stub `127.0.0.53`.
The kubelet gives it to pods, so CoreDNS forwarded to itself. (Plain vfkit NAT is not
the cause here: it isolates guests, which `vmnet-helper` fixes, see
[[labs/nixos-homelab/overview#Network]].)

The fix gives pods the real upstream servers:

```nix
services.kubernetes.kubelet.extraConfig.resolvConf = "/run/systemd/resolve/resolv.conf";
```

On a cluster that already runs the old setting, restart the pods that copied it:

```bash
kubectl -n kube-system rollout restart deploy/coredns deploy/hubble-relay
```

## Testing the network properly

`Ready` only means each kubelet has a CNI config. Prove traffic crosses nodes:
run a pod pinned to one worker and reach something on another.

```bash
kubectl run nettest --image=busybox:1.37 --restart=Never \
  --overrides='{"spec":{"nodeName":"k8s-02"}}' -- \
  sh -c 'nslookup kubernetes.default.svc.cluster.local; nc -w3 <pod-ip-on-k8s-03> 10053 </dev/null && echo ok'
```

Two of the first tests failed for reasons that had nothing to do with the
network:

> [!warning] Test the right protocol on the right port
> - Hubble relay speaks **gRPC**. An HTTP `wget` to it fails even when the
>   connection is fine. Test with a plain TCP connect (`nc`).
> - The NixOS CoreDNS addon listened on **10053** inside the pod; the `kube-dns`
>   service mapped 53 to it. A pod IP on port 53 answered "connection refused" —
>   a reply, so the network did deliver the packet. A timeout would have meant
>   the network.
>
> `kubectl get svc kube-dns -o jsonpath='{.spec.ports}'` shows the target port.

### The full suite

`cilium connectivity test` deploys clients, echo servers and policies, and lists
about 130 tests. On this lab (3 nodes, no kube-proxy) it passes: **82 tests (708
actions) successful, 48 skipped by design** (features this cluster does not enable,
such as ingress, egress gateway, mutual auth and BGP). Hubble flow validation was off:
the CLI could not reach Hubble Relay without a port-forward. The run time was not
measured. The table shows the earlier runs that found the problems fixed above.

| Run | Result | Why |
| --- | --- | --- |
| 1 | 35 of 82 failed | The API server and kube-proxy restarted during the run (the certmgr loop above) |
| 2 | Aborted in setup | Policies left by run 1 (`client-egress-only-dns`) blocked the test pods |
| 3 + subset | 78 of 82 pass | The 4 TLS-interception tests: the reverse-path filter |
| After kube-proxy removal | `to-fqdns` fails too | CoreDNS on 10053, then the reverse-path filter |
| rpfilter off, CoreDNS on 53 | all 9 previously failing tests pass | — |
| Same, full suite, no kube-proxy | **all 82 pass**, 48 skipped by design | — |

> [!tip] Clean up after each run
> The test leaves three namespaces behind, and a failed run can leave test policies
> applied, so the next run hangs in setup. Delete the namespaces:
> `kubectl delete ns cilium-test-1 cilium-test-ccnp1 cilium-test-ccnp2`.

The first run was the useful one: its failures pointed at the API server, not at
Cilium, and led to the certificate loop.

## Replacing kube-proxy

Order matters, so that Services keep working at every step:

1. Helm: `kubeProxyReplacement: true`, plus `k8sServiceHost`/`k8sServicePort`
   pointing at the API server — without kube-proxy, the `kubernetes` Service IP
   only works once Cilium runs, so Cilium cannot use it to find the API server.
   Both run side by side for a while; `cilium-dbg status` shows
   `KubeProxyReplacement: True`.
2. Per node: stop kube-proxy **and** remove its rules — stopping leaves them:

   ```bash
   kp=$(systemctl show kube-proxy -p ExecStart | grep -oE "/nix/store/[^ ;]+/bin/kube-proxy" | head -1)
   systemctl stop kube-proxy && $kp --cleanup
   iptables-save | grep -c KUBE      # 83 -> 8: the kubelet's own chains remain
   ```

3. Deploy `services.kubernetes.proxy.enable = false`.

Services, NodePorts, hairpin and plain DNS passed straight away. DNS **policies**
broke:

```text
xx drop (Policy denied) ... 10.1.2.76:38555 -> 10.1.2.70:10053 udp
```

The module's CoreDNS listens on **10053** in the pod. With kube-proxy, policy saw
the Service port, 53. Cilium's socket load balancer translates the Service
address **before** the policy check, so the policy now sees 10053 — and every
DNS rule written for port 53 stops matching. The port is hard-coded in the
module, so the addon is off and CoreDNS comes from its Helm chart on 53, keeping
the name `kube-dns`, the label `k8s-app: kube-dns` and the address `10.0.0.254`:

```nix
services.kubernetes.addons.dns.enable = false;
services.kubernetes.kubelet.clusterDns = [ "10.0.0.254" ];   # was derived from the addon
```

Disabling the addon does **not** delete its objects; the addon manager leaves
them. Delete them by hand right before `helm install` — about 40 seconds
without DNS.

## Cilium's proxies and the reverse-path filter

With CoreDNS on 53, FQDN policies still timed out. The agent log was precise:

```text
dns-proxy: Timeout waiting for response to forwarded proxied DNS lookup
           read udp 10.1.2.127:36654->10.1.2.69:53: i/o timeout
```

Step by step, what worked: the TPROXY rule counted the packets, the routing rule
`fwmark 0x200 lookup 2004` existed, the proxy listened, the kernel modules were
loaded. The query left the proxy — with the **pod's** address as source
(transparent mode) — and the answer never came back to it.

Turning transparent mode off made DNS work, and it looked like the fix. Then the
Envoy tests failed the same way — `SSL connection timeout`, `0 bytes received` —
and Envoy is a transparent proxy too. The common cause was in the NixOS
firewall, in the `mangle` table:

```text
-A PREROUTING -j nixos-fw-rpfilter
-A nixos-fw-rpfilter -m rpfilter --loose --validmark -j RETURN
...
-A nixos-fw-rpfilter -j DROP
```

```bash
iptables -t mangle -L nixos-fw-rpfilter -v -n -x
# DROP  2072 packets on k8s-02, 744 on k8s-03, 14 on the master
```

Answers to a transparent proxy carry mark `0x200`, which routes to table 2004 —
`local default dev lo`, everything local. `--validmark` checks the source address
*with* that mark, so an answer from `1.1.1.1` or from a CoreDNS pod looks like a
local address arriving from outside, and is dropped. The workers, where the test
pods ran, had the drops.

```nix
networking.firewall.checkReversePath = false;   # Cilium handles rp_filter itself
```

Transparent mode went back to Cilium's default, and all nine tests that had
failed — FQDN, FQDN through Envoy, the four TLS-interception tests — passed.

> [!tip] When a fix only moves the failure, keep looking
> Turning transparent mode off fixed DNS and left Envoy broken. Two proxies with
> one symptom pointed at something they share — the return path — not at
> either proxy. The DROP counter was the proof.

## Next
- Deploy from CI — which needs a deploy key on Woodpecker, a real security
  decision; see [[labs/nixos-homelab/woodpecker]].

<!-- uplink -->
Part of [[labs/nixos-homelab/index|NixOS home lab]].
