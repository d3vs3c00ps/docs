---
title: "Extending Kubernetes"
description: "Custom resources, operators, and the API machinery underneath them."
tags: [extending]
type: moc
status: complete
---

<!-- generated-moc -->

# Extending Kubernetes

Custom resources, operators, and the API machinery underneath them.


| Note | | What it covers |
| --- | --- | --- |
| [[kubernetes/extending/aggregation-layer\|The Aggregation Layer]] | lab | The aggregation layer is a way to extend the Kubernetes API |
| [[kubernetes/extending/apiserver-deepdive\|API server internals]] | concept | when extending the Kubernetes API server (CRDs, webhooks...) |
| [[kubernetes/extending/crd\|Custom Resource Definitions]] | lab | CRDs are one of the (many) ways to extend the API |
| [[kubernetes/extending/eck\|An ElasticSearch Operator]] | lab | We will install Elastic Cloud on Kubernetes, an ElasticSearch operator |
| [[kubernetes/extending/events\|Events]] | lab | Kubernetes has an internal structured log of events |
| [[kubernetes/extending/extending-api\|Extending the Kubernetes API]] | concept | There are multiple ways to extend the Kubernetes API. |
| [[kubernetes/extending/finalizers\|Finalizers]] | concept | perhaps it's 'precious' (holds important data) |
| [[kubernetes/extending/kubebuilder\|Kubebuilder]] | concept | Writing a quick and dirty operator is (relatively) easy |
| [[kubernetes/extending/operators-design\|Designing an operator]] | concept | Once we understand CRDs and operators, it's tempting to use them everywhere |
| [[kubernetes/extending/operators-example\|Writing a tiny operator]] | concept | Let's look at a simple operator |
| [[kubernetes/extending/operators\|Operators]] | concept | Operators are software extensions to Kubernetes that make use of custom resources to manage applications and their components. Operators follow Kubernetes… |
| [[kubernetes/extending/owners-and-dependents\|Owners and dependents]] | lab | Some objects are created by other objects |

> [!info] Derived from container.training
> Pages in this section marked with a `source` in their frontmatter are
> derived from [container.training](https://github.com/jpetazzo/container.training)
> under CC BY 4.0, with changes. See [[attribution]].

Part of [[kubernetes/index|Kubernetes]].
