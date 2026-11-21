---
title: "Shipping images with a registry"
description: "Initially, our app was running on a single node"
tags: [kubernetes, cicd, gitops]
type: concept
status: complete
source: https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/shippingimages.md
license: CC-BY-4.0
upstream_commit: 56563629
upstream_sync: manual
---

# Shipping images with a registry

- Initially, our app was running on a single node

- We could *build* and *run* in the same place

- Therefore, we did not need to *ship* anything

- Now that we want to run on a cluster, things are different

- The easiest way to ship container images is to use a registry

## How Docker registries work (a reminder)

- What happens when we execute `docker run alpine` ?

- If the Engine needs to pull the `alpine` image, it expands it into `library/alpine`

- `library/alpine` is expanded into `docker.io/library/alpine`

  (`index.docker.io` in older documentation; the registry API itself answers on
  `registry-1.docker.io`)

- The Engine communicates with Docker Hub to retrieve `library/alpine:latest`

- To use something else than Docker Hub, we specify it in the image name

  (a first component with a `.` or a `:`, or `localhost`, is a registry host)

- Examples:
  ```bash
  docker pull gcr.io/google-containers/alpine-with-bash:1.0

  docker build -t registry.mycompany.io:5000/myimage:awesome .
  docker push registry.mycompany.io:5000/myimage:awesome
  ```

## Running DockerCoins on Kubernetes

- Create one deployment for each component

  (hasher, redis, rng, webui, worker)

- Expose deployments that need to accept connections

  (hasher, redis, rng, webui)

- For redis, we can use the official redis image

- For the 4 others, we need to build images and push them to some registry

## Building and shipping images

- There are *many* options!

- Manually:

  - build locally (with `docker build` or otherwise)

  - push to the registry

- Automatically:

  - build and test locally

  - when ready, commit and push a code repository

  - the code repository notifies an automated build system

  - that system gets the code, builds it, pushes the image to the registry

## Which registry do we want to use?

- There are SAAS products like Docker Hub, Quay ...

- Each major cloud provider has an option as well

  (ACR on Azure, ECR on AWS, Artifact Registry on Google Cloud...)

  (Google Container Registry, GCR, was shut down in 2025; `gcr.io` names are now
  served by Artifact Registry)

- There are also commercial products to run our own registry

  (Docker EE, Quay...)

- And open source options, too!

- When picking a registry, pay attention to its build system

  (when it has one)

## Building on the fly

- Conceptually, it is possible to build images on the fly from a repository

- Example: [ctr.run](https://ctr.run/)

  (shut down in August 2020, after being acquired by Datadog)

- It did allow something like this:
  ```bash
  docker run ctr.run/github.com/jpetazzo/container.training/dockercoins/hasher
  ```

- No alternative yet

  (free startup idea, anyone?)

---

> [!info] Adapted from container.training
> This page is derived from [`slides/k8s/shippingimages.md`](https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/shippingimages.md)
> in **[container.training](https://github.com/jpetazzo/container.training)** by Jérôme Petazzoni and contributors,
> used under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).
> **Changes were made**: restructured from slides into a single page, remark
> markup converted to Obsidian callouts, referenced files inlined or linked,
> image name expansion and GCR status updated, tested with Docker and a local registry.

<!-- uplink -->
Part of [[kubernetes/cicd-gitops/index|CI/CD and GitOps]].
