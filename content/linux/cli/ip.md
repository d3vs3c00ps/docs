---
title: ip
description: Cheat sheet for the iproute2 `ip` command — routing table and interface statistics
tags: [linux, cli, networking, routing, cheatsheet]
type: reference
status: complete
---

# `ip` cheat sheet

The `ip` command from `iproute2` replaces the older `route`, `ifconfig` and
`arp` tools, and the routing and interface parts of `netstat` (`netstat -r`,
`netstat -i`). For sockets, `ss` replaces `netstat`.

> [!warning] Changes are not persistent
> Every command below modifies the running configuration only. Nothing here
> survives a reboot. To make a change permanent, write it to your
> distribution's network configuration, for example with
> [[linux/networking/nmcli]] (see also [[linux/distributions/opensuse-leap]]
> or [[linux/distributions/rhel]]).

## Routing

Show the routing table. `show` and `list` are the same command:

```bash
ip route show
ip route list
```

Add a route, either via an interface or via a gateway. A second default route
fails with `RTNETLINK answers: File exists`; use `ip route replace` to change it:

```bash
ip route add default via 192.168.0.254 dev eth0
ip route add 192.168.1.0/24 dev eth0
ip route add 192.168.2.0/24 via 192.168.0.254 dev eth0
```

Delete a route:

```bash
ip route delete 192.168.1.0/24 dev eth0
ip route delete 192.168.2.0/24 via 192.168.0.254 dev eth0
```

## Interface statistics

`-s` adds the RX and TX counters (bytes, packets, errors, dropped). Give it twice
(`-s -s`) for the detailed error counters:

```bash
ip -s link show eth0
```

<!-- uplink -->
Part of [[linux/cli/index|Command line tools]].
