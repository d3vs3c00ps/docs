---
title: Container security
description: Hardening containers — resource exhaustion, running as non-root, image hygiene, logging, healthchecks and restart policies
tags: [containers, docker, security, hardening]
type: reference
status: complete
---

# Container security

Notes on reducing the attack surface of a container deployment. See
[[containers/docker]] for the mechanics and [[containers/podman]] for the rootless
alternative, which addresses several of these points structurally.

## Resource exhaustion

A **fork bomb** — a process forking until resources are exhausted — is the simplest
denial of service available to anything running in a container. The straightforward
defence is to limit the number of tasks a single user can create, via `ulimit
nproc`:

```bash
docker run --pids-limit 100 --ulimit nproc=64:64 myimage
```

Also cap memory and CPU, or one container can starve every other on the host:

```bash
docker run --memory 512m --cpus 1.5 myimage
```

> [!important] Unlimited by default
> A container with no limits can consume all of the host's memory and CPU. The
> kernel's OOM killer then chooses a victim, which may well be something else
> entirely. Always set limits in production. Kubernetes expresses the same thing as
> requests and limits — see [[kubernetes/observability/resource-limits]].

## Do not run as root

A container started without a user runs as `root` — and, absent user namespace
remapping, that is the *host's* root. Prefer another user, specified in the
Dockerfile:

```dockerfile
RUN useradd --system --create-home --shell /usr/sbin/nologin app
USER app
```

The `USER` directive applies to every command executed afterwards in both the image
build and the running container. That prevents a process launched in the container
from running as root.

Or at runtime:

```bash
docker run --user 1000:1000 myimage
```

Additional hardening worth applying at the same time:

```bash
docker run \
  --read-only \
  --tmpfs /tmp \
  --cap-drop ALL \
  --security-opt no-new-privileges \
  myimage
```

| Flag | Effect |
| --- | --- |
| `--read-only` | the container filesystem is immutable; writes need an explicit mount |
| `--cap-drop ALL` | drop every Linux capability, then add back only what is needed |
| `--security-opt no-new-privileges` | the process cannot gain privileges via setuid binaries |

> [!warning] Membership of the `docker` group is equivalent to root
> Anyone who can talk to the Docker daemon can start a privileged container that
> mounts the host filesystem. No amount of in-container hardening changes that, which
> is the strongest argument for rootless [[containers/podman|Podman]].

## Networking

Disable inter-container communication on the default bridge, so containers cannot
reach each other unless deliberately placed on a shared network:

```json
// /etc/docker/daemon.json
{
  "icc": false
}
```

> [!note] Better still, use user-defined networks
> Setting `icc: false` is right, but the modern approach is to leave the
> default bridge unused entirely and put each application on its own user-defined
> network. Containers are then isolated by default *and* get DNS resolution — see
> [[containers/docker#Networks]].

## Logging

Send the output of processes running in containers to standard output. That makes it
easy to collect and forward to syslog, or to redirect to a specific file on the host
system.

This is the reason container images run their process in the foreground rather than
daemonising: the container runtime *is* the supervisor, and stdout is the log
transport.

```bash
docker run --log-driver syslog --log-opt syslog-address=tcp://siem.example.com:514 myimage
```

See rsyslog for the collector side.

> [!important] Bound the log size
> The default `json-file` driver has no limit, so a chatty container can fill the
> host's disk. Set it globally in `/etc/docker/daemon.json`:
>
> ```json
> {
>   "log-driver": "json-file",
>   "log-opts": { "max-size": "10m", "max-file": "3" }
> }
> ```

## Healthchecks

The `HEALTHCHECK` option runs a command periodically to verify the process in the
container is working:

```dockerfile
HEALTHCHECK --interval=30s --timeout=3s --retries=3 \
  CMD curl -fsS http://localhost/health || exit 1
```

Note that Docker only *reports* the status; it does not act on it. Restarting an
unhealthy container requires an orchestrator, or Compose's
`depends_on: condition: service_healthy`.

## Restart policy

Set `restart` to `always` for tests, and `on-failure` with a limit of 5 in
production, so a genuine problem becomes visible instead of being masked by an
endless restart loop:

```bash
docker run --restart on-failure:5 myimage
```

## Image hygiene

### Multi-stage builds

A multi-stage build lets you compile inside a container without leaving the
development libraries in the final image:

```dockerfile
FROM golang:1.23 AS build
WORKDIR /src
COPY . .
RUN CGO_ENABLED=0 go build -o /app ./cmd/app

FROM gcr.io/distroless/static:nonroot
COPY --from=build /app /app
USER nonroot:nonroot
ENTRYPOINT ["/app"]
```

Everything in the first stage — compiler, source, module cache — is discarded. Only
the binary is copied forward.

### Minimal base images

Alpine is a minimal Linux distribution that reduces both the footprint and the
attack surface. `distroless` images go further, containing no shell or package
manager at all — which also means no way to `exec` into them, a genuine trade-off
against debuggability.

> [!note] Alpine uses musl, not glibc
> That occasionally breaks software that assumes glibc, and can affect DNS
> resolution behaviour and performance in ways that are hard to diagnose. For a
> smaller image without changing libc, the openSUSE **BCI** images
> (`opensuse/bci/bci-micro`, `opensuse/bci/bci-minimal`) are the SUSE-native
> equivalent — glibc, and a fraction of the size of a full Leap image.

### Vulnerability scanning

Scan images for known vulnerabilities:

```bash
trivy image myimage:latest
docker scout cves myimage:latest
```

Wire one into CI so a base image that has drifted out of date fails the build.

> [!note] Docker Bench and `docker/labs`
> `docker-bench-security` still exists but has not kept pace; **Trivy** and
> **Docker Scout** are the current tools. The `docker/labs` security tutorials are
> archived.

### Use a private registry

Keep your own images in a private registry rather than pushing them to a public one,
and pin base images by digest rather than tag so a rebuild cannot silently pick up
different content:

```dockerfile
FROM opensuse/leap:16.0@sha256:1234abcd...
```

## Checklist

| Control | Mechanism |
| --- | --- |
| Not running as root | `USER` in the Dockerfile, `--user` at runtime |
| Capabilities dropped | `--cap-drop ALL` |
| No privilege escalation | `--security-opt no-new-privileges` |
| Immutable filesystem | `--read-only` plus explicit `--tmpfs` |
| Resource limits | `--memory`, `--cpus`, `--pids-limit` |
| Bounded logs | `max-size` / `max-file` log options |
| Network isolation | user-defined networks, `icc: false` |
| Small base image | `-slim`, Alpine or distroless |
| Reproducible base | pin by digest |
| Scanned | Trivy or Docker Scout in CI |
| Secrets not baked in | build secrets or runtime mounts, never `ENV` |

<!-- uplink -->
Part of [[containers/index|Containers]].
