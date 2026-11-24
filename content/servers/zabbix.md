---
title: Zabbix on Podman
description: Deploying the Zabbix monitoring stack as a Podman pod managed by a systemd user service
tags: [servers, monitoring, zabbix, podman, containers, observability]
type: howto
status: complete
---

# Zabbix on Podman

Zabbix monitors network parameters and the health and integrity of servers,
virtual machines, applications, services, databases, websites and cloud resources.

See [[containers/docker]] and [[containers/security]] for container background.

## Zabbix container images

Zabbix publishes an image for each of its components. They ship with support for
both MySQL and PostgreSQL, and for both Apache and nginx as the web front-end.

Running every component in a single **pod** means they share a network namespace,
so they reach each other on `127.0.0.1` — which is why every `DB_SERVER_HOST` below
is localhost.

> [!warning] Replace every password before using this
> The values below are placeholders. Anything passed with `-e` is visible in
> `podman inspect` and in the process environment. For anything real, use
> `--secret` or an env file with `600` permissions.

## Creating the pod

```bash
podman pod create --name zabbix -p 80:8080 -p 10051:10051
```

`10051` is the trapper port that agents and proxies report to; `8080` is the web
UI inside the pod, published here as `80`.

> [!note] Rootless Podman cannot publish port 80 by default
> This note runs the pod as a normal user (the systemd unit below is a `--user`
> unit). Ports below 1024 are privileged, so `-p 80:8080` fails with
> `permission denied`. Either publish a high port (`-p 8080:8080`), or lower the
> limit with a drop-in, as root:
>
> ```bash
> echo 'net.ipv4.ip_unprivileged_port_start=80' >/etc/sysctl.d/50-unprivileged-ports.conf
> sysctl -p /etc/sysctl.d/50-unprivileged-ports.conf
> ```
>
> The user also needs write access to the `/srv/zabbix` directories used below.

## MySQL container

Holds the Zabbix database:

```bash
podman run --name mysql-server \
  -e MYSQL_DATABASE="zabbix" \
  -e MYSQL_USER="zabbix" \
  -e MYSQL_PASSWORD="zabbix_pwd" \
  -e MYSQL_ROOT_PASSWORD="root_pwd" \
  -v /srv/zabbix/mysql/:/var/lib/mysql/:Z \
  --pod=zabbix -d docker.io/library/mysql:8.4 \
  --character-set-server=utf8mb4 \
  --collation-server=utf8mb4_bin \
  --log-bin-trust-function-creators=1
```

`--log-bin-trust-function-creators=1` lets the `zabbix` user create the triggers
in Zabbix's schema. MySQL has binary logging on by default, and without this
setting (or the `SUPER` privilege) the server container stops at
`ERROR 1419 ... You do not have the SUPER privilege and binary logging is enabled`
and never starts.

> [!warning] Correction: MySQL 8.4 and `mysql_native_password`
> The original pinned `mysql:8.0` with `utf8` and
> `--default-authentication-plugin=mysql_native_password`. MySQL 8.0 reached end
> of life in April 2026. `mysql_native_password` is deprecated since 8.0.34,
> disabled by default in 8.4 (not removed, as an earlier version of this note
> said) and removed in 9.0. Zabbix 7.0 connects with the default
> `caching_sha2_password`, and its schema wants `utf8mb4`. The original also
> lacked `--log-bin-trust-function-creators=1`, so a current Zabbix server could
> not create its schema.

## Zabbix server container

The central process: it polls data, evaluates triggers and sends notifications.
Agents and proxies report availability and health data to it. It can also check
network services (web, mail) remotely itself.

```bash
podman run --name zabbix-server-mysql \
  -e DB_SERVER_HOST="127.0.0.1" \
  -e MYSQL_DATABASE="zabbix" \
  -e MYSQL_USER="zabbix" \
  -e MYSQL_PASSWORD="zabbix_pwd" \
  -e ZBX_JAVAGATEWAY="127.0.0.1" \
  -e ZBX_JAVAGATEWAY_ENABLE="true" \
  -e ZBX_CACHESIZE="2G" \
  --pod=zabbix -d docker.io/zabbix/zabbix-server-mysql:alpine-7.0-latest
```

> [!note] Pin the Zabbix version
> The bare image names (`zabbix/zabbix-server-mysql`) mean `latest`, which moves
> to each new major release. The tags used here follow Zabbix 7.0 LTS. Keep all
> the components on the same version.

## Java gateway container

Only needed to monitor JMX applications. It is lightweight and needs no database.

```bash
podman run --name zabbix-java-gateway --pod=zabbix -d docker.io/zabbix/zabbix-java-gateway:alpine-7.0-latest
```

## Web front-end container

The web interface manages monitored resources and displays statistics.

```bash
podman run --name zabbix-web-mysql \
  -v /srv/zabbix/web/ssl.crt:/etc/ssl/apache2/ssl.crt:Z,U \
  -v /srv/zabbix/web/ssl.key:/etc/ssl/apache2/ssl.key:Z,U \
  -e ZBX_SERVER_HOST="127.0.0.1" \
  -e DB_SERVER_HOST="127.0.0.1" \
  -e MYSQL_DATABASE="zabbix" \
  -e MYSQL_USER="zabbix" \
  -e MYSQL_PASSWORD="zabbix_pwd" \
  --pod=zabbix -d docker.io/zabbix/zabbix-web-apache-mysql:alpine-7.0-latest
```

The certificate and key must exist before starting the container. For a self-signed
pair, or a real one, see [[security/cryptography/pki-and-x509]].

Apache in this image runs as user `zabbix` (UID 1997), and a private key is readable
by its owner only. `U` makes Podman give both files to that user. On the host they
then belong to a subordinate UID, so read them with `podman unshare cat` if needed.

> [!warning] Correction
> The original mounted the files with `:Z` only. In rootless Podman the key then
> belongs to root inside the container, Apache stops with `Permission denied: Can't
> open server private key file`, and the UI never answers.

## Agent container

The agent is normally deployed on each monitored target to watch local resources
and applications — disks, memory, CPU statistics. Here it monitors the Zabbix
server host itself.

```bash
podman run --name zabbix-agent \
  -e ZBX_HOSTNAME="Zabbix server" \
  -e ZBX_SERVER_HOST="127.0.0.1,localhost" \
  --pod=zabbix -d docker.io/zabbix/zabbix-agent:alpine-7.0-latest
```

## Running the pod as a service

So the pod comes back after a reboot, manage it with systemd. Create the user unit
directory:

```bash
mkdir -p ~/.config/systemd/user/
cd ~/.config/systemd/user/
```

Generate the unit files:

```bash
podman generate systemd --files --name zabbix
```

Reload the user daemon:

```bash
systemctl --user daemon-reload
```

Enable and start:

```bash
systemctl --user enable --now pod-zabbix.service
```

Check it is running:

```console
$ systemctl --user is-active pod-zabbix.service
active
```

> [!important] Rootless services need lingering
> A `--user` service stops when the user's last session ends, and does not start at
> boot. Enable lingering so it survives:
> `loginctl enable-linger $USER`

> [!warning] `podman generate systemd` is deprecated
> It still works, but prints a `DEPRECATED` warning. **Quadlet**, added in Podman
> 4.4, replaces it. For new deployments write `.pod`, `.container` and `.volume` files
> in `~/.config/containers/systemd/` and let Quadlet generate the units. The
> original notes also had `mkdir -p .conf/systemd/user/` — that path is a typo for
> `.config`, and a relative one, so the units landed somewhere systemd never reads.

<!-- uplink -->
Part of [[servers/index|Servers]].
