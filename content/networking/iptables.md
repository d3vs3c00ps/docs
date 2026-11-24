---
title: iptables
description: Netfilter filtering with iptables — tables and hooks, a default-deny baseline, common attack mitigations and persistence
tags: [networking, firewall, iptables, netfilter, linux, security]
type: reference
status: complete
---

# iptables

Several front-ends manage Netfilter. These rules should help get a feel for
iptables, which despite being superseded is still the best of them for
*learning* — the rules map closely onto what the kernel actually does. For the
successor see [[networking/nftables]].

> [!note] iptables is a compatibility layer now
> On any current distribution `iptables` is `iptables-nft`: it accepts the old
> syntax and programs the nftables engine underneath. Everything here still works,
> but do not mix `iptables` and `nft` rules on the same host — you will end up with
> two rulesets that each look complete and neither of which is.

## Tables and hooks

Rules are attached to hooks in the packet's path:

| Hook | When it sees the packet |
| --- | --- |
| `PREROUTING` | before the routing decision |
| `INPUT` | destined for a local process |
| `FORWARD` | traversing the router |
| `OUTPUT` | originating locally, destined for a remote resource |
| `POSTROUTING` | after the routing decision |

And rules live in tables, each with a purpose:

| Table | Purpose |
| --- | --- |
| `filter` | accept / drop decisions — the default table |
| `nat` | address translation, `REDIRECT`, `MASQUERADE` |
| `mangle` | packet tagging and header modification |
| `raw` | exemptions from connection tracking |

## Prerequisites

Install the `iptables` and `conntrack-tools` packages. `conntrack` is what makes
stateful rules possible.

Private and reserved IPv4 ranges worth knowing when writing rules:

| Range | Notes |
| --- | --- |
| `10.0.0.0/8` | RFC 1918 private |
| `172.16.0.0/12` | RFC 1918 private |
| `192.168.0.0/16` | RFC 1918 private |
| `127.0.0.0/8` | loopback |
| `169.254.0.0/16` | link-local |
| `224.0.0.0/4` | multicast (historically class D) |
| `240.0.0.0/4` | reserved (historically class E) |

Enable routing if you need it:

```bash
# for the running system
sysctl -w net.ipv4.ip_forward=1

# persistently
cat > /etc/sysctl.d/net-forward.conf <<'EOF'
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
EOF
sysctl --system
```

## Useful arguments

| Argument | Meaning |
| --- | --- |
| `-A <chain>` | append a rule |
| `-I <chain> [n]` | insert a rule, optionally at position `n` |
| `-D <chain>` | delete a rule |
| `-N <chain>` | create a user-defined chain |
| `-X` | delete user-defined chains |
| `-F` | flush — delete all rules |
| `-P <chain> <target>` | set the chain's default policy |
| `-t <table>` | operate on a table other than `filter` |

## Starting from a clean slate

Before writing any rule, clear the firewall so you are not reasoning about rules
you cannot see.

> [!warning] Do this in the right order or you will lock yourself out
> Set the policies to `ACCEPT` **before** flushing. If you flush a chain whose
> policy is already `DROP`, every packet is dropped the instant the rules
> disappear — including your SSH session. Keep an out-of-band console available.

`filter` table:

```bash
iptables  -t filter -P INPUT   ACCEPT
iptables  -t filter -P OUTPUT  ACCEPT
iptables  -t filter -P FORWARD ACCEPT
iptables  -t filter -F
iptables  -t filter -X
ip6tables -t filter -P INPUT   ACCEPT
ip6tables -t filter -P OUTPUT  ACCEPT
ip6tables -t filter -P FORWARD ACCEPT
ip6tables -t filter -F
ip6tables -t filter -X
```

`nat` table:

```bash
iptables -t nat -P PREROUTING  ACCEPT
iptables -t nat -P POSTROUTING ACCEPT
iptables -t nat -P OUTPUT      ACCEPT
iptables -t nat -F
iptables -t nat -X
```

`mangle` table:

```bash
iptables  -t mangle -P PREROUTING  ACCEPT
iptables  -t mangle -P POSTROUTING ACCEPT
iptables  -t mangle -P INPUT       ACCEPT
iptables  -t mangle -P OUTPUT      ACCEPT
iptables  -t mangle -P FORWARD     ACCEPT
iptables  -t mangle -F
iptables  -t mangle -X
ip6tables -t mangle -P PREROUTING  ACCEPT
ip6tables -t mangle -P POSTROUTING ACCEPT
ip6tables -t mangle -P INPUT       ACCEPT
ip6tables -t mangle -P OUTPUT      ACCEPT
ip6tables -t mangle -P FORWARD     ACCEPT
ip6tables -t mangle -F
ip6tables -t mangle -X
```

## A default-deny baseline

Apply a default drop policy:

```bash
iptables  -t filter -P INPUT   DROP
iptables  -t filter -P OUTPUT  DROP
iptables  -t filter -P FORWARD DROP
ip6tables -t filter -P INPUT   DROP
ip6tables -t filter -P OUTPUT  DROP
ip6tables -t filter -P FORWARD DROP
```

With `OUTPUT` at `DROP`, the host cannot open any new connection itself: no DNS
lookups, no package updates. Allow those explicitly, or keep `OUTPUT` at `ACCEPT`.

Without breaking already-established connections — your SSH session, for instance:

```bash
iptables  -A INPUT   -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables  -A OUTPUT  -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables  -A FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
ip6tables -A INPUT   -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
ip6tables -A OUTPUT  -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
ip6tables -A FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
```

> [!note] `-m state` is the deprecated spelling
> `-m state --state` is an alias kept for compatibility;
> `-m conntrack --ctstate` is the current module and supports more states.

Allow loopback — many services talk to themselves and will break without it:

```bash
iptables  -A INPUT  -i lo -j ACCEPT
iptables  -A OUTPUT -o lo -j ACCEPT
ip6tables -A INPUT  -i lo -j ACCEPT
ip6tables -A OUTPUT -o lo -j ACCEPT
```

## Dropping by MAC address

```bash
iptables -A INPUT -m mac --mac-source 00:60:56:45:00:08 -j DROP
```

Only meaningful on the local link — MAC addresses do not survive a router hop.

## ICMPv4

Per RFC 792, hosts must respond to Type 8 (echo request) by sending Type 0 (echo
reply). Rate-limit rather than block:

```bash
# echo requests, rate limited, above the ESTABLISHED rule
iptables -I INPUT 1 -p icmp --icmp-type echo-request -m limit --limit 6/s -j ACCEPT
iptables -I INPUT 2 -p icmp --icmp-type echo-request -j DROP

# type 3, destination unreachable
iptables -A INPUT -p icmp --icmp-type destination-unreachable -j ACCEPT

# type 11, time exceeded
iptables -A INPUT -p icmp --icmp-type time-exceeded -j ACCEPT
```

> [!warning] Order, and what not to block
> The limit comes before the `ESTABLISHED,RELATED` rule. Conntrack tracks a ping
> session: after the first reply, the next echo requests of the same `ping` are
> `ESTABLISHED`, so a limit placed after that rule never sees a flood. An echo reply
> (type 0) is never a NEW connection.
>
> Do not block Type 3 or Type 11: dropping destination-unreachable breaks Path MTU
> Discovery, which produces connections that hang on large transfers and is
> miserable to diagnose.

## ICMPv6

Per RFC 4890, these types must be permitted. IPv6 depends on ICMPv6 far more
fundamentally than IPv4 does on ICMP — Neighbour Discovery *is* ICMPv6, so
blocking it breaks IPv6 entirely:

```bash
# error messages
ip6tables -A INPUT              -p ipv6-icmp --icmpv6-type 1   -j ACCEPT
ip6tables -A INPUT              -p ipv6-icmp --icmpv6-type 2   -j ACCEPT
ip6tables -A INPUT              -p ipv6-icmp --icmpv6-type 3   -j ACCEPT
ip6tables -A INPUT              -p ipv6-icmp --icmpv6-type 4   -j ACCEPT

# neighbour and router discovery
ip6tables -A INPUT              -p ipv6-icmp --icmpv6-type 133 -j ACCEPT
ip6tables -A INPUT              -p ipv6-icmp --icmpv6-type 134 -j ACCEPT
ip6tables -A INPUT              -p ipv6-icmp --icmpv6-type 135 -j ACCEPT
ip6tables -A INPUT              -p ipv6-icmp --icmpv6-type 136 -j ACCEPT
ip6tables -A INPUT              -p ipv6-icmp --icmpv6-type 137 -j ACCEPT

# inverse neighbour discovery
ip6tables -A INPUT              -p ipv6-icmp --icmpv6-type 141 -j ACCEPT
ip6tables -A INPUT              -p ipv6-icmp --icmpv6-type 142 -j ACCEPT

# multicast listener discovery, link-local only
ip6tables -A INPUT -s fe80::/10 -p ipv6-icmp --icmpv6-type 130 -j ACCEPT
ip6tables -A INPUT -s fe80::/10 -p ipv6-icmp --icmpv6-type 131 -j ACCEPT
ip6tables -A INPUT -s fe80::/10 -p ipv6-icmp --icmpv6-type 132 -j ACCEPT
ip6tables -A INPUT -s fe80::/10 -p ipv6-icmp --icmpv6-type 143 -j ACCEPT

# certificate path
ip6tables -A INPUT              -p ipv6-icmp --icmpv6-type 148 -j ACCEPT
ip6tables -A INPUT              -p ipv6-icmp --icmpv6-type 149 -j ACCEPT

# multicast router discovery, link-local only
ip6tables -A INPUT -s fe80::/10 -p ipv6-icmp --icmpv6-type 151 -j ACCEPT
ip6tables -A INPUT -s fe80::/10 -p ipv6-icmp --icmpv6-type 152 -j ACCEPT
ip6tables -A INPUT -s fe80::/10 -p ipv6-icmp --icmpv6-type 153 -j ACCEPT
```

## Rate limiting to absorb floods

Declare your server's limits:

```bash
MAXHIT=40
BURST=60
```

Create a dedicated chain:

```bash
iptables -N DDOS
```

Set the traffic limits beyond which packets are dropped. Packets within the limit
are accepted and the source IP is recorded in a hash table for a minute, for
subsequent comparison:

```bash
iptables -A DDOS \
  -m hashlimit \
    --hashlimit-name DDOS \
    --hashlimit-upto "${MAXHIT}/minute" \
    --hashlimit-mode srcip \
    --hashlimit-burst "$BURST" \
    --hashlimit-htable-expire 60000 \
  -j ACCEPT
```

Anything over the limit is dropped:

```bash
iptables -A DDOS -j DROP
```

Then send HTTP traffic through the chain:

```bash
iptables -A INPUT -p tcp --dport 80  -j DDOS
iptables -A INPUT -p tcp --dport 443 -j DDOS
```

The limit counts packets, not connections. One HTTP request is about six packets
to port 80. In the baseline above, the `ESTABLISHED,RELATED` rule comes first, so
only the first packet of each connection reaches `DDOS`. The limit then counts new
connections. Without that rule, a few requests use the whole burst.

> [!important] This mitigates a flood, it does not stop a DDoS
> Rate limiting per source IP helps against a single noisy host. A genuine
> distributed attack arrives from thousands of sources, each under your threshold,
> and saturates the link before your rules run. That requires upstream scrubbing.

## A chain dedicated to logging

```bash
NET_ANYWHERE="0.0.0.0/0"

iptables -N DROP_INPUT
iptables -A DROP_INPUT -j LOG --log-prefix "[DROP_INPUT - firewall] "
iptables -A DROP_INPUT -j DROP
iptables -A INPUT -j DROP_INPUT

iptables -N DROP_OUTPUT
iptables -A DROP_OUTPUT -j LOG --log-prefix "[DROP_OUTPUT - firewall] "
iptables -A DROP_OUTPUT -j DROP
iptables -A OUTPUT -j DROP_OUTPUT

iptables -N DROP_FORWARD
iptables -A DROP_FORWARD -j LOG --log-prefix "[DROP_FORWARD - firewall] "
iptables -A DROP_FORWARD -j DROP
iptables -A FORWARD -j DROP_FORWARD
```

> [!note] `REJECT` or `DROP`
> `REJECT` is terminal, so a `DROP` after it never runs. Pick one: `REJECT` is
> friendlier for hosts on your own network, `DROP` gives an attacker less
> information. Build the chain before you hook it with `-j <chain>`, so no traffic
> reaches an empty chain and falls through.

> [!warning] The jump to the logging chain must be the last rule
> `iptables -A INPUT -j DROP_INPUT` drops everything that reaches it. Any rule you
> append to `INPUT` after it is never reached. Add it last, or insert later rules
> above it with `-I INPUT <n>`.

Rate-limit the logging itself, or a flood becomes a disk-space incident. Replace
the first rule of the chain (the `LOG` rule) with a limited one:

```bash
iptables -R DROP_INPUT 1 -m limit --limit 5/m --limit-burst 10 \
  -j LOG --log-prefix "[DROP_INPUT - firewall] "
```

> [!note] Why `-R`
> `-R` replaces the rule at that position. Appended with `-A DROP_INPUT`, the limited
> rule would come after the `DROP` rule, never run, and leave the unlimited `LOG` rule
> in place.

See [[linux/logging/rsyslog]] for routing these into their own file.

## Common attacks

### NULL packets, no flags set

Log the attempt:

```bash
iptables -A INPUT -p tcp --tcp-flags ALL NONE \
  -m limit --limit 3/m --limit-burst 5 \
  -j LOG --log-prefix "[DROP_INPUT - Null scan] "
```

Drop it and add the source to the `blacklist_60` list:

```bash
iptables -A INPUT -p tcp --tcp-flags ALL NONE \
  -m recent --name blacklist_60 --set \
  -m comment --comment "[DROP_INPUT - Null scan]" \
  -j DROP
```

`--set` only records the source. To block it for 60 seconds, a rule near the top
of `INPUT` must check the list:

```bash
iptables -I INPUT 1 -m recent --name blacklist_60 --rcheck --seconds 60 \
  -m comment --comment "[DROP_INPUT - blacklisted]" -j DROP
```

### XMAS scan

`nmap -sX` sets `FIN`, `PSH` and `URG`. The other two rules catch variants with
other impossible flag sets.

```bash
iptables -A INPUT -p tcp --tcp-flags ALL FIN,PSH,URG \
  -m limit --limit 3/m --limit-burst 5 \
  -j LOG --log-prefix "[DROP_INPUT - Xmas scan] "
iptables -A INPUT -p tcp --tcp-flags ALL SYN,RST,ACK,FIN,URG \
  -m limit --limit 3/m --limit-burst 5 \
  -j LOG --log-prefix "[DROP_INPUT - Xmas/PSH scan] "
iptables -A INPUT -p tcp --tcp-flags ALL ALL \
  -m limit --limit 3/m --limit-burst 5 \
  -j LOG --log-prefix "[DROP_INPUT - Xmas/All scan] "
```

```bash
iptables -A INPUT -p tcp --tcp-flags ALL SYN,RST,ACK,FIN,URG \
  -m recent --name blacklist_60 --set \
  -m comment --comment "[DROP_INPUT - Xmas scan]" -j DROP
iptables -A INPUT -p tcp --tcp-flags ALL FIN,PSH,URG \
  -m recent --name blacklist_60 --set \
  -m comment --comment "[DROP_INPUT - Xmas/PSH scan]" -j DROP
iptables -A INPUT -p tcp --tcp-flags ALL ALL \
  -m recent --name blacklist_60 --set \
  -m comment --comment "[DROP_INPUT - Xmas/All scan]" -j DROP
```

### FIN scan — avoids revealing closed ports

```bash
iptables -A INPUT -p tcp --tcp-flags ALL FIN \
  -m limit --limit 3/m --limit-burst 5 \
  -j LOG --log-prefix "[DROP_INPUT - FIN scan] "
iptables -A INPUT -p tcp --tcp-flags ALL FIN \
  -m recent --name blacklist_60 --set \
  -m comment --comment "[DROP_INPUT - FIN scan]" -j DROP
```

### Connections not starting with a SYN

```bash
iptables -A INPUT -p tcp ! --syn -m conntrack --ctstate NEW \
  -m comment --comment "[DROP_INPUT - TCP connection not starting with SYN]" \
  -j DROP
```

### Empty UDP packets

```bash
iptables -A INPUT -p udp -m length --length 0:28 \
  -m limit --limit 6/h --limit-burst 1 \
  -j LOG --log-prefix "[DROP_INPUT - zero-length UDP packet] "
iptables -A INPUT -p udp -m length --length 0:28 \
  -m comment --comment "[DROP_INPUT - empty UDP packet]" -j DROP
```

### DNS amplification

Detect an `ANY` query and drop repeats from the same source within 10 seconds:

```bash
iptables -A INPUT -p udp --dport 53 \
  -m string --from 40 --algo bm --hex-string '|0000FF0001|' \
  -m recent --set --name dnsanyquery --rsource
iptables -A INPUT -p udp --dport 53 \
  -m string --from 40 --algo bm --hex-string '|0000FF0001|' \
  -m recent --name dnsanyquery --rcheck --seconds 10 --hitcount 2 --rsource \
  -m comment --comment "[DROP_INPUT - DNS amplification]" -j DROP
```

`|0000FF0001|` is the end of the query name, then type `ANY` (255) and class
`IN` (1). `--from` is an offset from the start of the IP header. The question
starts at byte 40 (20 bytes of IP header, 8 of UDP, 12 of DNS header).

> [!note] Why `--from 40` and `--hitcount 2`
> A short name such as `isc.org` ends before byte 50, so a match `--from 50` misses
> its `ANY` query; `--from 40` catches every name. The first rule has already counted
> the current query, so `--hitcount 1` would drop every `ANY` query. `--hitcount 2`
> drops the second query within 10 seconds and the ones after it.

The better fix is on the resolver: disable recursion for the internet and enable
response rate limiting.

### Broadcast packets

```bash
iptables -A INPUT -m pkttype --pkt-type broadcast -j DROP
```

### Malformed packets

```bash
iptables -A INPUT -m conntrack --ctstate INVALID -j DROP
```

### Packets addressed to broadcast, multicast or anycast

```bash
iptables -A INPUT -m addrtype --dst-type BROADCAST -j DROP
iptables -A INPUT -m addrtype --dst-type MULTICAST -j DROP
iptables -A INPUT -m addrtype --dst-type ANYCAST   -j DROP
iptables -A INPUT -d 224.0.0.0/4 -j DROP
```

> [!warning] Not on a host that needs mDNS or DHCP
> DHCP offers arrive as broadcast, and mDNS/Avahi and many clustering heartbeats
> are multicast. These rules are appropriate for a hardened internet-facing server,
> not a LAN machine.

### SSH brute force

Allow four new connections in five minutes from one source. The fifth and later
ones are dropped:

```bash
iptables -N SSHBRUTE
iptables -A SSHBRUTE -m recent --name SSH --set
iptables -A SSHBRUTE -m recent --name SSH --update --seconds 300 --hitcount 5 \
  -m limit --limit 1/second --limit-burst 100 \
  -j LOG --log-prefix "[DROP_INPUT - SSH brute force] "
iptables -A SSHBRUTE -m recent --name SSH --update --seconds 300 --hitcount 5 \
  -m comment --comment "[DROP_INPUT - SSH brute force]" -j DROP
iptables -A SSHBRUTE -j ACCEPT

iptables -A INPUT -p tcp --dport 22 -m conntrack --ctstate NEW -j SSHBRUTE
```

> [!note] Four connections, not five
> `--set` counts the current connection before `--hitcount 5` is checked, so the fifth
> one is already dropped. Each dropped retry is counted too, so a client that keeps
> retrying stays blocked. The last line attaches `SSHBRUTE` to `INPUT`; without it,
> the chain is never used.

Or use the `connlimit` module:

```bash
iptables -A INPUT -p tcp --syn --dport 22 -m connlimit --connlimit-above 5 -j REJECT
iptables -A INPUT -p tcp --syn --dport 80 -m connlimit --connlimit-above 20 \
  --connlimit-mask 24 -j DROP
```

| Option | Meaning |
| --- | --- |
| `--connlimit-above 5` | matches when there are more than 5 connections |
| `--connlimit-mask 24` | group source IPs by prefix length (0–32 for IPv4) |

> [!tip] Key-based authentication removes the problem
> Rate limiting slows a brute force down; disabling password authentication ends
> it. See [[linux/ssh]].

### ICMP flooding

Allow six pings per second per source. This also protects against the reply flood
when responding to a compromised host sending echo requests:

```bash
iptables -N ICMPFLOOD
iptables -A ICMPFLOOD -m recent --name ICMP --rsource --set
iptables -A ICMPFLOOD -m recent --name ICMP --update --seconds 1 --hitcount 6 \
  --rsource --rttl -m limit --limit 1/sec --limit-burst 1 \
  -j LOG --log-prefix "[DROP - ICMP flood] "
iptables -A ICMPFLOOD -m recent --name ICMP --update --seconds 1 --hitcount 6 \
  --rsource --rttl -m comment --comment "[DROP - ICMP flood]" -j DROP
iptables -A ICMPFLOOD -j ACCEPT

ip6tables -N ICMPFLOODIPV6
ip6tables -A ICMPFLOODIPV6 -m recent --name ICMPIPV6 --rsource --set
ip6tables -A ICMPFLOODIPV6 -m recent --name ICMPIPV6 --update --seconds 1 --hitcount 6 \
  --rsource --rttl -m limit --limit 1/sec --limit-burst 1 \
  -j LOG --log-prefix "[DROP - ICMP flood IPv6] "
ip6tables -A ICMPFLOODIPV6 -m recent --name ICMPIPV6 --update --seconds 1 --hitcount 6 \
  --rsource --rttl -m comment --comment "[DROP - ICMP flood IPv6]" -j DROP
ip6tables -A ICMPFLOODIPV6 -j ACCEPT

iptables  -I INPUT 1 -p icmp      --icmp-type 8   -j ICMPFLOOD
ip6tables -I INPUT 1 -p ipv6-icmp --icmpv6-type 128 -j ICMPFLOODIPV6
```

> [!note] Why the jumps come first
> Only the first echo request of a `ping` session is `NEW`; the next ones are
> `ESTABLISHED`. Matched with `--ctstate NEW` or appended after the `ESTABLISHED` rule,
> a flood from one `ping` never reaches the chain. The jumps come first in `INPUT` and
> match every echo request.

## Matching several ports at once

```bash
iptables -A INPUT -p tcp -m multiport --dports 80,443,8080 -j ACCEPT
```

`multiport` accepts up to 15 ports and ranges (`--dports 6000:6010`), and saves a
rule per port.

## Port redirection

```bash
iptables -t nat -I PREROUTING --src 0/0 --dst 192.168.20.2 \
  -p tcp --dport 80 -j REDIRECT --to-ports 8080
```

## Persistence

The rules above live only in kernel memory and vanish on reboot. Dump them:

```bash
mkdir -p /etc/iptables
iptables-save  > /etc/iptables/rules.v4
ip6tables-save > /etc/iptables/rules.v6
```

Debian's `iptables-persistent` package loads these two files at boot. openSUSE
Leap ships no equivalent — restore the files
yourself from a oneshot unit ordered before the network comes up:

```ini
# /etc/systemd/system/iptables-restore.service
[Unit]
Description=Restore iptables rules
Before=network-pre.target
Wants=network-pre.target

[Service]
Type=oneshot
ExecStart=/usr/sbin/iptables-restore /etc/iptables/rules.v4
ExecStart=/usr/sbin/ip6tables-restore /etc/iptables/rules.v6
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
```

On RHEL, the `iptables-services` package provides the same via
`/etc/sysconfig/iptables`:

```bash
dnf install iptables-services
systemctl enable --now iptables ip6tables
```

To restore by hand:

```bash
iptables-restore < /etc/iptables/rules.v4
```

> [!note] No SysV init script
> `iptables-save` plus a restore unit (or `iptables-persistent` on Debian) is all you
> need. Avoid old `/etc/init.d/iptables` scripts: they often hardcode allowlists of
> provider IP addresses, which go stale, fail closed and are very hard to debug, and
> they load `nf_conntrack_ipv4`, a module removed from the kernel in 4.19.

## Commands that save time

List all rules, or per chain:

```bash
iptables -L -n -v --line-numbers
iptables -L INPUT -n -v --line-numbers
```

| Option | Meaning |
| --- | --- |
| `-L` | list rules |
| `-v` | verbose — interface name and rule options |
| `-n` | numeric output, no DNS resolution |
| `--line-numbers` | number each rule |

`-n` matters more than it looks: without it, listing a large ruleset issues a
reverse DNS lookup per address and can take minutes.

Line numbers let you delete a rule quickly:

```bash
iptables -D INPUT 42
```

Or insert between two rules — this becomes line 2, and the old line 2 becomes 3:

```bash
iptables -I INPUT 2 -s 192.168.1.1 -j DROP
```

Watch counters live to confirm a rule is matching:

```bash
watch -n1 'iptables -L INPUT -n -v --line-numbers'
```

Zero the counters before a test:

```bash
iptables -Z
```

## Making sense of a large ruleset

For a ruleset that has grown over years, a diagram of the chains and the jumps
between them is easier to reason about than the text. See
[[networking/traffic-visualisation]], which also covers tracing a specific packet
through the rules it traverses — usually the faster answer to "which rule is dropping
this?".

## Where to go next

- [[networking/nftables]] — the successor, and what the translation of these rules
  looks like
- [[automation/ansible/roles]] — the point at which a ruleset should stop being
  edited by hand. Generate the whole file from a template and reload it atomically;
  appending individual rules with the `iptables` module gives you a ruleset whose
  contents depend on the order things were run in, which is precisely what you were
  trying to escape
- [[kubernetes/networking/netpol]] — where these rules come from on a cluster node,
  and why hand-editing them there is futile
- [[linux/networking/virtual-interfaces]] — the interfaces the rules are matching on

<!-- uplink -->
Part of [[networking/index|Networking]].
