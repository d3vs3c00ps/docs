---
title: "Creating a deployment, step by step"
description: "What each Kubernetes component does when you create a Deployment, in 19 diagrams"
tags: [kubernetes, architecture]
type: concept
status: complete
source: https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/deploymentslideshow.md
license: CC-BY-4.0
upstream_commit: 56563629
upstream_sync: manual
---

# Creating a deployment, step by step

## 19,000 words

They say "a picture is worth a thousand words". The 19 diagrams below show what
happens when you run:

```bash
kubectl create deployment web --image=nginx
```

In short:

1. `kubectl` sends a Deployment object to the API server, which stores it in etcd.
2. The Deployment controller (in the controller manager) sees the new Deployment. It
   creates a ReplicaSet.
3. The ReplicaSet controller sees the new ReplicaSet. It creates a Pod.
4. The scheduler sees a Pod with no node. It binds the Pod to a node.
5. The kubelet on that node sees the Pod. It asks the container runtime to pull the
   image and start the container.

Each component only talks to the API server. You can follow the chain yourself:

```bash
kubectl get deployment,replicaset,pod -l app=web
kubectl get events --field-selector involvedObject.kind=Pod
```

The events show `Scheduled` (from the scheduler), then `Pulled`, `Created` and
`Started` (from the kubelet).

![kubectl create deployment slideshow 01](kubernetes/_attachments/kubectl-create-deployment-slideshow-01.svg)

![kubectl create deployment slideshow 02](kubernetes/_attachments/kubectl-create-deployment-slideshow-02.svg)

![kubectl create deployment slideshow 03](kubernetes/_attachments/kubectl-create-deployment-slideshow-03.svg)

![kubectl create deployment slideshow 04](kubernetes/_attachments/kubectl-create-deployment-slideshow-04.svg)

![kubectl create deployment slideshow 05](kubernetes/_attachments/kubectl-create-deployment-slideshow-05.svg)

![kubectl create deployment slideshow 06](kubernetes/_attachments/kubectl-create-deployment-slideshow-06.svg)

![kubectl create deployment slideshow 07](kubernetes/_attachments/kubectl-create-deployment-slideshow-07.svg)

![kubectl create deployment slideshow 08](kubernetes/_attachments/kubectl-create-deployment-slideshow-08.svg)

![kubectl create deployment slideshow 09](kubernetes/_attachments/kubectl-create-deployment-slideshow-09.svg)

![kubectl create deployment slideshow 10](kubernetes/_attachments/kubectl-create-deployment-slideshow-10.svg)

![kubectl create deployment slideshow 11](kubernetes/_attachments/kubectl-create-deployment-slideshow-11.svg)

![kubectl create deployment slideshow 12](kubernetes/_attachments/kubectl-create-deployment-slideshow-12.svg)

![kubectl create deployment slideshow 13](kubernetes/_attachments/kubectl-create-deployment-slideshow-13.svg)

![kubectl create deployment slideshow 14](kubernetes/_attachments/kubectl-create-deployment-slideshow-14.svg)

![kubectl create deployment slideshow 15](kubernetes/_attachments/kubectl-create-deployment-slideshow-15.svg)

![kubectl create deployment slideshow 16](kubernetes/_attachments/kubectl-create-deployment-slideshow-16.svg)

![kubectl create deployment slideshow 17](kubernetes/_attachments/kubectl-create-deployment-slideshow-17.svg)

![kubectl create deployment slideshow 18](kubernetes/_attachments/kubectl-create-deployment-slideshow-18.svg)

![kubectl create deployment slideshow 19](kubernetes/_attachments/kubectl-create-deployment-slideshow-19.svg)

---

> [!info] Adapted from container.training
> This page is derived from [`slides/k8s/deploymentslideshow.md`](https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/deploymentslideshow.md)
> in **[container.training](https://github.com/jpetazzo/container.training)** by Jérôme Petazzoni and contributors,
> used under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).
> **Changes were made**: restructured from slides into a single page, remark
> markup converted to Obsidian callouts, referenced files inlined or linked.
> A text summary of the diagrams and commands to follow the chain added.

<!-- uplink -->
Part of [[kubernetes/concepts/index|Concepts]].
