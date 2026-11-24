---
title: Vaultwarden with rootless Podman
description: Deploying Vaultwarden as a rootless Podman pod on openSUSE MicroOS, with MariaDB and an nginx reverse proxy
tags: [servers, vaultwarden, podman, containers, nginx, mariadb, security, rootless]
type: howto
status: complete
---

# Vaultwarden with rootless Podman

The same stack as [[servers/vaultwarden-docker]], but rootless — no daemon and no
root-equivalent group, which is the main reason to prefer it for something holding
your passwords.

## Installing and configuring rootless Podman

```bash
transactional-update pkg install podman slirp4netns crun
```

> [!note] Networking backend
> Podman 5 uses **pasta** rather than `slirp4netns` for rootless networking by
> default, and it is pulled in as a dependency. Installing `slirp4netns` does no
> harm and is still needed on older releases.

### Kernel command line

Edit `/etc/default/grub`:

```bash
GRUB_CMDLINE_LINUX_DEFAULT="splash=silent mitigations=auto quiet security=selinux selinux=1 enforcing=1 systemd.unified_cgroup_hierarchy=1 cgroup_no_v1=all"
```

> [!note] The cgroup arguments are usually redundant now
> `systemd.unified_cgroup_hierarchy=1 cgroup_no_v1=all` forced cgroup v2, which
> rootless Podman needs for resource limits. Every current distribution — MicroOS
> included — boots cgroup v2 by default, so these are only needed on older systems.
> Confirm with `stat -fc %T /sys/fs/cgroup/`, which should print `cgroup2fs`. See
> [[linux/boot/systemd#Control groups]].

Then regenerate the GRUB config — see [[linux/boot/grub]]:

```bash
transactional-update grub.cfg
```

### Sysctl settings

Rootless containers cannot bind privileged ports. Use a drop-in rather than
editing `sysctl.conf`:

```bash
cat > /etc/sysctl.d/99-podman.conf <<'EOF'
net.ipv4.ip_unprivileged_port_start=443
EOF

sysctl --system
```

`net.ipv4.ip_unprivileged_port_start=443` lowers the privileged-port boundary so an
unprivileged process may bind 443 and above.

> [!warning] Correction
> The original also set `vm.max_map_count=262144`, saying MariaDB needs it. It
> does not: that is the Elasticsearch and OpenSearch requirement. MariaDB runs with
> the default value.

Reboot to pick up the kernel command line:

```bash
reboot
```

### Service user

```bash
useradd podman
loginctl enable-linger podman
```

`enable-linger` is what stops the containers being killed when the user logs out,
and lets them start at boot without a login session.

## Preparing the volumes

As the `podman` user:

```bash
mkdir -p ~/md-data ~/nx-data ~/vw-data
cd ~
```

Write `nx-data/vaultwarden.conf`:

```nginx
server {
  listen 443 ssl;
  http2 on;
  server_name vaultwarden;

  ssl_certificate     /etc/ssl/certs/vaultwarden.crt;
  ssl_certificate_key /etc/ssl/private/vaultwarden.key;

  location / {
    proxy_http_version 1.1;
    proxy_set_header "Connection" "";

    proxy_set_header Host              $host;
    proxy_set_header X-Real-IP         $remote_addr;
    proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_pass http://127.0.0.1:8080;
  }
}
```

Everything in a pod shares one network namespace, which is why the proxy target is
`127.0.0.1:8080` here rather than a container name as in the Compose version.

### Certificate

`nx-data/req.conf`:

```ini
[req]
distinguished_name = req_distinguished_name
x509_extensions    = v3_req
prompt             = no

[req_distinguished_name]
C  = FR
ST = Example State
L  = Example City
O  = Example Corp
OU = IT
CN = vaultwarden.internal.example.com

[v3_req]
keyUsage         = keyEncipherment, dataEncipherment
extendedKeyUsage = serverAuth
subjectAltName   = @alt_names

[alt_names]
DNS.1 = vaultwarden.internal.example.com
```

```bash
cd nx-data
openssl req -x509 -nodes -days 730 -newkey rsa:2048 \
  -keyout vaultwarden.key -out vaultwarden.crt \
  -config req.conf -extensions 'v3_req'
cd ..
```

## Creating the pod and containers

```bash
podman network create vaultwarden
podman pod create -n vaultwarden --network vaultwarden -p 443:443
```

MariaDB:

```bash
podman run -d --name mariadb-server --pod vaultwarden \
  -v ~/md-data:/var/lib/mysql:Z \
  -e MARIADB_ROOT_PASSWORD="<root password>" \
  -e MARIADB_PASSWORD="<user password>" \
  -e MARIADB_DATABASE="<database>" \
  -e MARIADB_USER="<user>" \
  docker.io/library/mariadb:latest
```

Vaultwarden:

```bash
podman run -d --name vaultwarden-server --pod vaultwarden \
  -v ~/vw-data:/data:Z \
  -e SIGNUPS_ALLOWED='false' \
  -e INVITATIONS_ALLOWED='false' \
  -e ADMIN_TOKEN='<argon2 hash of the admin token>' \
  -e ROCKET_PORT=8080 \
  -e DATABASE_URL='mysql://<user>:<password>@127.0.0.1/<database>' \
  docker.io/vaultwarden/server:latest
```

> [!warning] Never hardcode the admin token
> The original notes had a short plaintext password inline here. That token grants
> full access to the admin panel. Generate an Argon2 hash instead —
> `podman run --rm -it docker.io/vaultwarden/server /vaultwarden hash` — or omit the variable
> entirely to disable the admin panel.

nginx:

```bash
podman run -d --name nginx-server --pod vaultwarden \
  -v ~/nx-data/vaultwarden.conf:/etc/nginx/conf.d/default.conf:Z \
  -v ~/nx-data/vaultwarden.crt:/etc/ssl/certs/vaultwarden.crt:Z \
  -v ~/nx-data/vaultwarden.key:/etc/ssl/private/vaultwarden.key:Z \
  docker.io/library/nginx:latest
```

The `:Z` suffix relabels the volume for SELinux, which MicroOS enforces.

> [!note] Full image names
> The image names include their registry (`docker.io/...`). For a short name
> like `vaultwarden/server`, openSUSE's `registries.conf` makes Podman try
> `registry.opensuse.org`, then `registry.suse.com`, then `docker.io`. That is
> slower, and an image with the same name on an earlier registry would be used
> instead of the one you meant.

## Persisting the pod

Export the running pod to a Kubernetes-style manifest:

```bash
podman kube generate vaultwarden > vaultwarden.yml
```

To deploy from that manifest, the existing pod must be removed first — otherwise
the name is already taken:

```bash
podman pod stop vaultwarden
podman pod rm -f vaultwarden
podman kube play --network vaultwarden vaultwarden.yml
```

`podman kube play --replace` does the remove and the deploy in one step. The
manifest does not record the pod's network, hence `--network`. The original
commands, `podman generate kube` and `podman play kube`, are older names that
still work.

> [!note] Quadlet is the current answer
> `podman generate kube` is useful for inspecting or moving a deployment, but for
> something that should start at boot, write Quadlet units in
> `~/.config/containers/systemd/` (`vaultwarden.pod`, `mariadb.container`, …) and
> let systemd manage them. See [[servers/zabbix]] for the same consideration.

## Access

| What | URL |
| --- | --- |
| Web vault | `https://<host>/` |
| Admin panel | `https://<host>/admin/` |

<!-- uplink -->
Part of [[servers/index|Servers]].
