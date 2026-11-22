---
title: "Managing configuration"
description: "Passing configuration to containers: command-line arguments, environment variables, the downward API, and ConfigMaps as files or variables"
tags: [kubernetes, configuration]
type: lab
status: complete
source: https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/configuration.md
license: CC-BY-4.0
upstream_commit: 56563629
upstream_sync: manual
---

# Managing configuration

> [!important] These labs expect the upstream repository
> Commands below reference files by their path in a local clone. Get it with:
>
> ```bash
> git clone https://github.com/jpetazzo/container.training
> ```
>
> The manifests can also be browsed at the pinned commit
> [`56563629`](https://github.com/jpetazzo/container.training/tree/565636291ec03abf1f2ab8bf6b935478e00e69a2).

Most applications need some configuration. Our code can get its configuration in many
ways:

- command-line arguments;
- environment variables;
- configuration files;
- configuration servers (it reads its configuration from a database, an API...);
- and more, because programmers can be very creative.

How do we do these things with containers and Kubernetes?

## Passing configuration to containers

There are many ways to pass configuration to code that runs in a container:

- bake it into a custom image;
- command-line arguments;
- environment variables;
- inject configuration files;
- expose it over the Kubernetes API;
- configuration servers.

Let's review these strategies.

## Baking custom images

Put the configuration in the image. It can be a configuration file, but also `ENV` or
`CMD` instructions in the Dockerfile.

It is easy and simple. But it also has downsides:

- many more images;
- different images for dev, staging, prod...
- even a small change needs a whole build, push, and pull cycle.

Avoid it, unless you do not have the time to set up another option.

## Command-line arguments

Command-line arguments say what to run in the container. Set `command` and/or `args`
in the container options of a Pod template. Both `command` and `args` are arrays.

Example ([source](https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/k8s/consul-1.yaml#L71)):

```yaml
args:
- "agent"
- "-bootstrap-expect=3"
- "-retry-join=provider=k8s label_selector=\"app=consul\" namespace=\"$(NAMESPACE)\""
- "-client=0.0.0.0"
- "-data-dir=/consul/data"
- "-server"
- "-ui"
```

Kubernetes replaces `$(NAMESPACE)` with the value of the container's `NAMESPACE`
environment variable. This is not a shell: no shell runs, and `$NAMESPACE` (without
parentheses) stays as it is.

## `args` or `command`?

- `command` replaces the `ENTRYPOINT` of the image.
- `args` keeps the `ENTRYPOINT` of the image: the values in `args` are passed to it.
  They replace the `CMD` of the image.
- If in doubt, use `command`.
- You can also use *both* `command` and `args`. They are joined, just like
  `ENTRYPOINT` and `CMD`.

The [documentation](https://kubernetes.io/docs/tasks/inject-data-application/define-command-argument-container/#notes)
explains how they work together.

## Command-line arguments, pros & cons

- They work well when the options go straight to the program that runs. Otherwise, a
  wrapper script can help.
- They work well when there are not too many parameters. Nobody wants a 20-line
  `args` array.
- You need to know the program, or read its documentation: "which parameters and
  flags do I need, again?"
- They suit mandatory parameters, with no default value.
- They are not ideal when we have to pass a real configuration file anyway.

## Environment variables

Pass options with the `env` list in the container specification. Example:

```yaml
env:
- name: ADMIN_PORT
  value: "8080"
- name: ADMIN_AUTH
  value: Basic
- name: ADMIN_CRED
  value: "admin:0pensesame!"
```

> [!warning]
> `value` must be a string! Quote numbers and strings with special characters.

Why this `{name: xxx, value: yyy}` form, instead of a simple map? Because an entry can
use `valueFrom` instead of `value`, to get its value from somewhere else. The next
sections show how.

## The downward API

In the previous example, environment variables have fixed values. We can also use the
*downward API*. It exposes information about the Pod or the container:

- either as files (we will not show that here);
- or as environment variables.

Kubernetes computes the values of these environment variables when the container
starts. Remember: environment variables do not (cannot) change after the container
starts.

Let's see a few examples.

## Exposing the pod's namespace

```yaml
    - name: MY_POD_NAMESPACE
      valueFrom:
        fieldRef:
          fieldPath: metadata.namespace
```

This helps to build the FQDN (fully qualified domain name) of a Service. In some
contexts, a short name is not enough.

For example, these two commands should be equivalent:

```bash
curl api-backend
curl api-backend.$MY_POD_NAMESPACE.svc.cluster.local
```

## Exposing the pod's IP address

```yaml
    - name: MY_POD_IP
      valueFrom:
        fieldRef:
          fieldPath: status.podIP
```

This helps when the code needs to know its IP address. We could also read it from
`eth0`, but this is more reliable.

## Exposing the container's resource limits

```yaml
    - name: MY_MEM_LIMIT
      valueFrom:
        resourceFieldRef:
          containerName: test-container
          resource: limits.memory
```

This helps runtimes with garbage-collected memory, like the JVM. The memory available
to the JVM is set with the `-Xmx` flag.

Best practice: set a memory limit, and pass it to the runtime.

Recent versions of the JVM can do this automatically. See
[JDK-8146115](https://bugs.openjdk.org/browse/JDK-8146115), and
[this blog post](https://very-serio.us/2017/12/05/running-jvms-in-kubernetes/) for
detailed examples.

## More about the downward API

[This documentation page](https://kubernetes.io/docs/tasks/inject-data-application/environment-variable-expose-pod-information/)
tells more about these environment variables.

[This one](https://kubernetes.io/docs/tasks/inject-data-application/downward-api-volume-expose-pod-information/)
explains the other way to use the downward API: through files that Kubernetes creates
in the container's filesystem. It also lists all the fields that the downward API can
expose.

## Environment variables, pros and cons

- They work well when the program expects these variables.
- They work well for optional parameters with good defaults, since the image can
  provide these defaults.
- They are sort of self-documenting: we can see which environment variables the image
  defines, and their values.
- They can be (ab)used for long values. You *can* put an entire Tomcat configuration
  file in an environment variable. But *should* you?

Do it if you really need to, we are not judging! But there are better ways.

## Injecting configuration files

Sometimes there is no way around it: we need to inject a full configuration file.
Kubernetes has a resource for that: the ConfigMap.

A ConfigMap is a resource that exists in a Namespace. It is a key-value map: the
values are any strings. We can use it in (at least) two ways:

- to hold entire configuration files;
- to hold individual configuration parameters.

To hold sensitive information, use Secrets instead. They are another resource, and
behave very much like ConfigMaps. See
[[kubernetes/configuration/secrets|Managing secrets]].

## Configmaps storing entire files

Here, each key-value pair is a configuration file:

- key = name of the file;
- value = content of the file.

There can be one key-value pair, or as many as needed, for complex apps with several
configuration files.

Examples:

```bash
# Create a configmap with a single key, "app.conf"
kubectl create configmap my-app-config --from-file=app.conf
# Create a configmap with a single key, "app.conf" but another file
kubectl create configmap my-app-config --from-file=app.conf=app-prod.conf
# Create a configmap with multiple keys (one per file in the config.d directory)
kubectl create configmap my-app-config --from-file=config.d/
```

`--from-file=config.d/` takes only the regular files in the directory. It skips
subdirectories.

## Configmaps storing individual parameters

Here, each key-value pair is a parameter:

- key = name of the parameter;
- value = value of the parameter.

Examples:

```bash
# Create a configmap with two keys
kubectl create cm my-app-config \
    --from-literal=foreground=red \
    --from-literal=background=blue

# Create a configmap from a file containing key=val pairs
kubectl create cm my-app-config \
    --from-env-file=app.conf
```

## Exposing configmaps to containers

A ConfigMap can appear as plain files in the container's filesystem. We declare a
volume, and mount it in the container. This suits ConfigMaps that hold whole files.

A ConfigMap can also appear as environment variables in the container, with
`valueFrom.configMapKeyRef` (one key) or `envFrom` (all keys). This suits ConfigMaps
that hold individual parameters.

> [!warning] Correction
> The original page said that environment variables from a ConfigMap use "the
> downward API". They do not: they use `configMapKeyRef` or `envFrom`. The downward
> API exposes information about the Pod itself.

Let's see how to do both.

## Example: HAProxy configuration

We are going to deploy HAProxy, a popular load balancer. It expects its configuration
file in a specific place:

`/usr/local/etc/haproxy/haproxy.cfg`

We will create a ConfigMap that holds the configuration file. Then we will mount that
ConfigMap in a Pod that runs HAProxy.

## Blue/green load balancing

In this example, we deploy two versions of our app:

- the "blue" version in the `blue` Namespace;
- the "green" version in the `green` Namespace.

Each Namespace has a Deployment and a Service, both named `color`.

We want to balance traffic between both Namespaces. A simple Service selector cannot
do it: selectors do not cross Namespaces.

## Deploying the app

We use the image `jpetazzo/color`. It is a simple "HTTP echo" server: it shows which
Pod served the request.

We could create each Namespace, Deployment, and Service by hand. Or:

> [!example] Hands-on
> - Deploy the app with a YAML manifest:
>   ```bash
>   kubectl apply -f ~/container.training/k8s/rainbow.yaml
>   ```

It also creates a third version, in the `red` Namespace.

## Testing the app

Reminder: the Service `x` in the Namespace `y` is reachable as `x.y`, `x.y.svc`, and
`x.y.svc.cluster.local`. The `cluster.local` suffix can change from one cluster to
another, so we use `x.y.svc`.

> [!example] Hands-on
> - Check that the app is up and running:
>   ```bash
>   kubectl run --rm -it --restart=Never --image=curlimages/curl:8.17.0 my-test-pod \
>           -- curl -s color.blue.svc
>   ```

> [!note]
> The original command used the image `nixery.dev/curl`, which exists only for
> amd64. `curlimages/curl` is multi-architecture.

## Creating the HAProxy configuration

Here is the file that we will use, [`k8s/haproxy.cfg`](https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/k8s/haproxy.cfg):

```ini
global
  daemon

defaults
  mode tcp
  timeout connect 5s
  timeout client 50s
  timeout server 50s

listen very-basic-load-balancer
  bind *:80
  server blue color.blue.svc:80
  server green color.green.svc:80

### Note: the services above must exist,
### otherwise HAproxy won't start.
```

The official HAProxy image starts HAProxy in the foreground (`-db`), which overrides
`daemon`.

## Creating the ConfigMap

> [!example] Hands-on
> - Create a ConfigMap named `haproxy` that holds the configuration file:
>   ```bash
>   kubectl create configmap haproxy --from-file ~/container.training/k8s/haproxy.cfg
>   ```
>
> - Check what our ConfigMap looks like:
>   ```bash
>   kubectl get configmap haproxy -o yaml
>   ```

> [!warning] Correction
> The original command was `--from-file=~/container.training/k8s/haproxy.cfg`. The
> shell does not expand `~` after `--from-file=`, so `kubectl` gets a literal `~` and
> fails with "no such file or directory". Use a space instead of `=`, or `$HOME`.

## Using the ConfigMap

Here is a Pod manifest that uses that ConfigMap, adapted from
[`k8s/haproxy.yaml`](https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/k8s/haproxy.yaml):

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: haproxy
spec:
  volumes:
  - name: config
    configMap:
      name: haproxy
  containers:
  - name: haproxy
    image: haproxy:3.2
    volumeMounts:
    - name: config
      mountPath: /usr/local/etc/haproxy/
```

> [!warning] Correction
> The upstream manifest uses the image `haproxy:1`. That tag is HAProxy 1.9, which
> reached end of life in 2020. `haproxy:3.2` is a long-term support (LTS) version.

## Creating the Pod

> [!example] Hands-on
> - Create the HAProxy Pod:
>   ```bash
>   kubectl apply -f ~/container.training/k8s/haproxy.yaml
>   ```
>
> - Check the IP address allocated to the Pod:
>   ```bash
>   kubectl get pod haproxy -o wide
>   IP=$(kubectl get pod haproxy -o jsonpath='{.status.podIP}')
>   ```

## Testing our load balancer

If everything went well, we should see a perfect round robin: one request to `blue`,
one request to `green`, one request to `blue`, and so on.

> [!example] Hands-on
> - Send a few requests:
>   ```bash
>   for i in $(seq 10); do
>   curl $IP
>   done
>   ```

This works from a cluster node. If your machine cannot reach Pod IP addresses (with
kind or Docker Desktop, for example), send the requests from a Pod, then read its
logs:

```bash
kubectl run lb-test --restart=Never --image=curlimages/curl:8.17.0 \
        --env=IP=$IP -- sh -c 'for i in $(seq 10); do curl -s $IP; done'
kubectl wait --for=jsonpath='{.status.phase}'=Succeeded pod/lb-test
kubectl logs lb-test
kubectl delete pod lb-test
```

`kubectl run --rm -i` would be shorter, but it attaches to the Pod only once the
container runs, so the first answers can be lost.

## Exposing configmaps as environment variables

We are going to run a Docker registry on a custom port. By default, the registry
listens on port 5000. The environment variable `REGISTRY_HTTP_ADDR` changes it.

We store the address and port in a ConfigMap. Then we expose that ConfigMap as an
environment variable in the container.

## Creating the registry ConfigMap

> [!example] Hands-on
> - Our ConfigMap has a single key, `http.addr`:
>   ```bash
>   kubectl create configmap registry --from-literal=http.addr=0.0.0.0:80
>   ```
>
> - Check our ConfigMap:
>   ```bash
>   kubectl get configmap registry -o yaml
>   ```

## Using the registry ConfigMap

We use this Pod definition:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: registry
spec:
  containers:
  - name: registry
    image: registry
    env:
    - name: REGISTRY_HTTP_ADDR
      valueFrom:
        configMapKeyRef:
          name: registry
          key: http.addr
```

It is in [`k8s/registry.yaml`](https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/k8s/registry.yaml).

## Creating the registry Pod

> [!example] Hands-on
> - Create the registry Pod:
>   ```bash
>   kubectl apply -f ~/container.training/k8s/registry.yaml
>   ```
>
> - Check the IP address allocated to the Pod:
>   ```bash
>   kubectl get pod registry -o wide
>   IP=$(kubectl get pod registry -o jsonpath='{.status.podIP}')
>   ```
>
> - Confirm that the registry answers on port 80:
>   ```bash
>   curl $IP/v2/_catalog
>   ```

The registry has no images yet, so it answers `{"repositories":[]}`. As above, run
`curl` from a Pod if your machine cannot reach Pod IP addresses.

---

> [!info] Adapted from container.training
> This page is derived from [`slides/k8s/configuration.md`](https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/configuration.md)
> in **[container.training](https://github.com/jpetazzo/container.training)** by Jérôme Petazzoni and contributors,
> used under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).
> **Changes were made**: restructured from slides into a single page, remark
> markup converted to Obsidian callouts, referenced files inlined or linked.
> Rewritten as prose; `--from-file=~/...`, the `haproxy:1` image and the claim that
> ConfigMap variables use the downward API corrected; `jq` replaced with
> `jsonpath`, `nixery.dev/curl` with `curlimages/curl`; tips for kind added.

<!-- uplink -->
Part of [[kubernetes/configuration/index|Configuration and secrets]].
