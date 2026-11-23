---
title: Kernel module attack surface
description: Why unused kernel modules are a liability, blacklisting them by hand and with modulejail, module signing, and kernel lockdown
tags: [security, linux, kernel, hardening, modules]
type: howto
status: complete
---

# Kernel module attack surface

A stock Linux kernel can auto-load several thousand modules. Almost none of them are
in use on any given machine, and each one is code running in ring 0 that a
vulnerability could be found in.

```bash
find /lib/modules/$(uname -r) -name '*.ko*' | wc -l    # available
lsmod | wc -l                                           # actually loaded
```

The gap between those two numbers is the point. The openSUSE Leap 16 kernel (6.12)
ships about 6,600 modules across its `kernel-default`, `-extra` and `-optional`
packages, 2,600 of them in `kernel-default` alone. A typical server has a few dozen
loaded.

## Why this matters

The risk is not that an attacker loads a module — that needs privilege already. It is
that **an unprivileged action can trigger auto-loading**, and the module then runs
attacker-influenced code in the kernel.

`request_module()` is called from many places: creating a socket of an unusual
protocol family loads that protocol's module, mounting a filesystem loads its driver,
an ioctl loads a device driver. So an unprivileged user creating a `DCCP` socket
causes the kernel to load `dccp.ko` — a rarely-used, rarely-audited protocol
implementation — and any bug in it is now reachable.

This is the mechanism behind a long line of local privilege escalations, and it is why
distributions ship blacklists for the obscure protocols.

## Blacklisting by hand

For the well-known offenders. Each module gets two lines: `install` stops every
load by name, and `blacklist` stops loading by alias (see the callout below):

```text
# /etc/modprobe.d/hardening.conf
install dccp /bin/false
blacklist dccp
install sctp /bin/false
blacklist sctp
install rds /bin/false
blacklist rds
install tipc /bin/false
blacklist tipc
install n_hdlc /bin/false
blacklist n_hdlc
install ax25 /bin/false
blacklist ax25
install netrom /bin/false
blacklist netrom
install x25 /bin/false
blacklist x25
install rose /bin/false
blacklist rose
install ieee802154_socket /bin/false
blacklist ieee802154_socket
install appletalk /bin/false
blacklist appletalk
install psnap /bin/false
blacklist psnap
install p8022 /bin/false
blacklist p8022
install can /bin/false
blacklist can

# Rarely-needed filesystems
install cramfs /bin/false
blacklist cramfs
install freevxfs /bin/false
blacklist freevxfs
install jffs2 /bin/false
blacklist jffs2
install hfs /bin/false
blacklist hfs
install hfsplus /bin/false
blacklist hfsplus
install squashfs /bin/false
blacklist squashfs
install udf /bin/false
blacklist udf

# FireWire and Thunderbolt: DMA access to memory
install firewire-core /bin/false
blacklist firewire-core
install thunderbolt /bin/false
blacklist thunderbolt
```

A name that your kernel does not build is harmless: the line never matches. Some of
these are useful on some machines: `squashfs` for snaps and live media, `udf` for
DVDs, `sctp` for telecom software, `thunderbolt` for docks. Remove what you need.

Rebuild the initramfs, so the file also applies in early boot:

```bash
sudo dracut -f          # openSUSE Leap and the RHEL family
```

> [!warning] Correction
> An earlier version used `install <mod> /bin/true` and listed `decnet`, `econet`,
> `ipx`, `p8023` and `af_802154`. Those five are gone: Econet was removed in Linux
> 3.5, IPX (and `p8023`, used only by IPX) in 4.18, DECnet in 6.1, and the 802.15.4
> socket module is now `ieee802154_socket`. DCCP was removed in 6.16, but 6.12
> kernels (openSUSE Leap 16, RHEL 10) still have it. Current DISA STIG rules for
> RHEL 9 ask for `install <mod> /bin/false` plus `blacklist <mod>`. With `/bin/false`,
> a blocked load fails loudly; with `/bin/true`, `modprobe` reports success and the
> caller believes the module is there.

> [!important] `install` is stronger than `blacklist`, and you want both
> `blacklist` only prevents *automatic* loading by alias — a direct
> `modprobe dccp` still works, as does any code path that requests the module by its
> real name.
>
> `install <mod> /bin/false` replaces the load action entirely, so the module cannot
> be loaded by any route short of `insmod` on the `.ko` file. For hardening, use the
> `install` form. Add the `blacklist` line too: compliance scanners check for it.
>
> It is weaker still for DCCP. The socket alias the kernel asks for
> (`net-pf-2-proto-33-type-6`) belongs to `dccp_ipv4`, which pulls in `dccp` as a
> dependency, and `blacklist` does not apply to dependencies. So `blacklist dccp`
> alone does not stop the auto-load. `install dccp /bin/false` does: `modprobe` runs
> install commands for dependencies too, and `dccp_ipv4` cannot load without `dccp`.

This is what CIS benchmarks and DISA STIGs check for, and what
[[linux/distributions/nixos/hardening|`boot.blacklistedKernelModules`]] generates on
NixOS.

## modulejail

[modulejail](https://github.com/jnuyens/modulejail) automates the general case: a
POSIX shell script that inspects which modules are currently loaded and writes a
`modprobe.d` blacklist for **everything else**.

```bash
# Read it first — see the warning below
curl -fsSL https://raw.githubusercontent.com/jnuyens/modulejail/v1.6.3/modulejail -o modulejail
less modulejail
sudo sh ./modulejail --dry-run     # print what it would block, write nothing
sudo sh ./modulejail
```

It writes `/etc/modprobe.d/modulejail-blacklist.conf` (`-o` picks another path).
By default each line logs the blocked load to syslog (when `logger` is installed)
and returns success; `-f` makes blocked loads fail, like `/bin/false` above. The
project also publishes `.deb` and `.rpm` packages on its releases page.

It ships profiles (`minimal`, `conservative`, `desktop`, `firewall`, `none`) for
machines that need more than the currently-loaded set — a desktop needs Wi-Fi and
audio drivers that may not be loaded at the moment you run it:

```bash
sudo sh ./modulejail -p desktop
```

> [!danger] Do not pipe this to a root shell
> The project's quickstart is `curl … | sudo sh`. That executes whatever the endpoint
> returns, as root, at the moment you run it — for a script whose entire purpose is
> changing what your kernel will load.
>
> Download it, read it, pin the version tag, and run it from disk. The irony of
> installing a hardening tool through an unverified remote-execution pattern is worth
> avoiding.

> [!warning] "Not currently loaded" is not the same as "not needed"
> The script's model is a snapshot. Anything that loads on demand — a USB device you
> plug in later, a filesystem you mount next month, a NIC that comes up after a
> hardware change, the driver for a disk in a rescue boot — is not loaded now and gets
> blacklisted.
>
> Test on a machine you can reach out of band. The realistic failure is a server that
> boots fine and then cannot mount a filesystem or bring up an interface after
> maintenance, with a cause several weeks removed from the change.

Sensible use: run it, **read the generated file**, and remove the entries for anything
you can foresee needing.

```bash
wc -l /etc/modprobe.d/modulejail-blacklist.conf
```

> [!note] The initramfs
> dracut copies `/etc/modprobe.d/` into the initramfs. A blacklist that blocks
> everything not loaded today can then stop the next kernel from finding its disk.
> `modulejail --install-initramfs-hook` installs a hook that keeps its file out of
> the initramfs.

## Preventing loading entirely

Once a machine has everything it needs, stop module loading altogether:

```bash
sudo sysctl -w kernel.modules_disabled=1
```

```ini
# /etc/sysctl.d/99-hardening.conf
kernel.modules_disabled = 1
```

This is one-way — it cannot be unset without a reboot, which is the point. Set it
late in boot, after all legitimate modules have loaded.

> [!warning] `modules_disabled=1` breaks things that load modules lazily
> Containers requesting `overlay` or `br_netfilter`, VPN clients, `iptables` loading a
> match module on first use, and some filesystems. On a Kubernetes node in particular
> this will break the CNI unless every needed module is loaded at boot.
>
> Pre-load what you need explicitly, then disable:
>
> ```text
> # /etc/modules-load.d/kubernetes.conf
> overlay
> br_netfilter
> ```

## The complementary controls

Blacklisting is one of three layers, and they solve different problems:

| Control | Prevents |
| --- | --- |
| **Blacklisting** | Loading a module you never wanted |
| **Module signing** | Loading a module you did not build. See [[security/boot-integrity/secure-boot]] |
| **Kernel lockdown** | Everything else — `/dev/mem`, unsigned kexec, tracing that could patch the kernel |

Distribution kernels built with `CONFIG_LOCK_DOWN_IN_EFI_SECURE_BOOT` (openSUSE
Leap 16's is one) turn on lockdown in `integrity` mode when Secure Boot is on. The
mainline default is no lockdown:

```bash
cat /sys/kernel/security/lockdown
# none [integrity] confidentiality
```

Together: signing means only your modules load, blacklisting means most of them never
get the chance, and lockdown means the kernel cannot be modified by other routes.

## Auditing

```bash
# What loaded, and when
journalctl -k | grep -i 'module'

# Watch for module loads
auditctl -a always,exit -F arch=b64 -S init_module,finit_module -k module_load
```

That audit rule is worth having permanently — a module load on a steady-state server
is unusual enough to be interesting. See [[security/auditd]].

## Where to go next

- [[security/boot-integrity/secure-boot]] — module signing, and enrolling your own key
- [[linux/distributions/nixos/hardening]] — the declarative equivalent
- [[security/auditd]] — persisting the audit rule
- [[containers/concepts]] — why the shared kernel makes this matter for containers

## Sources

- [modulejail](https://github.com/jnuyens/modulejail) — the blacklist generator
  described above

<!-- uplink -->
Part of [[security/index|Security]].
