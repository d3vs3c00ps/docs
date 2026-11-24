---
title: "Servers"
description: "Configuring and operating the daemons: web servers, databases, directory and time services. The TLS they all terminate is in Cryptography."
tags: [servers]
type: moc
status: complete
---

<!-- generated-moc -->

# Servers

Configuring and operating the daemons: web servers, databases, directory and time services. The TLS they all terminate is in [[security/cryptography/index|Cryptography]].


| Note | | What it covers |
| --- | --- | --- |
| [[servers/apache\|Apache]] | how-to | Hardening and tuning Apache 2 — information disclosure, mod_evasive, access control and choosing an MPM |
| [[servers/chrony\|chrony]] | how-to | Troubleshooting a chrony NTP server — activity, sources, source statistics, clients and logs |
| [[servers/config-validation\|Validating server configuration files]] | reference | Syntax-check commands for common daemons, so a bad config is caught before the restart that would take the service down |
| [[servers/mongodb\|MongoDB]] | how-to | Replica sets, sharded clusters, the balancer and chunk sizing |
| [[servers/mysql\|MySQL]] | how-to | Resetting a lost root password and setting up passwordless backups with a dedicated user |
| [[servers/nginx\|nginx]] | how-to | Managing an nginx web server or reverse proxy — cache clearing, hardening, rate limiting and upload size |
| [[servers/vaultwarden-docker\|Vaultwarden with Docker]] | how-to | Deploying Vaultwarden behind an nginx reverse proxy with MariaDB, using Docker Compose on openSUSE MicroOS |
| [[servers/vaultwarden-podman\|Vaultwarden with rootless Podman]] | how-to | Deploying Vaultwarden as a rootless Podman pod on openSUSE MicroOS, with MariaDB and an nginx reverse proxy |
| [[servers/zabbix\|Zabbix on Podman]] | how-to | Deploying the Zabbix monitoring stack as a Podman pod managed by a systemd user service |

Part of [[index|Ops Notes]].
