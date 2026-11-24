---
title: "Bento & RabbitMQ"
description: "In some of the previous runs, messages were dropped"
tags: [kubernetes, mlops]
type: concept
status: complete
source: https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/bento-rmq.md
license: CC-BY-4.0
upstream_commit: 56563629
upstream_sync: manual
---

# Bento & RabbitMQ

- In some of the previous runs, messages were dropped

  (we start with 1000 messages in `cities` and have e.g. 955 in `mayors`)

- This is caused by various errors during processing

  (e.g. too many timeouts; Bento being shutdown halfway through...)

- ...And by the fact that we are using a Redis queue

  (which doesn't offer delivery guarantees or acknowledgements)

- Can we get something better?

## The problem

- Some inputs (like `redis_list`) don't support *acknowledgements*

- When a message is pulled from the queue, it is deleted immediately

- If the message is lost for any reason, it is lost permanently

## The solution

- Some inputs (like `amqp_0_9`) support acknowledgements

- When a message is pulled from the queue:

  - it is not visible anymore to other consumers

  - it needs to be explicitly acknowledged

- The acknowledgement is done by Bento when the message reaches the output

- The acknowledgement deletes the message

- No acknowledgement after a while? Consumer crashes/disconnects?

  Message gets requeued automatically!

## `amqp_0_9`

- Protocol used by RabbitMQ

- Very simplified behavior:

  - messages are published to an [*exchange*][amqp-exchanges]

  - messages have a *routing key*

  - the exchange routes the message to one (or zero or more) queues
    (possibly using the routing key or message headers to decide which queue(s))

  - [*consumers*][amqp-consumers] subscribe to queues to receive messages

[amqp-exchanges]: https://www.rabbitmq.com/tutorials/amqp-concepts#exchanges
[amqp-consumers]: https://www.rabbitmq.com/tutorials/amqp-concepts#consumers

## Using the default exchange

- There is a default exchange (called `""` - empty string)

- The routing key indicates the name of the queue to deliver to

- The queue needs to exist (we need to create it beforehand)

> [!note]- Extra details
> ## Defining custom exchanges
>
> - Create an exchange
>
>   - exchange types: direct, fanout, topic, headers
>
>   - durability: persisted to disk to survive server restart or not?
>
> - Create a binding
>
>   - which exchange?
>
>   - which routing key? (for direct exchanges)
>
>   - which queue?

## RabbitMQ on Kubernetes

- RabbitMQ can be deployed on Kubernetes:

  - directly (creating e.g. a StatefulSet)

  - with the RabbitMQ operator

- We're going to do the latter!

- The operator includes the "topology operator"

  (to configure queues, exchanges, and bindings through custom resources)

## Installing the RabbitMQ operator

- Let's install the operator and the topology operator from their releases

  (both operators get their webhook certificates from cert-manager, so it comes first):

  ```bash
  kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.21.3/cert-manager.yaml
  kubectl -n cert-manager wait deploy --all --for=condition=Available --timeout=5m
  kubectl apply -f https://github.com/rabbitmq/cluster-operator/releases/download/v2.23.2/cluster-operator.yml
  kubectl apply -f https://github.com/rabbitmq/messaging-topology-operator/releases/download/v1.20.5/messaging-topology-operator-with-certmanager.yaml
  ```

> [!warning] Not the Bitnami chart
> Since Bitnami stopped publishing free images (2025), the images in the Bitnami
> `rabbitmq-cluster-operator` Helm chart no longer exist
> (`docker.io/bitnami/rabbitmq-cluster-operator:2.16.1-debian-12-r0` is gone), so its
> pods cannot start. The official manifests above work.

## Deploying a simple RabbitMQ cluster

- Let's use the YAML manifests in that directory:

  https://github.com/jpetazzo/beyond-load-balancers/tree/main/rabbitmq

- This creates:

  - a `RabbitmqCluster` called `mq`

  - a `Secret` called `mq-default-user` containing access credentials

  - a durable `Queue` named `q1`

(We can ignore the `Exchange` and the `Binding`, we won't use them.)

The directory also has a `ServiceMonitor`: it needs the Prometheus Operator CRDs
(e.g. from kube-prometheus-stack). Without them, apply only `cluster.yml` and `queue.yml`.

## 🏗️ Let's build something!

Let's replace the `cities` Redis list with our RabbitMQ queue.

(See next slide for steps and hints!)

## Steps

1. Edit the Bento configuration for our "CSV importer".

   (replace the `redis_list` output with `amqp_0_9`)

2. Run that pipeline and confirm that messages show up in RabbitMQ.

3. Edit the Bento configuration for the Ollama consumer.

   (replace the `redis_list` input with `amqp_0_9`)

4. Trigger a scale up of the Ollama consumer.

5. Update the KEDA Scaler to use RabbitMQ instead of Redis.

## 1️⃣ Sending messages to RabbitMQ

- Edit our Bento configuration (the one feeding the CSV file to Redis)

- We want the following `output` section:
  ```yaml
    output:
      amqp_0_9:
        exchange: ""
        key: q1
        mandatory: true
        urls:
         - "${AMQP_URL}"
  ```

- Then export the AMQP_URL environment variable using `connection_string` from Secret `mq-default-user`

💡 Yes, we can directly use environment variables in Bento configuration!

## 2️⃣ Testing our AMQP output

- Run the Bento pipeline

- To check that our messages made it:
  ```bash
  kubectl exec mq-server-0 -- rabbitmqctl list_queues
  ```

- We can also use Prometheus metrics, e.g. `rabbitmq_queue_messages`

## 3️⃣ Receiving messages from RabbitMQ

- Edit our other Bento configuration (the one in the Ollama consumer Pod)

- We want the following `input` section:
  ```yaml
    input:
      amqp_0_9:
        urls:
          - "${AMQP_URL}"
        queue: q1
  ```

## 4️⃣ Triggering Ollama scale up

- If the autoscaler is configured to scale to zero, disable it

  (easiest solution: delete the ScaledObject)

- Then manually scale the Deployment to e.g. 4 Pods

- Check that messages are processed and show up in the output

  (it should still be a Redis list at this point)

## 5️⃣ Autoscaling on RabbitMQ

- We need to update our ScaledObject

- Check the [RabbitMQ Queue Scaler][keda-rabbitmq]

- Multiple ways to pass the AMQP URL:

  - hardcode it (easier solution for testing!)

  - use `...fromEnv` and set environment variables in target pod

  - create and use a TriggerAuthentication

💡 Since we have the AMQP URL in a Secret, TriggerAuthentication works great!

[keda-rabbitmq]: https://keda.sh/docs/latest/scalers/rabbitmq-queue/

---

> [!info] Adapted from container.training
> This page is derived from [`slides/k8s/bento-rmq.md`](https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/bento-rmq.md)
> in **[container.training](https://github.com/jpetazzo/container.training)** by Jérôme Petazzoni and contributors,
> used under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).
> **Changes were made**: restructured from slides into a single page, remark
> markup converted to Obsidian callouts, referenced files inlined or linked,
> Bitnami operator chart replaced by the official manifests (cert-manager first),
> tested on kind.

<!-- uplink -->
Part of [[kubernetes/mlops/index|MLOps]].
