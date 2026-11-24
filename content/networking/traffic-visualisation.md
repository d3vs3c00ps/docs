---
title: Visualising traffic and firewall rules
description: Turning packet captures into topology graphs with PcapViz, and iptables rulesets into flow diagrams with iptable_vis
tags: [networking, visualisation, pcap, iptables, troubleshooting]
type: howto
status: complete
---

# Visualising traffic and firewall rules

Two problems where a diagram genuinely beats reading text: understanding who talks to
whom on a network you did not build, and understanding a firewall ruleset that has
accumulated for years.

## PcapViz — network topology from a capture

[PcapViz](https://github.com/1ultimat3/PcapViz) reads a packet capture and produces a
graph of the communication it contains — nodes for hosts, edges for the traffic
between them.

The use case is arriving at an unfamiliar environment. A `tcpdump` capture answers
"what is on this segment?" far faster than reading configuration, because it shows
what is actually happening rather than what was intended.

### Capturing

```bash
sudo tcpdump -i eth0 -w capture.pcap -c 100000
sudo tcpdump -i eth0 -w capture.pcap -G 300 -W 1     # stop after 5 minutes
sudo tcpdump -i any -w capture.pcap 'not port 22'    # exclude your own session
```

Excluding your SSH session matters — otherwise your own connection dominates the
graph.

> [!warning] A capture contains everything, including credentials
> Any unencrypted protocol on that segment is in the file: HTTP basic auth, SNMP
> community strings, LDAP simple binds, legacy database protocols. Treat a `.pcap`
> as a secret, store it accordingly, and delete it when finished.
>
> Capturing on a network you do not administer is interception. See
> [[security/offensive/hetty]] for the same caveat about proxies.

### Generating a graph

PcapViz has no release and no package. Install it from Git, in a virtual
environment. Its `pygraphviz` dependency comes as a binary wheel with Graphviz
inside, but the wheel still loads the system's X11 and GLib libraries. A desktop
has them; on a minimal openSUSE server, install `libX11-6 libXrender1 libXext6
libgobject-2_0-0` first. Where no wheel fits your Python, pip builds `pygraphviz`
from source and needs `gcc`, `python3-devel` and `graphviz-devel`.

```bash
git clone https://github.com/1ultimat3/PcapViz
cd PcapViz
python3 -m venv .venv && . .venv/bin/activate
pip install -r requirements.txt

python main.py -i capture.pcap -o topology.png                  # layer 3 by default
python main.py -i capture.pcap -o topology.png --layer2         # Ethernet
python main.py -i capture.pcap -o topology.png --layer4         # TCP and UDP
```

`--layer2` needs a capture from one Ethernet interface. A capture with `-i any`
has no MAC header, and PcapViz stops with a Python traceback.

> [!warning] Correction
> The original wrote `--layer 3` and `--layer 2`. PcapViz has no `--layer`
> option: the flags are `--layer2`, `--layer3` (the default) and `--layer4`.

| Layer | Shows |
| --- | --- |
| 2 | MAC addresses — the physical topology, switches, unexpected devices |
| 3 | IP addresses — routing and which subnets talk |
| 4 | Ports and services — what the conversations actually are |

Layer 2 finds things nothing else does: a device with an unexpected MAC, or two
interfaces that turn out to be the same host.

### Reading the result

What the graph makes obvious, and text does not:

- **Hubs.** A node with many edges is a gateway, a proxy, or something that should not
  be talking to everything.
- **Unexpected pairs.** A database server talking directly to a workstation.
- **Isolated clusters.** Segments that are genuinely separate, confirming or
  contradicting the intended design.
- **External destinations.** Anything leaving to an address you do not recognise.

`tshark` answers specific questions better; the graph is for the questions you did not
know to ask.

```bash
tshark -r capture.pcap -q -z conv,ip          # conversations, ranked
tshark -r capture.pcap -q -z endpoints,ip
tshark -r capture.pcap -q -z io,phs           # protocol hierarchy
```

`-z conv,ip` is the text equivalent and worth running alongside — the graph shows
structure, the table gives you volumes.

## iptable_vis — firewall rules as a diagram

[iptable_vis](https://github.com/Nudin/iptable_vis) renders an iptables ruleset as a
graph of chains and the jumps between them.

Any ruleset that has grown over years becomes hard to reason about — custom chains
jumping to other custom chains, rules whose position determines whether they are ever
reached. A diagram of the chain structure makes the control flow visible.

It is an `awk` script that reads the output of `iptables -v -L` and writes a
[blockdiag](http://blockdiag.com) file, and `blockdiag` draws it.

`blockdiag` 3.0.0 (2021) is no longer maintained. It needs Pillow older than 10,
which has no packages for Python newer than 3.11, and `pkg_resources`, which
`setuptools` 81 removed. [uv](https://docs.astral.sh/uv/) can create a Python 3.11
environment for it:

```bash
git clone https://github.com/Nudin/iptable_vis
uv venv -p 3.11 .venv && . .venv/bin/activate
uv pip install blockdiag 'pillow<10' 'setuptools<81'

sudo iptables -v -L > iptables.txt
awk -f iptable_vis/iptables-vis.awk < iptables.txt > iptables.dia
blockdiag iptables.dia -T svg -o iptables.svg
```

`iptables -t nat -v -L` works the same for another table. To draw only some
chains, pass a regular expression:
`awk -f iptable_vis/iptables-vis.awk -v 'chain_selector=INPUT|mychain'`.

> [!warning] Correction
> The original showed `python iptable_vis.py rules.txt | dot -Tpng`. The project
> has no Python script and does not read `iptables-save` output: it is the `awk`
> script above, its input is `iptables -v -L`, and its output is for `blockdiag`,
> not Graphviz.

The output shows the built-in chains, the user-defined ones, and every `-j` between
them — so an orphaned chain nothing jumps to, or an unreachable rule after a
terminating target, becomes apparent.

> [!important] The diagram shows structure, not order — and order decides everything
> iptables evaluates rules top to bottom within a chain, first match wins. A graph of
> chain relationships cannot express that a `DROP` at position 4 makes position 30
> unreachable.
>
> Use it to understand the *shape* of the ruleset, then read the chain itself for the
> ordering:
>
> ```bash
> sudo iptables -L INPUT -n -v --line-numbers
> ```
>
> The packet and byte counters in that output are the other half of the picture — a
> rule with zero hits after months is either dead or protecting against something that
> never happens.

See [[networking/iptables]] for the ruleset itself, and [[networking/nftables]] for
the successor, whose `nft list ruleset` output is considerably more readable and needs
less visualising.

### Tracing a packet instead

When the question is "which rule is dropping this?", tracing beats diagramming:

```bash
sudo iptables -t raw -A PREROUTING -p tcp --dport 8080 -j TRACE
sudo xtables-monitor --trace
```

That prints every rule the matching packet traverses, in order. Remove the TRACE
rule afterwards — it is expensive and verbose:

```bash
sudo iptables -t raw -D PREROUTING -p tcp --dport 8080 -j TRACE
```

> [!warning] Correction
> The original loaded `nf_log_ipv4` and read the trace with `dmesg`. That is how
> the legacy iptables backend logs. Current distributions use `iptables-nft`,
> where `TRACE` sets the nftables trace flag and the events go to
> `xtables-monitor --trace` (or `nft monitor trace`), not to the kernel log.

## Where to go next

- [[networking/iptables]] — the ruleset being visualised
- [[networking/nftables]] — the successor, with more readable output
- [[linux/networking/virtual-interfaces]] — what the topology looks like on a container host
- [[linux/cli/lnav]] — reading the logs these produce

<!-- uplink -->
Part of [[networking/index|Networking]].
