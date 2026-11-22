---
title: "Kubernetes metrology"
description: "Measuring a cluster: metrics-server, kube-state-metrics and kube-prometheus-stack, the PromQL that matters, alerts, backups and troubleshooting."
tags: [metrology]
type: moc
status: complete
---

<!-- generated-moc -->

# Kubernetes metrology

Measuring a cluster: metrics-server, kube-state-metrics and kube-prometheus-stack, the PromQL that matters, alerts, backups and troubleshooting.


| Note | | What it covers |
| --- | --- | --- |
| [[kubernetes/observability/metrology/advanced\|Kubernetes metrology in depth]] | reference | ServiceMonitor, PodMonitor and PrometheusRule for your own app, the key container, API server and etcd metrics, chart values for retention and storage, and scraping the control plane on kind and kubeadm |
| [[kubernetes/observability/metrology/backup\|Back up a Kubernetes monitoring stack]] | how-to | What to back up in kube-prometheus-stack — rules and dashboards as code, Helm values, a Prometheus TSDB snapshot copied out of a distroless pod and restored into a fresh Prometheus, Grafana state |
| [[kubernetes/observability/metrology/quickstart\|Kubernetes metrology quickstart]] | how-to | Measure a Kubernetes cluster in minutes — metrics-server and kubectl top, then kube-prometheus-stack with Prometheus, Grafana and the first PromQL queries |
| [[kubernetes/observability/metrology/troubleshooting\|Troubleshooting Kubernetes metrology]] | reference | Fixes for kubectl top errors, control-plane targets down on kubeadm and kind, ServiceMonitors that are ignored, CRDs too big for kubectl apply, Prometheus OOM and cardinality, full volumes, Grafana "No data" and alerts that never fire |

Part of [[kubernetes/observability/index|Observability and scaling]].
