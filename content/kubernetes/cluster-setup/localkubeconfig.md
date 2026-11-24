---
title: "Controlling a Kubernetes cluster remotely"
description: "kubectl can be used either on cluster instances or outside the cluster"
tags: [kubernetes, installation]
type: lab
status: complete
source: https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/localkubeconfig.md
license: CC-BY-4.0
upstream_commit: 56563629
upstream_sync: manual
---

# Controlling a Kubernetes cluster remotely

- `kubectl` can be used either on cluster instances or outside the cluster

- Here, we are going to use `kubectl` from our local machine

## Requirements

> [!warning]
> The commands in this chapter should be run *on your local machine*.

- `kubectl` is officially available on Linux, macOS, Windows

  (and unofficially anywhere we can build and run Go binaries)

- You may skip these commands if you are following along from:

  - a tablet or phone

  - a web-based terminal

  - an environment where you can't install and run new binaries

## Installing `kubectl`

- If you already have `kubectl` on your local machine, you can skip this

> [!example] Hands-on
> - Download the `kubectl` binary for your system from `dl.k8s.io`, e.g. for Linux on
>   amd64 (replace `linux` with `darwin` or `windows`, and `amd64` with `arm64` if
>   needed; on Windows the file is `kubectl.exe`):
>   ```bash
>   curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
>   ```
>   (or use a package manager: see the
>   [install guide](https://kubernetes.io/docs/tasks/tools/#kubectl))
>
> - On Linux and macOS, make the binary executable with `chmod +x kubectl`
>
>   (And remember to run it with `./kubectl` or move it to your `$PATH`)

> [!note] Where to get `kubectl`
> `dl.k8s.io` is the official download host. `kubectl` is supported within one minor
> version of the API server.

Note: if you are following along with a phone or tablet, installing `kubectl` might be impossible, so feel free to skip this section.

## Testing `kubectl`

- Check that `kubectl` works correctly

  (before even trying to connect to a remote cluster!)

> [!example] Hands-on
> - Ask `kubectl` to show its version number:
>   ```bash
>   kubectl version --client
>   ```

The output should look like this:
```
Client Version: v1.37.1
Kustomize Version: v5.8.1
```

(Before Kubernetes 1.28, the output was one long `version.Info{...}` structure; add
`-o yaml` to see all the details.)

## Preserving the existing `~/.kube/config`

- If you already have a `~/.kube/config` file, rename it

  (we are going to overwrite it in the following slides!)

- If you never used `kubectl` on your machine before: nothing to do!

> [!example] Hands-on
> - Make a copy of `~/.kube/config`; if you are using macOS or Linux, you can do:
>   ```bash
>   cp ~/.kube/config ~/.kube/config.before.training
>   ```
>
> - If you are using Windows, you will need to adapt this command

## Copying the configuration file from `node1`

- The `~/.kube/config` file that is on `node1` contains all the credentials we need

- Let's copy it over!

> [!example] Hands-on
> - Copy the file from `node1`; if you are using macOS or Linux, you can do:
>   ```
>   scp USER@X.X.X.X:.kube/config ~/.kube/config
>   # Make sure to replace X.X.X.X with the IP address of node1,
>   # and USER with the user name used to log into node1!
>   ```
>
> - If you are using Windows, adapt these instructions to your SSH client

## Updating the server address

- There is a good chance that we need to update the server address

- To know if it is necessary, run `kubectl config view`

- Look for the `server:` address:

  - if it matches the public IP address of `node1`, you're good!

  - if it is anything else (especially a private IP address), update it!

- To update the server address, run:
  ```bash
  kubectl config set-cluster kubernetes --server=https://X.X.X.X:6443
  # Make sure to replace X.X.X.X with the IP address of node1!
  ```

> [!note]- Extra details
> ## What if we get a certificate error?
>
> - Generally, the Kubernetes API uses a certificate that is valid for:
>
>   - `kubernetes`
>   - `kubernetes.default`
>   - `kubernetes.default.svc`
>   - `kubernetes.default.svc.cluster.local`
>   - the ClusterIP address of the `kubernetes` service
>   - the hostname of the node hosting the control plane (e.g. `node1`)
>   - the IP address of the node hosting the control plane
>
> - On most clouds, the IP address of the node is an internal IP address
>
> - ... And we are going to connect over the external IP address
>
> - ... And that external IP address was not used when creating the certificate!

> [!note]- Extra details
> ## Working around the certificate error
>
> - We need to tell `kubectl` to skip TLS verification
>
>   (only do this with testing clusters, never in production!)
>
> - The following command will do the trick:
>   ```bash
>   kubectl config set-cluster kubernetes --insecure-skip-tls-verify
>   ```

## Checking that we can connect to the cluster

- We can now run a couple of trivial commands to check that all is well

> [!example] Hands-on
> - Check the versions of the local client and remote server:
>   ```bash
>   kubectl version
>   ```
>
> - View the nodes of the cluster:
>   ```bash
>   kubectl get nodes
>   ```

We can now utilize the cluster exactly as if we're logged into a node, except that it's remote.

---

> [!info] Adapted from container.training
> This page is derived from [`slides/k8s/localkubeconfig.md`](https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/localkubeconfig.md)
> in **[container.training](https://github.com/jpetazzo/container.training)** by Jérôme Petazzoni and contributors,
> used under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).
> **Changes were made**: restructured from slides into a single page, remark
> markup converted to Obsidian callouts, referenced files inlined or linked,
> download links and version output updated, tested with kubectl 1.37.

<!-- uplink -->
Part of [[kubernetes/cluster-setup/index|Cluster setup]].
