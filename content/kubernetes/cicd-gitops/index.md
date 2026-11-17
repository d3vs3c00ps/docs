---
title: "CI/CD and GitOps"
description: "Building images, and getting them deployed from a Git repository."
tags: [cicd-gitops]
type: moc
status: complete
---

<!-- generated-moc -->

# CI/CD and GitOps

Building images, and getting them deployed from a Git repository.


| Note | | What it covers |
| --- | --- | --- |
| [[kubernetes/cicd-gitops/argocd-advanced\|ArgoCD advanced patterns]] | concept | It's very common to deploy multiple apps or components following the same pattern |
| [[kubernetes/cicd-gitops/argocd\|ArgoCD]] | lab | We're going to implement a basic GitOps workflow with ArgoCD |
| [[kubernetes/cicd-gitops/build-with-docker\|Building images with the Docker Engine]] | lab | Until now, we have built our images manually, directly on a node |
| [[kubernetes/cicd-gitops/build-with-kaniko\|Building images with Kaniko]] | lab | Kaniko is an open source tool to build container images within Kubernetes |
| [[kubernetes/cicd-gitops/buildshiprun-dockerhub\|Using images from the Docker Hub]] | concept | For everyone's convenience, we took care of building DockerCoins images |
| [[kubernetes/cicd-gitops/buildshiprun-selfhosted\|Self-hosting our registry]] | lab | *Note: this section shows how to run the Docker |
| [[kubernetes/cicd-gitops/flux\|FluxCD]] | lab | We're going to implement a basic GitOps workflow with Flux |
| [[kubernetes/cicd-gitops/gitlab\|CI/CD with GitLab]] | concept | In this section, we will see how to set up a CI/CD pipeline with GitLab |
| [[kubernetes/cicd-gitops/gitworkflows\|Git-based workflows (GitOps)]] | concept | we don't know who deployed what and when |
| [[kubernetes/cicd-gitops/harbor\|Running a Harbor registry]] | concept | There are many open source registries available out there |
| [[kubernetes/cicd-gitops/kuik\|Kube Image Keeper]] | concept | Open source solution to improve registry availability |
| [[kubernetes/cicd-gitops/shippingimages\|Shipping images with a registry]] | concept | Initially, our app was running on a single node |
| [[kubernetes/cicd-gitops/tilt\|Tilt]] | concept | What does a development workflow look like? |

> [!info] Derived from container.training
> Pages in this section marked with a `source` in their frontmatter are
> derived from [container.training](https://github.com/jpetazzo/container.training)
> under CC BY 4.0, with changes. See [[attribution]].

Part of [[kubernetes/index|Kubernetes]].
