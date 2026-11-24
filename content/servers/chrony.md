---
title: chrony
description: Troubleshooting a chrony NTP server — activity, sources, source statistics, clients and logs
tags: [linux, servers, ntp, chrony, troubleshooting]
type: howto
status: complete
---

# chrony

`chrony` is the default NTP implementation on current RHEL and SUSE releases,
replacing `ntpd`. Everything below is runtime inspection with `chronyc`.

The configuration file depends on the distribution:

| Distribution | Configuration |
| --- | --- |
| RHEL | `/etc/chrony.conf` |
| openSUSE Leap 16 | `/usr/etc/chrony.conf` from the package, plus drop-ins in `/etc/chrony.d/*.conf`. Put local settings in a drop-in. A file named `/etc/chrony.conf` replaces the package's file entirely |

## Overall service state

```console
$ chronyc activity
200 OK
2 sources online
0 sources offline
0 sources doing burst (return to online)
0 sources doing burst (return to offline)
0 sources with unknown address
```

`serverstats` shows how many NTP and command packets have been received from
clients:

```console
$ chronyc serverstats
NTP packets received       : 12
NTP packets dropped        : 0
Command packets received   : 22
Command packets dropped    : 0
Client log records dropped : 0
NTS-KE connections accepted: 0
NTS-KE connections dropped : 0
Authenticated NTP packets  : 12
```

## Source state

```console
$ chronyc sources -v

  .-- Source mode  '^' = server, '=' = peer, '#' = local clock.
 / .- Source state '*' = current best, '+' = combined, '-' = not combined,
| /             'x' = may be in error, '~' = too variable, '?' = unusable.
||                                                 .- xxxx [ yyyy ] +/- zzzz
||      Reachability register (octal) -.           |  xxxx = adjusted offset,
||      Log2(Polling interval) --.      |          |  yyyy = measured offset,
||                                \     |          |  zzzz = estimated error.
||                                 |    |           \
MS Name/IP address         Stratum Poll Reach LastRx Last sample
===============================================================================
=+ node1.cluster.local          11   9   275   134    +49us[  -93us] +/-  827us
=* node3.cluster.local          10   8   375    14    -41us[ -185us] +/-  113us
```

The `M` and `S` columns are the most useful part: `*` marks the source currently
being used, and a `Reach` value that is not climbing toward `377` (octal, all
eight recent polls answered) means packets are being lost.

Detail for one source:

```console
$ chronyc ntpdata node1.cluster.local

Remote address  : 192.168.1.2 (C0A80102)
Remote port     : 123
Local address   : 192.168.1.1 (C0A80101)
Leap status     : Normal
Version         : 3
Mode            : Symmetric active
Stratum         : 11
Poll interval   : 6 (64 seconds)
Precision       : -25 (0.000000030 seconds)
Root delay      : 0.000275 seconds
Root dispersion : 0.000092 seconds
Reference ID    : C0A80101 ()
Reference time  : Thu Aug 25 11:49:50 2022
Offset          : -0.000018892 seconds
Peer delay      : 0.000289173 seconds
Peer dispersion : 0.121996298 seconds
Jitter asymmetry: +0.00
NTP tests       : 111 111 1110
Interleaved     : No
Authenticated   : Yes
TX timestamping : Daemon
RX timestamping : Kernel
Total TX        : 12
Total RX        : 12
Total valid RX  : 10
```

`NTP tests` is a bitfield of the RFC 5905 validity tests — a `0` anywhere means
that test failed and the sample was rejected.

## Source statistics

```console
$ chronyc sourcestats
Name/IP Address            NP  NR  Span  Frequency  Freq Skew  Offset  Std Dev
==============================================================================
node1.cluster.local         6   3   26m     -0.015      0.146    +85us    22us
node3.cluster.local         6   4   25m     -0.137      0.225    -34us    30us
```

`NP` is the number of sample points retained, `Span` the interval they cover. A
large `Std Dev` relative to the others points at an unstable network path.

## Client state

```console
$ chronyc clients
Hostname                      NTP   Drop Int IntL Last     Cmd   Drop Int  Last
===============================================================================
client.cluster.local            4      0   1   -    54       0      0   -     -
ipv6-localhost                  0      0   -   -     -      14      0   0    24
```

| Column | Meaning |
| --- | --- |
| Hostname | client name |
| NTP | NTP packets received from the client |
| Drop | NTP packets dropped to rate-limit responses |
| Int | average interval between NTP packets |
| IntL | average interval between NTP packets after rate limiting |
| Last | time since the last NTP packet received |
| Cmd | command packets received from the client |
| Drop | command packets dropped to rate-limit responses |
| Int | average interval between command packets |
| Last | time since the last command packet |

> [!note] `chronyc clients` needs the client log
> chronyd logs client accesses by default (`noclientlog` turns that off, and
> `clientloglimit` sets its memory). A server with no `allow` directive answers
> no NTP client, so the list stays empty.

## Logs

Logs live in the `logdir` directory, `/var/log/chrony/` on RHEL and Leap. Which
files exist depends on the `log` directive. Neither distribution sets one by
default, so the directory starts empty. To log statistics and tracking:

```bash
# openSUSE: a drop-in. RHEL reads no drop-in directory by default: add the line to /etc/chrony.conf
echo 'log statistics tracking' >/etc/chrony.d/log.conf
systemctl restart chronyd
```

```console
$ ls -l /var/log/chrony/
total 16
-rw-r--r-- 1 chrony chrony 8190 Aug 25 11:27 statistics.log
-rw-r--r-- 1 chrony chrony 6336 Aug 25 11:27 tracking.log
```

`statistics.log` gets a line each time a source's statistics are updated, so a
server whose only source is `local` writes none.

The `rtc` log option writes `rtc.log` only when chronyd tracks the hardware clock
with `rtcfile`. The default configurations use `rtcsync` instead, so `log rtc`
adds nothing there.

See also [[servers/config-validation]] and [[linux/cli/journalctl]] for
`journalctl -u chronyd`.

<!-- uplink -->
Part of [[servers/index|Servers]].
