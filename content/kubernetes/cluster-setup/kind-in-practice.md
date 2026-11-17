---
title: kind in practice
description: Using kind as a local and CI test cluster — pinned versions, multi-node configs, loading images, a local registry, LoadBalancer and Ingress with cloud-provider-kind, NetworkPolicy, kubeadm patches
tags: [kubernetes, cluster-setup, kind, testing, ci]
type: howto
status: complete
---

# kind in practice

[kind](https://kind.sigs.k8s.io) (Kubernetes IN Docker) runs each Kubernetes node as
a container. Inside each node container, kubeadm sets up a normal cluster with
containerd. So a kind cluster behaves like a kubeadm cluster, but it starts in about a
minute and you delete it with one command.

[[kubernetes/cluster-setup/kind]] is the overview from the course. This note is the
hands-on part: the options you need to use kind as a real test cluster. All the
Kubernetes tests of this site run on kind.

## Install

kind is one static binary. Pin the version, and check the checksum:

```bash
KIND_VERSION=v0.33.0
ARCH=$(uname -m | sed 's/x86_64/amd64/; s/aarch64/arm64/')
curl -fsSLo kind "https://github.com/kubernetes-sigs/kind/releases/download/${KIND_VERSION}/kind-linux-${ARCH}"
curl -fsSL "https://github.com/kubernetes-sigs/kind/releases/download/${KIND_VERSION}/kind-linux-${ARCH}.sha256sum" \
  | sed 's|  .*|  kind|' | sha256sum -c -
mkdir -p ~/.local/bin
install -m 0755 kind ~/.local/bin/kind
kind version
```

kind needs a container engine (Docker or Podman) and `kubectl`.

## Create, list, delete

```bash
kind create cluster --name demo
kind get clusters
kubectl cluster-info --context kind-demo
kind delete cluster --name demo
```

The kubeconfig context is always `kind-<name>`. The default name is `kind`.

### Pin the Kubernetes version

Each kind release has a default node image, and lists the images built for it. Use
the image **with its digest**. The kind release notes say a tag alone may give an
image that was not built for your kind version.

```bash
kind create cluster --name demo \
  --image kindest/node:v1.37.0@sha256:a1ed56cfb0e7b93589bdf97c8cd566405a265939e3620fc4f5de89adff580ae5
kubectl --context kind-demo get nodes -o wide
```

## Several nodes

A config file describes the cluster. This one has one control plane and two workers:

```yaml
# kind-multinode.yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
  - role: worker
  - role: worker
```

```bash
kind create cluster --name multi --config kind-multinode.yaml
kubectl --context kind-multi get nodes
```

```text
NAME                  STATUS   ROLES           AGE   VERSION
multi-control-plane   Ready    control-plane   60s   v1.37.0
multi-worker          Ready    <none>          40s   v1.37.0
multi-worker2         Ready    <none>          40s   v1.37.0
```

Each node is a container with the same name:

```bash
docker ps --filter label=io.x-k8s.kind.cluster=multi --format '{{.Names}}'
```

## Look inside a node

A node is a container, so `docker exec` gives you a shell on it. This is how you reach
things that a managed cluster hides:

```bash
docker exec multi-control-plane ls /etc/kubernetes/manifests
docker exec multi-control-plane crictl ps --name kube-apiserver
docker exec multi-worker systemctl is-active kubelet containerd
```

The control plane runs as static pods, like on any kubeadm cluster (see
[[kubernetes/cluster-setup/staticpods]]). You can read or edit
`kube-apiserver.yaml` there; the kubelet restarts the API server when the file
changes.

To collect every log from every node, for a bug report or a failed CI job:

```bash
kind export logs ./kind-logs --name multi
ls ./kind-logs/multi-control-plane
```

## Use images you built locally

Pods pull images from a registry. A kind node cannot see the images in your local
Docker. `kind load` copies an image into every node:

```bash
docker build -t myapp:dev .
kind load docker-image myapp:dev --name demo
```

> [!warning] Do not use the `latest` tag for loaded images
> For an image tagged `latest` (or with no tag), Kubernetes sets
> `imagePullPolicy: Always`. The kubelet then tries to pull it from Docker Hub, and the
> pod fails with `ErrImagePull` even though the image is on the node. Use a real tag
> such as `:dev`, or set `imagePullPolicy: IfNotPresent`.

Check which images a node has:

```bash
docker exec demo-control-plane crictl images | grep myapp
```

## A local registry

`kind load` is slow for big images and must be repeated on each change. A registry
container is faster, and `docker push` works as usual. With kind v0.27 or later, the
node images already read registry settings from `/etc/containerd/certs.d`, so the setup
is:

```bash
# 1. The registry, reachable on the host as localhost:5001
docker run -d --restart=always -p 127.0.0.1:5001:5000 --name kind-registry registry:3

# 2. Tell containerd on each node that localhost:5001 means the registry container
for node in $(kind get nodes --name demo); do
  docker exec "$node" mkdir -p /etc/containerd/certs.d/localhost:5001
  echo '[host."http://kind-registry:5000"]' |
    docker exec -i "$node" cp /dev/stdin /etc/containerd/certs.d/localhost:5001/hosts.toml
done

# 3. Put the registry on the kind network, so the nodes can reach it by name
docker network connect kind kind-registry
```

Then:

```bash
docker tag myapp:dev localhost:5001/myapp:dev
docker push localhost:5001/myapp:dev
kubectl --context kind-demo create deployment myapp --image=localhost:5001/myapp:dev
```

`localhost` inside a node is the node itself, not your host. That is why step 2
redirects the name to the registry container.

## Reach your applications

A kind node has an IP address on the `kind` Docker network. You can reach it from the
Docker host, but not always from your laptop (for example with Docker Desktop, where
Docker runs in a VM). Three ways, from the simplest:

### `kubectl port-forward`

Works everywhere, for one service at a time:

```bash
kubectl create deployment web --image=nginx:1.29
kubectl expose deployment web --port=80
kubectl rollout status deployment/web
kubectl port-forward service/web 8080:80 &
sleep 2      # port-forward needs a moment before it accepts connections
curl -s localhost:8080 | grep -o '<title>.*</title>'
```

### Port mappings

`extraPortMappings` publishes a node port on the host, like `docker run -p`. It can
only be set when you create the cluster. Map a NodePort:

```yaml
# kind-ports.yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
    extraPortMappings:
      - containerPort: 30080
        hostPort: 8081
```

```bash
kind create cluster --name ports --config kind-ports.yaml
kubectl --context kind-ports create deployment web --image=nginx:1.29
kubectl --context kind-ports expose deployment web --type=NodePort --port=80 \
  --overrides='{"spec":{"ports":[{"port":80,"nodePort":30080}]}}'
kubectl --context kind-ports rollout status deployment/web
# kube-proxy may need a few seconds after the rollout to open the NodePort
curl -s --retry 10 --retry-all-errors localhost:8081 | grep -o '<title>.*</title>'
```

### LoadBalancer, Ingress and Gateway API with cloud-provider-kind

A kind cluster has no load balancer, so a `LoadBalancer` Service stays `<pending>`.
[cloud-provider-kind](https://github.com/kubernetes-sigs/cloud-provider-kind) fixes
that. It runs **on the host**, watches your kind clusters, and starts one small proxy
container per LoadBalancer Service. Since v0.9.0 it also implements Ingress and
Gateway API, so you do not need to install an ingress controller.

```bash
cloud-provider-kind &     # needs access to the Docker socket
kubectl expose deployment web --name web-lb --type=LoadBalancer --port=80
kubectl get service web-lb -w      # EXTERNAL-IP changes from <pending> to an IP
```

It also ships as an image. Run it on the `kind` Docker network: there it reaches each
cluster by its internal name (`<cluster>-control-plane:6443`) and the proxy containers
by their IP. Use this form when the binary cannot reach the containers directly, for
example when you run your tools in a container:

```bash
docker run -d --name cloud-provider-kind --network kind \
  -v /var/run/docker.sock:/var/run/docker.sock \
  registry.k8s.io/cloud-provider-kind/cloud-controller-manager:v0.11.1
```

```bash
LB_IP=$(kubectl get service web-lb -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
curl -s "http://$LB_IP" | grep -o '<title>.*</title>'
```

An Ingress with no class is served by cloud-provider-kind too:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: web
spec:
  rules:
    - http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: web
                port:
                  number: 80
```

```bash
INGRESS_IP=$(kubectl get ingress web -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
curl -s "http://$INGRESS_IP/" | grep -o '<title>.*</title>'
```

> [!note] Ingress NGINX
> The Kubernetes project retired the Ingress NGINX controller. Its repository was
> archived in March 2026, so it gets no more releases or security fixes. For new work,
> use Gateway API, or another controller such as Traefik. On kind, cloud-provider-kind
> covers both Ingress and Gateway API for tests.

## NetworkPolicy works out of the box

Since kind v0.24, the default CNI (kindnet) enforces NetworkPolicy. You can test
policies without installing Calico or Cilium:

```bash
kubectl create deployment web --image=nginx:1.29
kubectl expose deployment web --port=80
kubectl run client --image=busybox:1.37 --restart=Never -- sleep 3600
kubectl wait --for=condition=Ready pod/client
kubectl exec client -- wget -qO- -T 3 http://web | grep -c nginx     # works
```

```yaml
# deny-all-ingress.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: deny-all-ingress
spec:
  podSelector: {}
  policyTypes: [Ingress]
```

```bash
kubectl apply -f deny-all-ingress.yaml
kubectl exec client -- wget -qO- -T 3 http://web     # now times out
```

For Cilium features (L7 rules, Hubble), create the cluster without kindnet and install
Cilium yourself. See the next section and [[kubernetes/networking/cilium/install]].

## Networking options

```yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
networking:
  disableDefaultCNI: true    # no kindnet: nodes stay NotReady until you install a CNI
  kubeProxyMode: "none"      # no kube-proxy, for a CNI that replaces it (Cilium)
  podSubnet: "10.244.0.0/16"
  serviceSubnet: "10.96.0.0/12"
```

`kubeProxyMode` also accepts `iptables` (the default) and `nftables`.

## Change control plane flags: kubeadm patches

kind builds the kubeadm configuration for you. `kubeadmConfigPatches` merges your
changes into it. Use it for API server flags, admission plugins, or audit logs. With
current Kubernetes versions (kubeadm `v1beta4`), `extraArgs` is a list of `name` /
`value` pairs:

```yaml
# kind-patched.yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
featureGates:
  DRADeviceTaintRules: true   # beta and off by default in Kubernetes 1.37
nodes:
  - role: control-plane
    kubeadmConfigPatches:
      - |
        kind: ClusterConfiguration
        apiServer:
          extraArgs:
            - name: enable-admission-plugins
              value: NodeRestriction,AlwaysPullImages
```

kind passes `featureGates` to every component. Feature gates change with each
Kubernetes release: an unknown or removed gate stops the API server from starting, and
`kind create cluster` fails. Check the gate list for your version first.

Check that the flags reached the API server:

```bash
kind create cluster --name patched --config kind-patched.yaml
docker exec patched-control-plane grep -E 'enable-admission-plugins|feature-gates' \
  /etc/kubernetes/manifests/kube-apiserver.yaml
```

## Storage

kind installs a default StorageClass named `standard`. It uses the
[local-path provisioner](https://github.com/rancher/local-path-provisioner): each
volume is a directory on the node that runs the pod. The binding mode is
`WaitForFirstConsumer`, so a PVC stays `Pending` until a pod uses it. That is normal.

```bash
kubectl get storageclass
```

```text
NAME                 PROVISIONER             RECLAIMPOLICY   VOLUMEBINDINGMODE      ALLOWVOLUMEEXPANSION   AGE
standard (default)   rancher.io/local-path   Delete          WaitForFirstConsumer   false                  2m
```

## Use in CI

kind runs on GitHub Actions runners with no extra setup, because Docker is already
there. A minimal step:

```yaml
- name: Create a kind cluster
  run: |
    kind create cluster --name ci --image "$KIND_NODE_IMAGE" --wait 180s
    kubectl wait --for=create serviceaccount/default --timeout=60s
    kubectl get nodes
```

`--wait` blocks until the control plane node is `Ready`. It does not wait for
everything else. A controller creates the `default` ServiceAccount in each namespace a
few seconds later. If you create a pod before that, the API server refuses it:

```text
Error from server (Forbidden): pods "dev" is forbidden: error looking up service account default/default: serviceaccount "default" not found
```

`kubectl wait --for=create` (kubectl 1.31 and later) closes that gap. The same race
exists in any namespace you have just created.
Always pin the node image in CI, or a new kind default changes your Kubernetes version
under you. The tests of this site create their cluster the same way, in
`scripts/test-notes.sh`.

## kind or k3s?

Short version: kind for tests that must look like upstream kubeadm Kubernetes, k3s
when you want a small real cluster with batteries included. The full comparison is in
[[kubernetes/cluster-setup/k3s#kind or k3s?]].

<!-- uplink -->
Part of [[kubernetes/cluster-setup/index|Cluster setup]].
