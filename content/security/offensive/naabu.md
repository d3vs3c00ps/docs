---
title: naabu
description: Fast port scanning for attack surface inventory — SYN versus CONNECT, chaining into other tools, and using it to find what you did not know you exposed
tags: [security, offensive, scanning, naabu, networking]
type: howto
status: complete
---

# naabu

[naabu](https://github.com/projectdiscovery/naabu) is a fast port scanner written in
Go, designed to feed other tools rather than to replace `nmap`.

> [!warning] Port scanning requires authorisation
> Scanning hosts you do not own is unauthorised, is logged, and in many jurisdictions
> is an offence regardless of intent. Scope it to your own address space, and tell
> whoever watches the IDS before you start.

**The defensive use, and the reason it is here:** attack surface inventory. Scanning
your own ranges regularly and diffing the result finds services nobody meant to
expose — which is a different and more common problem than a vulnerable service.

## Installation

```bash
go install -v github.com/projectdiscovery/naabu/v2/cmd/naabu@latest

# or
brew install naabu
```

SYN scanning (`-s s`) needs privileges:

```bash
sudo setcap cap_net_raw+ep "$(which naabu)"
```

## Basic use

```bash
naabu -host 10.0.0.1
naabu -host 10.0.0.0/24
naabu -list targets.txt

naabu -host 10.0.0.0/24 -top-ports 1000
naabu -host 10.0.0.0/24 -p 22,80,443,8080-8090
naabu -host 10.0.0.0/24 -p -                    # all 65535
```

With no `-p` or `-top-ports`, naabu scans the top 100 ports only, so a service on a
port such as 2379 (etcd) is not found.

Output for piping:

```bash
naabu -host 10.0.0.0/24 -silent               # host:port only
naabu -host 10.0.0.0/24 -json -o results.json
naabu -host 10.0.0.0/24 -o open-ports.txt
```

## Scan types

| Flag | Type | Notes |
| --- | --- | --- |
| `-s s` | SYN | Needs root or `cap_net_raw`. Faster, does not complete the handshake |
| `-s c` | CONNECT | The default. Full TCP connection. No privileges needed, more visible in logs |

```bash
naabu -host 10.0.0.0/24 -s c      # unprivileged
```

> [!note] CONNECT is the default
> In naabu 2.7 the default scan type is CONNECT, even as root
> (`-scan-type ... (default "c")`); pass `-s s` for a SYN scan.

> [!note] SYN scanning is not stealthy in any meaningful sense
> The "half-open scan avoids logging" claim dates from an era of application-only
> logging. Any current firewall, IDS or flow collector records it, and a burst of SYNs
> across a /24 is one of the most obvious patterns there is.
>
> Choose SYN for speed, not for concealment. If you are testing whether your own
> detection notices, that visibility is the point.

## Rate control

```bash
naabu -host 10.0.0.0/24 -rate 1000 -c 25 -timeout 1000 -retries 2
```

| Flag | Meaning |
| --- | --- |
| `-rate` | Packets per second |
| `-c` | Concurrent workers |
| `-timeout` | Milliseconds per port |
| `-retries` | Retries before declaring closed |

Defaults are fast enough to disrupt fragile network equipment and to trip rate limits
on cloud provider networks. Lower them for anything production-adjacent.

## Chaining

naabu's design intent — it finds the ports, other tools do the rest:

```bash
# Ports → HTTP probing → vulnerability scanning
naabu -list targets.txt -silent \
  | httpx -silent \
  | nuclei -tags exposure,misconfig -severity medium,high,critical
```

```bash
# Hand the open ports to nmap for real service detection
naabu -host 10.0.0.0/24 -silent -nmap-cli 'nmap -sV -sC'
```

> [!important] naabu finds ports; `nmap -sV` identifies services
> naabu tells you 8080 is open. It does not tell you whether that is a Jenkins
> instance, a metrics endpoint or a forgotten test harness — and for inventory work
> that is the part that matters.
>
> The `-nmap-cli` handoff gives you naabu's speed for discovery and nmap's depth for
> the small set of ports that turned out to be open, which is the right division of
> labour. naabu 2.7 also has its own `-sV` service probe, which is lighter than nmap's.

## Attack surface inventory

The defensive workflow worth automating:

```bash
#!/bin/bash
# Weekly external surface check
RANGES="203.0.113.0/24 198.51.100.0/24"
TODAY=$(date +%F)

naabu -host $RANGES -top-ports 1000 -silent -rate 500 \
  | sort > "surface-${TODAY}.txt"

if [ -f surface-previous.txt ]; then
  echo "=== NEW since last run ==="
  comm -13 surface-previous.txt "surface-${TODAY}.txt"
  echo "=== GONE since last run ==="
  comm -23 surface-previous.txt "surface-${TODAY}.txt"
fi

cp "surface-${TODAY}.txt" surface-previous.txt
```

The diff is the product. A steady list of open ports is uninteresting; a port that
appeared this week and nobody can explain is exactly what you are looking for.

Feed the additions into [[security/offensive/nuclei]] for a misconfiguration pass.

## Kubernetes and cloud

```bash
# What is actually reachable on the node network
naabu -host 10.0.0.0/16 -p 10250,10255,2379,2380,6443 -silent
```

Those ports are worth checking explicitly: the kubelet API (10250), the read-only
kubelet port (10255, deprecated and sometimes still enabled), etcd (2379–2380) and
the API server (6443). Any of them reachable from a pod network or the internet is a
serious finding — see [[kubernetes/security/control-plane-auth]].

> [!warning] Cloud providers have acceptable use policies about scanning
> Scanning within your own VPC is generally fine. Scanning **from** a cloud instance
> towards external targets frequently violates the provider's terms and can get the
> account suspended. Check before pointing it outward.

## Configuration

```yaml
# ~/.config/naabu/config.yaml
rate: 500
retries: 2
timeout: 1500
top-ports: 1000
exclude-hosts:
  - 10.0.0.1        # the gateway everyone forgets and then breaks
```

Excluding fragile infrastructure — gateways, printers, industrial equipment,
management interfaces — in the config rather than remembering each time is worth
doing once.

## Where to go next

- [[security/offensive/nuclei]] — scanning what naabu found
- [[security/offensive/interactsh]] — out-of-band detection
- networking — writing your own scanner, and why bounding it matters
- iptables — the filtering that should be producing the results you want

<!-- uplink -->
Part of [[security/offensive/index|Offensive tooling]].
