---
title: Ansible inventory, connections and facts
description: Describing hosts and groups, connecting over SSH and WinRM, testing connectivity, and gathering facts
tags: [automation, ansible, inventory, ssh, winrm, facts]
type: howto
status: complete
---

# Inventory, connections and facts

## The inventory

All managed servers are described in one or more inventory files:

```ini
dns-01                              # a server belonging to no group
ntp   ansible_host=ntp.test.lab     # an alias, to make the inventory readable

[apache:children]                   # a group of groups
apache_pub
apache_admin

[apache_pub]
svr-apache-01

[apache_admin]
svr-apache-02
```

Use an inventory other than the default:

```bash
ansible -i ~/alternative_inventory apache -m ping
```

Inspect the inventory and its variables without opening the file:

```bash
ansible-inventory all -i ~/alternative_inventory --graph
ansible-inventory all -i ~/alternative_inventory --graph --vars
ansible-inventory all -i ~/alternative_inventory --list      # JSON
```

> [!tip] YAML inventories and inventory directories
> The INI format above is the classic one, but `inventory: ./inventory/` pointing at
> a *directory* lets you split hosts across several files — and mix INI, YAML and
> dynamic inventory scripts — which scales much better than one large file.

## Connecting to hosts

Ansible uses each OS's native mechanism: SSH for Linux, WinRM for Windows.

For SSH, prefer key exchange — more secure than a password and easier to manage.
Generate a key pair:

```bash
ssh-keygen -t ed25519
```

Then send the public key to the remote servers:

```bash
ssh-copy-id -i ~/.ssh/id_ed25519.pub ansible_user@remote-server
```

See [[linux/ssh]] for more on key management.

By default Ansible connects as the current user. To use another account, set it in
the inventory as a host variable:

```ini
svr-apache-01   ansible_user=deploy
```

Or directly in the playbook:

```yaml
- hosts: apache
  become: true
  remote_user: deploy
```

`become` performs privilege escalation regardless of the target OS — provided the
account has the rights to do so via sudo or equivalent.

### Windows and WinRM

Windows hosts need WinRM configured and listening before Ansible can reach them.
Microsoft and the Ansible project publish a bootstrap script for this:

```powershell
.\ConfigureRemotingForAnsible.ps1
```

Get it from
[`ansible-documentation`](https://github.com/ansible/ansible-documentation/blob/devel/examples/scripts/ConfigureRemotingForAnsible.ps1).
It is not vendored here: it is GPLv3, and pinning a copy would leave you running a
stale bootstrap script against a current Windows build.

> [!note] It moved repositories
> The script used to live in `ansible/ansible` under `examples/scripts/`. It was
> removed from that repository's `devel` branch and is now maintained in
> `ansible/ansible-documentation`, so older links to it 404.

See administration for the OS side of these hosts.

> [!warning] The default configuration is for testing only
> Run bare, the script sets up an HTTP listener with a self-signed certificate and
> Basic authentication. For anything real, use `-CertValidityDays`,
> `-ForceNewSSLCert` and disable Basic auth in favour of Kerberos or CredSSP.

Then in the inventory:

```ini
[windows]
win-01

[windows:vars]
ansible_connection=winrm
ansible_winrm_transport=kerberos
ansible_port=5986
```

## Testing connectivity

Once the inventory is written, there is a module for testing it. Test the whole
inventory, then a group, then one server:

```bash
ansible all -m ping
ansible apache -m ping
ansible svr-apache-01 -m ping
```

You can also exclude a host from a group:

```bash
ansible 'apache:!svr-apache-02' -m ping
```

> [!note] `ping` is not ICMP
> The `ping` module connects over SSH, runs a trivial Python payload and expects
> `pong`. So it validates the whole chain — reachability, authentication *and* a
> usable Python interpreter — which is much more useful than an ICMP echo. For
> Windows the equivalent is `win_ping`.

## Facts

**Facts** are information gathered from the servers. By default every **play**
begins by gathering facts from the remote hosts, which can waste time
unnecessarily.

If you do not use them, disable collection by adding `gather_facts: false` to the
play. You can also disable it by default in the configuration and set
`gather_facts: true` only where you need it — see
[[automation/ansible/installation]], `gathering = explicit`.

You can also use fact caching, which avoids interrogating hosts on every run.

### The setup module

`setup` is the module that retrieves facts about a target:

```console
$ ansible svr-apache-01 -m setup
svr-apache-01 | SUCCESS => {
    "ansible_facts": {
        "ansible_default_ipv4": {
            "address": "172.20.10.11",
            "broadcast": "172.20.10.15",
            "device": "en0",
            "gateway": "172.20.10.1",
            "interface": "en0",
            "macaddress": "f0:18:98:14:6d:77",
            "mtu": "1500",
            "netmask": "255.255.255.240",
            "network": "172.20.10.0",
            "type": "ether"
        },
        "ansible_distribution": "openSUSE Leap",
        "ansible_distribution_major_version": "16",
        "ansible_distribution_version": "16.0",
        ...
```

Filter to the fact you actually want, rather than reading all of it:

```bash
ansible svr-apache-01 -m setup -a 'filter=ansible_distribution*'
```

The facts most often used in conditions are `ansible_os_family`,
`ansible_distribution`, `ansible_distribution_major_version` and
`ansible_default_ipv4.address` — see
[[automation/ansible/variables#Conditions]].

<!-- uplink -->
Part of [[automation/ansible/index|Ansible]].
