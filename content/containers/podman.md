---
title: Podman
description: The daemonless, rootless container engine — how it differs from Docker, pods, and running containers under systemd with Quadlet
tags: [containers, podman, rootless, systemd, quadlet]
type: concept
status: complete
---

# Podman

Podman runs containers without a daemon and, more importantly, without root. It
implements the same CLI as Docker, so `alias docker=podman` covers most day-to-day
use.

## How it differs from Docker

| | Docker | Podman |
| --- | --- | --- |
| Architecture | client talks to a long-running root daemon | no daemon; the CLI forks the container directly |
| Privileges | the `docker` group is root-equivalent | rootless by default, as an ordinary user |
| Process model | containers are children of the daemon | containers are children of your shell or of systemd |
| Init integration | the daemon supervises | systemd supervises, natively |
| Pods | no equivalent | first-class, and the same concept Kubernetes uses |

The daemonless design is the substantive difference. With Docker, anything that can
reach the socket can start a privileged container and own the host — see
[[containers/security#Do not run as root]]. With rootless Podman there is no
privileged component to reach: a container escape lands you in an unprivileged user
account.

## Rootless mechanics

Rootless containers rely on three things:

- **user namespaces** — the container's `root` maps to your unprivileged UID on the
  host. See virtual-interfaces.
- **subuid / subgid ranges** — the set of host UIDs your user may map into a
  container, from `/etc/subuid` and `/etc/subgid`.
- **pasta** (or `slirp4netns` on older versions) — user-mode networking, since an
  unprivileged process cannot create a veth pair on the host bridge.

Two consequences catch people out:

```bash
# unprivileged processes cannot bind ports below 1024
sysctl -w net.ipv4.ip_unprivileged_port_start=443
echo 'net.ipv4.ip_unprivileged_port_start = 443' > /etc/sysctl.d/50-unprivileged-ports.conf
```

The first line changes the running system, the second makes it last after a reboot.

```bash
# rootless containers stop when your last session ends, unless lingering is enabled
loginctl enable-linger "$USER"
```

Both are done in vaultwarden-podman.

Check your mappings resolve:

```bash
podman unshare cat /proc/self/uid_map
podman info --format '{{.Host.IDMappings}}'
```

### File ownership

The mapping above decides who owns what a container writes to a bind mount:

- A file written by `root` in the container belongs to **you** on the host: container
  UID 0 is your UID.
- A file written by any other user in the container belongs to a **subuid**. With the
  range starting at 100000, container UID 1000 is host UID 100999. `ls` shows that
  unfamiliar number, and you cannot edit the file directly.

`podman unshare` runs a command inside the mapping, where you are root. To take the
files back:

```bash
podman unshare chown -R 0:0 ./data
```

> [!note] Who owns the files
> Files written as `root` in the container belong to you on the host; files written
> by the container's other users get subuid owners.

## Pods

A **pod** is a group of containers sharing namespaces — network, and optionally IPC
and PID. Containers in a pod reach each other on `127.0.0.1`, which is why
zabbix points every component at localhost.

```bash
podman pod create --name mypod -p 8080:80
podman run -d --pod mypod --name web docker.io/library/nginx:alpine
podman run --rm --pod mypod docker.io/library/alpine wget -qO- http://127.0.0.1:80/
podman pod ps
```

The second container reaches nginx on `127.0.0.1`, because the pod shares one network
namespace. The port is published on the pod, not on a container. Stop and remove it
with `podman pod stop mypod` and `podman pod rm mypod`.

This is deliberately the same model as a Kubernetes pod — see
[[kubernetes/concepts/concepts-k8s]] — which is what makes the manifest export below
useful.

## Kubernetes interop

Generate a Kubernetes manifest from a running pod:

```bash
podman kube generate mypod > mypod.yml
```

And run one:

```bash
podman kube play mypod.yml
```

Useful for moving a local setup toward a cluster, or for inspecting what a pod
actually consists of. The pod must not already exist when you `play` a manifest that
names it; `podman kube play --replace` removes it first. The older spellings
`podman generate kube` and `podman play kube` still work.

## Running containers under systemd with Quadlet

This is the current answer to "how do I make my container start at boot". Write
declarative unit files in `~/.config/containers/systemd/` (or
`/etc/containers/systemd/` for root) and systemd generates the services:

```ini
# ~/.config/containers/systemd/myapp.container
[Unit]
Description=My application
After=network-online.target

[Container]
Image=ghcr.io/example/myapp:1.2.3
PublishPort=8080:80
Volume=%h/myapp-data:/data:Z
Environment=LOG_LEVEL=info

[Service]
Restart=always

[Install]
WantedBy=default.target
```

```bash
mkdir -p ~/myapp-data
systemctl --user daemon-reload
systemctl --user start myapp
```

The bind-mounted directory must exist: Podman does not create it, and the service
fails to start without it. The generated service is named after the file
(`myapp.service`), and the container `systemd-myapp`.

`.pod`, `.volume`, `.network` and `.image` files exist too, so a whole stack can be
declared this way. To see the units Quadlet would generate, without starting anything:
`/usr/lib/systemd/user-generators/podman-user-generator --dryrun`.

> [!warning] `podman generate systemd` is deprecated
> It was the previous approach and both zabbix and
> vaultwarden-podman use it. Podman 5 still has it but prints
> "DEPRECATED command". The units it generated embedded a full `podman run` command
> line, which was brittle. Quadlet is declarative and regenerates the units on every
> daemon-reload.

## Compose

Podman implements the Docker API socket, so `docker compose` works against it:

```bash
systemctl --user enable --now podman.socket
export DOCKER_HOST="unix://$XDG_RUNTIME_DIR/podman/podman.sock"
docker compose up -d
```

`podman-compose` also exists, but the socket approach is better supported.

## SELinux

> [!note] Not tested here
> The tests for this note run on a host without SELinux, so this section is not tested.

On SELinux systems — RHEL and its rebuilds, openSUSE Leap 16, MicroOS — volume mounts
need a relabel or the container cannot read them:

| Suffix | Effect |
| --- | --- |
| `:z` | shared label — several containers may access the volume |
| `:Z` | private label — only this container may access it |

```bash
podman run -v /srv/data:/data:Z myimage
```

Getting this wrong produces permission denied errors that look like ownership
problems but are not. `ausearch -m avc -ts recent` shows the actual denial.

## Where to go next

- [[containers/docker]] — the differences that matter when translating a command
- [[security/selinux]] — what the `:Z` above is actually doing
- [[ai/llama-cpp]] — a worked case of the awkward part of rootless containers: a GPU
  is not namespaced, so the device nodes and the driver have to be passed in, and
  rootless adds a further permissions problem on top

<!-- uplink -->
Part of [[containers/index|Containers]].
