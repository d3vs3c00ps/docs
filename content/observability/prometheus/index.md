---
title: "Prometheus"
description: "Install, configure, query, alert, back up and debug a standalone Prometheus."
tags: [prometheus]
type: moc
status: complete
---

<!-- generated-moc -->

# Prometheus

Install, configure, query, alert, back up and debug a standalone Prometheus.


| Note | | What it covers |
| --- | --- | --- |
| [[observability/prometheus/advanced\|Prometheus advanced configuration]] | reference | Relabelling, file and HTTP service discovery, recording and alerting rules with unit tests, Alertmanager routing, retention, reload, remote write, TLS and basic auth, native histograms and useful PromQL |
| [[observability/prometheus/backup\|Prometheus backup and restore]] | how-to | Back up the Prometheus TSDB with a snapshot from the admin API, restore it, keep the configuration in git, and backfill old data with promtool |
| [[observability/prometheus/quickstart\|Prometheus quickstart]] | how-to | Run Prometheus and node_exporter with Docker Compose, write a first prometheus.yml, run first PromQL queries, then install Prometheus from the release tarball as a systemd service |
| [[observability/prometheus/troubleshooting\|Prometheus troubleshooting]] | reference | Find why a target is down, why a reload failed, where high cardinality comes from, and what to do with WAL replay, out-of-order samples, a full disk, clock skew and alerts that never reach Alertmanager |

Part of [[observability/index|Observability]].
