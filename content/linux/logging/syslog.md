---
title: Syslog
description: The syslog protocol — RFC3164 vs RFC5424 message formats, the facility/severity matrix, and transport trade-offs
tags: [linux, logging, syslog, networking, protocol]
type: concept
status: complete
---

# Syslog

## Overview

Syslog is the standard logging solution on Unix and Linux systems. Implementations
also exist for other operating systems (including Windows) and it is commonly
found in network equipment such as switches and routers.

As a protocol it has a client and a server side. The client emits messages over
the network — by default UDP port 514, though TCP is supported. Servers collect
those messages and are responsible for writing the logs.

Two standards coexist, and they differ slightly:

- **RFC3164**, also called *legacy* or *BSD*
- **RFC5424**, also called *IETF*

Implementations: [[linux/logging/rsyslog]] and [[linux/logging/syslog-ng]].
For the local systemd journal see [[linux/cli/journalctl]].

## RFC3164 — legacy / BSD

Three parts:

- **PRI** — the **priority** number, a combination of facility and severity, from
  the matrix below.
- **HEADER** — the timestamp and the hostname (short name only) or IP address.
- **MSG** — the name of the program or process that generated the message,
  followed by the message text.

```text
<35>Oct 12 22:14:15 client_machine su: 'su root' failed for joe on /dev/pts/2
```

| Part | Value | Meaning |
| --- | --- | --- |
| PRI | `<35>` | facility 4 (security/auth), severity 3 (error) |
| timestamp | `Oct 12 22:14:15` | no year, no timezone, second precision |
| hostname | `client_machine` | the source (the `%hostname%` field in the payload) |
| tag | `su:` | application tag — here the process name |
| message | `'su root' failed for joe...` | the application's text |

This RFC is purely informational; it specifies almost nothing about content or
form:

> 4. Packet Format and Contents
>
> The payload of any IP packet that has a UDP destination port of 514
> MUST be treated as a syslog message. There MAY be differences
> between the format of an originally transmitted syslog message and
> the format of a relayed message. In essence, it is RECOMMENDED to
> transmit a syslog message in the format specified in this document,
> but it is not required. If a relay is able to recognize the message
> as adhering to that format then it MUST retransmit the message
> without making any changes to it. However, if a relay receives a
> message but cannot discern the proper implementation of the format,
> it is REQUIRED to modify the message so that it conforms to that
> format before it retransmits it.

So anything arriving on port 514 *is* a syslog message. Not exactly rigorous —
but remember RFC stands for Request For Comment, and this one had a single
purpose: to document syslog as it already existed and propose a normalisation.

RFC3195 was written to address that need but is too poorly supported to rely on,
so RFC5424 is the one to target.

## RFC5424 — IETF

Also three parts:

- **HEADER**
  - *PRI* — the priority number, as above.
  - *VERSION* — the syslog protocol version.
  - *ISOTIMESTAMP* — when the message was generated, in ISO 8601 format
    (`yyyy-mm-ddThh:mm:ss±ZONE`).
  - *HOSTNAME* — the hostname of the source machine.
  - *APPLICATION* — the name of the program or device.
  - *PID* — the process name or Process ID that generated the message.
  - *MESSAGEID* — the message identifier.
- **STRUCTURED-DATA** — optional extra information about the message or the
  application (a traffic counter, a client IP). One or more blocks enclosed in
  square brackets, each with a block ID and one or more key/value pairs.
- **MSG** — the message text. It must be UTF-8, and if a syslog application
  encodes MSG as UTF-8 the string must begin with the Unicode byte order mark
  (BOM).

`APPLICATION`, `PID`, `MESSAGEID` and `STRUCTURED-DATA` may all be null, written
as a hyphen `-`. `MSG` may also be empty.

```text
<35>1 2013-10-11T22:14:15.003Z client_machine su - - - 'su root' failed for joe on /dev/pts/2
```

Its advantages over RFC3164:

- a more precise timestamp, with year and timezone
- messages longer than the 1024-byte RFC3164 limit
- structured, machine-parseable key/value metadata

## Facility and severity matrix

The priority is computed as:

```text
PRI = Facility × 8 + Severity
```

Severities, most to least severe:

| Severity | Name |
| --- | --- |
| 0 | Emergency |
| 1 | Alert |
| 2 | Critical |
| 3 | Error |
| 4 | Warning |
| 5 | Notice |
| 6 | Info |
| 7 | Debug |

Facilities, with the RFC3164 description and the keyword you actually write in
`rsyslog`/`syslog-ng` configuration:

| Facility | RFC3164 description | Config keyword |
| --- | --- | --- |
| 0 | kernel messages | `kern` |
| 1 | user-level messages | `user` |
| 2 | mail system | `mail` |
| 3 | system daemons | `daemon` |
| 4 | security/authorization messages | `auth` |
| 5 | messages generated internally by syslogd | `syslog` |
| 6 | line printer subsystem | `lpr` |
| 7 | network news subsystem | `news` |
| 8 | UUCP subsystem | `uucp` |
| 9 | clock daemon | `cron` |
| 10 | security/authorization messages (private) | `authpriv` |
| 11 | FTP daemon | `ftp` |
| 12 | NTP subsystem | — |
| 13 | log audit | — |
| 14 | log alert | — |
| 15 | clock daemon | `cron` (Solaris) |
| 16–23 | locally used facilities | `local0`–`local7` |

The resulting PRI values:

| Facility | Emerg 0 | Alert 1 | Crit 2 | Err 3 | Warn 4 | Notice 5 | Info 6 | Debug 7 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| kern (0) | 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 |
| user (1) | 8 | 9 | 10 | 11 | 12 | 13 | 14 | 15 |
| mail (2) | 16 | 17 | 18 | 19 | 20 | 21 | 22 | 23 |
| daemon (3) | 24 | 25 | 26 | 27 | 28 | 29 | 30 | 31 |
| auth (4) | 32 | 33 | 34 | **35** | 36 | 37 | 38 | 39 |
| syslog (5) | 40 | 41 | 42 | 43 | 44 | 45 | 46 | 47 |
| lpr (6) | 48 | 49 | 50 | 51 | 52 | 53 | 54 | 55 |
| news (7) | 56 | 57 | 58 | 59 | 60 | 61 | 62 | 63 |
| uucp (8) | 64 | 65 | 66 | 67 | 68 | 69 | 70 | 71 |
| cron (9) | 72 | 73 | 74 | 75 | 76 | 77 | 78 | 79 |
| authpriv (10) | 80 | 81 | 82 | 83 | 84 | 85 | 86 | 87 |
| ftp (11) | 88 | 89 | 90 | 91 | 92 | 93 | 94 | 95 |
| ntp (12) | 96 | 97 | 98 | 99 | 100 | 101 | 102 | 103 |
| logaudit (13) | 104 | 105 | 106 | 107 | 108 | 109 | 110 | 111 |
| logalert (14) | 112 | 113 | 114 | 115 | 116 | 117 | 118 | 119 |
| clock (15) | 120 | 121 | 122 | 123 | 124 | 125 | 126 | 127 |
| local0 (16) | 128 | 129 | 130 | 131 | 132 | 133 | 134 | 135 |
| local1 (17) | 136 | 137 | 138 | 139 | 140 | 141 | 142 | 143 |
| local2 (18) | 144 | 145 | 146 | 147 | 148 | 149 | 150 | 151 |
| local3 (19) | 152 | 153 | 154 | 155 | 156 | 157 | 158 | 159 |
| local4 (20) | 160 | 161 | 162 | 163 | 164 | 165 | 166 | 167 |
| local5 (21) | 168 | 169 | 170 | 171 | 172 | 173 | 174 | 175 |
| local6 (22) | 176 | 177 | 178 | 179 | 180 | 181 | 182 | 183 |
| local7 (23) | 184 | 185 | 186 | 187 | 188 | 189 | 190 | 191 |

## Testing with `logger`

To check whether a given RFC is handled, or to validate a collector or relay
configuration, use `logger`.

| Option | Meaning |
| --- | --- |
| `-n` | syslog server to send to |
| `-T` | use TCP |
| `-d` | use UDP |
| `-P` | destination port |
| `--rfc3164` / `--rfc5424` | message format |
| `--sd-id` / `--sd-param` | STRUCTURED-DATA block ID and key/value pair |

RFC3164:

```bash
# on the source
logger -n rsyslog-relay.internal.example.com -T -P 514 --rfc3164 "$(who)"
```

```text
# the resulting log on the destination
2022-10-07T12:59:48+00:00 rsyslog-client root: setup pts/0 Oct 7 12:46 (10.240.1.99)
```

RFC5424, with two STRUCTURED-DATA blocks:

```bash
logger -n rsyslog-relay.internal.example.com -T -P 514 --rfc5424 \
    --sd-id syslog@42    --sd-param syslog=\"enabled\" \
    --sd-id example@123  --sd-param afk=\"false\"      \
    "Linux FTW"
```

```text
# the resulting log on the destination
2022-10-07T13:16:29+00:00 rsyslog-client 1 2022-10-07T13:16:29.622409+00:00 rsyslog-client root - - [timeQuality tzKnown="1" isSynced="1" syncAccuracy="3907"][syslog@42 syslog="enabled"][example@123 afk="false"] Linux FTW
```

Note that `logger` adds its own `timeQuality` structured-data block alongside the
ones you supply.

## Transport

> [!note] TCP has flow control
> A slow collector makes a TCP sender wait. What TCP syslog lacks is an
> application-level acknowledgement, which RELP adds.

| Transport | Delivery guarantee | Notes |
| --- | --- | --- |
| **UDP** | none | historical default; fastest |
| **TCP** | to the host, not the app | TLS possible; no app-level ack |
| **RELP** | application-level ack | `rsyslog`; TLS possible |
| **RLTP** | application-level ack | `syslog-ng` Enterprise only |

**UDP** — the historical default. Fast, but gives no assurance the message
arrived.

**TCP** — marginally slower, and confirms delivery via TCP acknowledgements *if*
source and destination are reachable. The caveats matter:

- It confirms the packet reached the remote *machine*, not the remote
  *application*. A packet can sit in the receive buffer while the application is
  down.
- On a network break or collector outage there is no fast failure — you wait for
  a timeout. Meanwhile messages queue in a limited buffer on the source. When the
  destination returns, the syslog client does not know which message to
  retransmit, and once the buffer is full messages are dropped.
- TCP's own flow control slows the sender when the collector reads too slowly.
  But syslog over TCP has no application-level acknowledgement, so the sender
  cannot know which messages the collector actually processed.
- A TLS tunnel can be layered on top.

**RELP** (Reliable Event Logging Protocol) — an application-level protocol that
confirms the message was actually received.

- supported by `rsyslog`
- can duplicate messages
- message loss is still possible if the syslog service restarts, but is greatly
  reduced compared to TCP during a network outage
- slower than TCP/UDP; can become a problem above ~200k EPS (events per second),
  partly because it does not support multithreading
- a TLS tunnel can be layered on top

**RLTP** — comparable to RELP.

- supported by `syslog-ng` in its Enterprise edition only
- sends and receives using ALTP (Advanced Log Transfer Protocol)
- if a message is lost in transit, the source resumes from the last message
  actually received
- slower than TCP/UDP; same ~200k EPS caveat
- supports both RFC3164 (BSD-syslog) and RFC5424 (IETF-syslog)

<!-- uplink -->
Part of [[linux/logging/index|Logging]].
