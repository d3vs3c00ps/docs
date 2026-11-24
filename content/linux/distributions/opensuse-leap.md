---
title: openSUSE Leap
description: Reclaiming disk space with zypper, controlling upgrades with repository priorities and locks, unattended patching and system hardening
tags: [linux, opensuse, leap, zypper, rpm, packaging, security, hardening]
type: howto
status: complete
---

# openSUSE Leap

Notes for managing an openSUSE Leap 16 server. See [[linux/distributions/rhel]]
for the RHEL equivalents.

> [!note] Which release these notes target
> Leap 16.0, released October 2025. Leap 16 is a substantial break from the 15.x
> line: **YaST is gone**, **SELinux replaces AppArmor** as the default LSM, and
> NetworkManager is the default network stack (`wicked` is only left as a
> community package). Where a command differs from 15.x,
> it is called out below.

> [!info] `zypper` versus `rpm`
> `zypper` is the dependency-resolving package manager and the one you want for
> anything that installs, removes or updates. `rpm` operates on individual
> packages with no dependency resolution — use it for queries (`rpm -qf`,
> `rpm -Va`) and leave changes to `zypper`.

## Reclaiming disk space

When a Leap server starts running out of space, the package layer is usually
worth a look first.

Empty the package cache in `/var/cache/zypp`:

```bash
zypper clean --all
```

`--all` drops both the downloaded RPMs and the repository metadata. To keep the
metadata and only discard the packages, give no option:

```bash
zypper clean
```

> [!note] No `--packages`
> `zypper clean --packages` stops with `The flag --packages is not known`. Plain
> `zypper clean` removes the cached packages only.

> [!note] The cache is usually smaller than APT's
> Unlike APT, zypper does not keep downloaded RPMs by default — `keeppackages`
> is off on each repository unless you turn it on. If `/var/cache/zypp` is large,
> check `zypper repos --details` for a repository with caching enabled.

List packages that nothing else requires any more:

```bash
zypper packages --unneeded
```

Remove a package along with the dependencies it was the only user of:

```bash
zypper remove --clean-deps <package>
```

Trim translations and documentation you do not need. Set the locales to keep in
a macro file such as `/etc/rpm/macros.lang` (rpm reads `/etc/rpm/macros.*`, not a
`macros.d` folder under `/etc/rpm/`):

```text
%_install_langs en:en_US:en_GB
```

and, to skip documentation entirely, in `/etc/zypp/zypp.conf`:

```text
rpm.install.excludedocs = yes
```

> [!warning] Both settings only apply going forward
> They affect packages installed or updated *after* the change; files already on
> disk stay. Reinstalling the affected packages is what actually frees the space.

> [!tip] Find what is actually using the space first
> `rpm -qa --queryformat '%{SIZE}\t%{NAME}\n' | sort -n | tail -20` lists the
> twenty largest installed packages. Often one of them is the real problem.

## Controlling upgrades

Leap gives you three levers where APT has pin priorities: **repository
priority**, **package locks**, and **vendor stickiness**.

### The openSUSE release model

| Release | Meaning |
| --- | --- |
| **Leap** | fixed release, built on SLES sources; security and maintenance updates only |
| **Slowroll** | Tumbleweed's package set, batched into roughly monthly updates |
| **Tumbleweed** | rolling; continuously updated |

Unlike Debian there is no `testing`/`unstable` to borrow single packages from.
The equivalent move is to add an **OBS devel project** repository for the one
package you need, at a lower priority than the distribution.

### Repository priorities

```bash
zypper modifyrepo --priority 90 <alias>
zypper repos --sort-by-priority --details
```

> [!warning] Lower numbers win — the opposite of APT
> zypper priorities run **1 (highest) to 2147483647 (lowest)**, default **99**.
> This is inverted relative to `apt_preferences(5)`, where a *higher* number
> wins. Setting an OBS repository to `100` puts it *below* the distribution;
> setting it to `50` lets it override the distribution wholesale, which is
> almost never what you want.

Priority is compared before version: a package available from a
higher-priority repository is chosen even when a lower-priority repository has a
newer version.

### Vendor stickiness

zypper will not silently swap a package for a build from a different vendor.
Once a package comes from an OBS project, updates keep coming from that project;
moving it back to the distribution build takes an explicit flag:

```bash
zypper install --allow-vendor-change --from openSUSE:repo-oss <package>
```

This is the mechanism that keeps a single package from a third-party repository
from dragging the rest of the system along with it — the failure mode that makes
APT pinning across suites so risky.

### Locking a package

The equivalent of `apt-mark hold`:

```bash
zypper addlock kernel-default      # freeze
zypper locks                       # list
zypper removelock kernel-default   # release
```

Locks live in `/etc/zypp/locks`, one stanza per lock, and accept globs
(`zypper addlock 'kernel-*'`).

> [!note] What a lock does to an update
> `zypper update` leaves a locked package where it is, lists it under "The
> following package update will NOT be installed", and updates the rest. An
> explicit `zypper install` of a new version of the locked package is refused.
> zypper reports a conflict only when another package needs the locked one to
> change.

> [!note] What a lock does
> `zypper update` skips a locked package, and says so in its list. It does not stop
> and ask.

### Repositories on Leap 16

Leap 16 manages the distribution repositories through the **openSUSE-repos**
package, which uses the Repository Index Service to point at `cdn.opensuse.org`
and picks a mirror for you. Their aliases carry an `openSUSE:` prefix:

```bash
zypper repos --details
```

| Alias | Contents |
| --- | --- |
| `openSUSE:repo-oss` | the distribution — open source software |
| `openSUSE:repo-non-oss` | packages under non-free licences |
| `openSUSE:repo-oss-source` | source RPMs |
| `openSUSE:repo-oss-debug` | debuginfo |

Enable or disable them by alias rather than editing files:

```bash
zypper modifyrepo --enable openSUSE:repo-non-oss
zypper modifyrepo --disable openSUSE:repo-oss-debug
```

> [!warning] Two changes from Leap 15.x
> There is **no separate update repository** any more — updates ship in the
> distribution repositories. And repository metadata is now **split per
> architecture**, which is why refreshes are noticeably faster. Configuration
> written for 15.x that adds `repo-update` by hand will not work.

Third-party repositories still land in `/etc/zypp/repos.d/*.repo`, the
positional equivalent of `/etc/apt/sources.list.d/`. Adding one:

```bash
zypper addrepo --refresh --priority 100 \
  https://download.opensuse.org/repositories/<project>/16.0/ <alias>
zypper --gpg-auto-import-keys refresh
```

## Unattended upgrades

Leap's equivalent of `unattended-upgrades` is **os-update**, which wraps zypper
in a systemd timer and handles service restarts and reboots.

```bash
zypper install os-update
systemctl enable --now os-update.timer
```

Vendor defaults live in `/usr/share/os-update/os-update.conf`; put your
overrides in `/etc/os-update.conf`:

```text
# auto | dup | up | security
UPDATE_CMD="security"

# auto | rebootmgr | reboot | none
REBOOT_CMD="none"

RESTART_SERVICES="yes"
IGNORE_SERVICES_FROM_RESTART="dbus dbus-broker"
SERVICES_TRIGGERING_REBOOT=""
LOG_TAG="os-update"
```

`UPDATE_CMD="security"` runs `zypper patch --category security`, which is the
closest match to taking only the security origins in
`Unattended-Upgrade::Origins-Pattern`.

Adjust the schedule as you would any timer, with a drop-in rather than by
editing the shipped unit:

```bash
systemctl edit os-update.timer
```

Output goes to the journal under the configured `LOG_TAG`:

```bash
journalctl -t os-update
```

See what patching would do without changing anything:

```bash
zypper --non-interactive patch --dry-run --category security
```

### Restarting what the patch affected

Patching is not enough — until the affected service restarts, it keeps running
the old code and the vulnerability remains. zypper tracks this itself, so
there is no `needrestart` to install:

```bash
zypper ps -s              # services running deleted or updated libraries
zypper needs-rebooting    # is a full reboot required?
```

`os-update` uses `zypper ps` to find the services to restart
(`RESTART_SERVICES`). It does not call `zypper needs-rebooting`: it asks for a reboot
(`REBOOT_CMD`) when a newer kernel is installed or when a service listed in
`SERVICES_TRIGGERING_REBOOT` needs a restart.

> [!note] `os-update`
> `os-update` only calls `zypper ps`; checked in the `os-update` script of Leap 16.0.

## Useful commands

Check for pending patches, and list them by severity:

```bash
zypper patch-check
zypper list-patches --category security
```

Download a package without installing it — it lands in
`/var/cache/zypp/packages/`:

```bash
zypper install --download-only <package>
```

Find which package owns a file, or which package would provide one:

```bash
rpm -qf /usr/bin/ss
zypper what-provides /usr/bin/ss
```

Repair a system whose dependencies have been broken by hand:

```bash
zypper verify
```

## Hardening

### SELinux

Leap 16 ships **SELinux with the targeted policy, enforcing by default**. Check
where you stand:

```bash
sestatus
getenforce
```

> [!warning] Do not reach for AppArmor on 16
> AppArmor cannot be selected as the LSM during a fresh Leap 16 install — it was
> dropped from SLE 16 and Leap follows. A system *upgraded* from 15.6 keeps
> AppArmor, so a fleet mid-migration will have both; check `sestatus` rather
> than assuming. Configuration written against `aa-status` and
> `/etc/apparmor.d/` does not carry over.

When a service misbehaves after a policy change, read the denials before
loosening anything:

```bash
journalctl -t setroubleshoot
ausearch -m AVC -ts recent
```

### File permissions and setuid monitoring

SUSE ships a permissions framework in place of Debian's `checksecurity`.
`chkstat` compares the system against a declared profile:

```bash
zypper install permissions
chkstat --system            # check and apply
chkstat --system --warn     # report only
```

> [!warning] There is no `--dry-run`
> chkstat reads `--dry-run` as the one path to check, prints `Cannot check this path`,
> and reports nothing else. Use `--warn`.

The profile is selected in `/etc/sysconfig/security` via
`PERMISSION_SECURITY`, with `easy`, `secure` and `paranoid` shipped in
`/usr/share/permissions/`. Local overrides go in `/etc/permissions.local`.

> [!tip] `paranoid` removes almost every setuid bit
> It is a useful audit baseline — run it with `--warn` to see the full list
> of setuid and setgid binaries on the host — but applying it on a general
> purpose server will break `sudo`, `su`, `mount` and ping. Prefer `secure`.

### Verifying package integrity

Where Debian needs `debsums` installed, RPM records digests for every packaged
file and verifies them out of the box:

```bash
rpm --verify --all
```

Each line of output is a file that differs from what its package shipped. The
flags mark what changed — `S` size, `M` mode, `5` digest, `U` owner, `G` group,
`T` mtime — and `c` marks a configuration file, where local edits are expected.

Show only files whose contents changed, ignoring config:

```bash
rpm -Va | grep '^..5' | grep -v '^.\{9\}  c '
```

> [!note] Why this filter
> `rpm -Va | grep -v '^..5......  c '` only hides changed config files, and still
> shows every other line, such as mode, owner or time changes. The filter above keeps
> the lines with `5` in the digest column, then drops config files.

> [!note] Strictly stronger than `debsums`
> RPM verification uses SHA-256 and checks mode, ownership and size as well as
> content, so there is nothing to generate for packages that "ship no checksums"
> — the metadata is part of every RPM. The `debsums --generate=missing` trap,
> where you bake a compromise into the baseline, has no equivalent here.

The one thing it cannot tell you is whether the RPM database itself was
tampered with. Keep a copy of `/var/lib/rpm` off the host if that matters.

### Finding orphaned packages

Packages still installed but no longer provided by any repository:

```bash
zypper packages --orphaned
```

Packages nothing depends on any more:

```bash
zypper packages --unneeded
```

Review the list, and only then remove:

```bash
zypper remove --clean-deps <package>...
```

> [!warning] Read the list every time
> `--unneeded` reports packages with no reverse dependencies, which includes
> everything you installed deliberately. Piping it straight into `zypper remove`
> unreviewed will eventually take something you wanted.

`zypper dist-upgrade` keeps orphaned packages. Add `--remove-orphaned` to have it
remove them:

```bash
zypper dist-upgrade --remove-orphaned
```

> [!note] Orphans
> `zypper dist-upgrade` does not remove orphaned packages by itself; it needs
> `--remove-orphaned`.

### Auditing with lynis

`lynis` walks the system configuration and produces a summary of system
information and security findings, in a form usable by professional auditors and
for automated audits.

`lynis` is in the distribution repository:

```bash
zypper install lynis
```

> [!note] `lynis` is in `repo-oss`
> Leap 16.0 ships `lynis` in `repo-oss`. Use the `security` project on the Open Build
> Service only if you need a newer version, with a priority above 99 (see
> [[#Repository priorities]]).

```bash
lynis audit system --quick
```

The report is written to `/var/log/lynis-report.dat`.

### Linux Malware Detect (maldet)

```bash
wget https://www.rfxn.com/downloads/maldetect-current.tar.gz
tar xfz maldetect-current.tar.gz
cd maldetect-*
./install.sh
```

Update the signature database:

```bash
maldet -u
```

Settings — email reports, quarantine behaviour — live in
`/usr/local/maldetect/conf.maldet`.

maldet's signatures can be added to ClamAV so a single scan uses both databases:

```bash
zypper install clamav
ln -s /usr/local/maldetect/sigs/rfxn.hdb /var/lib/clamav/rfxn.hdb
ln -s /usr/local/maldetect/sigs/rfxn.ndb /var/lib/clamav/rfxn.ndb
systemctl restart clamd
```

> [!warning] The service is `clamd`, not `clamav-daemon`
> SUSE names the unit `clamd.service`. `freshclam.service` handles signature
> updates separately.

Then scan — `--recursive` descends the tree, `--infected` prints only positive
results, and `--log` records the output:

```bash
clamscan --recursive --infected --log=/var/log/clamscan
```

> [!warning] Installing from an unverified tarball
> This pipes a tarball from a third-party site straight into a root install
> script. Verify the download before running it, and prefer the distribution's
> `clamav` packages where they suffice.

### Restricting cron

To allow only some users to create scheduled tasks, list them in
`/etc/cron.allow`. Once the file exists, every user who is not in it is refused:

```bash
echo your.name >> /etc/cron.allow
```

> [!note] `cron.allow` wins
> If `/etc/cron.allow` exists, only the users listed in it may use `crontab` and
> `cron.deny` is ignored entirely. root may always use `crontab`, even with an
> empty `cron.allow`. `cron.deny` lists users to refuse when there is no
> `cron.allow`.

> [!warning] cronie has no `ALL` keyword
> `echo ALL >> /etc/cron.deny` denies a user named `ALL`: every other user may still use
> `crontab`. An empty `cron.allow` does not lock out root: cronie lets root through.

> [!tip] Leap 16 defaults to `cronie`
> Systemd timers are the better target for anything you control, since they get
> journal integration, dependency ordering and `systemd-analyze` verification.
> The `cron.allow`/`cron.deny` gate does not apply to them — restrict timer
> creation with filesystem permissions on `/etc/systemd/system/` instead.

### Disabling Ctrl+Alt+Del

On Linux this key combination reboots the system. Anyone with physical or console
access can use it, so disable it:

```bash
systemctl mask ctrl-alt-del.target
```

This is the supported equivalent of the older
`ln -s /dev/null /etc/systemd/system/ctrl-alt-del.target`.

### Disabling the Magic SysRq key

Magic SysRq combinations let anyone on a console trigger low-level kernel
actions. You hold `Alt` + `SysRq` (`Print Screen`) and press an action key:

| Keys | Action |
| --- | --- |
| `Alt+SysRq+o` | power off the system immediately |
| `Alt+SysRq+r,e,i,s,u,b` | reboot cleanly — *Reboot Even If System Utterly Broken* |

Useful, but dangerous: it can remount filesystems read-only, reboot the host, or
panic the kernel. Disable it with a drop-in:

```bash
echo 'kernel.sysrq = 0' > /etc/sysctl.d/99-disable-sysrq.conf
sysctl --system
```

> [!note] The `reisub` order is deliberate
> **r**aw keyboard, t**e**rminate, k**i**ll, **s**ync, **u**nmount, re**b**oot —
> it syncs and unmounts before rebooting, which is why it is the safe sequence
> rather than just `b`.

> [!warning] `/etc` is override-only on Leap 16
> systemd's shipped configuration moved to `/usr/lib/sysctl.d/` and
> `/usr/lib/systemd/`. Keep writing your own settings to `/etc/sysctl.d/` and
> `/etc/systemd/system/` — those still win — but do not edit the `/usr` copies,
> since a package update will replace them.

## Coming from Debian

| Debian / APT | openSUSE Leap 16 |
| --- | --- |
| `apt install` / `remove` | `zypper install` / `remove` |
| `apt update` | `zypper refresh` |
| `apt upgrade` | `zypper update` |
| `apt full-upgrade`, release upgrade | `zypper dist-upgrade` |
| `apt-get clean` / `autoclean` | `zypper clean --all` / `zypper clean` |
| `apt-get autoremove` | `zypper packages --unneeded` then `zypper rm --clean-deps` |
| `apt-get download` | `zypper install --download-only` |
| `apt-cache search` | `zypper search` |
| `apt-file search`, `dpkg -S` | `zypper what-provides`, `rpm -qf` |
| `dpkg -L` | `rpm -ql` |
| `apt-mark hold` | `zypper addlock` |
| `/etc/apt/preferences.d/` pin priorities | repository priority (inverted), locks, vendor stickiness |
| `/etc/apt/sources.list.d/` | `/etc/zypp/repos.d/` |
| `unattended-upgrades` | `os-update` |
| `needrestart` | `zypper ps -s`, `zypper needs-rebooting` |
| `debsums` | `rpm --verify --all` |
| `deborphan` | `zypper packages --orphaned` / `--unneeded` |
| `checksecurity` | `chkstat`, the `permissions` package |
| `localepurge` | `%_install_langs`, `rpm.install.excludedocs` |
| `update-initramfs -u` | `dracut --force` |
| AppArmor | SELinux, targeted policy, enforcing |

<!-- uplink -->
Part of [[linux/distributions/index|Distributions]].
