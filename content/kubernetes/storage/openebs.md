---
title: "OpenEBS"
description: "[OpenEBS] is a popular open-source storage solution for Kubernetes"
tags: [kubernetes, storage]
type: lab
status: complete
source: https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/openebs.md
license: CC-BY-4.0
upstream_commit: 56563629
upstream_sync: manual
---

# OpenEBS

> [!important] These labs expect the upstream repository
> Commands below reference files by their path in a local clone. Get it with:
>
> ```bash
> git clone https://github.com/jpetazzo/container.training
> ```
>
> The manifests can also be browsed at the pinned commit
> [`56563629`](https://github.com/jpetazzo/container.training/tree/565636291ec03abf1f2ab8bf6b935478e00e69a2).

- [OpenEBS] is a popular open-source storage solution for Kubernetes

 - Uses the concept of "Container Attached Storage"

   (1 volume = 1 dedicated controller pod + a set of replica pods)

 - Supports a wide range of storage engines:

   - LocalPV: local volumes (hostpath or device), no replication

   - Jiva: for lighter workloads with basic cloning/snapshotting

   - cStor: more powerful engine that also supports resizing, RAID, disk pools ...

   - [Mayastor]: newer, even more powerful engine with NVMe and vhost-user support

> [!warning] OpenEBS 4 engines
> In OpenEBS 4, the engines are **Local PV
> Hostpath**, **Local PV LVM**, **Local PV ZFS** and **Replicated PV Mayastor**.
> Jiva, cStor and the device manager (NDM) are not part of OpenEBS 4 any more, and
> Jiva has had no change since 2024. This page installs OpenEBS 4.6 and uses
> Local PV Hostpath, which works as described. The Jiva parts are kept for context
> but cannot be followed with a current OpenEBS.

[OpenEBS]: https://openebs.io/

[Mayastor]: https://github.com/openebs/MayaStor#mayastor

> [!note]- Extra details
> ## What are all these storage engines?
>
> - LocalPV is great if we want good performance, no replication, easy setup
>
>   (it is similar to the Rancher local path provisioner)
>
> - Jiva is great if we want replication and easy setup
>
>   (data is stored in containers' filesystems)
>
> - cStor is more powerful and flexible, but requires more extensive setup
>
> - Mayastor is designed to achieve extreme performance levels
>
>   (with the right hardware and disks)
>
> - The OpenEBS documentation has a [good comparison of engines] to help us pick
>
> [good comparison of engines]: https://openebs.io/docs/

## Installing OpenEBS with Helm

- The OpenEBS control plane can be installed with Helm

- It will run as a set of containers on Kubernetes worker nodes

> [!example] Hands-on
> - Install OpenEBS, with only the Local PV Hostpath engine:
>   ```bash
>   helm upgrade --install openebs openebs \
>     --repo https://openebs.github.io/openebs \
>     --namespace openebs --create-namespace \
>     --version 4.6.2 \
>     --set engines.replicated.mayastor.enabled=false \
>     --set engines.local.lvm.enabled=false \
>     --set engines.local.zfs.enabled=false \
>     --set loki.enabled=false --set alloy.enabled=false
>   ```

> [!note] Which chart, and which engines
> The current chart is in `https://openebs.github.io/openebs`. The old
> `https://openebs.github.io/charts` (OpenEBS 2.x) still installs, but its device
> manager pods never start on kind, and its Jiva class needs iSCSI on every node.
> Mayastor needs hugepages and NVMe-TCP on the nodes, LVM and ZFS need a volume group
> or a pool, and Loki and Alloy are the logging add-ons: we turn them off to keep only
> Local PV Hostpath.

## Checking what was installed

- Wait a little bit ...

> [!example] Hands-on
> - Look at the pods in the `openebs` namespace:
>   ```bash
>   kubectl get pods --namespace openebs
>   ```
>
> - And the StorageClasses that were created:
>   ```bash
>   kubectl get sc
>   ```

## The default StorageClasses

- OpenEBS 2 created three default StorageClasses; with the install above, OpenEBS 4
  creates only `openebs-hostpath`

- `openebs-jiva-default` (OpenEBS 2 only) provisioned 3 replicated Jiva pods per volume

  - data is stored in `/openebs` in the replica pods
  - `/openebs` is a localpath volume mapped to `/var/openebs/pvc-...` on the node

- `openebs-hostpath` uses LocalPV with local directories

  - volumes are hostpath volumes created in `/var/openebs/local` on each node

- `openebs-device` (OpenEBS 2 only) used LocalPV with local block devices

  - requires available disks and/or a bit of extra configuration
  - the default configuration filters out loop, LVM, MD devices

## When do we need custom StorageClasses?

- To store LocalPV hostpath volumes on a different path on the host

- To change the number of replicated Jiva pods

- To use a different Jiva pool

  (i.e. a different path on the host to store the Jiva volumes)

- To create a cStor pool

- ...

> [!note]- Extra details
> ## Defining a custom StorageClass
>
> Example for a LocalPV hostpath class using an extra mount on `/mnt/vol001`:
>
> ```yaml
> apiVersion: storage.k8s.io/v1
> kind: StorageClass
> metadata:
>   name: localpv-hostpath-mntvol001
>   annotations:
>     openebs.io/cas-type: local
>     cas.openebs.io/config: |
>       - name: BasePath
>         value: "/mnt/vol001"
>       - name: StorageType
>         value: "hostpath"
> provisioner: openebs.io/local
> volumeBindingMode: WaitForFirstConsumer
> ```
>
> - `provisioner` needs to be set accordingly
> - `volumeBindingMode: WaitForFirstConsumer` is required: a local volume is made on
>   the node of the first Pod that uses it
>
> > [!warning] Without it
> > Without `volumeBindingMode`, the class is `Immediate`. The
> > provisioner then fails with `configuration error, no node was specified`, and
> > the PVC stays `Pending` (tested with OpenEBS 4.6).
> - Storage engine is chosen by specifying the annotation `openebs.io/cas-type`
> - Storage engine configuration is set with the annotation `cas.openebs.io/config`

## Checking the default hostpath StorageClass

- Let's inspect the StorageClass that OpenEBS created for us

> [!example] Hands-on
> - Let's look at the OpenEBS LocalPV hostpath StorageClass:
>   ```bash
>   kubectl get storageclass openebs-hostpath -o yaml
>   ```

## Create a host path PVC

- Let's create a Persistent Volume Claim using an explicit StorageClass

> [!example] Hands-on
> ```bash
> kubectl apply -f - <<EOF
> kind: PersistentVolumeClaim
> apiVersion: v1
> metadata:
>   name: local-hostpath-pvc
> spec:
>   storageClassName: openebs-hostpath
>   accessModes:
>     - ReadWriteOnce
>   resources:
>     requests:
>       storage: 1G
> EOF
> ```

## `WaitForFirstConsumer`

- Did OpenEBS create a PV for our PVC?

> [!example] Hands-on
> - Find out:
>   ```bash
>   kubectl get pv,pvc
>   ```

- No!

- This is because that class is `WaitForFirstConsumer` instead of `Immediate`

## Create a Pod to consume the PV

> [!example] Hands-on
> - Create a Pod using that PVC:
>   ```bash
>   kubectl apply -f ~/container.training/k8s/openebs-pod.yaml
>   ```
>
> - Here are the sections that declare and use the volume:
>   ```yaml
>     volumes:
>     - name: storage
>       persistentVolumeClaim:
>         claimName: local-hostpath-pvc
>     containers:
>     ...
>       volumeMounts:
>       - mountPath: /mnt/storage
>         name: storage
>   ```

## Making sure that a PV was created for our PVC

- At that point, the `openebs-hostpath` StorageClass created a PV for our PVC

> [!example] Hands-on
> - Look at the PV and PVC:
>   ```bash
>   kubectl get pv,pvc
>   ```

## Verify that data is written on the node

- Let's find the file written by the Pod on the node where the Pod is running

> [!example] Hands-on
> - Get the worker node where the pod is located
>   ```bash
>   kubectl get pod openebs-local-hostpath-pod -ojsonpath={.spec.nodeName}
>   ```
>
> - SSH into the node
>
> - Check the volume content
>   ```bash
>   sudo tail /var/openebs/local/pvc-*/greet.txt
>   ```

## Heads up!

> [!note] With OpenEBS 4
> There is no Jiva class to use: replicated volumes now come from Replicated PV
> Mayastor, which needs hugepages, the NVMe-TCP kernel module and spare disks on 3
> nodes. That was not tested here (the tests run on kind). The commands below set
> `openebs-hostpath` as the default class instead: it works, but it does **not**
> replicate anything.

- The following labs and exercises will use the Jiva storage class

- This storage class creates 3 replicas by default

- It uses *anti-affinity* placement constraints to put these replicas on different nodes

- **This requires a cluster with multiple nodes!**

- It also requires the iSCSI client (aka *initiator*) to be installed on the nodes

- On many platforms, the iSCSI client is preinstalled and will start automatically

- If it doesn't, you might want to check [this documentation page] for details

[this documentation page]: https://docs.openebs.io/docs/next/prerequisites.html

## The default StorageClass

- The PVC that we defined earlier specified an explicit StorageClass

- We can also set a default StorageClass

- It will then be used for all PVC that *don't* specify an explicit StorageClass

- This is done with the annotation `storageclass.kubernetes.io/is-default-class`

> [!example] Hands-on
> - Check if we have a default StorageClass:
>   ```bash
>   kubectl get storageclasses
>   ```

- The default StorageClass (if there is one) is shown with `(default)`

## Setting a default StorageClass

- Let's set the default StorageClass to use `openebs-hostpath`

  (OpenEBS 4 has no `openebs-jiva-default`)

> [!example] Hands-on
> - Remove the annotation (just in case we already have a default class):
>   ```bash
>   kubectl annotate storageclass storageclass.kubernetes.io/is-default-class- --all
>   ```
>
> - Annotate the Jiva StorageClass:
>   ```bash
>   kubectl annotate storageclasses \
>     openebs-hostpath storageclass.kubernetes.io/is-default-class=true
>   ```
>
> - Check the result:
>   ```bash
>   kubectl get storageclasses
>   ```

## We're ready now!

- We have a StorageClass that can provision PersistentVolumes

- With Jiva (OpenEBS 2) or Mayastor (OpenEBS 4), these PersistentVolumes would be
  replicated across nodes, and could withstand single-node failures

- With `openebs-hostpath`, they live on one node: losing that node loses the volume

---

> [!info] Adapted from container.training
> This page is derived from [`slides/k8s/openebs.md`](https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/openebs.md)
> in **[container.training](https://github.com/jpetazzo/container.training)** by Jérôme Petazzoni and contributors,
> used under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).
> **Changes were made**: restructured from slides into a single page, remark
> markup converted to Obsidian callouts, referenced files inlined or linked,
> updated to OpenEBS 4.6 (install, engines), Local PV Hostpath labs tested on
> Kubernetes 1.37.

<!-- uplink -->
Part of [[kubernetes/storage/index|Storage]].
