---
title: "Deploying with YAML"
description: "Generating, creating, applying, combining and pruning YAML manifests with kubectl"
tags: [kubernetes, kubectl]
type: lab
status: complete
source: https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/yamldeploy.md
license: CC-BY-4.0
upstream_commit: 56563629
upstream_sync: manual
---

# Deploying with YAML

So far, we created resources with these commands:

- `kubectl run`
- `kubectl create deployment`
- `kubectl expose`

We can also create resources directly from YAML manifests.

## Why use YAML? (1/3)

Some resources cannot be created easily with `kubectl`: for example DaemonSets,
StatefulSets, or webhook configurations. `kubectl create` has no subcommand for them.

Some features and fields are not available as `kubectl create` options: for example
resource limits, health checks, or volumes.

## Why use YAML? (2/3)

- Create a complicated resource with a single, simple command:
  `kubectl create -f stuff.yaml`
- Create *multiple* resources with a single, simple command:
  `kubectl create -f more-stuff.yaml` or `kubectl create -f directory-with-yaml/`
- Create resources from a remote manifest:
  `kubectl create -f https://.../.../stuff.yaml`
- Create and update resources:
  `kubectl apply -f stuff.yaml`

## Why use YAML? (3/3)

YAML lets us work *declaratively*. We describe what we want to run on Kubernetes:
the "desired state". Then tools like `kubectl`, Helm, kapp, Flux or Argo CD make it
happen: they "reconcile" the actual state with the desired state. This is very
similar to Terraform, for example.

> [!note]- Extra details
> ## Overrides and `kubectl set`
>
> Just so you know:
>
> - `kubectl run ... --overrides '{...}'` takes a JSON patch, applied on top of the
>   YAML that `kubectl` generates;
> - `kubectl set ...` changes images, service accounts, resources, and more.
>
> > [!warning] Correction
> > The original showed `kubectl create deployment ... --overrides`. That option
> > does not exist: `kubectl create deployment` fails with
> > `unknown flag: --overrides`. Only `kubectl run` has it.

## Various ways to write YAML

- Start from examples in the docs, tutorials, blog posts, or a chat assistant. It is
  the easiest option when getting started.
- Dump an existing resource with `kubectl get -o yaml ...`. The result has many extra
  fields: clean it up.
- Ask `kubectl` to generate the YAML, with `kubectl --dry-run=client -o yaml
  create/run ...`.
- Write it from scratch with our favorite editor. This is black belt level.

## Writing a Pod manifest

Let's use `kubectl --dry-run=client -o yaml`.

> [!example] Hands-on
> - Generate the Pod manifest:
>   ```bash
>   kubectl run --dry-run=client -o yaml purple --image=jpetazzo/color
>   ```
>
> - Save it to a file:
>   ```bash
>   kubectl run --dry-run=client -o yaml purple --image=jpetazzo/color > pod-purple.yaml
>   ```

## Running the Pod

Let's create the Pod with the manifest we just generated.

> [!example] Hands-on
> - Create all the resources (at this point, just our Pod) described in the manifest:
>   ```bash
>   kubectl create -f pod-purple.yaml
>   ```
>
> - Confirm that the Pod is running
>   ```bash
>   kubectl get pods
>   ```

> [!note]- Extra details
> ## Comparing with direct `kubectl run`
>
> The Pod should be the same as one created directly with `kubectl run`.
>
> > [!example] Hands-on
> > - Create a Pod directly with `kubectl run`:
> >   ```bash
> >   kubectl run yellow --image=jpetazzo/color
> >   ```
> >
> > - Compare both Pod manifests and status:
> >   ```bash
> >   kubectl get pod purple -o yaml
> >   kubectl get pod yellow -o yaml
> >   ```

## Generating a Deployment manifest

After a Pod, let's create a Deployment.

> [!example] Hands-on
> - Generate the YAML for a Deployment:
>   ```bash
>   kubectl create deployment purple --image=jpetazzo/color -o yaml --dry-run=client
>   ```
>
> - Save it to a file:
>   ```bash
>   kubectl create deployment purple --image=jpetazzo/color -o yaml --dry-run=client > deployment-purple.yaml
>   ```
>
> - And create the Deployment:
>   ```bash
>   kubectl create -f deployment-purple.yaml
>   ```

## Updating our Deployment

What if we want to scale that Deployment? We can use `kubectl scale`, or update the
YAML manifest. Let's update the manifest.

> [!example] Hands-on
> - Edit the YAML manifest:
>   ```bash
>   vim deployment-purple.yaml
>   ```
>
> - Find the line with `replicas: 1` and update the number of replicas

## Applying our changes

Problem: `kubectl create` does not update ("overwrite") existing resources.

> [!example] Hands-on
> - Try it out:
>   ```bash
>   kubectl create -f deployment-purple.yaml
>   # This gives an error ("AlreadyExists")
>   ```

So, what can we do?

## Updating resources

- Delete the Deployment and create it again. It works, but it causes downtime.
- Use `kubectl scale` or `kubectl edit` on the Deployment. It works, but it is
  cheating: we want to use YAML.
- Use `kubectl apply`.

## `kubectl apply` vs `create`

`kubectl create -f whatever.yaml`:

- creates resources if they don't exist;
- if resources already exist, leaves them alone and shows an error.

`kubectl apply -f whatever.yaml`:

- creates resources if they don't exist;
- if resources already exist, updates them to match the YAML file;
- stores the manifest in an *annotation* of the resource.

## Trying `kubectl apply`

> [!example] Hands-on
> - First, delete the Deployment:
>   ```bash
>   kubectl delete deployment purple
>   ```
>
> - Re-create it using `kubectl apply`:
>   ```bash
>   kubectl apply -f deployment-purple.yaml
>   ```
>
> - Edit the YAML manifest, change the number of replicas again:
>   ```bash
>   vim deployment-purple.yaml
>   ```
>
> - Apply the new manifest:
>   ```bash
>   kubectl apply -f deployment-purple.yaml
>   ```

## `create` → `apply`

What are the differences between `kubectl create -f` and `kubectl apply -f`?

- `kubectl apply` adds an annotation,
  `kubectl.kubernetes.io/last-applied-configuration`.
- `kubectl apply` makes an extra `GET` request, to get the existing object, or at
  least to check if there is one.

Otherwise, the result is the same. It is almost always better to use `kubectl apply`.
One exception: when we don't want the extra annotation, for example for huge objects
like some CustomResourceDefinitions (CRDs). An annotation is limited to 256 KiB.

From now on, we will almost always use `kubectl apply -f` instead of
`kubectl create -f`.

## Adding a Service

Let's generate the YAML for a Service that exposes our Deployment.

> [!example] Hands-on
> - Run `kubectl expose`, once again with `-o yaml --dry-run=client`:
>   ```bash
>   kubectl expose deployment purple --port 80 -o yaml --dry-run=client
>   ```
>
> - Save it to a file:
>   ```bash
>   kubectl expose deployment purple --port 80 -o yaml --dry-run=client > service-purple.yaml
>   ```

Note: if the Deployment does not exist, `kubectl expose` does not work, even with
`--dry-run=client`. It reads the Deployment to find the selector.

## What if the Deployment doesn't exist?

We can also use `kubectl create service`. The syntax is slightly different:
`--port` becomes `--tcp`, for some reason.

> [!example] Hands-on
> - Generate the YAML with `kubectl create service`:
>   ```bash
>   kubectl create service clusterip purple --tcp 80 -o yaml --dry-run=client
>   ```

## Combining manifests

We can put several resources in a single YAML file. We separate them with the
standard YAML document separator: `---` alone on its line.

> [!example] Hands-on
> - Generate a combined YAML file:
>   ```bash
>     for YAMLFILE in deployment-purple.yaml service-purple.yaml; do
>       echo ---
>       cat $YAMLFILE
>     done > app-purple.yaml
>   ```

> [!note]- Extra details
> ## Resource ordering
>
> *In general,* the order of the resources does not matter:
>
> - in many cases, resources do not reference each other directly. For example, a
>   Service can exist even if the matching Deployment does not;
> - in some cases, there is a short error, but Kubernetes retries and succeeds in
>   the end.
>
> One exception: a Namespace must be created *before* the resources in it.

## Using `-f` with other commands

We can also use `kubectl delete -f`, `kubectl label -f`, and more.

> [!example] Hands-on
> - Apply the resulting YAML file:
>   ```bash
>   kubectl apply -f app-purple.yaml
>   ```
>
> - Add a label to both the Deployment and the Service:
>   ```bash
>   kubectl label -f app-purple.yaml release=production
>   ```
>
> - Delete them:
>   ```bash
>   kubectl delete -f app-purple.yaml
>   ```

> [!note]- Extra details
> ## Pruning resources
>
> To *prune* means to remove the dead branches of a tree. `kubectl` can remove old
> resources with `kubectl apply -f ... --prune`. It removes resources that are not
> in the YAML file(s), but only the ones created with `kubectl apply` in the first
> place: the ones with the annotation
> `kubectl.kubernetes.io/last-applied-configuration`.
>
> `--prune` needs a selector (`-l`) or `--all`, or it fails with
> `all resources selected for prune without explicitly passing --all`. Its help
> still calls it alpha. Give every resource of the app the same label, and prune by
> that label, in one namespace. For example, to apply a directory and remove what was
> taken out of it:
>
> ```bash
> kubectl apply -n myapp -f directory-with-yaml/ --prune -l app=myapp
> ```
>
> Run it once with `--dry-run=server` first: it lists what would be pruned.
>
> > [!warning] Correction
> > The original example was `kubectl apply -f directory-with-yaml/ --prune --all`.
> > Do not use it. The default list of kinds to prune includes cluster-scoped kinds,
> > like Namespace and PersistentVolume. So `--prune --all` also deletes *every*
> > Namespace of the cluster that was created with `kubectl apply` and is not in your
> > directory, with everything in it. On a kind cluster, that includes
> > `local-path-storage`, which holds the storage provisioner. If you must use `--all`,
> > limit the kinds with `--prune-allowlist` (for example
> > `--prune-allowlist=core/v1/ConfigMap --prune-allowlist=apps/v1/Deployment`).

## Advantage of YAML

Using YAML, instead of `kubectl create <kind>`, lets us be *declarative*:

- the YAML describes the desired state of our cluster and applications;
- YAML can be stored, versioned, and archived, for example in git repositories;
- to change resources, we change the YAML files, instead of using
  `kubectl edit`/`scale`/`label`/etc.;
- changes can be reviewed before they are applied, with code reviews and pull
  requests;
- our version control system now has a full history of what we deploy.

## GitOps

This workflow is sometimes called "GitOps". Tools like Flux
([[kubernetes/cicd-gitops/flux]]) and Argo CD ([[kubernetes/cicd-gitops/argocd]])
help with it. It is like "Infrastructure-as-Code", but for app deployments.

> [!note]- Extra details
> ## Actually GitOps?
>
> There is some debate about the "true" definition of GitOps:
>
> *My applications are defined with manifests, templates, configurations...
> that are stored in source repositories with version control,
> and I only make changes to my applications by changing these files,
> like I would change source code.*
>
> vs
>
> *Same, but it's only "GitOps" if the deployment of the manifests is
> fully automated (as opposed to manually running commands like `kubectl apply`
> or more complex scripts or tools).*
>
> Your instructor may or may not have an opinion on the matter!

## YAML in practice

1. Get started with `kubectl create deployment` and `kubectl expose`, until you have
   something that works.
2. Then run these commands again, with `-o yaml --dry-run=client`, to generate and
   save YAML manifests.
3. Apply these manifests in a clean environment, for example a new Namespace.
4. Check that everything works. Tweak and repeat if needed.
5. Commit the YAML to a repository.

## "Day 2" YAML

Remove the fields you don't use: for example `creationTimestamp: null`, and most
`{}` values.

Check your YAML with linters:

- [kube-score](https://github.com/zegl/kube-score) (can be installed with krew);
- [kube-linter](https://github.com/stackrox/kube-linter).

Check live resources with tools like [Popeye](https://popeyecli.io/).

Like all linters, they need to be configured for your needs.

> [!note]- Extra details
> ## Specifying the namespace
>
> When we create resources from YAML manifests, the namespace is optional.
>
> If the manifest gives a namespace, the resources are created in that namespace.
> This is typical for things deployed only once per cluster: system components,
> cluster add-ons...
>
> If it does not, the resources are created in the current namespace. This is
> typical for things that may be deployed several times: applications (production,
> staging, feature branches...).

---

> [!info] Adapted from container.training
> This page is derived from [`slides/k8s/yamldeploy.md`](https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/yamldeploy.md)
> in **[container.training](https://github.com/jpetazzo/container.training)** by Jérôme Petazzoni and contributors,
> used under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).
> **Changes were made**: restructured from slides into a single page, remark
> markup converted to Obsidian callouts, referenced files inlined or linked.
> Rewritten as prose; `--overrides` corrected, and the `--prune` requirements and
> risks added.

<!-- uplink -->
Part of [[kubernetes/workloads/index|Workloads]].
