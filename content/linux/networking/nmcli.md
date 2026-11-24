---
title: nmcli
description: NetworkManager from the command line — connections versus devices, static addressing, bridges and bonds, VLANs, and the field selection that makes it scriptable
tags: [linux, networking, nmcli, networkmanager, cli]
type: reference
status: complete
---

# nmcli

`nmcli` drives NetworkManager, which owns networking on most current distributions.
On openSUSE Leap 16 it is the default network stack, and it is equally standard on
RHEL and its derivatives and on Fedora.

> [!note]
> SUSE dropped `wicked` from SLES 16, and new Leap 16 systems use NetworkManager. But Leap 16.0 still has a
> community `wicked` package (from Backports) in its repository.

The concept that makes it click:

> [!important] A **connection** is a profile; a **device** is hardware
> A device is an interface — `eth0`, `wlan0`. A connection is a named, stored
> configuration that can be **applied** to a device. One device can have many
> connection profiles, only one active at a time.
>
> This is why `nmcli con up "Office LAN"` works: you are activating a saved profile,
> not configuring an interface. Once that distinction is clear, the rest of the tool
> is obvious.

## Status

```bash
nmcli                      # everything, colourised
nmcli general status
nmcli device status
nmcli connection show
nmcli connection show --active
```

```bash
nmcli device show eth0
nmcli connection show "Wired connection 1"
```

## Field selection

The flag that turns `nmcli` into something scriptable:

```bash
nmcli -t -f NAME,DEVICE,STATE connection show
nmcli -g IP4.ADDRESS device show eth0
nmcli -t -f DEVICE,STATE device status
```

| Flag | Effect |
| --- | --- |
| `-t` | Terse — colon-separated, no headers |
| `-f` | Select fields |
| `-g` | Get values only, one per line — best for scripts |
| `-p` | Pretty, human-oriented |

```bash
# Every active connection and its device
nmcli -t -f NAME,DEVICE connection show --active | while IFS=: read -r name dev; do
  echo "$name on ${dev:-none}"
done
```

`nmcli -f ALL device show eth0` lists every available field, which is how you find the
right name for `-g`.

## Creating connections

### DHCP

```bash
nmcli connection add type ethernet con-name "office" ifname eth0
nmcli connection up "office"
```

### Static

```bash
nmcli connection add type ethernet con-name "static-eth0" ifname eth0 \
  ipv4.method manual \
  ipv4.addresses 192.168.1.10/24 \
  ipv4.gateway 192.168.1.1 \
  ipv4.dns "192.168.1.1,9.9.9.9" \
  ipv4.dns-search "example.com" \
  ipv6.method disabled \
  connection.autoconnect yes
```

> [!warning] `ipv4.method manual` is required, and easily forgotten
> Setting `ipv4.addresses` without `ipv4.method manual` leaves the connection on
> `auto`. NetworkManager then runs DHCP **and** adds your address as an extra one:
> the interface gets two addresses, and the DHCP server's gateway and DNS. With no
> DHCP server, the activation fails after the DHCP timeout.

> [!note] Both addresses are set
> DHCP does not replace the static address: both are set. The advice stays the same.

## Modifying

```bash
nmcli connection modify "static-eth0" ipv4.addresses 192.168.1.20/24
nmcli connection modify "static-eth0" +ipv4.addresses 192.168.1.21/24   # add
nmcli connection modify "static-eth0" -ipv4.addresses 192.168.1.21/24   # remove
nmcli connection modify "static-eth0" ipv4.dns ""                       # clear
```

Changes are written but **not applied** until reactivated:

```bash
nmcli connection up "static-eth0"
# or
nmcli device reapply eth0
```

> [!danger] Reactivating a connection over SSH disconnects you
> `nmcli connection up` on the interface carrying your session drops it, and if the
> new configuration is wrong you have no way back.
>
> Two defences. Schedule a revert before making the change:
>
> ```bash
> sudo sh -c 'sleep 300 && nmcli connection up "known-good"' &
> ```
>
> Or make the change from a console session — see usage for
> serial console access on a VM. `nmcli device reapply` applies changes without a full
> deactivation and sometimes survives, but do not rely on it.

## Interactive editor

```bash
nmcli connection edit "static-eth0"
```

```text
nmcli> print ipv4
nmcli> set ipv4.dns 9.9.9.9
nmcli> verify
nmcli> save
nmcli> quit
```

`verify` before `save` catches invalid combinations, which is worth the extra step for
anything complex.

## Wi-Fi

```bash
nmcli device wifi list
nmcli device wifi rescan

nmcli device wifi connect "SSID" password "passphrase"
nmcli device wifi connect "SSID" password "passphrase" hidden yes

nmcli radio wifi off
nmcli radio wifi on
```

Enterprise networks:

```bash
nmcli connection add type wifi con-name "corp" ifname wlan0 ssid "CorpNet" \
  wifi-sec.key-mgmt wpa-eap \
  802-1x.eap peap \
  802-1x.phase2-auth mschapv2 \
  802-1x.identity "your.name@example.com" \
  802-1x.ca-cert /etc/pki/tls/certs/corp-ca.pem
```

## Bridges

For KVM and containers:

```bash
nmcli connection add type bridge con-name br0 ifname br0 \
  ipv4.method manual \
  ipv4.addresses 192.168.1.10/24 \
  ipv4.gateway 192.168.1.1 \
  ipv4.dns 192.168.1.1 \
  bridge.stp no

nmcli connection add type ethernet con-name br0-port1 ifname eth0 master br0

nmcli connection up br0
```

If `eth0` is already active with another profile, `nmcli connection up br0` only
brings up the bridge and says `controller waiting for ports`. Activate the port
profile too. It takes `eth0` from the old profile, so do it from a console, not over
SSH on `eth0`:

```bash
nmcli connection up br0-port1
```

`master br0` still works. Newer `nmcli` versions also accept `controller br0`, the
current name.

`bridge.stp no` is right for a host bridge with one uplink — spanning tree adds a
delay of tens of seconds at link-up for no benefit when there is no loop to prevent.

See [[linux/networking/virtual-interfaces]] for what a bridge is doing.

## Bonds

```bash
nmcli connection add type bond con-name bond0 ifname bond0 \
  bond.options "mode=802.3ad,miimon=100,lacp_rate=fast,xmit_hash_policy=layer3+4" \
  ipv4.method manual \
  ipv4.addresses 192.168.1.10/24 \
  ipv4.gateway 192.168.1.1

nmcli connection add type ethernet con-name bond0-p1 ifname eth0 master bond0
nmcli connection add type ethernet con-name bond0-p2 ifname eth1 master bond0

nmcli connection up bond0
```

As with a bridge, run `nmcli connection up bond0-p1` (and `bond0-p2`) if the
interfaces are in use by other profiles.

| Mode | Needs switch configuration | Notes |
| --- | --- | --- |
| `active-backup` | No | Failover only. The safe default |
| `802.3ad` (LACP) | Yes | Aggregation and failover. Requires a configured port channel |
| `balance-alb` | No | Load balancing without switch support |

`802.3ad` against a switch that is not configured for LACP produces a link that
appears up and drops traffic — worth confirming with the network team first.

## VLANs

```bash
nmcli connection add type vlan con-name vlan100 ifname vlan100 \
  dev eth0 id 100 \
  ipv4.method manual \
  ipv4.addresses 10.100.0.10/24
```

Stacking on a bond or bridge works the same way with `dev bond0`.

## Routes and policy routing

```bash
nmcli connection modify "static-eth0" \
  +ipv4.routes "10.0.0.0/8 192.168.1.254"

nmcli connection modify "static-eth0" \
  +ipv4.routes "172.16.0.0/12 192.168.1.254 100"     # with a metric

nmcli connection modify "static-eth0" ipv4.never-default yes
```

`ipv4.never-default yes` stops an interface installing a default route — essential on
a management or storage interface that should not become the default path.

## Where profiles live

```bash
ls /etc/NetworkManager/system-connections/
```

Keyfile format, mode 600 because they may contain passphrases. They are editable by
hand, followed by:

```bash
nmcli connection reload
```

Editing directly is reasonable for configuration management; see
[[automation/ansible/index|Ansible]], which has an `nmcli` module.

## Troubleshooting

```bash
nmcli -f GENERAL.STATE,GENERAL.REASON,IP4 device show eth0
nmcli connection show "static-eth0" | grep -E 'ipv4|autoconnect'
journalctl -u NetworkManager -f
nmcli general logging level DEBUG domains ALL
```

| Symptom | Check |
| --- | --- |
| Interface up, no address | `ipv4.method` — probably still `auto` |
| Does not come up at boot | `connection.autoconnect` |
| Wrong DNS | `ipv4.ignore-auto-dns`, or another connection winning |
| Two connections fighting | `connection.autoconnect-priority` |
| Device shows `unmanaged` | Excluded in `NetworkManager.conf`, or another tool owns it |

`unmanaged` is common on servers where `systemd-networkd` or an older `ifcfg` setup is
also present — two managers on one interface produces behaviour that looks random.

## Where to go next

- [[linux/cli/ip]] — the lower-level view of the result
- [[linux/networking/virtual-interfaces]] — bridges, VLANs and veth explained
- [[networking/iptables]] — filtering on the interfaces configured here

## Further reading

- [nmcli command examples cheatsheet](https://www.golinuxcloud.com/nmcli-command-examples-cheatsheet-centos-rhel/)

<!-- uplink -->
Part of [[linux/networking/index|Linux networking]].
