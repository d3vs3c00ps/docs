---
title: "Collecting metrics with Prometheus"
description: "multiple service discovery backends to figure out which metrics to collect"
tags: [kubernetes, observability, monitoring, prometheus]
type: lab
status: complete
source: https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/prometheus.md
license: CC-BY-4.0
upstream_commit: 56563629
upstream_sync: manual
---

# Collecting metrics with Prometheus

- Prometheus is an open-source monitoring system including:

  - multiple *service discovery* backends to figure out which metrics to collect

  - a *scraper* to collect these metrics

  - an efficient *time series database* to store these metrics

  - a specific query language (PromQL) to query these time series

  - an *alert manager* to notify us according to metrics values or trends

- We are going to use it to collect and query some metrics on our Kubernetes cluster

## Why Prometheus?

- We don't endorse Prometheus more or less than any other system

- It's relatively well integrated within the cloud-native ecosystem

- It can be self-hosted (this is useful for tutorials like this)

- It can be used for deployments of varying complexity:

  - one binary and 10 lines of configuration to get started

  - all the way to thousands of nodes and millions of metrics

## Exposing metrics to Prometheus

- Prometheus obtains metrics and their values by querying *exporters*

- An exporter serves metrics over HTTP, in plain text

- The *node exporter* serves node metrics on port 9100, at `/metrics`

- Prometheus itself exposes its own internal metrics, too (port 9090, `/metrics`)

  (the public demo at `demo.robustperception.io` that the original linked to is gone)

- If you want to expose custom metrics to Prometheus:

  - serve a text page like these, and you're good to go

  - libraries are available in various languages to help with quantiles etc.

## How Prometheus gets these metrics

- The *Prometheus server* will *scrape* URLs like these at regular intervals

  (by default: every minute; can be more/less frequent)

- The list of URLs to scrape (the *scrape targets*) is defined in configuration

*Worried about the overhead of parsing a text format?
Check this [comparison](https://github.com/RichiH/OpenMetrics/blob/master/markdown/protobuf_vs_text.md) of the text format with the protobuf format!
(Prometheus 2.0 dropped protobuf scraping; recent versions use it again for native
histograms.)*

## Defining scrape targets

This is maybe the simplest configuration file for Prometheus:
```yaml
scrape_configs:
  - job_name: 'prometheus'
    static_configs:
      - targets: ['localhost:9090']
```

- In this configuration, Prometheus collects its own internal metrics

- A typical configuration file will have multiple `scrape_configs`

- In this configuration, the list of targets is fixed

- A typical configuration file will use dynamic service discovery

## Service discovery

This configuration file will leverage existing DNS `A` records:
```yaml
scrape_configs:
  - ...
  - job_name: 'node'
    dns_sd_configs:
      - names: ['api-backends.example.com']
        type: 'A'
        port: 9100
```

- In this configuration, Prometheus resolves the provided name(s)

  (here, `api-backends.example.com`)

- Each resulting IP address is added as a target on port 9100

## Dynamic service discovery

- In the DNS example, the names are re-resolved at regular intervals

- As DNS records are created/updated/removed, scrape targets change as well

- Existing data (previously collected metrics) is not deleted

- Other service discovery backends work in a similar fashion

## Other service discovery mechanisms

- Prometheus can connect to e.g. a cloud API to list instances

- Or to the Kubernetes API to list nodes, pods, services ...

- Or a service like Consul, Zookeeper, etcd, to list applications

- The resulting configurations files are *way more complex*

  (but don't worry, we won't need to write them ourselves)

## Time series database

- We could wonder, "why do we need a specialized database?"

- One metrics data point = metrics ID + timestamp + value

- With a classic SQL or noSQL data store, that's at least 160 bits of data + indexes

- Prometheus is way more efficient, without sacrificing performance

  (it will even be gentler on the I/O subsystem since it needs to write less)

- Would you like to know more? Check this video:

  [Storage in Prometheus 2.0](https://www.youtube.com/watch?v=C4YV-9CrawA) by [Goutham V](https://twitter.com/putadent) at DC17EU

## Checking if Prometheus is installed

- Before trying to install Prometheus, let's check if it's already there

> [!example] Hands-on
> - Look for services with a label `app.kubernetes.io/name=prometheus` across all namespaces:
>   ```bash
>   kubectl get services --selector=app.kubernetes.io/name=prometheus --all-namespaces
>   ```

> [!warning] Correction
> The original looked for the label `app=prometheus`. Current versions of the chart
> use the standard `app.kubernetes.io/name=prometheus` label, so the old selector finds
> nothing even when Prometheus is installed.

If we see a `NodePort` service called `prometheus-server`, we're good!

(We can then skip to "Connecting to the Prometheus web UI".)

## Running Prometheus on our cluster

We need to:

- Run the Prometheus server in a pod

  (using e.g. a Deployment to ensure that it keeps running)

- Expose the Prometheus server web UI (e.g. with a NodePort)

- Run the *node exporter* on each node (with a Daemon Set)

- Set up a Service Account so that Prometheus can query the Kubernetes API

- Configure the Prometheus server

  (storing the configuration in a Config Map for easy updates)

## Helm charts to the rescue

- To make our lives easier, we are going to use a Helm chart

- The Helm chart will take care of all the steps explained above

  (including some extra features that we don't need, but won't hurt)

## Step 1: install Helm

- If we already installed Helm earlier, this command won't break anything

> [!example] Hands-on
> - Install the Helm CLI:
>   ```bash
>   curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-4 \
>   | bash
>   ```

## Step 2: install Prometheus

- The following command, just like the previous ones, is idempotent

  (it won't error out if Prometheus is already installed)

> [!example] Hands-on
> - Install Prometheus on our cluster:
>   ```bash
>     helm upgrade prometheus --install prometheus \
>         --repo https://prometheus-community.github.io/helm-charts \
>         --namespace prometheus --create-namespace \
>         --set server.service.type=NodePort \
>         --set server.service.nodePort=30090 \
>         --set server.persistentVolume.enabled=false \
>         --set alertmanager.enabled=false \
>         --version 29.47.2
>   ```

Curious about all these flags? They're explained below.

> [!note]- Extra details
> ## Explaining all the Helm flags
>
>
> - `helm upgrade prometheus` → upgrade the release named `prometheus`
>   (a "release" is an instance of an app deployed with Helm)
>
> - `--install` → if it doesn't exist, install it (instead of upgrading)
>
> - `prometheus` → use the chart named `prometheus`
>
> - `--repo ...` → the chart is located on the following repository
>
> - `--namespace prometheus` → put it in that specific namespace
>
> - `--create-namespace` → create the namespace if it doesn't exist
>
> - `--set ...` → here are some *values* to be used when rendering the chart's templates

> [!note]- Extra details
> ## Values for the Prometheus chart
>
> Helm *values* are parameters to customize our installation.
>
> - `server.service.type=NodePort` → expose the Prometheus server with a NodePort
>
> - `server.service.nodePort=30090` → set the specific NodePort number to use
>
> - `server.persistentVolume.enabled=false` → do not use a PersistentVolumeClaim
>
> - `alertmanager.enabled=false` → disable the alert manager entirely

## Connecting to the Prometheus web UI

- Let's connect to the web UI and see what we can do

> [!example] Hands-on
> - Figure out the NodePort that was allocated to the Prometheus server:
>   ```bash
>   kubectl get svc --all-namespaces | grep prometheus-server
>   ```
>
> - With your browser, connect to that port
>
> - It should be 30090 if we just installed Prometheus with the Helm chart!

## Querying some metrics

- This is easy... if you are familiar with PromQL

> [!example] Hands-on
> - Click on "Graph", and in "expression", paste the following:
>   ```
>     sum by (instance) (
>       irate(
>         container_cpu_usage_seconds_total{
>           pod=~"worker.*"
>           }[5m]
>       )
>     )
>   ```

- Click on the blue "Execute" button and on the "Graph" tab just below

- We see the cumulated CPU usage of worker pods for each node
  (if we just deployed Prometheus, there won't be much data to see, though)

## Getting started with PromQL

- We can't learn PromQL in just 5 minutes

- But we can cover the basics to get an idea of what is possible

  (and have some keywords and pointers)

- We are going to break down the query above

  (building it one step at a time)

## Graphing one metric across all tags

This query will show us CPU usage across all containers:
```
container_cpu_usage_seconds_total
```

- The suffix of the metrics name tells us:

  - the unit (seconds of CPU)

  - that it's the total used since the container creation

- Since it's a "total," it is an increasing quantity

  (we need to compute the derivative if we want e.g. CPU % over time)

- We see that the metrics retrieved have *tags* attached to them

## Selecting metrics with tags

This query will show us only metrics for worker containers:
```
container_cpu_usage_seconds_total{pod=~"worker.*"}
```

- The `=~` operator allows regex matching

- We select all the pods with a name starting with `worker`

  (it would be better to use labels to select pods; more on that later)

- The result is a smaller set of containers

## Transforming counters in rates

This query will show us CPU usage % instead of total seconds used:
```
100*irate(container_cpu_usage_seconds_total{pod=~"worker.*"}[5m])
```

- The [`irate`](https://prometheus.io/docs/prometheus/latest/querying/functions/#irate) operator computes the "per-second instant rate of increase"

  - `irate` uses only the last two samples in the window: it follows fast changes

  - `rate` averages over the whole window: smoother, better for alerts and long graphs

  - both handle counter resets (a counter that goes back to zero gives no negative spike)

- The `[5m]` tells how far to look back if there is a gap in the data

> [!warning] Correction
> The original said that `rate` "allows decreasing counters and negative values" and
> that only `irate` avoids negative spikes. Both functions detect counter resets; the
> difference is how many samples they use.

- And we multiply with `100*` to get CPU % usage

## Aggregation operators

This query sums the CPU usage per node:
```
sum by (instance) (
  irate(container_cpu_usage_seconds_total{pod=~"worker.*"}[5m])
)
```

- `instance` corresponds to the node on which the container is running

- `sum by (instance) (...)` computes the sum for each instance

- Note: all the other tags are collapsed

  (in other words, the resulting graph only shows the `instance` tag)

- PromQL supports many more [aggregation operators](https://prometheus.io/docs/prometheus/latest/querying/operators/#aggregation-operators)

## What kind of metrics can we collect?

- Node metrics (related to physical or virtual machines)

- Container metrics (resource usage per container)

- Databases, message queues, load balancers, ...

  (check out this [list of exporters](https://prometheus.io/docs/instrumenting/exporters/)!)

- Instrumentation (=deluxe `printf` for our code)

- Business metrics (customers served, revenue, ...)

> [!note]- Extra details
> ## Node metrics
>
> - CPU, RAM, disk usage on the whole node
>
> - Total number of processes running, and their states
>
> - Number of open files, sockets, and their states
>
> - I/O activity (disk, network), per operation or volume
>
> - Physical/hardware (when applicable): temperature, fan speed...
>
> - ...and much more!

> [!note]- Extra details
> ## Container metrics
>
> - Similar to node metrics, but not totally identical
>
> - RAM breakdown will be different
>
>   - active vs inactive memory
>   - some memory is *shared* between containers, and specially accounted for
>
> - I/O activity is also harder to track
>
>   - async writes can cause deferred "charges"
>   - some page-ins are also shared between containers
>
> For details about container metrics, see:
> http://jpetazzo.github.io/2013/10/08/docker-containers-metrics/

> [!note]- Extra details
> ## Application metrics
>
> - Arbitrary metrics related to your application and business
>
> - System performance: request latency, error rate...
>
> - Volume information: number of rows in database, message queue size...
>
> - Business data: inventory, items sold, revenue...

> [!note]- Extra details
> ## Detecting scrape targets
>
> - Prometheus can leverage Kubernetes service discovery
>
>   (with proper configuration)
>
> - Services or pods can be annotated with:
>
>   - `prometheus.io/scrape: true` to enable scraping
>   - `prometheus.io/port: 9090` to indicate the port number
>   - `prometheus.io/path: /metrics` to indicate the URI (`/metrics` by default)
>
> - Prometheus will detect and scrape these (without needing a restart or reload)

## Querying labels

- What if we want to get metrics for containers belonging to a pod tagged `worker`?

- The cAdvisor exporter does not give us Kubernetes labels

- Kubernetes labels are exposed through another exporter

- We can see Kubernetes labels through metrics `kube_pod_labels`

  (each pod appears as a time series with constant value of `1`)

> [!warning] Correction
> kube-state-metrics v2 exposes `kube_pod_labels` only for labels that you allow, and
> it allows none by default: with the chart's defaults, the metric does not exist. Allow
> the pod labels, then they appear as `label_<name>` tags:
>
> ```bash
> helm upgrade prometheus prometheus --repo https://prometheus-community.github.io/helm-charts \
>   --namespace prometheus --reuse-values \
>   --set 'kube-state-metrics.metricLabelsAllowlist[0]=pods=[*]'
> ```
>
> The original also said that each *container* appears as a series; it is each pod.

- Prometheus *kind of* supports "joins" between time series

- But only if the names of the tags match exactly

> [!note]- Extra details
> ## What if the tags don't match?
>
> - Older versions of cAdvisor exporter used tag `pod_name` for the name of a pod
>
> - The Kubernetes service endpoints exporter uses tag `pod` instead
>
> - See [this blog post](https://www.robustperception.io/exposing-the-software-version-to-prometheus) or [this other one](https://www.weave.works/blog/aggregating-pod-resource-cpu-memory-usage-arbitrary-labels-prometheus/) to see how to perform "joins"
>
> - Note that Prometheus cannot "join" time series with different labels
>
>   (see [Prometheus issue #2204](https://github.com/prometheus/prometheus/issues/2204) for the rationale)
>
> - There is a workaround involving relabeling, but it's "not cheap"
>
>   - see [this comment](https://github.com/prometheus/prometheus/issues/2204#issuecomment-261515520) for an overview
>
>   - or [this blog post](https://5pi.de/2017/11/09/use-prometheus-vector-matching-to-get-kubernetes-utilization-across-any-pod-label/) for a complete description of the process

## In practice

- Grafana is a beautiful (and useful) frontend to display all kinds of graphs

- Not everyone needs to know Prometheus, PromQL, Grafana, etc.

- But in a team, it is valuable to have at least one person who knows them

- That person can set up queries and dashboards for the rest of the team

- It's a little bit like knowing how to optimize SQL queries, Dockerfiles...

  Don't panic if you don't know these tools!

  ...But make sure at least one person in your team is on it 💯

---

> [!info] Adapted from container.training
> This page is derived from [`slides/k8s/prometheus.md`](https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/prometheus.md)
> in **[container.training](https://github.com/jpetazzo/container.training)** by Jérôme Petazzoni and contributors,
> used under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).
> **Changes were made**: restructured from slides into a single page, remark
> markup converted to Obsidian callouts, referenced files inlined or linked,
> Helm script, chart label, `rate`/`irate` explanation and `kube_pod_labels` corrected, dead demo link
> removed, chart version pinned, queries tested on kind with chart 29.47.2.

<!-- uplink -->
Part of [[kubernetes/observability/index|Observability and scaling]].
