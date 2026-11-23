---
title: SELinux
description: Mandatory access control on Linux — contexts, modes, booleans, and fixing the mislabelled file that broke your web server
tags: [security, linux, selinux, mac, hardening]
type: howto
status: complete
---

# SELinux

**Security-Enhanced Linux** lets you define access policies for elements of the
operating system — processes (daemons) and files.

Each process is confined to one or more **domains**, and files are **labelled**
accordingly. Simplifying somewhat: a process can only access files labelled for the
domain it is confined to.

Think of SELinux as an extra layer on top of traditional Unix permissions. That
definition is crude, but it explains most of the trouble you will run into: a file
can have permissions that clearly allow access and still be unreadable, because the
label is wrong.

SELinux improves the security of the servers it runs on. If a process is
compromised, it still only reaches files labelled for it, and still cannot do
anything beyond what it was designed to do.

> [!note] It complements, it does not replace
> SELinux is not a substitute for the rest: patched programs, a firewall, sane
> password policy. It is one more layer.

## Operating modes

| Mode | Behaviour |
| --- | --- |
| **Enforcing** | The default on most modern SELinux-enabled distributions. Access is restricted according to the active policy. |
| **Permissive** | Debugging mode. Rules are evaluated and violations logged, but nothing is blocked. Useful to collect every denial a process would hit. |
| **Disabled** | Nothing restricted, nothing logged. |

`getenforce` reports the current mode. `setenforce` switches temporarily between
enforcing and permissive — the change does not survive a reboot:

```bash
setenforce 0    # permissive
setenforce 1    # enforcing
```

> [!warning] Files created while SELinux is disabled have no label
> With SELinux disabled, newly created files are not labelled. Re-enabling SELinux
> then leaves those files inaccessible, and the whole filesystem needs relabelling:
>
> ```bash
> touch /.autorelabel
> systemctl reboot
> ```
>
> At the next boot every file is relabelled. On a large filesystem this takes a
> while, and the machine is unavailable throughout.

> [!warning] Correction
> An earlier version said permissive mode also leaves new files unlabelled. It does
> not: in permissive mode the policy is loaded and files get their labels as usual.
> Only the disabled state skips labelling. That is why you switch to permissive, not
> disabled, to debug.

## Current status

`sestatus` gives the general picture — enabled or not, current mode, loaded policy:

```bash
$ sestatus
SELinux status:                 enabled
SELinuxfs mount:                /sys/fs/selinux
SELinux root directory:         /etc/selinux
Loaded policy name:             targeted
Current mode:                   enforcing
Mode from config file:          enforcing
Policy MLS status:              enabled
Policy deny_unknown status:     allowed
Memory protection checking:     actual (secure)
Max kernel policy version:      33
```

More generally, `-Z` shows SELinux context information and is understood by `ps`,
`ls`, `cp`, `id` and others.

### Contexts of all processes

```bash
$ ps -ef -Z
LABEL                           UID        PID  PPID  C STIME TTY          TIME CMD
system_u:system_r:init_t:s0     root         1     0  0 May09 ?        00:00:02 /sbin/init
system_u:system_r:kernel_t:s0   root         2     0  0 May09 ?        00:00:00 [kthreadd]
system_u:system_r:kernel_t:s0   root         3     2  0 May09 ?        00:00:00 [migration/0]
system_u:system_r:kernel_t:s0   root         4     2  0 May09 ?        00:00:12 [ksoftirqd/0]
```

### Contexts of the httpd processes

```bash
$ ps -ef -Z | grep httpd
system_u:system_r:httpd_t:s0    root      2792     1  0 May09 ?        00:00:18 /usr/sbin/httpd
system_u:system_r:httpd_t:s0    apache   13928  2792  0 May13 ?        00:00:01 /usr/sbin/httpd
system_u:system_r:httpd_t:s0    apache   18787  2792  0 May10 ?        00:00:07 /usr/sbin/httpd
```

### Contexts of files under `/var/www/`

```bash
$ ls -alZ /var/www/
drwxr-xr-x  root   root   system_u:object_r:httpd_sys_content_t:s0 .
drwxr-xr-x  root   root   system_u:object_r:var_t:s0       ..
drwxr-xr-x  root   root   system_u:object_r:httpd_sys_script_exec_t:s0 cgi-bin
drwxr-xr-x  root   root   system_u:object_r:httpd_sys_content_t:s0 error
drwxr-xr-x  root   root   system_u:object_r:httpd_sys_content_t:s0 html
drwxr-xr-x  root   root   system_u:object_r:httpd_sys_content_t:s0 icons
```

File contexts are defined by the policy installed on the system. Some packages ship
their own SELinux module, either integrated directly or as a sub-package. Either
way, the module carries the rules that let the program work under SELinux.

## Reading a context

A context looks like this:

```text
user:role:type:level
```

For `/var/www/html`:

```text
system_u:object_r:httpd_sys_content_t:s0 html
```

- user `system_u`
- role `object_r`
- type `httpd_sys_content_t`
- level `s0`

### Users

Every Linux user is mapped to an SELinux user by the current policy, inheriting that
user's rights and restrictions. List the mapping with:

```bash
# semanage login -l

Login Name           SELinux User         MLS/MCS Range        Service

__default__          unconfined_u         s0-s0:c0.c1023       *
root                 unconfined_u         s0-s0:c0.c1023       *
```

### Roles

Roles sit between users and domains. Domains are reachable by defined roles, and
roles are reachable by defined users.

### Types

A type groups objects that are similar from a security point of view — it is not
tied to a particular file or directory. Users' home directories, for example, hold
wildly different content; what they have in common is belonging to a user, hence the
type `user_home_t`.

> [!warning] Correction
> An earlier version named this type `home_user_t`. The targeted policy has no such
> type: it is `user_home_t` (and `user_home_dir_t` for the home directory itself).

## What it actually buys you

Each process is confined to its domain and cannot reach anything outside the right
context. `sesearch` lists what a domain is allowed to do:

```bash
dnf install -y setools-console
```

For `httpd`:

```bash
sesearch --allow -s httpd_t -c file -p write
```

Abridged output from RHEL 10 (setools 4). A rule on an attribute (`httpdcontent`,
`domain`) covers every type in it. A rule followed by a boolean in brackets applies
only when that boolean is on:

```text
allow httpd_t cifs_t:file { append create getattr ioctl link lock open read rename setattr unlink watch watch_reads write }; [ httpd_use_cifs ]:True
allow httpd_t httpdcontent:file { append create getattr ioctl link lock open read rename setattr unlink watch watch_reads write }; [ ( httpd_builtin_scripting && httpd_unified && httpd_enable_cgi ) ]:True
```

Any file not labelled with one of those types cannot be written by `httpd`. The same
query with `-p read` gives the types it may read. Apache will not be allowed to touch
any other file **even if the Unix permissions say it can**.

## A worked example

Serve a simple HTML file with Apache. Create a working directory under
`/var/www/html`, owned by your own user and group:

```bash
mkdir /var/www/html/selinux && chown -R alice:alice /var/www/html/selinux
```

Create `index.html` in it:

```html
<!DOCTYPE html>
<html lang="en">
<head>
    <title>SELinux test</title>
    <meta charset="UTF-8" />
</head>
<body>
    <p>SELinux is letting you read this page.</p>
</body>
</html>
```

Look at the contexts:

```bash
$ ls -alZ /var/www/html/selinux/
drwxr-xr-x  alice alice unconfined_u:object_r:httpd_sys_content_t:s0 .
drwxr-xr-x  root  root  system_u:object_r:httpd_sys_content_t:s0 ..
-rw-rw-r--  alice alice unconfined_u:object_r:httpd_sys_content_t:s0 index.html
```

Opening `http://localhost/selinux/index.html` works. It works because the directory
is labelled `httpd_sys_content_t`, which is one of the types `httpd_t` may read.

Now the interesting half:

```bash
cp /var/www/html/selinux/index.html /tmp/selinux.html && mv /tmp/selinux.html /var/www/html/selinux/
```

```bash
$ ls -alZ /var/www/html/selinux/
drwxr-xr-x  alice alice unconfined_u:object_r:httpd_sys_content_t:s0 .
drwxr-xr-x  root  root  system_u:object_r:httpd_sys_content_t:s0 ..
-rw-rw-r--  alice alice unconfined_u:object_r:httpd_sys_content_t:s0 index.html
-rw-rw-r--  alice alice unconfined_u:object_r:user_tmp_t:s0 selinux.html
```

`http://localhost/selinux/selinux.html` now returns *Forbidden*, and
**setroubleshoot** reports that SELinux prevented httpd from using a potentially
mislabelled file. The file is labelled `user_tmp_t`, which `httpd_t` cannot read.

Why was one file labelled correctly and the other not? It is entirely about how each
was created:

- `index.html` was created directly at its final location, so it **inherited the
  parent directory's context**.
- `selinux.html` was created in `/tmp` — picking up `/tmp`'s default context — and
  then **moved**. `mv` does not create a new file; it preserves the existing
  permissions and SELinux context, carrying `user_tmp_t` along with it.

> [!tip] `cp` relabels, `mv` does not
> This is the single most common way to break an SELinux-protected service. `cp`
> creates a new file that inherits the destination's context; `mv` preserves the
> source's. Use `cp --preserve=context` when you deliberately want the old label,
> and `restorecon` after any `mv` across contexts.

## Correcting a context

Two options: set a context manually, or restore the path's default.

The first needs you to know what you are doing — the goal is not to assign a context
at random, nor to hand Apache more rights than it needs. The second relies on the
rules already installed on the system.

### Restoring the default context

`matchpathcon` tells you what context a path *should* have:

```bash
$ matchpathcon /var/www/html/selinux/selinux.html
/var/www/html/selinux/selinux.html      system_u:object_r:httpd_sys_content_t:s0
```

> [!note] `matchpathcon` is deprecated
> It still ships and still works, but it is deprecated in favour of the `selabel`
> interface. The modern equivalent is:
>
> ```bash
> selabel_lookup -b file -k /var/www/html/selinux/selinux.html
> ```

`restorecon` applies it:

```bash
# restorecon -v /var/www/html/selinux/selinux.html
restorecon reset /var/www/html/selinux/selinux.html context unconfined_u:object_r:user_tmp_t:s0->system_u:object_r:httpd_sys_content_t:s0
```

The file moved from `user_tmp_t` to `httpd_sys_content_t` and is now readable by
Apache.

### Setting a context yourself

Sometimes you need to choose the context: a file living somewhere not intended for
that use, a package that ignores SELinux, or software installed by hand.

Fedora's PHP packagers hit this regularly. Packaging rules say program files belong
in `/usr/share`, but that directory's default context does not let Apache read it:

```bash
$ matchpathcon /usr/share/
/usr/share      system_u:object_r:usr_t:s0
```

Anything created under `/usr/share` inherits `usr_t`, which `httpd_t` has no access
to. So if you want Apache to serve content from outside `/var/www`, you must change
the context. Two tools:

**`chcon`** changes the context of a file or directory, but **not permanently**:

```bash
# chcon -t httpd_sys_content_t /var/www/html/selinux/selinux.html
```

That works. But it survives only until the next relabel or the next `restorecon` on
the file or one of its parents, at which point the file is relabelled from the
closest parent with a defined context.

**`semanage`** does not change a file's context directly. It defines the *default*
context, which `restorecon` and any filesystem relabel will then apply. This is what
you want whenever the change should stick.

> [!note] Where semanage stores your rules
> Paths declared through `semanage` land in
> `/etc/selinux/targeted/contexts/files/file_contexts.local`.

Say you move `/var/www/html/selinux` to `/srv/web/selinux/`, with a symlink back:

```bash
# mkdir /srv/web
# mv /var/www/html/selinux /srv/web/
# cd /var/www/html
# ln -s /srv/web/selinux .
# ls -alZ /srv/web/
drwxr-xr-x  root  root  unconfined_u:object_r:var_t:s0   .
drwxr-xr-x  root  root  system_u:object_r:var_t:s0       ..
drwxr-xr-x  alice alice unconfined_u:object_r:httpd_sys_content_t:s0 selinux
```

The pages still work, because `mv` preserved the contexts. Then run `restorecon`:

```bash
# restorecon -R -v /srv/web
restorecon reset /srv/web/selinux context unconfined_u:object_r:httpd_sys_content_t:s0->system_u:object_r:var_t:s0
restorecon reset /srv/web/selinux/selinux.html context system_u:object_r:httpd_sys_content_t:s0->system_u:object_r:var_t:s0
restorecon reset /srv/web/selinux/index.html context unconfined_u:object_r:httpd_sys_content_t:s0->system_u:object_r:var_t:s0
```

Everything is now `var_t` and the pages are broken again. Define the default context
for the new location and its descendants:

```bash
# semanage fcontext -a -t httpd_sys_content_t '/srv/web(/.*)?'
```

That declares it but does not apply it. `restorecon` does:

```bash
# restorecon -R -v /srv/web
restorecon reset /srv/web context unconfined_u:object_r:var_t:s0->system_u:object_r:httpd_sys_content_t:s0
restorecon reset /srv/web/selinux context system_u:object_r:var_t:s0->system_u:object_r:httpd_sys_content_t:s0
restorecon reset /srv/web/selinux/index.html context system_u:object_r:var_t:s0->system_u:object_r:httpd_sys_content_t:s0
```

To undo the experiment:

```bash
# semanage fcontext -d '/srv/web(/.*)?'
# rm /var/www/html/selinux
# rm -rf /srv/web/
```

## Booleans

Booleans let you flip parts of the policy on and off without knowing anything about
writing policy. Toggling one requires no compilation and no module reload.

List them with descriptions:

```bash
# semanage boolean -l
```

Or just the names and values:

```bash
getsebool -a
```

> [!note] `getsebool`/`setsebool` versus `semanage boolean`
> `semanage` is the general-purpose tool — it covers far more than booleans.
> `getsebool` and `setsebool` do one thing.
>
> `semanage boolean` and `setsebool` must run as root; `getsebool` can run as an
> ordinary user. `semanage boolean -l` prints a description for each entry,
> `getsebool -a` just lists them.

For Apache:

```bash
$ semanage boolean -l | grep httpd
httpd_builtin_scripting        (on   ,   on)  Allow httpd to builtin scripting
httpd_can_network_connect      (off  ,  off)  Allow httpd to can network connect
httpd_can_network_connect_db   (off  ,  off)  Allow httpd to can network connect db
httpd_can_network_relay        (off  ,  off)  Allow httpd to can network relay
httpd_can_sendmail             (off  ,  off)  Allow httpd to can sendmail
httpd_enable_cgi               (on   ,   on)  Allow httpd to enable cgi
httpd_enable_ftp_server        (off  ,  off)  Allow httpd to enable ftp server
httpd_enable_homedirs          (off  ,  off)  Allow httpd to enable homedirs
httpd_execmem                  (off  ,  off)  Allow httpd to execmem
httpd_unified                  (off  ,  off)  Allow httpd to unified
httpd_use_cifs                 (off  ,  off)  Allow httpd to use cifs
httpd_use_nfs                  (off  ,  off)  Allow httpd to use nfs
```

Abridged, from RHEL 10. The two values are the current state and the default.

A concrete case: a PHP application on a local Fedora server needs PHP's `mail()`
function, and SELinux blocks Apache from sending mail. Flip the relevant boolean:

```bash
# setsebool -P httpd_can_sendmail on
```

`-P` makes it permanent across reboots. Leave it off while you are still testing.

## Troubleshooting denials

When something is blocked, the denial is in the audit log. The quickest route:

```bash
# ausearch -m AVC -ts recent
```

`audit2why` explains a denial in prose, and `audit2allow` generates a policy module
that would permit it:

```bash
# ausearch -m AVC -ts recent | audit2why
# ausearch -m AVC -ts recent | audit2allow -M mylocalpolicy
# semodule -i mylocalpolicy.pp
```

`audit2why` also tells you when a boolean would allow the access. For the
`user_tmp_t` file of the worked example it answers "The boolean
httpd_read_user_content was set incorrectly". The better fix there is still
`restorecon`: turning that boolean on would let Apache read all user files.

> [!warning] `audit2allow` is a loaded gun
> It will happily generate a rule permitting whatever was denied, including the
> thing an attacker just tried. Read the generated `.te` file before installing it,
> and prefer a boolean or a correct label over a custom module whenever one exists.

If denials are being suppressed as duplicates, `semodule -DB` disables `dontaudit`
rules so you can see everything, and `semodule -B` restores them.

## Command summary

### Inspecting

| Command | Purpose |
| --- | --- |
| `sestatus` | current SELinux status |
| `getenforce` | current mode |
| `ls -Z` / `ps -Z` | files / processes with their contexts |
| `sesearch` | search the loaded policy |
| `getsebool` | read booleans |
| `matchpathcon` | the context a path should have |
| `ausearch -m AVC` | recent denials |
| `audit2why` | explain a denial |

### Changing

| Command | Purpose |
| --- | --- |
| `setenforce` | switch mode |
| `setsebool` | set a boolean (`-P` to persist) |
| `restorecon` | restore the policy's context |
| `chcon` | set a context, non-persistently |
| `semanage` | manage policy, including default contexts |
| `audit2allow` | generate a module from denials |

## Relabelling everything

Resets every context on the filesystem to what the policy says it should be:

```bash
touch /.autorelabel
systemctl reboot
```

## Where to go next

- [[security/auditd]] — the audit subsystem the denials are logged through
- [[containers/podman]] — SELinux separation for containers, via `container-selinux`
- [[kubernetes/security/pod-security-admission]] — the equivalent controls in a cluster

<!-- uplink -->
Part of [[security/index|Security]].
