---
title: "The Horizontal Pod Autoscaler"
description: "What is the Horizontal Pod Autoscaler, or HPA?"
tags: [kubernetes, observability, monitoring]
type: lab
status: complete
source: https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/horizontal-pod-autoscaler.md
license: CC-BY-4.0
upstream_commit: 56563629
upstream_sync: manual
---

# The Horizontal Pod Autoscaler

- What is the Horizontal Pod Autoscaler, or HPA?

- It is a controller that can perform *horizontal* scaling automatically

- Horizontal scaling = changing the number of replicas

  (adding/removing pods)

- Vertical scaling = changing the size of individual replicas

  (increasing/reducing CPU and RAM per pod)

- Cluster scaling = changing the size of the cluster

  (adding/removing nodes)

## Principle of operation

- Each HPA resource (or "policy") specifies:

  - which object to monitor and scale (e.g. a Deployment, ReplicaSet...)

  - min/max scaling ranges (the max is a safety limit!)

  - a target resource usage (e.g. the default is CPU=80%)

- The HPA continuously monitors the CPU usage for the related object

- It computes how many pods should be running:

  `TargetNumOfPods = ceil(sum(CurrentPodsCPUUtilization) / Target)`

- It scales the related object up/down to this target number of pods

## Pre-requirements

- The metrics server needs to be running

  (i.e. we need to be able to see pod metrics with `kubectl top pods`)

- The pods that we want to autoscale need to have resource requests

  (because the target CPU% is not absolute, but relative to the request)

- The latter actually makes a lot of sense:

  - if a Pod doesn't have a CPU request, it might be using 10% of CPU...

  - ...but only because there is no CPU time available!

  - this makes sure that we won't add pods to nodes that are already resource-starved

## Testing the HPA

- We will start a CPU-intensive web service

- We will send some traffic to that service

- We will create an HPA policy

- The HPA will automatically scale up the service for us

## A CPU-intensive web service

- Let's use `jpetazzo/busyhttp`

  (it is a web server that will use 1s of CPU for each HTTP request)

> [!example] Hands-on
> - Deploy the web server:
>   ```bash
>   kubectl create deployment busyhttp --image=jpetazzo/busyhttp
>   ```
>
> - Expose it with a ClusterIP service:
>   ```bash
>   kubectl expose deployment busyhttp --port=80
>   ```
>
> - Get the ClusterIP allocated to the service:
>   ```bash
>   kubectl get svc busyhttp
>   ```
>
> - Keep it in a variable:
>   ```bash
>   CLUSTERIP=$(kubectl get svc busyhttp -o jsonpath={.spec.clusterIP})
>   ```

## Monitor what's going on

- Let's start a bunch of commands to watch what is happening

> [!example] Hands-on
> - Monitor pod CPU usage:
>   ```bash
>   watch kubectl top pods -l app=busyhttp
>   ```
>
> - Monitor service latency:
>   ```bash
>   httping http://$CLUSTERIP/
>   ```
>
> - Monitor cluster events:
>   ```bash
>   kubectl get events -w
>   ```

## Send traffic to the service

- We will use `ab` (Apache Bench) to send traffic

> [!example] Hands-on
> - Send a lot of requests to the service, with a concurrency level of 3:
>   ```bash
>   ab -c 3 -n 100000 http://$CLUSTERIP/
>   ```

The latency (reported by `httping`) should increase above 3s.

The CPU utilization should increase to 100%.

(The server is single-threaded and won't go above 100%.)

## Create an HPA policy

- There is a helper command to do that for us: `kubectl autoscale`

> [!example] Hands-on
> - Create the HPA policy for the `busyhttp` deployment:
>   ```bash
>   kubectl autoscale deployment busyhttp --max=10
>   ```

By default, it will assume a target of 80% CPU usage.

This can also be set with `--cpu-percent=`.

*The autoscaler doesn't seem to work. Why?*

## What did we miss?

- The events stream gives us a hint, but to be honest, it's not very clear:

  `missing request for cpu`

- We forgot to specify a resource request for our Deployment!

- The HPA target is not an absolute CPU%

- It is relative to the CPU requested by the pod

## Adding a CPU request

- Let's edit the deployment and add a CPU request

- Since our server can use up to 1 core, let's request 1 core

> [!example] Hands-on
> - Edit the Deployment definition:
>   ```bash
>   kubectl edit deployment busyhttp
>   ```
>
> - In the `containers` list, add the following block:
>   ```yaml
>     resources:
>       requests:
>         cpu: "1"
>   ```

## Results

- After saving and quitting, a rolling update happens

  (if `ab` or `httping` exits, make sure to restart it)

- It will take a minute or two for the HPA to kick in:

  - the HPA runs every 15 seconds by default

  - it needs to gather metrics from the metrics server first

- Scaling up happens as soon as the metrics ask for it

- Scaling down waits: the HPA uses the highest recommendation of the last 5 minutes
  (the *stabilization window*), so short dips do not remove pods

> [!note] Timings
> The sync period is 15 seconds, scale up has no delay by default, and scale down uses
> a 300-second stabilization window. Both can be tuned per HPA in `spec.behavior` (see
> [[kubernetes/observability/hpa-v2]]). The 30-second period and the 3- and 5-minute
> waits found in older guides are the rules from before Kubernetes 1.18.

## What about other metrics?

- The HPA in API group `autoscaling/v1` only supports CPU scaling

- The HPA in API group `autoscaling/v2` supports metrics from various API groups

  (`autoscaling/v2beta2` was removed in Kubernetes 1.26):

  - metrics.k8s.io, aka metrics server (per-Pod CPU and RAM)

  - custom.metrics.k8s.io, custom metrics per Pod

  - external.metrics.k8s.io, external metrics (not associated to Pods)

- Kubernetes doesn't implement any of these API groups

- Using these metrics requires [registering additional APIs](https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale/#support-for-metrics-apis)

- The metrics provided by metrics server are standard; everything else is custom

- For more details, see [this great blog post](https://medium.com/uptime-99/kubernetes-hpa-autoscaling-with-custom-and-external-metrics-da7f41ff7846) or [this talk](https://www.youtube.com/watch?v=gSiGFH4ZnS8)

## Cleanup

- Since `busyhttp` uses CPU cycles, let's stop it before moving on

> [!example] Hands-on
> - Delete the `busyhttp` Deployment, its Service and its HPA:
>   ```bash
>   kubectl delete deployment,service,hpa busyhttp
>   ```

---

> [!info] Adapted from container.training
> This page is derived from [`slides/k8s/horizontal-pod-autoscaler.md`](https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/horizontal-pod-autoscaler.md)
> in **[container.training](https://github.com/jpetazzo/container.training)** by Jérôme Petazzoni and contributors,
> used under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).
> **Changes were made**: restructured from slides into a single page, remark
> markup converted to Obsidian callouts, referenced files inlined or linked,
> `$CLUSTERIP` variable added, HPA timing and API version updated, cleanup
> completed, tested on kind.

<!-- uplink -->
Part of [[kubernetes/observability/index|Observability and scaling]].
