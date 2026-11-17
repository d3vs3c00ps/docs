---
title: "Observability and scaling"
description: "Logs, metrics, resource limits and the autoscalers that act on them."
tags: [observability]
type: moc
status: complete
---

<!-- generated-moc -->

# Observability and scaling

Logs, metrics, resource limits and the autoscalers that act on them.

## Sections

- [[kubernetes/observability/metrology/index|Kubernetes metrology]]

## Notes in this section

| Note | | What it covers |
| --- | --- | --- |
| [[kubernetes/observability/cluster-autoscaler\|Cluster autoscaler]] | lab | When the cluster is full, we need to add more nodes |
| [[kubernetes/observability/cluster-sizing\|Cluster sizing]] | concept | What happens when the cluster gets full? |
| [[kubernetes/observability/goldpinger\|goldpinger]] | how-to | Continuous pod-to-pod connectivity checking — a DaemonSet that pings every peer and draws the result, for finding partial network failures |
| [[kubernetes/observability/healthchecks-more\|Adding healthchecks to an app]] | lab | Let's add healthchecks to DockerCoins! |
| [[kubernetes/observability/healthchecks\|Healthchecks]] | concept | detect when a container has crashed, and restart it automatically |
| [[kubernetes/observability/horizontal-pod-autoscaler\|The Horizontal Pod Autoscaler]] | lab | What is the Horizontal Pod Autoscaler, or HPA? |
| [[kubernetes/observability/hpa-v2\|Scaling with custom metrics]] | lab | The HorizontalPodAutoscaler v1 can only scale on Pod CPU usage |
| [[kubernetes/observability/logs-centralized\|Centralized logging]] | lab | when a node goes down, its logs are not available anymore |
| [[kubernetes/observability/logs-cli\|Accessing logs from the CLI]] | lab | it cannot stream logs from multiple pods at a time |
| [[kubernetes/observability/metrics-server\|Checking Node and Pod resource usage]] | lab | We've installed a few things on our cluster so far |
| [[kubernetes/observability/prometheus-stack\|Prometheus and Grafana]] | concept | What if we want metrics retention, view graphs, trends? |
| [[kubernetes/observability/prometheus\|Collecting metrics with Prometheus]] | lab | multiple service discovery backends to figure out which metrics to collect |
| [[kubernetes/observability/resource-limits\|Resource Limits]] | lab | We can attach resource indications to our pods |

> [!info] Derived from container.training
> Pages in this section marked with a `source` in their frontmatter are
> derived from [container.training](https://github.com/jpetazzo/container.training)
> under CC BY 4.0, with changes. See [[attribution]].

Part of [[kubernetes/index|Kubernetes]].
