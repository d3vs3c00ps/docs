---
title: Apache
description: Hardening and tuning Apache 2 — information disclosure, mod_evasive, access control and choosing an MPM
tags: [servers, apache, web, security, performance, tuning]
type: howto
status: complete
---

# Apache

Hardening and tuning Apache 2. See [[servers/nginx]] for the nginx equivalents and
[[security/cryptography/pki-and-x509]] for TLS.

## Testing the configuration

```bash
apachectl configtest      # check the syntax
httpd -t                  # the same check, run by the server binary
apachectl -S              # dump the parsed vhost layout
```

On openSUSE Leap 16, `apachectl` is in the `apache2-utils` package, which the
`apache2` package does not pull in: `zypper install apache2-utils`. RHEL's
`apachectl` refuses `-S` ("option is not supported"): run `httpd -S` there.

> [!note] `apachectl` on Leap 16
> Leap 16 has no `apache2ctl`: the script is `apachectl`, as on RHEL.

`-S` finds the problems a syntax check cannot: overlapping `ServerName`s, and
vhosts matching in an order you did not intend. See
[[servers/config-validation]].

## Hardening

Start by reducing the attack surface: limit what the server discloses about
itself. On openSUSE this is `/etc/apache2/httpd.conf`, with per-vhost files in
`/etc/apache2/vhosts.d/*.conf`.

> [!note] SUSE drives Apache from `/etc/sysconfig/apache2`
> The module list (`APACHE_MODULES`), server flags (`APACHE_SERVER_FLAGS`) and
> the config path (`APACHE_HTTPD_CONF`) are set there, and `apache2ctl`
> regenerates the generated include files from it. Use `a2enmod`/`a2dismod` and
> `a2enflag`/`a2disflag` rather than editing the generated files by hand.

Reference: [Apache core directives](https://httpd.apache.org/docs/current/mod/core.html).

### ServerTokens

Controls the `Server` response header, which can otherwise reveal the operating
system and details of the compiled-in modules.

| Value | Example header |
| --- | --- |
| `Full` (default if unset) | `Server: Apache/2.4.2 (Unix) PHP/4.2.2 MyMod/1.2` |
| `OS` | `Server: Apache/2.4.2 (Unix)` |
| `Min[imal]` | `Server: Apache/2.4.2` |
| `Minor` | `Server: Apache/2.4` |
| `Major` | `Server: Apache/2` |
| `Prod[uctOnly]` | `Server: Apache` |

This applies server-wide and cannot be set per virtual host.

`ServerTokens Prod` is the best choice — it is the minimum Apache will emit.

### ServerSignature

Sets a footer line on server-generated documents: error pages, `mod_proxy` FTP
directory listings, `mod_info` output. In a chain of proxies the user often has no
way to tell which proxy generated an error, which is one reason such a footer gets
added in the first place.

The default `Off` removes the footer. `On` adds the server version and the vhost's
`ServerName`; `EMail` additionally adds a `mailto:` reference to the `ServerAdmin`
address.

To stay consistent with `ServerTokens Prod`, set:

```apache
ServerSignature Off
```

### mod_evasive

`mod_evasive` limits the damage from a DoS attack:

```bash
zypper install apache2-mod_evasive
a2enmod evasive24
```

The package ships version 1.10 of the module, `mod_evasive24.so`, with a default
configuration in `/etc/apache2/conf.d/mod_evasive.conf`.

> [!warning] The module is `evasive24`
> `a2enmod evasive` adds a name that loads nothing, and an `<IfModule mod_evasive20.c>`
> test is false, so Apache skips every setting inside it without an error. The
> package is in the Leap 16 repositories.

Then put your settings in `/etc/apache2/conf.d/mod_evasive.conf`:

```apache
<IfModule mod_evasive24.c>
    DOSHashtableSize    3097
    DOSPageCount        4
    DOSSiteCount        100
    DOSPageInterval     1
    DOSSiteInterval     1
    DOSBlockingPeriod   3600
    DOSEmailNotify      admin@example.com
    DOSLogDir           "/var/log/mod_evasive"
</IfModule>
```

| Directive | Meaning |
| --- | --- |
| `DOSHashTableSize` | size of the hash table — can consume a significant amount of RAM |
| `DOSPageInterval` | window in seconds for counting requests to a single page |
| `DOSSiteInterval` | window in seconds for counting requests to the whole site |
| `DOSPageCount` | requests allowed per page within `DOSPageInterval` before the IP is blocked |
| `DOSSiteCount` | requests allowed per site within `DOSSiteInterval` before the IP is blocked |
| `DOSBlockingPeriod` | seconds the IP stays blocked, during which the server returns `403` |
| `DOSEmailNotify` | send an alert email — note it shells out to `/bin/mail` |
| `DOSWhitelist` | an IP that will never be blocked (one per line) |
| `DOSLogDir` | where to write the log files |
| `DOSSystemCommand` | command to run when an IP is blocked |

> [!warning] `mod_evasive` is per-process
> Its counters live in each child process's own hash table, so with a
> multi-process MPM the effective threshold is roughly your configured value
> multiplied by the number of children. It mitigates crude floods; it is not a
> substitute for a WAF or upstream rate limiting.

### Limiting connections

You can also cap simultaneous and persistent connections. For a personal server:

```apache
MaxRequestWorkers 150
KeepAlive On
MaxKeepAliveRequests 100
KeepAliveTimeout 5
```

> [!note] `MaxClients` was renamed
> It became `MaxRequestWorkers` in Apache 2.3. The old name still works as an alias
> but the new one is what current documentation uses.

### Access control

Access is handled by `mod_authz_core`. There are three kinds of container:

| Container | Applies to |
| --- | --- |
| `<Directory>` | a directory on the server's filesystem |
| `<Location>` | a path in the website's URL space |
| `<Files>` | a file |

Deny everything by default and permit only what is needed:

```apache
<Directory />
    Require all denied
</Directory>
```

> [!warning] Apache 2.2 syntax is deprecated
> Older guides use the 2.2 form:
>
> ```apache
> <Directory />
>     Order deny,allow
>     Deny from all
> </Directory>
> ```
>
> `Order`, `Allow` and `Deny` come from `mod_access_compat`. They are deprecated in
> 2.4 and mixing them with `Require` in the same context produces results almost
> nobody predicts correctly. Use `Require` alone:
> `Require all denied`, `Require all granted`, `Require ip 192.168.0.0/24`,
> `Require host example.com`.

### Options and AllowOverride

`Options` controls:

| Option | Effect |
| --- | --- |
| `FollowSymLinks` | follow symbolic links |
| `SymLinksIfOwnerMatch` | follow them only if link and target share an owner — the safer of the two |
| `ExecCGI` | allow CGI script execution — avoid wherever possible |
| `Includes` | Server Side Includes |
| `IncludesNOEXEC` | SSI without `#exec` and `#include` of CGI |
| `Indexes` | generate a directory index when no index file exists |
| `MultiViews` | content negotiation — a request for `index.html` may be served `index.html.en` or `index.html.fr` according to the browser's preference |
| `All` | every option except `MultiViews` |
| `None` | no options |

```apache
<Directory />
    Options SymLinksIfOwnerMatch
    AllowOverride None
</Directory>
```

`AllowOverride` determines what an `.htaccess` file is permitted to change. It
takes groups of directives, not `Options` values: `All`, `None`, `AuthConfig`,
`FileInfo`, `Indexes`, `Limit`, and `Options[=...]` (which `Options` an
`.htaccess` file may set). `None` also stops Apache looking for `.htaccess`
files at all, which is a measurable performance win.

> [!note] Different values
> `AllowOverride` does not take the same values as `Options`:
> `AllowOverride SymLinksIfOwnerMatch` is a syntax error.

### Testing the TLS configuration

Qualys' [SSL Server Test](https://www.ssllabs.com/ssltest/index.html).

## Useful commands

Reload without dropping connections:

```bash
apachectl -k graceful
systemctl reload apache2   # the same through systemd; the unit is httpd on RHEL
```

## Tuning

### Choosing an MPM

Apache uses a Multi-Processing Module to handle network connections, distribute
requests and bind ports. Exactly one MPM is active at a time.

Find out which one is in use:

```bash
httpd -V
```

| MPM | Model | When to use it |
| --- | --- | --- |
| **prefork** | multiple child processes, one thread each | the traditional default. Uses the most memory, but is the most robust because nothing is shared between threads — and the only safe choice with non-thread-safe libraries |
| **worker** | child processes with multiple threads each, one thread per connection | good for high-traffic servers thanks to a smaller memory footprint, but breaks with libraries or languages that are not thread-safe (older PHP being the classic case) |
| **event** | like worker, but hands idle keep-alive connections back to a listener thread | serves many more concurrent connections; Apache 2.4+ only, and the sensible default today |

> [!note] `--with-mpm` is a build-time flag
> `--with-mpm=(worker|prefork|event)` is passed to `./configure` when compiling
> Apache, not to a running server. On packaged installs you switch MPM by
> selecting it — on openSUSE, install `apache2-event`, set `APACHE_MPM="event"`
> in `/etc/sysconfig/apache2` and restart. On RHEL, uncomment the matching
> `LoadModule` line in `/etc/httpd/conf.modules.d/00-mpm.conf`.
>
> openSUSE's `a2enmod` has no `-m` option: `a2enmod -m event` does not work.

### MPM directives

#### StartServers — prefork, worker, event

Number of child processes created at startup.

#### MinSpareServers — prefork

The minimum number of idle processes waiting for a request. If the count falls
below this, Apache creates more (one per second in 2.2, up to 32 per second in
2.4). Keeping spare capacity is faster than creating processes on demand.

Rough guidance:

| RAM | MinSpareServers |
| --- | --- |
| 1–2 GB | 10 |
| 2–4 GB | 20 |
| 4 GB+ | 25 |

Raising it beyond reason is counterproductive — idle processes still cost memory.

#### MaxSpareServers — prefork

The maximum number of idle processes; beyond this they are stopped. If
`MaxSpareServers` is not greater than `MinSpareServers`, Apache silently raises
it to `MinSpareServers + 1`.

#### ServerLimit — prefork, worker, event

- **prefork**: the ceiling for `MaxRequestWorkers` (256 by default)
- **worker / event**: the ceiling on child processes

#### ThreadLimit — worker, event

The maximum value `ThreadsPerChild` may take, 64 by default. Setting it far too
high can destabilise the system.

#### ThreadsPerChild — worker, event

Threads created by each child process. One thread serves one request at a time.
The upper bound is `ThreadLimit`, so raising `ThreadsPerChild` past 64 means
raising `ThreadLimit` too.

Raising it lets each child handle more requests for less memory, because threads
in one process share their caches — something separate processes cannot do.

#### MaxRequestWorkers — prefork, worker, event

Was `MaxClients` before Apache 2.3.

The maximum number of simultaneous requests. Any beyond it are queued, up to
`ListenBacklog`. Too low throttles your clients; too high exhausts memory.

For `prefork` this equals the maximum number of child processes — 256 by default,
and raising it requires raising `ServerLimit` as well. `ServerLimit` should
generally equal `MaxRequestWorkers`.

There is no magic formula, but measuring the resident size of one Apache process
gives you:

```text
MaxRequestWorkers = (total RAM − OS and critical services) / size of one Apache process
```

#### MaxConnectionsPerChild — prefork, worker, event

How many connections a child process may serve before being recycled. This
contains memory leaks: once the threshold is reached the process exits and its
memory is reclaimed by a fresh one. `0` means never recycle, so a leaking process
lives forever.

A formula exists but needs good metrics:

```text
MaxConnectionsPerChild = daily requests / daily processes
```

`1000` is a common choice.

#### ExtendedStatus

Collects far more per-request statistics for `mod_status`, at a small cost to
performance. Since Apache 2.3.6 it is `On` by default when `mod_status` is
loaded, so set `ExtendedStatus Off` explicitly if you load `mod_status` and do
not need the per-request details.

> [!note] Already on
> With `mod_status` loaded, it is already on.

<!-- uplink -->
Part of [[servers/index|Servers]].
