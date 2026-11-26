---
title: "Deploying a sample application"
description: "Deploying DockerCoins, a demo app with five microservices, and looking at its logs and web UI"
tags: [kubernetes, kubectl]
type: lab
status: complete
source: https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/kubercoins.md
license: CC-BY-4.0
upstream_commit: 56563629
upstream_sync: manual
---

# Deploying a sample application

> [!important] These labs expect the upstream repository
> Commands below reference files by their path in a local clone. Get it with:
>
> ```bash
> git clone https://github.com/jpetazzo/container.training
> ```
>
> The manifests can also be browsed at the pinned commit
> [`56563629`](https://github.com/jpetazzo/container.training/tree/565636291ec03abf1f2ab8bf6b935478e00e69a2).

We connect to a Kubernetes cluster and deploy a sample application, DockerCoins.
DockerCoins has several microservices and a web UI.

## Connecting to our Kubernetes cluster

In the course environment, the cluster has several nodes named `node1`, `node2`, and
so on. We do everything from `node1`. We have SSH access to the other nodes. We do not
need it, but it helps for debugging and troubleshooting.

On another cluster (kind, for example), the node names are different. Any machine
with a working `kubectl` will do.

> [!example] Hands-on
> - Log into `node1`
>
> - Check that all nodes are `Ready`:
>   ```bash
>   kubectl get nodes
>   ```

## Cloning the repository

We need a clone of the training repository. It has the DockerCoins demo app, the
slides, some scripts and more manifests.

> [!example] Hands-on
> - Clone the repository on `node1`:
>   ```bash
>   git clone https://github.com/jpetazzo/container.training
>   ```

## Running the application

Let's start the application.

> [!example] Hands-on
> - Apply the manifest for DockerCoins:
>   ```bash
>   kubectl apply -f ~/container.training/k8s/dockercoins.yaml
>   ```

The manifest creates one Deployment per component, and a Service for each component
except `worker`. The images are `dockercoins/<component>:v0.1` and `redis`.

## What's this application?

It is a DockerCoin miner. No, you cannot buy coffee with DockerCoins.

How DockerCoins works:

1. generate a few random bytes;
2. hash these bytes;
3. increment a counter (to keep track of speed);
4. repeat forever.

DockerCoins is *not* a cryptocurrency. The only things in common are randomness,
hashing, and "coins" in the name.

## DockerCoins in the microservices era

DockerCoins is made of 5 services:

| Service | Role |
| --- | --- |
| `rng` | web service that generates random bytes |
| `hasher` | web service that computes a hash of the data POSTed to it |
| `worker` | background process that calls `rng` and `hasher` |
| `webui` | web interface to watch progress |
| `redis` | data store; holds a counter updated by `worker` |

These 5 services are visible in the application's Compose file,
[compose.yml](https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/dockercoins/compose.yml).

## How DockerCoins works

- `worker` calls the web service `rng` to generate random bytes.
- `worker` calls the web service `hasher` to hash these bytes.
- `worker` does this in an infinite loop.
- Every second, `worker` updates `redis` with the number of loops done.
- `webui` queries `redis`, computes the "hashing speed", and shows it in the browser.

![Diagram showing the 5 containers of the applications](kubernetes/_attachments/dockercoins-diagram.png)

## Service discovery in container-land

How does each service find the address of the other ones?

We do not hard-code IP addresses or FQDNs (fully qualified domain names) in the code.
We connect to a service name, and DNS does the rest. In Kubernetes, the cluster DNS
resolves the name of a Service in the same namespace to that Service's ClusterIP.

## Example in `worker/worker.py`

```python
redis = Redis("redis")

def get_random_bytes():
    r = requests.get("http://rng/32")
    return r.content

def hash_bytes(data):
    r = requests.post("http://hasher/",
                      data=data,
                      headers={"Content-Type": "application/octet-stream"})
```

See the [full source code][dockercoins-worker-code] of the worker.

[dockercoins-worker-code]: https://github.com/jpetazzo/container.training/blob/8279a3bce9398f7c1a53bdd95187c53eda4e6435/dockercoins/worker/worker.py#L17

## Show me the code!

- The GitHub repository has all the materials of the workshop:
  https://github.com/jpetazzo/container.training
- The application is in the [dockercoins](https://github.com/jpetazzo/container.training/tree/565636291ec03abf1f2ab8bf6b935478e00e69a2/dockercoins)
  subdirectory.
- The Compose file ([compose.yml](https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/dockercoins/compose.yml))
  lists all 5 services.
- `redis` uses an official image from the Docker Hub.
- `hasher`, `rng`, `worker` and `webui` are each built from a Dockerfile.
- Each service's Dockerfile and source code is in its own directory: `hasher` is in
  the [hasher](https://github.com/jpetazzo/container.training/tree/565636291ec03abf1f2ab8bf6b935478e00e69a2/dockercoins/hasher)
  directory, `rng` in the [rng](https://github.com/jpetazzo/container.training/tree/565636291ec03abf1f2ab8bf6b935478e00e69a2/dockercoins/rng)
  directory, and so on.

> [!note] The Compose file was renamed
> Upstream renamed `docker-compose.yml` to `compose.yml`. The old links to
> `blob/master/dockercoins/docker-compose.yml` no longer work. The links above point
> to the pinned commit.

## Our application at work

We can check the logs of the application's Pods.

> [!example] Hands-on
> - Check the logs of the various components:
>   ```bash
>   kubectl logs deploy/worker
>   kubectl logs deploy/hasher
>   ```

The worker prints a line such as `10 units of work done, updating hash counter`
about every second. The hasher prints one line per HTTP request.

## Connecting to the web UI

Logs are not much fun to watch. The `webui` container exposes a web dashboard; let's
view it.

> [!example] Hands-on
> - Check the NodePort allocated to the web UI:
>   ```bash
>   kubectl get svc webui
>   ```
>
> - Open `http://<node-address>:<node-port>/` in a web browser

A drawing area shows up, and after a few seconds, a blue graph appears. The page
reads its data from `/json`, which returns the counter from `redis`.

If you cannot reach the nodes directly, use
`kubectl port-forward svc/webui 8080:80` and open `http://localhost:8080/`.

---

> [!info] Adapted from container.training
> This page is derived from [`slides/k8s/kubercoins.md`](https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/kubercoins.md)
> in **[container.training](https://github.com/jpetazzo/container.training)** by Jérôme Petazzoni and contributors,
> used under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).
> **Changes were made**: restructured from slides into a single page, remark
> markup converted to Obsidian callouts, referenced files inlined or linked.
> Rewritten as prose, links pinned to the upstream commit, port-forward added.

<!-- uplink -->
Part of [[kubernetes/workloads/index|Workloads]].
