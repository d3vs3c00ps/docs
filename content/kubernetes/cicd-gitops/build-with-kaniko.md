---
title: "Building images with Kaniko"
description: "Kaniko is an open source tool to build container images within Kubernetes"
tags: [kubernetes, cicd, gitops]
type: lab
status: complete
source: https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/build-with-kaniko.md
license: CC-BY-4.0
upstream_commit: 56563629
upstream_sync: manual
---

# Building images with Kaniko

> [!important] These labs expect the upstream repository
> Commands below reference files by their path in a local clone. Get it with:
>
> ```bash
> git clone https://github.com/jpetazzo/container.training
> ```
>
> The manifests can also be browsed at the pinned commit
> [`56563629`](https://github.com/jpetazzo/container.training/tree/565636291ec03abf1f2ab8bf6b935478e00e69a2).

- [Kaniko](https://github.com/GoogleContainerTools/kaniko) is an open source tool to build container images within Kubernetes

- It can build an image using any standard Dockerfile

- The resulting image can be pushed to a registry or exported as a tarball

- It doesn't require any particular privilege

  (and can therefore run in a regular container in a regular pod)

- This combination of features is pretty unique

  (most other tools use different formats, or require elevated privileges)

> [!warning] Kaniko is archived
> Google archived the Kaniko repository in June 2025; v1.23.2 is the last upstream
> release, and its images on `gcr.io/kaniko-project` still work (tested). Chainguard
> maintains a fork. For new setups, also consider BuildKit (`buildkitd` can run
> rootless) or Buildah.

## Kaniko in practice

- Kaniko provides an "executor image", `gcr.io/kaniko-project/executor`

- When running that image, we need to specify at least:

  - the path to the build context (=the directory with our Dockerfile)

  - the target image name (including the registry address)

- Simplified example:
  ```
  docker run \
      -v ...:/workspace gcr.io/kaniko-project/executor \
      --context=/workspace \
      --destination=registry:5000/image_name:image_tag
  ```

## Running Kaniko in a Docker container

- Let's build the image for the DockerCoins `worker` service with Kaniko

> [!example] Hands-on
> - Find the port number for our self-hosted registry:
>   ```bash
>   kubectl get svc registry
>   PORT=$(kubectl get svc registry -o json | jq .spec.ports[0].nodePort)
>   ```
>
> - Run Kaniko:
>   ```bash
>   docker run --net host \
>       -v ~/container.training/dockercoins/worker:/workspace \
>       gcr.io/kaniko-project/executor:v1.23.2 \
>       --context=/workspace \
>       --destination=127.0.0.1:$PORT/worker-kaniko:latest
>   ```

We use `--net host` so that we can connect to the registry over `127.0.0.1`.

## Running Kaniko in a Kubernetes pod

- We need to mount or copy the build context to the pod

- We are going to build straight from the git repository

  (to avoid depending on files sitting on a node, outside of containers)

- We need to `git clone` the repository before running Kaniko

- We are going to use two containers sharing a volume:

  - a first container to `git clone` the repository to the volume

  - a second container to run Kaniko, using the content of the volume

- However, we need the first container to be done before running the second one

🤔 How could we do that?

## [Init Containers](https://kubernetes.io/docs/concepts/workloads/pods/init-containers/) to the rescue

- A pod can have a list of `initContainers`

- `initContainers` are executed in the specified order

- Each Init Container needs to complete (exit) successfully

- If any Init Container fails (non-zero exit status) the pod fails

  (what happens next depends on the pod's `restartPolicy`)

- After all Init Containers have run successfully, normal `containers` are started

- We are going to execute the `git clone` operation in an Init Container

## Our Kaniko builder pod

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: kaniko-build
spec:
  restartPolicy: OnFailure
  initContainers:
  - name: git-clone
    image: alpine
    command: ["sh", "-c"]
    args:
    - |
      apk add --no-cache git &&
      git clone https://github.com/jpetazzo/container.training /workspace
    volumeMounts:
    - name: workspace
      mountPath: /workspace
  containers:
  - name: build-image
    image: gcr.io/kaniko-project/executor:v1.23.2
    args:
      - "--context=/workspace/dockercoins/rng"
      - "--insecure"
      - "--destination=registry:5000/rng-kaniko:latest"
    volumeMounts:
    - name: workspace
      mountPath: /workspace
  volumes:
  - name: workspace
```

> [!note] `https://` and `restartPolicy`
> GitHub turned off the unencrypted `git://` protocol in 2022: clone with `https://`.
> The upstream `k8s/kaniko-build.yaml` still has `git://`. Without a `restartPolicy`
> the pod gets `Always`: when Kaniko exits after the push, the kubelet starts it
> again, and it builds and pushes in a loop. `restartPolicy: OnFailure` lets the pod
> end as `Completed`.

## Explanations

- We define a volume named `workspace` (using the default `emptyDir` provider)

- That volume is mounted to `/workspace` in both our containers

- The `git-clone` Init Container installs `git` and runs `git clone`

- The `build-image` container executes Kaniko

- We use our self-hosted registry DNS name (`registry`)

- We add `--insecure` to use plain HTTP to talk to the registry

## Running our Kaniko builder pod

- The YAML for the pod is in `k8s/kaniko-build.yaml`

> [!example] Hands-on
> - Create the pod:
>   ```bash
>   kubectl apply -f ~/container.training/k8s/kaniko-build.yaml
>   ```
>
> - Watch the logs:
>   ```bash
>   stern kaniko
>   ```

## Discussion

*What should we use? The Docker build technique shown earlier? Kaniko? Something else?*

- The Docker build technique is simple, and has the potential to be very fast

- However, it doesn't play nice with Kubernetes resource limits

- Kaniko plays nice with resource limits

- However, it's slower (there is no caching at all)

- [Jessica Frazelle](https://twitter.com/jessfraz)'s [img](https://github.com/genuinetools/img)
  builder is no longer maintained. Its ideas live on in BuildKit,
  which can run rootless in a pod

But ... is it all about [speed](https://github.com/AkihiroSuda/buildbench/issues/1)? (No!)

## The big picture

- For starters: the [Docker Hub automated builds](https://docs.docker.com/docker-hub/builds/) are very easy to set up

  - link a GitHub repository with the Docker Hub

  - each time you push to GitHub, an image gets built on the Docker Hub

- If this doesn't work for you: why?

  - too slow (I'm far from `us-east-1`!) → consider using your cloud provider's registry

  - I'm not using a cloud provider → ok, perhaps you need to self-host then

  - I need fancy features (e.g. CI) → consider something like GitLab

---

> [!info] Adapted from container.training
> This page is derived from [`slides/k8s/build-with-kaniko.md`](https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/build-with-kaniko.md)
> in **[container.training](https://github.com/jpetazzo/container.training)** by Jérôme Petazzoni and contributors,
> used under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).
> **Changes were made**: restructured from slides into a single page, remark
> markup converted to Obsidian callouts, referenced files inlined or linked,
> `git://` clone and missing `restartPolicy` fixed, Kaniko pinned and its archived status noted, img replaced by
> BuildKit, tested on kind and Docker.

<!-- uplink -->
Part of [[kubernetes/cicd-gitops/index|CI/CD and GitOps]].
