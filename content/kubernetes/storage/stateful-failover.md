---
title: "Stateful failover"
description: "How can we achieve true durability?"
tags: [kubernetes, storage]
type: lab
status: complete
source: https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/stateful-failover.md
license: CC-BY-4.0
upstream_commit: 56563629
upstream_sync: manual
---

# Stateful failover

> [!important] These labs expect the upstream repository
> Commands below reference files by their path in a local clone. Get it with:
>
> ```bash
> git clone https://github.com/jpetazzo/container.training
> ```
>
> The manifests can also be browsed at the pinned commit
> [`56563629`](https://github.com/jpetazzo/container.training/tree/565636291ec03abf1f2ab8bf6b935478e00e69a2).

- How can we achieve true durability?

- How can we store data that would survive the loss of a node?

- We need to use Persistent Volumes backed by highly available storage systems

- There are many ways to achieve that:

  - leveraging our cloud's storage APIs

  - using NAS/SAN systems or file servers

  - distributed storage systems

## Our test scenario

- We will use it to deploy a SQL database (PostgreSQL)

- We will insert some test data in the database

- We will disrupt the node running the database

- We will see how it recovers

## Our Postgres Stateful set

- The next slide shows `k8s/postgres.yaml`

- It defines a Stateful set

- With a `volumeClaimTemplate` requesting a 1 GB volume

- That volume will be mounted to `/var/lib/postgresql/data`

```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: postgres
spec:
  selector:
    matchLabels:
      app: postgres
  serviceName: postgres
  template:
    metadata:
      labels:
        app: postgres
    spec:
      #schedulerName: stork
      initContainers:
      - name: rmdir
        image: alpine
        volumeMounts:
        - mountPath: /vol
          name: postgres
        command: ["sh", "-c", "if [ -d /vol/lost+found ]; then rmdir /vol/lost+found; fi"]
      containers:
      - name: postgres
        image: postgres:12
        env:
        - name: POSTGRES_HOST_AUTH_METHOD
          value: trust
        volumeMounts:
        - mountPath: /var/lib/postgresql/data
          name: postgres
  volumeClaimTemplates:
  - metadata:
      name: postgres
    spec:
      accessModes: ["ReadWriteOnce"]
      resources:
        requests:
          storage: 1Gi
```
<small>Source: [`k8s/postgres.yaml`](https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/k8s/postgres.yaml)</small>

## Creating the Stateful set

- Before applying the YAML, watch what's going on with `kubectl get events -w`

> [!example] Hands-on
> - Apply that YAML:
>   ```bash
>   kubectl apply -f ~/container.training/k8s/postgres.yaml
>   ```

## Testing our PostgreSQL pod

- We will use `kubectl exec` to get a shell in the pod

- Good to know: we need to use the `postgres` user in the pod

> [!example] Hands-on
> - Get a shell in the pod, as the `postgres` user:
>   ```bash
>   kubectl exec -ti postgres-0 -- su postgres
>   ```
>
> - Check that default databases have been created correctly:
>   ```bash
>   psql -l
>   ```

(This should show us 3 lines: postgres, template0, and template1.)

## Inserting data in PostgreSQL

- We will create a database and populate it with `pgbench`

> [!example] Hands-on
> - Create a database named `demo`:
>   ```bash
>   createdb demo
>   ```
>
> - Populate it with `pgbench`:
>   ```bash
>   pgbench -i demo
>   ```

- The `-i` flag means "create tables"

- If you want more data in the test tables, add e.g. `-s 10` (to get 10x more rows)

## Checking how much data we have now

- The `pgbench` tool inserts rows in table `pgbench_accounts`

> [!example] Hands-on
> - Check that the `demo` base exists:
>   ```bash
>   psql -l
>   ```
>
> - Check how many rows we have in `pgbench_accounts`:
>   ```bash
>   psql demo -c "select count(*) from pgbench_accounts"
>   ```
>
> - Check that `pgbench_history` is currently empty:
>   ```bash
>   psql demo -c "select count(*) from pgbench_history"
>   ```

## Testing the load generator

- Let's use `pgbench` to generate a few transactions

> [!example] Hands-on
> - Run `pgbench` for 10 seconds, reporting progress every second:
>   ```bash
>   pgbench -P 1 -T 10 demo
>   ```
>
> - Check the size of the history table now:
>   ```bash
>   psql demo -c "select count(*) from pgbench_history"
>   ```

Note: on small cloud instances, a typical speed is about 100 transactions/second.

## Generating transactions

- Now let's use `pgbench` to generate more transactions

- While it's running, we will disrupt the database server

> [!example] Hands-on
> - Run `pgbench` for 10 minutes, reporting progress every second:
>   ```bash
>   pgbench -P 1 -T 600 demo
>   ```
>
> - You can use a longer time period if you need more time to run the next steps

## Find out which node is hosting the database

- We can find that information with `kubectl get pods -o wide`

> [!example] Hands-on
> - Check the node running the database:
>   ```bash
>   kubectl get pod postgres-0 -o wide
>   ```

We are going to disrupt that node.

By "disrupt" we mean: "disconnect it from the network".

## Node failover

⚠️ This will partially break your cluster!

- We are going to disconnect the node running PostgreSQL from the cluster

- We will see what happens, and how to recover

- We will not reconnect the node to the cluster

- This whole lab will take at least 10-15 minutes (due to various timeouts)

⚠️ Only do this lab at the very end, when you don't want to run anything else after!

## Disconnecting the node from the cluster

> [!example] Hands-on
> - Find out where the Pod is running, and SSH into that node:
>   ```bash
>   kubectl get pod postgres-0 -o jsonpath={.spec.nodeName}
>   ssh nodeX
>   ```
>
> - Check the name of the network interface:
>   ```bash
>   sudo ip route ls default
>   ```
>
> - The output should look like this:
>   ```
>   default via 10.10.0.1 dev ensX proto dhcp src 10.10.0.13 metric 100
>   ```
>
> - Shutdown the network interface:
>   ```bash
>   sudo ip link set ensX down
>   ```

> [!note]- Extra details
> ## Another way to disconnect the node
>
> - We can also use `iptables` to block all traffic exiting the node
>
>   (except SSH traffic, so we can repair the node later if needed)
>
> > [!example] Hands-on
> > - SSH to the node to disrupt:
> >   ```bash
> >   ssh nodeX
> >   ```
> >
> > - Allow SSH traffic leaving the node, but block all other traffic:
> >   ```bash
> >   sudo iptables -I OUTPUT -p tcp --sport 22 -j ACCEPT
> >   sudo iptables -I OUTPUT 2 -j DROP
> >   ```

## Watch what's going on

- Let's look at the status of Nodes, Pods, and Events

> [!example] Hands-on
> - In a first pane/tab/window, check Nodes and Pods:
>   ```bash
>   watch kubectl get nodes,pods -o wide
>   ```
>
> - In another pane/tab/window, check Events:
>   ```bash
>   kubectl get events --watch
>   ```

## Node Ready → NotReady

- After \~30 seconds, the control plane stops receiving heartbeats from the Node

- The Node is marked NotReady

- It is not *schedulable* anymore

  (the scheduler won't place new pods there, except some special cases)

- All Pods on that Node are also *not ready*

  (they get removed from service Endpoints)

- ... But nothing else happens for now

  (the control plane is waiting: maybe the Node will come back shortly?)

## Pod eviction

- After \~5 minutes, the control plane will evict most Pods from the Node

- These Pods are now `Terminating`

- The Pods controlled by e.g. ReplicaSets are automatically moved

  (or rather: new Pods are created to replace them)

- But nothing happens to the Pods controlled by StatefulSets at this point

  (they remain `Terminating` forever)

- Why? 🤔

- This is to avoid *split brain scenarios*

> [!note]- Extra details
> ## Split brain 🧠⚡️🧠
>
> - Imagine that we create a replacement pod `postgres-0` on another Node
>
> - And 15 minutes later, the Node is reconnected and the original `postgres-0` comes back
>
> - Which one is the "right" one?
>
> - What if they have conflicting data?
>
> 😱
>
> - We *cannot* let that happen!
>
> - Kubernetes won't do it
>
> - ... Unless we tell it to

## The Node is gone

- One thing we can do, is tell Kubernetes "the Node won't come back"

  (there are other methods; but this one is the simplest one here)

- This is done with a simple `kubectl delete node`

> [!example] Hands-on
> - `kubectl delete` the Node that we disconnected

## Pod rescheduling

- Kubernetes removes the Node

- After a brief period of time (\~1 minute) the "Terminating" Pods are removed

- A replacement Pod is created on another Node

- ... But it doesn't start yet!

- Why? 🤔

## Multiple attachment

- By default, a disk can only be attached to one Node at a time

  (sometimes it's a hardware or API limitation; sometimes enforced in software)

- In our Events, we should see `FailedAttachVolume` and `FailedMount` messages

- After \~5 more minutes, the disk will be force-detached from the old Node

- ... Which will allow attaching it to the new Node!

🎉

- The Pod will then be able to start

- Failover is complete!

## Check that our data is still available

- We are going to reconnect to the (new) pod and check

> [!example] Hands-on
> - Get a shell on the pod:
>   ```bash
>   kubectl exec -ti postgres-0 -- su postgres
>   ```
>
> - Check how many transactions are now in the `pgbench_history` table:
>   ```bash
>   psql demo -c "select count(*) from pgbench_history"
>   ```

If the 10-second test that we ran earlier gave e.g. 80 transactions per second,
and we failed the node after 30 seconds, we should have about 2400 rows in that table.

## Double-check that the pod has really moved

- Just to make sure the system is not bluffing!

> [!example] Hands-on
> - Look at which node the pod is now running on
>   ```bash
>   kubectl get pod postgres-0 -o wide
>   ```

---

> [!info] Adapted from container.training
> This page is derived from [`slides/k8s/stateful-failover.md`](https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/stateful-failover.md)
> in **[container.training](https://github.com/jpetazzo/container.training)** by Jérôme Petazzoni and contributors,
> used under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).
> **Changes were made**: restructured from slides into a single page, remark
> markup converted to Obsidian callouts, referenced files inlined or linked.

<!-- uplink -->
Part of [[kubernetes/storage/index|Storage]].
