---
title: "Creating better Helm charts"
description: "We are going to create a chart with the helper helm create"
tags: [kubernetes, helm]
type: lab
status: complete
source: https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/helm-create-better-chart.md
license: CC-BY-4.0
upstream_commit: 56563629
upstream_sync: manual
---

# Creating better Helm charts

- We are going to create a chart with the helper `helm create`

- This will give us a chart implementing lots of Helm best practices

  (labels, annotations, structure of the `values.yaml` file ...)

- We will use that chart as a generic Helm chart

- We will use it to deploy DockerCoins

- Each component of DockerCoins will have its own *release*

- In other words, we will "install" that Helm chart multiple times

  (one time per component of DockerCoins)

## Creating a generic chart

- Rather than starting from scratch, we will use `helm create`

- This will give us a basic chart that we will customize

> [!example] Hands-on
> - Create a basic chart:
>   ```bash
>   cd ~
>   helm create helmcoins
>   ```

This creates a basic chart in the directory `helmcoins`.

## What's in the basic chart?

- The basic chart will create a Deployment and a Service

- Optionally, it will also include an Ingress

- If we don't pass any values, it will deploy the `nginx` image

- We can override many things in that chart

- Let's try to deploy DockerCoins components with that chart!

## Writing `values.yaml` for our components

- We need to write one `values.yaml` file for each component

  (hasher, redis, rng, webui, worker)

- We will start with the `values.yaml` of the chart, and remove what we don't need

- We will create 5 files:

  hasher.yaml, redis.yaml, rng.yaml, webui.yaml, worker.yaml

- In each file, we want to have:
  ```yaml
  image:
    repository: IMAGE-REPOSITORY-NAME
    tag: IMAGE-TAG
  ```

## Getting started

- For component X, we want to use the image dockercoins/X:v0.1

  (for instance, for rng, we want to use the image dockercoins/rng:v0.1)

- Exception: for redis, we want to use the official image redis:latest

> [!example] Hands-on
> - Write YAML files for the 5 components, with the following model:
>   ```yaml
>   image:
>     repository: dockercoins/worker
>     tag: v0.1
>   ```
>   (this is `worker.yaml`; for redis, `repository: redis` and `tag: latest`)

## Deploying DockerCoins components

- For convenience, let's work in a separate namespace

> [!example] Hands-on
> - Create a new namespace (if it doesn't already exist):
>   ```bash
>   kubectl create namespace helmcoins
>   ```
>
> - Switch to that namespace:
>   ```bash
>   kns helmcoins
>   ```
>   (`kns` comes from [kubectx](https://github.com/ahmetb/kubectx); without it:
>   `kubectl config set-context --current --namespace helmcoins`)

## Deploying the chart

- To install a chart, we can use the following command:
  ```bash
  helm install COMPONENT-NAME CHART-DIRECTORY
  ```

- We can also use the following command, which is *idempotent*:
  ```bash
  helm upgrade COMPONENT-NAME CHART-DIRECTORY --install
  ```

> [!example] Hands-on
> - Install the 5 components of DockerCoins:
>   ```bash
>   for COMPONENT in hasher redis rng webui worker; do
>     helm upgrade $COMPONENT helmcoins --install --values=$COMPONENT.yaml
>   done
>   ```

> [!note]- Extra details
> ## "Idempotent"
>
> - Idempotent = that can be applied multiple times without changing the result
>
>   (the word is commonly used in maths and computer science)
>
> - In this context, this means:
>
>   - if the action (installing the chart) wasn't done, do it
>
>   - if the action was already done, don't do anything
>
> - Ideally, when such an action fails, it can be retried safely
>
>   (as opposed to, e.g., installing a new release each time we run it)
>
> - Other example: `kubectl apply -f some-file.yaml`

## Checking what we've done

- Let's see if DockerCoins is working!

> [!example] Hands-on
> - Check the logs of the worker:
>   ```bash
>   stern worker
>   ```
>   (without [stern](https://github.com/stern/stern): `kubectl logs deploy/worker-helmcoins`)
>
> - Look at the resources that were created:
>   ```bash
>   kubectl get all
>   ```

There are issues to fix!

## The image tag

- The images were pulled: each Deployment uses the image and tag of its values file

- Let's see how the chart does that

> [!example] Hands-on
> - Show the structure of the `helmcoins` chart that Helm generated:
>   ```bash
>   tree helmcoins
>   ```
>
> - Look for the `image:` parameter in the Deployment template:
>   ```bash
>   grep image: helmcoins/templates/deployment.yaml
>   ```

*The image tag is `{{ .Values.image.tag | default .Chart.AppVersion }}`. What is that `.Chart.AppVersion`?*

## The `.Chart` variable

- `.Chart` is a map corresponding to the values in `Chart.yaml`

- Let's look for `AppVersion` there!

> [!example] Hands-on
> - Look for the `appVersion:` parameter:
>   ```bash
>   grep appVersion: helmcoins/Chart.yaml
>   ```

(Yes, the case is different between the template and the Chart file.)

- `default` uses `appVersion` (`1.16.0`) only when `image.tag` is empty

- Our values files set `image.tag`, so the right tags are used

> [!warning] Correction
> The original lab expected the pods to fail to pull `rng:1.16.0`: its chart used
> `{{ .Chart.AppVersion }}` alone as the tag, and the next step changed the
> template to `{{ .Values.image.tag }}`. The chart that `helm create` generates
> today already has the `default` fallback, so there is nothing to fix here.

## Troubleshooting readiness

> [!example] Hands-on
> - Check how our pods are doing:
>   ```bash
>   kubectl get pods
>   ```

- All pods are "Running", but not all of them are READY

- `hasher` and `rng` should show up as `1/1 READY`

- `redis` and `worker` should show up as `0/1 READY`, and restart from time to time

- `webui` too, for now: it needs `redis`, and cannot reach it yet

- Why?

## Troubleshooting pods

- The easiest way to troubleshoot pods is to look at *events*

- We can look at all the events on the cluster (with `kubectl get events`)

- Or we can use `kubectl describe` on the objects that have problems

  (`kubectl describe` will retrieve the events related to the object)

> [!example] Hands-on
> - Check the events for the redis pods:
>   ```bash
>   kubectl describe pod -l app.kubernetes.io/instance=redis
>   ```

It's failing both its liveness and readiness probes!

> [!warning] Correction
> The original selected `app.kubernetes.io/name=redis`, which finds nothing: in
> this chart, `app.kubernetes.io/name` is the chart name (`helmcoins`) for every
> component. The release name is in `app.kubernetes.io/instance`.

## Healthchecks

- The default chart defines healthchecks doing HTTP requests on the `http` port

  (port 80, from `service.port`)

- That won't work for redis and worker

  (redis is not HTTP, and not on port 80; worker doesn't even listen)

- The probes are defined in the chart's `values.yaml`, under `livenessProbe` and
  `readinessProbe`

- The Deployment template only adds them if they are set:

  ```yaml
            {{- with .Values.livenessProbe }}
            livenessProbe:
              {{- toYaml . | nindent 12 }}
            {{- end }}
  ```

- `{{ with x }} ... {{ end }}` is a conditional: the block is only rendered if `x`
  is not empty (and inside it, `.` is `x`)

## Removing the healthchecks

- Setting a value to `null` removes the chart's default for that value

> [!example] Hands-on
> - Add this to `redis.yaml` and `worker.yaml`:
>   ```yaml
>   livenessProbe: null
>   readinessProbe: null
>   ```
>
> - Upgrade all components with their values files:
>   ```bash
>   for COMPONENT in hasher redis rng webui worker; do
>     helm upgrade $COMPONENT helmcoins --values=$COMPONENT.yaml
>   done
>   ```
>
> - Check how our pods are doing:
>   ```bash
>   kubectl get pods
>   ```

`redis` and `worker` should now be `1/1 READY`.

> [!warning] Correction
> The original lab edited the Deployment template and wrapped the probes in
> `{{ if false }} ... {{ end }}`. In today's generated chart, the probes are values,
> already wrapped in `{{- with }}`, so a `null` in the values file is enough.

## What's next?

- Is this working now?

> [!example] Hands-on
> - Let's check the logs of the worker:
>   ```bash
>   stern worker
>   ```

This error might look familiar ... The worker can't resolve `redis`.

Typically, that error means that the `redis` service doesn't exist.

## Checking services

- What about the services created by our chart?

> [!example] Hands-on
> - Check the list of services:
>   ```bash
>   kubectl get services
>   ```

They are named `COMPONENT-helmcoins` instead of just `COMPONENT`.

We need to change that!

## Where do the service names come from?

- Look at the YAML template used for the services

- It should be using `{{ include "helmcoins.fullname" . }}`

- `include` indicates a *template block* defined somewhere else

> [!example] Hands-on
> - Find where that `fullname` thing is defined:
>   ```bash
>   grep -r 'define.*fullname' helmcoins/templates
>   ```
>   (`-r`: the chart has a `templates/tests/` folder, which a plain
>   `grep ... templates/*` reports as an error)

It should be in `_helpers.tpl`.

We can look at the definition, but it's fairly complex ...

## Changing service names

- Instead of that `{{ include }}` tag, let's use the name of the release

- The name of the release is available as `{{ .Release.Name }}`

> [!example] Hands-on
> - Edit `helmcoins/templates/service.yaml`
>
> - Replace the service name with `{{ .Release.Name }}`
>
> - Upgrade all the releases to use the new chart
>
> - Confirm that the services now have the right names

## Is it working now?

- If we look at the worker logs, it appears that the worker is still stuck

- What could be happening?

- The redis service is not on port 80!

- Let's see how the port number is set

## Service template

- In the service template, we have the following section:
  ```yaml
    ports:
      - port: {{ .Values.service.port }}
        targetPort: http
        protocol: TCP
        name: http
  ```

- `port` is the port on which the service is "listening"

  (i.e. to which our code needs to connect)

- `targetPort` is the port on which the pods are listening

- The `name` is not important (it's OK if it's `http` even for non-HTTP traffic)

## Deployment template

- In the Deployment template, the container port uses the same value:
  ```yaml
            ports:
              - name: http
                containerPort: {{ .Values.service.port }}
                protocol: TCP
  ```

- So one value, `service.port`, sets both

> [!warning] Correction
> The original chart hard-coded `containerPort: 80`, and the lab changed it to
> `{{ .Values.service.port }}`. Today's generated chart already does that.

## Setting the redis port

- Let's add a `service.port` value to the redis release

> [!example] Hands-on
> - Edit `redis.yaml` to add:
>   ```yaml
>   service:
>     port: 6379
>   ```
>
> - Apply the new values file:
>   ```bash
>   helm upgrade redis helmcoins --values=redis.yaml
>   ```

## Apply changes

- Check the worker logs

- This time, it should be working!

## Extra steps

- We don't need to create a service for the worker

- We can put the whole service block in a conditional

  (this will require additional changes in other files referencing the service)

- We can set the webui to be a NodePort service

- We can change the number of workers with `replicaCount`

- And much more!

---

> [!info] Adapted from container.training
> This page is derived from [`slides/k8s/helm-create-better-chart.md`](https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/helm-create-better-chart.md)
> in **[container.training](https://github.com/jpetazzo/container.training)** by Jérôme Petazzoni and contributors,
> used under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).
> **Changes were made**: restructured from slides into a single page, remark
> markup converted to Obsidian callouts, referenced files inlined or linked,
> lab updated for the chart that `helm create` generates today (image tag,
> probes and container port need no template edit), tested with Helm 4.3.

<!-- uplink -->
Part of [[kubernetes/packaging/index|Packaging with Helm]].
