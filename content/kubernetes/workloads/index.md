---
title: "Workloads"
description: "Running things: the kubectl verbs, deployments and rollouts, jobs, and how scheduling decisions are influenced."
tags: [workloads]
type: moc
status: complete
---

<!-- generated-moc -->

# Workloads

Running things: the kubectl verbs, deployments and rollouts, jobs, and how scheduling decisions are influenced.


| Note | | What it covers |
| --- | --- | --- |
| [[kubernetes/workloads/batch-jobs\|Executing batch jobs]] | lab | Jobs and CronJobs — retries, completions and parallelism, deadlines, schedules, overlap and clean-up |
| [[kubernetes/workloads/daemonset\|Daemon sets]] | lab | Running one rng Pod per node with a DaemonSet, then using labels and selectors to take Pods in and out of a Service |
| [[kubernetes/workloads/demo-apps\|Our demo apps]] | lab | The color and DockerCoins demo apps used in the labs, and the container.training repository that holds their manifests |
| [[kubernetes/workloads/disruptions\|Disruptions]] | concept | Voluntary and involuntary disruptions, node failures, eviction under pressure, and Pod Disruption Budgets |
| [[kubernetes/workloads/exercise-wordsmith\|Exercise — deploying on Kubernetes]] | lab | Exercise: deploy the three-tier wordsmith app with kubectl create deployment and kubectl expose |
| [[kubernetes/workloads/exercise-yaml\|Exercise — writing YAML]] | lab | Exercise: write YAML manifests for the wordsmith app, and test them in a new namespace |
| [[kubernetes/workloads/kubectl-logs\|Revisiting `kubectl logs`]] | lab | Reading the logs of several Pods at once with kubectl logs, and its limits |
| [[kubernetes/workloads/kubectl-run\|Running our first containers on Kubernetes]] | lab | Running a first Pod with kubectl run, reading its logs, and why Deployments and ReplicaSets exist |
| [[kubernetes/workloads/kubectlexpose\|Exposing containers]] | lab | Exposing Pods with Services: kubectl expose, ClusterIP, load balancing and DNS names |
| [[kubernetes/workloads/kubectlget\|First contact with `kubectl`]] | lab | First contact with kubectl: get, describe, output formats, jq, namespaces and the kubernetes Service |
| [[kubernetes/workloads/kubectlproxy\|Accessing the API with `kubectl proxy`]] | lab | Using kubectl proxy to reach the Kubernetes API, and Services, without handling credentials |
| [[kubernetes/workloads/kubectlscale\|Scaling a deployment]] | lab | Scaling the DockerCoins worker Deployment with kubectl scale, and watching Pods and Deployments change |
| [[kubernetes/workloads/kubercoins\|Deploying a sample application]] | lab | Deploying DockerCoins, a demo app with five microservices, and looking at its logs and web UI |
| [[kubernetes/workloads/labels-annotations\|Labels and annotations]] | lab | Labels and annotations on Kubernetes resources: viewing, setting, selecting, and their size limits |
| [[kubernetes/workloads/namespaces\|Namespaces]] | lab | Namespaces: creating them, switching the active one, DNS between Namespaces, and why they do not isolate workloads |
| [[kubernetes/workloads/ourapponkube\|Running our application on Kubernetes]] | lab | Deploying DockerCoins with kubectl create deployment and kubectl expose, then reaching its web UI through a NodePort |
| [[kubernetes/workloads/record\|Recording deployment actions]] | lab | The change-cause annotation, the deprecated --record flag, and why the rollout history can show the wrong cause |
| [[kubernetes/workloads/rollout\|Rolling updates]] | lab | How a Deployment replaces its Pods progressively, what maxUnavailable and maxSurge do, and how to roll back |
| [[kubernetes/workloads/scalingdockercoins\|Scaling our demo app]] | lab | Scaling the DockerCoins workers, hitting a limit at 10 hashes per second, and finding the slow service with httping |
| [[kubernetes/workloads/taints-and-tolerations\|Taints and tolerations]] | concept | Taints keep Pods off a node unless they tolerate them: effects, operators, tolerationSeconds and taint-based evictions |
| [[kubernetes/workloads/yamldeploy\|Deploying with YAML]] | lab | Generating, creating, applying, combining and pruning YAML manifests with kubectl |

> [!info] Derived from container.training
> Pages in this section marked with a `source` in their frontmatter are
> derived from [container.training](https://github.com/jpetazzo/container.training)
> under CC BY 4.0, with changes. See [[attribution]].

Part of [[kubernetes/index|Kubernetes]].
