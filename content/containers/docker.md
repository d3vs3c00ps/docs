---
title: Docker
description: Installing Docker, the commands worth knowing, network modes, writing a Dockerfile, and complementary tooling
tags: [containers, docker, images, networking]
type: howto
status: complete
---

# Docker

## Vocabulary

| Term | Meaning |
| --- | --- |
| **Image** | a package containing all the code needed to run an application |
| **Container** | a started image |
| **Layer** | one filesystem diff in an image; images are stacks of layers |
| **Registry** | where images are stored and distributed from |

For the underlying kernel features see
virtual-interfaces and
systemd.

## Installation on openSUSE Leap

Docker comes from the distribution repositories:

```bash
zypper install docker docker-buildx docker-compose
systemctl enable --now docker
```

Add yourself to the `docker` group so the socket is usable without `sudo`, then
start a new login session:

```bash
usermod -aG docker "$USER"
newgrp docker
```

> [!warning] The `docker` group is root-equivalent
> Anyone in it can bind-mount `/` into a privileged container. On a shared host,
> prefer [[containers/podman|Podman]] in rootless mode, or leave the socket to
> `sudo`. See [[containers/security]].

> [!note] There is no `download.docker.com` repository for openSUSE
> Docker Inc. publishes `.deb` and `.rpm` repositories for Debian, Ubuntu, RHEL
> and Fedora only — there is no openSUSE build, so the `docker-ce` /
> `containerd.io` packages have no equivalent here. openSUSE maintains its own
> `docker` package instead, which is the supported route on Leap.
> See opensuse-leap.

> [!note] Compose is a plugin, not a standalone binary
> Leap 16's `docker-compose` package ships Compose v2 as a CLI plugin only
> (`/usr/lib/docker/cli-plugins/docker-compose`) — it puts no `docker-compose`
> in `$PATH`. Like `docker-buildx`, it adds a subcommand: `docker compose` —
> note the space, not the hyphen of the old v1 binary.

Run your first container:

```bash
docker run hello-world
```

After installation the host has a new network interface, `docker0`, which passes
container packets through IP masquerade — see iptables.

## Commands worth knowing

List images:

```bash
docker image ls --all
```

List containers:

```bash
docker container ls          # running only
docker container ls --all    # including stopped
docker container ls -aq      # IDs only, for scripting
docker ps -a                 # the older equivalent
```

Inspect an image or container:

```bash
docker inspect opensuse/leap:16
```

Installation information:

```bash
docker version
docker info
```

By default a container gets a random two-word name. To choose one, use `--name`:

```bash
docker run --name leap_ftw opensuse/leap:16
```

Read a container's standard output:

```bash
docker logs leap_ftw
docker logs -f leap_ftw    # follow
```

Start a container interactively (`-i`) with a pseudo-terminal (`-t`):

```bash
docker run -it opensuse/leap:16 /bin/bash
```

Run a command inside an **already running** container:

```bash
docker exec -it leap_ftw /bin/bash
docker exec -it leap_ftw date
```

> [!note] `run` and `exec` are not interchangeable
> `run` creates a *new* container
> from an image; `exec` attaches to one that is already running. Running `exec`
> against a stopped container fails.

Restart a container and reattach:

```bash
docker start leap_ftw
docker attach leap_ftw
```

Pause and unpause — this freezes the processes with the cgroup freezer rather than
signalling them:

```bash
docker pause leap_ftw
docker unpause leap_ftw
```

Save changes made inside a container as a new image:

```bash
docker commit leap_ftw my-nginx
```

> [!warning] `commit` is a debugging tool, not a build tool
> The resulting image is unreproducible — nothing records how it was made. Use a
> `Dockerfile` for anything you intend to keep. `commit` is genuinely useful for
> capturing a broken container's state before you destroy it.

Run a container publishing a port, in the background:

```bash
docker run -d -p 8080:80 nginx
```

Remove containers and images:

```bash
docker rm leap_ftw
docker rm $(docker ps -aq)          # every container
docker rmi $(docker images -q)      # every image
```

> [!tip] Cleaning up
> In practice, prefer the purpose-built commands:
>
> ```bash
> docker system prune -a    # unused containers, networks, images
> docker system df          # what is actually taking the space
> ```

## Networks

List the networks:

```console
$ docker network ls
NETWORK ID     NAME     DRIVER   SCOPE
182bf8a04984   bridge   bridge   local
e70bd15b7f9d   host     host     local
634398d60018   none     null     local
```

| Driver | Behaviour |
| --- | --- |
| `bridge` | the default. The container gets its own network namespace on a virtual bridge, and reaches the outside via NAT. Published ports are needed to reach it from outside. |
| `host` | the container **shares the host's network namespace**. It sees the host's interfaces directly, has no isolation, and needs no port publishing — a listener binds the host's port directly. |
| `none` | no interfaces except loopback. The container can only talk to itself. |

> [!warning] `host` is the least isolated mode
> Host mode *removes* network isolation: the container gets the host's full network
> access, external connectivity included.

Create a bridge network so containers on it can reach each other by name and reach
the outside — for a cluster under Molecule, for
instance:

```bash
docker network create -d bridge test
```

> [!tip] User-defined bridges give you DNS
> On the default `bridge` network containers can only reach each other by IP. On a
> network you created yourself, Docker runs an embedded DNS resolver so container
> names resolve. That is why Compose creates a network per project.

Remove a network:

```bash
docker network rm test
```

## Dockerfile

A Dockerfile describes your image and what goes in it. Create an empty directory and
a `Dockerfile` in it:

```dockerfile
# Use the official openSUSE Leap image as the base
FROM opensuse/leap:16.0

LABEL maintainer="your.name@example.com"
LABEL description="Webserver"
LABEL version="1"

# Document the port the container listens on
EXPOSE 80

# Install in a single layer, and clean up in the same one
RUN zypper --non-interactive install --no-recommends apache2 \
    && zypper clean --all

# The default docroot is empty, and an empty docroot answers 403
RUN echo "It works" > /srv/www/htdocs/index.html

CMD ["start_apache2", "-DFOREGROUND"]
```

> [!warning] Four Dockerfile traps
> - `FROM` must be the first instruction (only `ARG` may precede it). A `MAINTAINER`
>   before it fails the build at once.
> - `MAINTAINER` is deprecated in favour of `LABEL maintainer=`.
> - Run the package refresh and the install in one `RUN`, with `zypper clean --all`.
>   Each `RUN` is a layer, so metadata cached by a separate refresh is baked
>   permanently into the image.
> - Without a `CMD`, the image inherits the base image's shell and exits at once: it
>   never serves anything.

> [!note] No `apache2ctl` on openSUSE
> Debian's `apache2ctl` and the upstream `apachectl` do not exist in Leap 16's
> `apache2` package. SUSE wraps httpd in `start_apache2`, which builds the module
> and config flags from `/etc/sysconfig/apache2`; `-DFOREGROUND` keeps it in the
> foreground, which is what a container needs.

> [!note] zypper in a Dockerfile
> `--non-interactive` is what makes zypper scriptable — without it, it stops at
> the confirmation prompt and the build hangs. `--no-recommends` keeps
> recommended-but-unrequired packages out, which matters more on SUSE than on
> Debian because the default is to pull them in. The `opensuse/leap` image
> already sets `rpm.install.excludedocs`, so documentation is excluded for you.

Build it:

```bash
docker build -t apache .
```

> [!tip] Add a `.dockerignore`
> Without one, `docker build` sends the entire directory to the daemon as build
> context — including `.git`. That is slow and can leak files into the image.

## Complementary tooling

### dive

Visualises an image's layers, identifies wasted or duplicated space, and can report
results to a CI pipeline — [wagoodman/dive](https://github.com/wagoodman/dive).

The one on this list worth installing: it makes layer bloat immediately obvious.

### dockly

A terminal interface for Docker commands —
[lirantal/dockly](https://github.com/lirantal/dockly).

### lazydocker

The more actively maintained equivalent of dockly —
[jesseduffield/lazydocker](https://github.com/jesseduffield/lazydocker).

### hadolint

A Dockerfile linter. It would have caught three of the four Dockerfile problems
above — [hadolint/hadolint](https://github.com/hadolint/hadolint).

```bash
docker run --rm -i hadolint/hadolint < Dockerfile
```

## See also

- [[containers/security]] — hardening containers
- [[containers/podman]] — the daemonless, rootless alternative
- vaultwarden-docker — a worked Compose deployment
- [[kubernetes/index]] — orchestrating containers at scale

<!-- uplink -->
Part of [[containers/index|Containers]].
