---
title: nginx
description: Managing an nginx web server or reverse proxy — cache clearing, hardening, rate limiting and upload size
tags: [servers, nginx, web, reverse-proxy, security]
type: howto
status: complete
---

# nginx

Managing an nginx web server or reverse proxy. See [[servers/apache]] for the
Apache equivalents and [[security/cryptography/pki-and-x509]] for TLS.

## Clearing the cache

The cache lives in the directory named by `proxy_cache_path` (or
`fastcgi_cache_path`). `/var/cache/nginx/` is a common choice. Packages differ: nginx.org's
packages create that directory, openSUSE Leap's does not.

```bash
find /var/cache/nginx/ -type f -delete
```

nginx notices that a file is gone and fetches the response again, so the next
request is fresh at once. Only the cache index (the `keys_zone` in shared memory)
still lists the deleted entries; nginx clears those itself as it goes, or you can
reload:

```bash
systemctl reload nginx
```

> [!note] No reload needed
> nginx does not serve cached bodies from memory: they are always read from the
> files, so deleting them is enough.

## Testing the configuration

```bash
nginx -t
nginx -t -c /etc/nginx/nginx.conf
```

See [[servers/config-validation]] for other daemons.

## Hardening

### `server_tokens`

As on Apache, this controls what the `Server` response header reveals — the
server's version, and by implication which vulnerabilities might apply. Set it in
`/etc/nginx/nginx.conf`:

```nginx
server_tokens off;
```

> [!note] It only removes the version, not the product
> nginx will still send `Server: nginx`. Removing that entirely requires the
> third-party `headers-more` module (`more_clear_headers Server;`) or nginx Plus.

### Limiting concurrent connections per IP

```nginx
limit_conn_zone $binary_remote_addr zone=limit_per_ip:10m;
limit_conn limit_per_ip 20;
```

This limits each client IP to 20 simultaneous connections.

### Limiting request rate per IP

```nginx
limit_req_zone $binary_remote_addr zone=allips:10m rate=200r/s;
limit_req zone=allips burst=200 nodelay;
```

This limits each client IP to 200 requests per second, allowing a burst of 200
above that before rejecting.

> [!warning] `10m` is memory, not time
> `10m` is the **size of the shared memory zone** that holds the per-IP state:
> 10 megabytes, enough for roughly 160,000 IPv4 addresses. It has nothing to do with
> duration. The rate is set only by `rate=` for `limit_req`, and `limit_conn` has no
> time component at all, since it counts connections currently open.

Both limits run after the rewrite phase. A `location` that answers with `return`
is never limited, because `return` ends the request first.

`limit_req` returns `503` by default when the limit is exceeded; `limit_req_status
429` is usually more accurate. Both directives belong in the `http` block, with
`limit_conn`/`limit_req` optionally narrowed to a `server` or `location`.

### Increasing the maximum upload size

To allow larger uploads through nginx — in front of a file server, for instance —
set this in the `http` block of `/etc/nginx/nginx.conf`:

```nginx
client_max_body_size 20M;
```

The default is `1m`, and exceeding it returns `413 Request Entity Too Large`. When
proxying, remember the backend has its own limit too.

<!-- uplink -->
Part of [[servers/index|Servers]].
