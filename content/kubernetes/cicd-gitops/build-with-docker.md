---
title: "Building images with the Docker Engine"
description: "Until now, we have built our images manually, directly on a node"
tags: [kubernetes, cicd, gitops]
type: lab
status: complete
source: https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/build-with-docker.md
license: CC-BY-4.0
upstream_commit: 56563629
upstream_sync: manual
---

# Building images with the Docker Engine

> [!important] These labs expect the upstream repository
> Commands below reference files by their path in a local clone. Get it with:
>
> ```bash
> git clone https://github.com/jpetazzo/container.training
> ```
>
> The manifests can also be browsed at the pinned commit
> [`56563629`](https://github.com/jpetazzo/container.training/tree/565636291ec03abf1f2ab8bf6b935478e00e69a2).

- Until now, we have built our images manually, directly on a node

- We are going to show how to build images from within the cluster

  (by executing code in a container controlled by Kubernetes)

- We are going to use the Docker Engine for that purpose

- To access the Docker Engine, we will mount the Docker socket in our container

- After building the image, we will push it to our self-hosted registry

## Resource specification for our builder pod

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: build-image
spec:
  restartPolicy: OnFailure
  containers:
  - name: docker-build
    image: docker
    env:
    - name: REGISTRY_PORT
      value: "3XXXX"     # the NodePort of the registry, e.g. "30000"
    command: ["sh", "-c"]
    args:
    - |
      apk add --no-cache git &&
      mkdir /workspace &&
      git clone https://github.com/jpetazzo/container.training /workspace &&
      docker build -t localhost:$REGISTRY_PORT/worker /workspace/dockercoins/worker &&
      docker push localhost:$REGISTRY_PORT/worker
    volumeMounts:
    - name: docker-socket
      mountPath: /var/run/docker.sock
  volumes:
  - name: docker-socket
    hostPath:
      path: /var/run/docker.sock
```

> [!warning] Correction: most nodes have no Docker Engine
> This pod needs a Docker Engine on the node. Since Kubernetes 1.24 removed dockershim,
> most clusters run containerd or CRI-O, and `/var/run/docker.sock` does not exist on
> the nodes. On such a node (kind, for example) the build fails with
> `Cannot connect to the Docker daemon`. The variant below runs its own Docker Engine
> in a sidecar ("Docker-in-Docker"); [[kubernetes/cicd-gitops/build-with-kaniko]]
> builds without any Docker Engine.

> [!example]- Variant: Docker-in-Docker sidecar
> The engine runs in a privileged sidecar and listens on `localhost:2375` (no TLS,
> only inside the pod). It pushes to the registry Service by its name, so it needs
> `--insecure-registry` for that plain-HTTP registry.
>
> ```yaml
> apiVersion: v1
> kind: Pod
> metadata:
>   name: build-image-dind
> spec:
>   restartPolicy: OnFailure
>   containers:
>   - name: docker-build
>     image: docker:29.9.3-cli
>     env:
>     - name: DOCKER_HOST
>       value: tcp://localhost:2375
>     command: ["sh", "-c"]
>     args:
>     - |
>       apk add --no-cache git &&
>       git clone https://github.com/jpetazzo/container.training /workspace &&
>       until docker info >/dev/null 2>&1; do sleep 1; done &&
>       docker build -t registry:5000/worker /workspace/dockercoins/worker &&
>       docker push registry:5000/worker
>   initContainers:
>   - name: dind
>     image: docker:29.9.3-dind
>     restartPolicy: Always    # a native sidecar: stopped when the build ends
>     args: ["--insecure-registry=registry:5000"]
>     env:
>     - name: DOCKER_TLS_CERTDIR
>       value: ""
>     securityContext:
>       privileged: true
> ```
>
> The engine is a *native sidecar* (an init container with `restartPolicy: Always`,
> stable since Kubernetes 1.33): it starts first, and the Pod completes when the
> build container exits.
>
> A privileged container can take over its node: keep such builders on dedicated
> nodes, or use a daemonless builder.

## Breaking down the pod specification (1/2)

- `restartPolicy: OnFailure` prevents the build from running in an infinite loop

- We use the `docker` image (so that the `docker` CLI is available)

- We rely on the fact that the `docker` image is based on `alpine`

  (which is why we use `apk` to install `git`)

- The port for the registry is passed through an environment variable

  (this avoids repeating it in the specification, which would be error-prone)

> [!warning]
> The environment variable has to be a string, so the `"`s are mandatory!

## Breaking down the pod specification (2/2)

- The volume `docker-socket` is declared with a `hostPath`, indicating a bind-mount

- It is then mounted in the container onto the default Docker socket path

- We show an interesting way to specify the commands to run in the container:

  - the command executed will be `sh -c <args>`

  - `args` is a list of strings

  - `|` is used to pass a multi-line string in the YAML file

## Running our pod

- Let's try this out!

> [!example] Hands-on
> - Check the port used by our self-hosted registry:
>   ```bash
>   kubectl get svc registry
>   ```
>
> - Edit [`~/container.training/k8s/docker-build.yaml`](https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/k8s/docker-build.yaml) to put the port number
>
> - Schedule the pod by applying the resource file:
>   ```bash
>   kubectl apply -f ~/container.training/k8s/docker-build.yaml
>   ```
>
> - Watch the logs:
>   ```bash
>   stern build-image
>   ```

## What's missing?

What do we need to change to make this production-ready?

- Build from a long-running container (e.g. a `Deployment`) triggered by web hooks

  (the payload of the web hook could indicate the repository to build)

- Build a specific branch or tag; tag image accordingly

- Handle repositories where the Dockerfile is not at the root

  (or containing multiple Dockerfiles)

- Expose build logs so that troubleshooting is straightforward

🤔 That seems like a lot of work!

That's why services like Docker Hub (with [automated builds](https://docs.docker.com/docker-hub/builds/)) are helpful.
They handle the whole "code repository → Docker image" workflow.

## Things to be aware of

- This is talking directly to a node's Docker Engine to build images

- It bypasses resource allocation mechanisms used by Kubernetes

  (but you can use *taints* and *tolerations* to dedicate builder nodes)

- Be careful not to introduce conflicts when naming images

  (e.g. do not allow the user to specify the image names!)

- Your builds are going to be *fast*

  (because they will leverage Docker's caching system)

---

> [!info] Adapted from container.training
> This page is derived from [`slides/k8s/build-with-docker.md`](https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/build-with-docker.md)
> in **[container.training](https://github.com/jpetazzo/container.training)** by Jérôme Petazzoni and contributors,
> used under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).
> **Changes were made**: restructured from slides into a single page, remark
> markup converted to Obsidian callouts, referenced files inlined or linked,
> the missing node Docker Engine noted, a Docker-in-Docker variant added and tested
> on kind, typos fixed.

<!-- uplink -->
Part of [[kubernetes/cicd-gitops/index|CI/CD and GitOps]].
