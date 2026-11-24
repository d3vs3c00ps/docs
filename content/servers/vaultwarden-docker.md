---
title: Vaultwarden with Docker
description: Deploying Vaultwarden behind an nginx reverse proxy with MariaDB, using Docker Compose on openSUSE MicroOS
tags: [servers, vaultwarden, docker, containers, nginx, mariadb, security]
type: howto
status: complete
---

# Vaultwarden with Docker

Vaultwarden is a lightweight, self-hosted implementation of the Bitwarden server
API. This deploys it on openSUSE MicroOS with MariaDB and an nginx reverse proxy
terminating TLS.

For the rootless Podman version of the same stack see
[[servers/vaultwarden-podman]].

## Installing Docker

MicroOS is immutable, so packages are installed into a new snapshot:

```bash
transactional-update pkg install docker docker-compose
```

> [!important] Reboot to activate the snapshot
> `transactional-update` writes into a new btrfs snapshot which only becomes active
> after a reboot. Nothing you installed is available until then.

Allow a user to drive Docker:

```bash
usermod -aG docker <username>
```

> [!warning] The `docker` group is root-equivalent
> Anyone in it can start a privileged container and take over the host. This is
> exactly why the [[servers/vaultwarden-podman|Podman variant]] runs rootless.

## nginx reverse proxy

Vaultwarden must be reached over HTTPS, which means a reverse proxy in front.

Create the directory for nginx's files:

```bash
mkdir nx-data
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
    proxy_pass http://vaultwarden;
  }
}
```

> [!note] `listen ... http2` is deprecated
> Since nginx 1.25.1 HTTP/2 is enabled with a separate `http2 on;` directive, and
> `listen 443 ssl http2;` logs a deprecation warning.

### Self-signed certificate

Prepare `nx-data/req.conf`:

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
CN = vaultwarden.example.com

[v3_req]
keyUsage         = keyEncipherment, dataEncipherment
extendedKeyUsage = serverAuth
subjectAltName   = @alt_names

[alt_names]
DNS.1 = vaultwarden.example.com
```

Generate the key and certificate, writing them next to the nginx config so the
volume mounts below find them:

```bash
cd nx-data
openssl req -x509 -nodes -days 730 -newkey rsa:2048 \
  -keyout vaultwarden.key -out vaultwarden.crt \
  -config req.conf -extensions 'v3_req'
cd ..
```

See [[security/cryptography/pki-and-x509]] for the openssl detail, and for getting a real
certificate instead.

## MariaDB

Vaultwarden defaults to SQLite, which is perfectly adequate for a small instance.
A separate database such as MariaDB is optional.

```bash
mkdir mb-data
```

## Vaultwarden data

```bash
mkdir vw-data
```

## Compose file

`docker-compose.yml`, wiring the three containers together:

```yaml
services:
  mariadb:
    image: mariadb
    container_name: mariadb
    restart: always
    volumes:
      - ./mb-data:/var/lib/mysql
    environment:
      MARIADB_ROOT_PASSWORD: "<root password>"
      MARIADB_PASSWORD: "<database user password>"
      MARIADB_DATABASE: "<database name>"
      MARIADB_USER: "<database user>"

  vaultwarden:
    image: vaultwarden/server:latest
    container_name: vaultwarden
    restart: always
    depends_on:
      - mariadb
    environment:
      SIGNUPS_ALLOWED: "false"
      INVITATIONS_ALLOWED: "false"
      ADMIN_TOKEN: "<argon2 hash of the admin token>"
      DATABASE_URL: "mysql://<user>:<password>@mariadb/<database name>"
    volumes:
      - ./vw-data:/data

  nginx:
    image: nginx
    container_name: nginx
    restart: always
    depends_on:
      - vaultwarden
    volumes:
      - ./nx-data/vaultwarden.conf:/etc/nginx/conf.d/default.conf
      - ./nx-data/vaultwarden.crt:/etc/ssl/certs/vaultwarden.crt
      - ./nx-data/vaultwarden.key:/etc/ssl/private/vaultwarden.key
    ports:
      - "443:443"
```

> [!note] Two details
> - `depends_on:` is enough: containers on the default Compose network resolve each
>   other by service name, which is what makes `proxy_pass http://vaultwarden` work.
>   `links:` is legacy and unnecessary.
> - MariaDB's own `MARIADB_*` variables are preferred over the `MYSQL_*` aliases.

> [!warning] `ADMIN_TOKEN` should be a hash
> Current Vaultwarden expects an Argon2 PHC string rather than a plaintext token,
> and logs a warning if given plaintext. Generate one with:
> `docker run --rm -it vaultwarden/server /vaultwarden hash`
>
> The hash is full of `$` signs, which Compose reads as variables. In
> `docker-compose.yml`, write each `$` as `$$`, or Compose warns that a variable
> "is not set" and passes a broken token.
>
> Better still, leave `ADMIN_TOKEN` unset entirely — that disables the admin panel,
> which is the right choice unless you actively need it.

Bring the stack up:

```bash
docker compose up -d
```

## Access

| What | URL |
| --- | --- |
| Web vault | `https://<host>/` |
| Admin panel | `https://<host>/admin/` |

With `SIGNUPS_ALLOWED: "false"` you must create the first account through the
admin panel, or set it `true` briefly, register, then set it back.

<!-- uplink -->
Part of [[servers/index|Servers]].
