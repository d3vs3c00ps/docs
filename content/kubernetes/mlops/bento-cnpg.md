---
title: "Bento & PostgreSQL"
description: "Bento can also use SQL databases for input/output"
tags: [kubernetes, mlops]
type: concept
status: complete
source: https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/bento-cnpg.md
license: CC-BY-4.0
upstream_commit: 56563629
upstream_sync: manual
---

# Bento & PostgreSQL

- Bento can also use SQL databases for input/output

- We're going to demonstrate that by writing to a PostgreSQL database

- That database will be deployed with the Cloud Native PostGres operator

  (https://cloudnative-pg.io/)

## CNPG in a nutshell

- Free, open source

- Originally created by [EDB] (EnterpriseDB, well-known PgSQL experts)

- Non-exhaustive list of features:

  - provisioning of Postgres servers, replicas, bouncers

  - automatic failover

  - backups (full backups and WAL shipping)

  - provisioning from scratch, from backups, PITR

  - manual and automated switchover (e.g. for node maintenance)

  - and many more!

[EDB]: https://www.enterprisedb.com/workload/kubernetes

## What we're going to do

1. Install CNPG.

2. Provision a Postgres cluster.

3. Configure Bento to write to that cluster.

4. Set up a Grafana dashboard to see the data.

## 1️⃣ Installing CNPG

Many options available, see the [documentation][cnpg-install]:

- raw YAML manifests (tested with 1.30.1):
  ```bash
  kubectl apply --server-side -f \
    https://github.com/cloudnative-pg/cloudnative-pg/releases/download/v1.30.1/cnpg-1.30.1.yaml
  ```

- kubectl CNPG plugin (`kubectl cnpg install generate`)

- Helm chart

- OLM

[cnpg-install]: https://cloudnative-pg.io/documentation/current/installation_upgrade/

## 2️⃣ Provisioning a Postgres cluster

Minimal manifest:

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: db
spec:
  storage:
    size: 1Gi
```

> [!note]- Extra details
> ## For production...
>
> We might also add:
>
> - `spec.monitoring.enablePodMonitor: true`
>
> - `spec.instances: 2`
>
> - `resources.{requests,limits}.{cpu,memory}`
>
> - `walStorage.size`
>
> - `backup`
>
> - `postgresql.parameters`
>
> See [this manifest][cluster-maximal] for a detailed example.
>
> [cluster-maximal]: https://github.com/jpetazzo/pozok/blob/main/cluster-maximal.yaml

## 3️⃣ Configuring Bento to write to SQL

- We'll use the [`sql_insert`][sql-insert] output

- Our cluster is named `db`, so there will be a Secret `db-app`

- This Secret will contain a `uri` field

- That field can be used as the `dsn` in the Bento configuration, with `driver: postgres`

- We will also need to create the table that we want to use

  (see next slide for instructions)

[sql-insert]: https://warpstreamlabs.github.io/bento/docs/components/outputs/sql_insert

## Creating a table

- If we just want to store the city name and its population:
  ```sql
      CREATE TABLE IF NOT EXISTS cities (
        city varchar(100) NOT NULL,
        population integer
      );
  ```

- This statement can be executed:

  - manually, with a `psql` shell as the `app` user, using the URI from the Secret:
    ```bash
    kubectl exec -it db-1 -- psql "$(kubectl get secret db-app -o jsonpath='{.data.uri}' | base64 -d)"
    ```

  - automatically, with the `init_statement` of Bento's `sql_insert` output

> [!warning] Correction
> The original suggested `kubectl exec -it db-1 -- psql app` (or `kubectl cnpg psql db`).
> Both connect as the `postgres` superuser, so the table belongs to `postgres`, and
> Bento, which connects as `app`, then fails with `permission denied for table cities`.
> Create the table as `app`, or let `init_statement` create it.

## 4️⃣ Viewing the table in Grafana

- In Grafana, in the home menu on the left, click "connections"

- Add a PostgreSQL data source

- Enter the host:port, database, user, password

- Then add a visualization using that data source

  (it should be relatively self-explanatory!)

> [!note]- Extra details
> ## Automating it all
>
> - Expose PostgreSQL credentials through environment variables
>
>   (in the Bento container)
>
> - Use the `${...}` syntax in Bento to use these environment variables
>
> - Export the Grafana dashboard to a JSON file
>
> - Store the JSON file in a ConfigMap, with label `grafana_dashboard=1`
>
> - Create that ConfigMap in the namespace where Grafana is running
>
> - Similarly, data sources (like the Redis and the PostgreSQL one) can be defined in YAML
>
> - And that YAML can be put in a ConfigMap with label `grafana_datasource=1`

---

> [!info] Adapted from container.training
> This page is derived from [`slides/k8s/bento-cnpg.md`](https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/bento-cnpg.md)
> in **[container.training](https://github.com/jpetazzo/container.training)** by Jérôme Petazzoni and contributors,
> used under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).
> **Changes were made**: restructured from slides into a single page, remark
> markup converted to Obsidian callouts, referenced files inlined or linked,
> field names and cluster name fixed, install command added, table created as the
> app user, tested on kind.

<!-- uplink -->
Part of [[kubernetes/mlops/index|MLOps]].
