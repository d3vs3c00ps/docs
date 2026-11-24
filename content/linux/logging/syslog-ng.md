---
title: syslog-ng
description: Installing and configuring syslog-ng — sources, destinations, TLS-encrypted forwarding and troubleshooting
tags: [linux, logging, syslog, syslog-ng]
type: howto
status: complete
---

# syslog-ng

## Overview

`syslog-ng` is one of the two common syslog implementations on Linux, alongside
[[linux/logging/rsyslog]]. It is built around an explicit pipeline: you declare
**sources**, optional **filters** and **parsers**, and **destinations**, then join
them with `log { }` statements. That makes routing rules easier to read than
rsyslog's older `facility.severity` selector syntax, at the cost of being more
verbose.

For the protocol itself — message formats, the facility/severity matrix and
transport trade-offs — see [[linux/logging/syslog]].

## Installation

```bash
zypper install -y syslog-ng
```

On the RHEL family, `syslog-ng` is not in the base repositories and requires
[[linux/distributions/rhel#Enabling EPEL|EPEL]]:

```bash
dnf install "https://dl.fedoraproject.org/pub/epel/epel-release-latest-$(rpm -E %rhel).noarch.rpm"
dnf install -y syslog-ng
```

Since `rsyslog` is installed by default and the two would compete for the same
sockets, remove it:

```bash
dnf remove -y rsyslog
```

> [!note] Newer versions than EPEL ships
> EPEL tends to lag. Peter Czanik maintains current builds in a COPR repository,
> which is where you go if you need a recent feature:
> `dnf copr enable czanik/syslog-ng-stable`

## Enabling the service

```bash
systemctl enable --now syslog-ng
```

## Configuration

By default `syslog-ng` collects logs directly from `journald`, so you do **not**
need to ask `journald` to forward them. Confirm that in
`/etc/systemd/journald.conf`:

```ini
ForwardToSyslog=no
```

And that `syslog-ng` is reading the system source in
`/etc/syslog-ng/syslog-ng.conf`:

```text
source src {
    system();
    internal();
};
```

`system()` picks the right platform-specific inputs automatically; `internal()`
is syslog-ng's own log stream, which you want so that its errors are visible.

> [!important] The default source name differs per distribution
> This trips people up constantly when copying configuration between hosts:
>
> | Family | Default source name |
> | --- | --- |
> | SUSE | `src` |
> | RHEL | `s_sys` |
> | Debian | `s_src` |

## Forwarding logs unencrypted

Two steps. First declare the destination in `/etc/syslog-ng/syslog-ng.conf`:

```text
destination d_net {
    tcp("192.168.1.1" port(514));
};
```

Replace `tcp` with `udp` to send over UDP. The default port is 514 for both, but
can be changed.

Then tell `syslog-ng` which source goes to which destination — substituting your
distribution's source name from the table above:

```text
log {
    source(s_src);
    destination(d_net);
};
```

Restart the service:

```bash
systemctl restart syslog-ng
```

> [!tip] Prefer the `syslog()` driver for RFC5424
> `tcp()` and `udp()` emit legacy RFC3164. To send RFC5424 use
> `syslog("192.168.1.1" transport(tcp) port(601));` — 601 being the IANA-assigned
> port for it.

## Forwarding logs over TLS

Generate certificates and point the configuration at them. Get an unencrypted
forward working first — it removes half the variables when something doesn't work.

The client needs the CA certificate that signed the *server's* certificate.
`syslog-ng` looks certificates up in `ca_dir()` by subject hash, so the CA file
must be symlinked to `<hash>.0`:

```bash
mkdir -p /etc/syslog-ng/ca.d

# place the CA certificate, then find its subject hash
openssl x509 -noout -hash -in /etc/syslog-ng/ca.d/ca.crt
# -> aa19aea1

ln -s ca.crt /etc/syslog-ng/ca.d/aa19aea1.0
```

Then in `/etc/syslog-ng/syslog-ng.conf`:

```text
destination d_net {
    syslog("192.168.1.1"
        transport(tls)
        port(6514)
        tls(
            ca_dir("/etc/syslog-ng/ca.d")
            peer-verify(required-trusted)
        )
        log_fifo_size(1000)
    );
};

log { source(s_src); destination(d_net); };
```

> [!warning] The CA is not `cert_file`
> `ca_dir()`/`ca_file()` hold the CA used to **verify the server**, while
> `cert_file()` and `key_file()` are the client's *own* certificate and private key,
> needed only for mutual TLS. Passing the CA as `cert_file` does not establish trust.

If the collector requires client certificates, add them:

```text
        tls(
            ca_dir("/etc/syslog-ng/ca.d")
            cert_file("/etc/syslog-ng/cert.d/client.crt")
            key_file("/etc/syslog-ng/key.d/client.key")
            peer-verify(required-trusted)
        )
```

Restart to apply:

```bash
systemctl restart syslog-ng
```

> [!note] Port 6514
> 6514 is the IANA-registered port for syslog over TLS. Sending TLS to 514 works
> if the collector listens there, but 6514 is the convention.

## Troubleshooting

### Checking the configuration syntax

```bash
syslog-ng -svf /etc/syslog-ng/syslog-ng.conf
```

| Option | Meaning |
| --- | --- |
| `-s` | check the syntax and exit without starting |
| `-v` | verbose output, so you see *why* it failed |
| `-f` | check a specific configuration file |

See config-validation for the equivalent on other daemons.

### Running in a container

This error means capability management is unavailable, which is normal inside a
container:

```text
syslog-ng: Error setting capabilities, capability management disabled; error='Operation not permitted'
```

Disable it by adding this to `/etc/default/syslog-ng` (RHEL family, with the EPEL
package):

```bash
SYSLOGNG_OPTS="--no-caps"
```

On openSUSE, the unit reads `/etc/sysconfig/syslog` instead, and the variable is
`SYSLOG_NG_PARAMS`:

```bash
SYSLOG_NG_PARAMS="--no-caps"
```

<!-- uplink -->
Part of [[linux/logging/index|Logging]].
