---
title: Validating server configuration files
description: Syntax-check commands for common daemons, so a bad config is caught before the restart that would take the service down
tags: [servers, troubleshooting, operations, cheatsheet]
type: reference
status: complete
---

# Validating server configuration files

Almost every daemon can parse its configuration without applying it. Running the
check before `systemctl restart` is the difference between a caught typo and an
outage — and, on a remote host, between a working `sshd` and a lockout.

> [!important] Check first, then reload, then restart
> Prefer `reload` over `restart` where the daemon supports it: existing connections
> survive, and a config the daemon refuses leaves the old one running. `restart`
> tears the service down first, so a bad config means downtime.

## Quick reference

| Service | Syntax check |
| --- | --- |
| Apache | `apachectl configtest` or `httpd -t` |
| BIND — config | `named-checkconf /etc/named.conf` |
| BIND — zone | `named-checkzone example.com /var/named/zone.example.com` |
| chrony | `chronyd -p` |
| ISC DHCPd | `dhcpd -t -cf /etc/dhcp/dhcpd.conf` |
| ISC DHCPd — lease db | `dhcpd -T -lf /var/lib/dhcpd/dhcpd.leases` |
| Kea DHCPv4 | `kea-dhcp4 -t /etc/kea/kea-dhcp4.conf` |
| MySQL 8.0.16+ | `mysqld --validate-config` |
| MariaDB | `mariadbd --verbose --help 1>/dev/null` |
| nginx | `nginx -t` |
| OpenLDAP (slapd) | `slapd -Tt -f /etc/openldap/slapd.conf` |
| Postfix | `postfix check` |
| rsyslog | `rsyslogd -N 1 -f /etc/rsyslog.conf` |
| Squid | `squid -k parse` |
| sshd | `sshd -t` |
| syslog-ng | `syslog-ng -svf /etc/syslog-ng/syslog-ng.conf` |
| sudoers | `visudo -c` |
| systemd unit | `systemd-analyze verify /path/to/unit.service` |

## Notes per service

### Apache

```bash
apachectl configtest      # check the syntax
httpd -t                  # the same check, run by the server binary
apachectl -S              # dump the parsed vhost layout (httpd -S on RHEL)
```

`apachectl` is in `apache2-utils` on openSUSE Leap 16, which has no `apache2ctl`.
`-S` is the one that finds the real problems — overlapping `ServerName`s and vhosts
matching in an order you did not intend. See [[servers/apache]].

### BIND

```bash
named-checkconf /etc/named.conf
named-checkzone example.com /var/named/zone.example.com
```

`named-checkconf -z` additionally loads every zone declared in the config, which
catches a valid config pointing at a broken zone file.

### chrony

```bash
chronyd -p
```

Parses the configuration, with every `include` and `confdir` file, prints it and
exits. A bad line stops it with `Fatal error : Invalid directive` and exit status 1.
It reads `/etc/chrony.conf`. On openSUSE Leap 16 the package's file is elsewhere,
so name it: `chronyd -p -f /usr/etc/chrony.conf`. See [[servers/chrony]].

> [!warning] Correction
> The original used `chronyd -Q`. That is not a syntax check: it starts a real
> measurement against the configured servers, waits for them, prints the offset
> and exits. With no reachable server it fails after ten seconds even when the
> configuration is valid.

### DHCPd

```bash
dhcpd -t                                        # syntax, default config path
dhcpd -t -cf /etc/dhcp/dhcpd.conf               # syntax, explicit config
dhcpd -T                                        # test the lease database
dhcpd -T -lf /var/lib/dhcpd/dhcpd.leases        # explicit lease file
```

| Option | Meaning |
| --- | --- |
| `-t` | check configuration syntax |
| `-T` | test the lease database |
| `-cf` | configuration file to test |
| `-lf` | lease database file to test |

The default paths differ: openSUSE uses `/etc/dhcpd.conf` and
`/var/lib/dhcp/db/dhcpd.leases`.

`-T` reports a damaged lease file as `possibly corrupt lease file`, but still
exits with status 0. Read its output; do not trust the exit status alone.

> [!warning] ISC DHCP is end of life
> ISC stopped maintaining its DHCP server in 2022. RHEL 10 no longer ships it;
> openSUSE Leap 16 still does. Its successor is Kea, whose servers check a
> configuration with `-t`:
>
> ```bash
> kea-dhcp4 -t /etc/kea/kea-dhcp4.conf
> ```
### MySQL

```bash
mysqld --validate-config                                      # MySQL 8.0.16 and later
mysqld --defaults-file=/root/test-my.cnf --validate-config
mariadbd --verbose --help 1>/dev/null                         # MariaDB
```

`--validate-config` reads the option files, reports unknown or invalid options
and exits. MariaDB has no such option: `--verbose --help` also reads every option
file and fails on an unknown option, and discarding stdout leaves only the errors.
On MariaDB, `mysqld` is a deprecated name for `mariadbd`. See [[servers/mysql]].

### nginx

```bash
nginx -t
nginx -T          # also dump the full resolved configuration
```

See [[servers/nginx]].

### OpenLDAP

```bash
slapd -Tt                                  # default config
slapd -Tt -f /etc/openldap/slapd.conf      # explicit file
```

On installations using the newer `slapd.d` config directory, use
`slaptest -F /etc/openldap/slapd.d`.

On openSUSE Leap 16 (package `openldap2_6`), the shipped `slapd.conf` uses the
`mdb` backend but leaves its `modulepath` and `moduleload back_mdb.la` lines
commented out, so the check fails with `Unrecognized database type (mdb)` until
you uncomment them.

`-Tt` also opens the databases. On a new server with no data yet it fails with
`bi_db_open failed`. Add `-u` (`slapd -Tt -u`) to check the configuration only.

### Postfix

```bash
postfix check
postconf -n       # show only settings that differ from the defaults
```

`postconf -n` is the fastest way to see what you have actually changed.

### rsyslog

```bash
rsyslogd -N 1 -f /etc/rsyslog.conf
```

`-N` sets config-check verbosity and exits without starting. See
[[linux/logging/rsyslog]].

### Squid

```bash
squid -k parse     # parse and report
squid -k check     # check a running instance
```

### sshd

```bash
sshd -t     # syntax check
sshd -T     # dump the full effective configuration
```

> [!warning] Always check sshd before restarting it
> This is the one where a mistake locks you out of the host. Keep a second session
> open while you do it. See [[linux/ssh]].

### syslog-ng

```bash
syslog-ng -svf /etc/syslog-ng/syslog-ng.conf
```

`-s` checks syntax and exits, `-v` explains why it failed, `-f` selects the file.
See [[linux/logging/syslog-ng]].

### sudoers

```bash
visudo -c                              # /etc/sudoers and every file it includes
visudo -cf /etc/sudoers.d/admins       # one file
```

On openSUSE Leap 16, the package installs `/usr/etc/sudoers` with mode `0444`,
and `visudo -c` reports `bad permissions, should be mode 0440` for it. Check
your own drop-in with `-cf` there.

### systemd units

```bash
systemd-analyze verify /etc/systemd/system/myapp.service
```

It fails (exit status 1) on a command that is not executable or a dependency
that does not exist. An unknown directive is only a warning (`Unknown key ...,
ignoring`), with exit status 0, so read the output, do not trust the exit status
alone. See [[linux/boot/systemd]].

<!-- uplink -->
Part of [[servers/index|Servers]].
