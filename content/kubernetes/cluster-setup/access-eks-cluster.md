---
title: "Accessing our EKS cluster"
description: "We also have a shared EKS cluster"
tags: [kubernetes, installation, aws, eks]
type: lab
status: complete
source: https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/access-eks-cluster.md
license: CC-BY-4.0
upstream_commit: 56563629
upstream_sync: manual
---

# Accessing our EKS cluster

> [!note] Not tested locally
> This lab needs the course's shared EKS cluster and an AWS account.

## Accessing our EKS cluster

- We also have a shared EKS cluster

- With individual IAM users

- Let's connect to this cluster!

## What we need

- `kubectl` (obviously!)

- `aws` CLI (recent-ish version)

  (or `aws` CLI + `aws-iam-authenticator` plugin)

- AWS API access key and secret access key

- AWS region

- EKS cluster name

## Setting up AWS credentials

- There are many ways to do this

- We're going to use environment variables

- You're welcome to use whatever you like (e.g. AWS profiles)

> [!example] Hands-on
> - Set the AWS region, API access key, and secret key:
>   ```bash
>   export AWS_DEFAULT_REGION=us-east-2
>   export AWS_ACCESS_KEY_ID=AKI...
>   export AWS_SECRET_ACCESS_KEY=xyz123...
>   ```
>
> - Check that the AWS API recognizes us:
>   ```bash
>   aws sts get-caller-identity
>   ```

## Updating our kubeconfig file

- Now we can use the AWS CLI to:

  - obtain the Kubernetes API address

  - register it in our kubeconfig file

> [!example] Hands-on
> - Update our kubeconfig file:
>   ```bash
>   aws eks update-kubeconfig --name fancy-clustername-1234
>   ```
>
> - Run some harmless command:
>   ```bash
>   kubectl version
>   ```

## Our resources

- We have the following permissions:

  - `view` in the `default` namespace

  - `edit` in the `container-training` namespace

  - `admin` in our personal namespace

- Our personal namespace is our IAM user name

  (but with dots replaced with dashes)

- For instance, user `ada.lovelace` has namespace `ada-lovelace`

## Deploying things

- Let's deploy DockerCoins in our personal namespace!

- Expose the Web UI with a `LoadBalancer` service

---

> [!info] Adapted from container.training
> This page is derived from [`slides/k8s/access-eks-cluster.md`](https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/access-eks-cluster.md)
> in **[container.training](https://github.com/jpetazzo/container.training)** by Jérôme Petazzoni and contributors,
> used under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).
> **Changes were made**: restructured from slides into a single page, remark
> markup converted to Obsidian callouts, referenced files inlined or linked,
> slide highlight backticks removed from commands, "not tested" notice added.

<!-- uplink -->
Part of [[kubernetes/cluster-setup/index|Cluster setup]].
