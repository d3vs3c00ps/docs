---
title: "CloudNativePG"
description: "CloudNativePG (CNPG) is an operator to run PostgreSQL on Kubernetes"
tags: [kubernetes, storage, postgresql]
type: concept
status: complete
source: https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/cnpg.md
license: CC-BY-4.0
upstream_commit: 56563629
upstream_sync: manual
---

# CloudNativePG

- CloudNativePG (CNPG) is an operator to run PostgreSQL on Kubernetes

- Makes it easy to run production Postgres on K8S

- Supports streaming replication, backups, PITR, TLS, monitoring...

- Open source

- Accepted to CNCF on January 21, 2025 at the Sandbox maturity level

  (https://www.cncf.io/projects/cloudnativepg/)

## A few examples

- [EphemeraSearch](https://www.ephemerasearch.com/)

  *personal project, ~200 GB database, tiny budget*

- [Sellsy](https://enix.io/en/clients/)

  *40,000 databases across 50 clusters, Talos, Proxmox VE*

- MistralAI

  *30 production clusters, each from a few GB to a few TB size*

→ CNPG works for environments with small, big, and many clusters!

## Typical operation

- Decide what kind of storage we want to use

  (cloud, local, distributed, hyperconverged...)

- Decide on backup strategy

  (typically object store, e.g. S3-compatible)

- Set up `StorageClass` if needed

- Install CNPG

- Deploy Postgres cluster(s) with YAML manifests

- Profit!

## Local vs remote storage

- Local storage can feel less safe

  (compared to a SAN, cloud block device, distributed volume...)

- However, it can be much faster

  (much lower latency, much higher throughput)

- If we're using replication, losing a local volume is no problem

- Distributed storage can also fail

  (or be unavailable for a while)

## CNPG installation

Example with Helm:
```bash
helm upgrade --install --namespace cnpg-system --create-namespace \
  --repo https://cloudnative-pg.io/charts/ \
  cloudnative-pg cloudnative-pg \
  --version 0.29.1
```

> [!note] Chart version, not operator version
> Helm's `--version` is the *chart* version, which has its own numbers: with
> `--version 1.25.1` (an operator version), Helm answers `chart "cloudnative-pg"
> version "1.25.1" not found`. Chart 0.29.1 installs operator 1.30.1 (tested on
> Kubernetes 1.37).

Interesting options to add, to integrate with Prometheus Operator:
```bash
--set monitoring.podMonitorEnabled=true
--set monitoring.grafanaDashboard.create=true
--set monitoring.grafanaDashboard.namespace=prom-system
```

## Minimal Postgres cluster

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: minimal
spec:
  instances: 2
  storage:
    size: 10G
```

Note: this is missing (notably) resource requests and backups!

## `kubectl` plugin

- There is a `kubectl-cnpg` plugin

- Install it (e.g. with `krew`, or from the
  [release assets](https://github.com/cloudnative-pg/cloudnative-pg/releases))

- Check commands like:

  `k cnpg status`

  `k cnpg psql`

  `k cnpg backup`

  `k cnpg promote`

## Production clusters

Check the following YAML manifest:

https://github.com/jpetazzo/pozok/blob/main/cluster-production.yaml

If you want to test this, you need an S3-compatible object store.

- Set the required variables:

  `$CLUSTER_NAME`, `$AWS_ACCESS_KEY_ID`, `$AWS_SECRET_ACCESS_KEY`, `$AWS_DEFAULT_REGION`, `$BUCKET_NAME`, `$AWS_ENDPOINT_URL`

- Then `envsubst < cluster-production.yaml | kubectl apply -f-`

- Cluster comes up; backups and WAL segments land in the S3 bucket!

## Automated switchover

- CNPG detects when we `kubectl cordon` a node

- It assumes "cordon = maintenance"

- If the node hosts a primary server, it initiates a switchover

- It also uses Pod Disruption Budgets (PDB) to collaborate with evictions

  (the PDB prevents the eviction of the primary until it gets demoted)

## Benchmarking

- Postgres has `pgbench`

- Step 1: execute e.g. `pgbench -i -s 10` to prepare the database

  (`-s` is an optional "scaling factor" for a bigger dataset)

- Step 2: execute `pgbench -P1 -T10` to run the benchmark

  (`-P1` = report progress every second, `-T10` = run for 10 seconds)

- These commands can be executed in the pod running the primary, e.g.:

  `kubectl exec minimal-1 -- pgbench app -i -s 10`

  `kubectl exec minimal-1 -- pgbench app -P1 -T60`

## CNPG lab 1

- Install CNPG on a managed cluster with a default `StorageClass`

- Provision a CNPG cluster (primary+replica)

- Run a `pgbench` (e.g. 60 seconds)

- Note the number of transactions / second

- Install another `StorageClass` (e.g. `rancher/local-path-provisioner`)

- Provision another CNPG cluster with that storage class

- Run a benchmark and compare the numbers

- Discuss!

## CNPG lab 2

- This one requires access to an S3-compatible object store

- Deploy a cluster sending backups to the object store

- Run a benchmark (to populate the database)

- Trigger a backup (e.g. with `k cnpg backup`)

- Create a new cluster from the backup

- Confirm that the number of rows (e.g. in `pgbench_history`) is the same

---

> [!info] Adapted from container.training
> This page is derived from [`slides/k8s/cnpg.md`](https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/cnpg.md)
> in **[container.training](https://github.com/jpetazzo/container.training)** by Jérôme Petazzoni and contributors,
> used under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).
> **Changes were made**: restructured from slides into a single page, remark
> markup converted to Obsidian callouts, referenced files inlined or linked,
> chart version corrected, install, minimal cluster, plugin, benchmark and
> cordon switchover tested with CNPG 1.30.

<!-- uplink -->
Part of [[kubernetes/storage/index|Storage]].
