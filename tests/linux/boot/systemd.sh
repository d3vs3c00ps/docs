#!/usr/bin/env bash
# note: linux/boot/systemd.md
# env: rocky-systemd
# timeout: 900
# Rocky, because the note's examples use RHEL unit names (httpd, chronyd, mariadb).
source "$NOTES_ROOT/tests/lib/assert.sh"

NOTE=linux/boot/systemd
export SYSTEMD_PAGER=cat SYSTEMD_COLORS=0
dnf -y -q install --setopt=install_weak_deps=False chrony httpd mariadb-server \
  openssh-server openssh-clients >/dev/null
cd "$(mktemp -d)"
blk() { note_block "$NOTE" "$@"; }

section "Targets"
check "get-default (from the note)" bash -ec "$(blk Targets 1)"
check "set-default multi-user.target (from the note)" bash -ec "$(blk Targets 2)"
check_output "the default is now multi-user.target" '^multi-user\.target$' systemctl get-default
check "isolate multi-user.target (from the note)" bash -ec "$(blk Targets 3)"
for n in 2 3 4; do
  check_output "runlevel$n.target is multi-user.target" 'multi-user\.target$' readlink "/usr/lib/systemd/system/runlevel$n.target"
done
check_output "runlevel1.target is rescue.target" 'rescue\.target$' readlink /usr/lib/systemd/system/runlevel1.target
check_output "runlevel5.target is graphical.target" 'graphical\.target$' readlink /usr/lib/systemd/system/runlevel5.target

section "Inspecting a unit"
systemctl start chronyd
retry 10 systemctl is-active chronyd
cat_out=$(systemctl cat chronyd)
while IFS= read -r line; do
  [[ $line == '$ '* || $line == '...' || -z $line ]] && continue
  # shellcheck disable=SC2001 # a regex escape needs sed
  assert_match "systemctl cat shows: $line" "^$(sed 's/[][$.*^()|+?{}\\]/\\&/g' <<<"$line")\$" "$cat_out"
done < <(blk 'Inspecting a unit' 1)
show=$(systemctl show --all chronyd)
while IFS= read -r line; do
  [[ $line =~ ^[A-Za-z]+= ]] || continue
  key=${line%%=*}
  # shellcheck disable=SC2001 # a regex escape needs sed
  case $key in
    MainPID|ExecStart|MemoryCurrent|TasksCurrent) assert_match "systemctl show has $key" "^$key=" "$show" ;;
    *) assert_match "systemctl show: $line" "^$(sed 's/[][$.*^()|+?{}\\]/\\&/g' <<<"$line")\$" "$show" ;;
  esac
done < <(blk 'Inspecting a unit' 2)
check_output "an unset number shows as [not set]" '^MemoryCurrent=\[not set\]$' systemctl show -p MemoryCurrent httpd
check_output "systemctl show -p CPUWeight (from the note)" '^CPUWeight=\[not set\]$' \
  bash -ec "$(blk 'Inspecting a unit' 3 | sed -n 's/^\$ //p')"

section "Overriding a unit with a drop-in"
check "the drop-in, written by hand (from the note)" bash -ec "$(blk 'Overriding a unit' 1)"
assert_eq "systemctl edit puts the same lines in its file" "$(blk 'Overriding a unit' 3)" \
  "$(sed -n '/^\[Service\]/,$p' /etc/systemd/system/chronyd.service.d/50-resources.conf)"
check_output "the drop-in applies: Restart=always" '^Restart=always$' systemctl show -p Restart chronyd
check_output "and CPUAffinity" '^CPUAffinity=0-3$' systemctl show -p CPUAffinity chronyd
systemctl restart chronyd
status=$(systemctl status chronyd --no-pager)
for re in 'Loaded: loaded \(/usr/lib/systemd/system/chronyd\.service; enabled; preset: enabled\)' \
  'Drop-In: /etc/systemd/system/chronyd\.service\.d' '└─50-resources\.conf' 'Active: active \(running\)' \
  'CGroup: /system\.slice/chronyd\.service'; do
  assert_match "systemctl status shows /$re/" "$re" "$status"
done
# systemctl edit needs a terminal (script) and an editor (a script that writes the lines).
# systemctl passes +LINE before the file name, as for vim: the file is the last argument.
cat >/tmp/ed.sh <<'EOS'
#!/bin/sh
eval f=\${$#}
sed -i '/^### Anything between here/a [Service]\nNice=1' "$f"
EOS
chmod +x /tmp/ed.sh
check "systemctl edit names its file override.conf" \
  bash -c 'script -qec "SYSTEMD_EDITOR=/tmp/ed.sh systemctl edit chronyd" /dev/null >/dev/null && test -f /etc/systemd/system/chronyd.service.d/override.conf'
rm -f /etc/systemd/system/chronyd.service.d/override.conf
printf '[Service]\nExecStart=/usr/sbin/chronyd -n -u chrony $OPTIONS\n' >/etc/systemd/system/chronyd.service.d/60-exec.conf
systemctl daemon-reload
check_fails "a second ExecStart= without clearing: the unit is refused" systemctl restart chronyd
check_output "with the reason" 'more than one ExecStart= setting' journalctl -b -o cat -u chronyd
blk 'Overriding a unit' 5 >/etc/systemd/system/chronyd.service.d/60-exec.conf
systemctl daemon-reload
check "clearing it first with ExecStart= (from the note) works" systemctl restart chronyd
check_output "and the new command runs" '-u chrony' systemctl show -p ExecStart chronyd
rm /etc/systemd/system/chronyd.service.d/60-exec.conf
systemctl daemon-reload
check "a Type=oneshot unit accepts several ExecStart=" \
  systemd-run --wait -q -p Type=oneshot -p ExecStart=/bin/true -p ExecStart=/bin/true /bin/true

section "Security-related options"
run() { systemd-run --wait --pipe -q -G "$@" 2>&1 || true; }
echo hello >/tmp/mine
check_output "PrivateTmp=: the service sees its own empty /tmp" '^empty$' \
  run -p PrivateTmp=yes bash -c 'test -e /tmp/mine && echo shared || echo empty'
systemd-run -q --unit=ptmp -p PrivateTmp=yes bash -c 'touch /tmp/x; sleep 60'
sleep 1
check "its files are under /tmp/systemd-private-*-<unit>-*/tmp" bash -c 'ls -d /tmp/systemd-private-*-ptmp.service-*/tmp/x'
systemctl stop ptmp
check_output "PrivateNetwork=: only a loopback device" '^lo$' \
  run -p PrivateNetwork=yes bash -c "ip -o link | awk -F': ' '{print \$2}'"
check_output "ProtectSystem=yes: /usr is read-only" 'Read-only file system' run -p ProtectSystem=yes touch /usr/x
check "but /etc is still writable" run -p ProtectSystem=yes bash -c 'touch /etc/x && rm /etc/x'
check_output "ProtectSystem=full: /etc is read-only too" 'Read-only file system' run -p ProtectSystem=full touch /etc/x
check_output "ProtectSystem=strict: everything, /var too" 'Read-only file system' run -p ProtectSystem=strict touch /var/x
mkdir -p /home/alice && echo s >/home/alice/f
check_output "ProtectHome=yes: /home looks empty" '^$' run -p ProtectHome=yes ls -A /home
check_output "ProtectHome=read-only: visible, not writable" 'Read-only file system' run -p ProtectHome=read-only touch /home/alice/g
check_output "PrivateDevices=: only pseudo devices in /dev" '^null$' \
  run -p PrivateDevices=yes bash -c 'ls /dev | grep -x null; ls /dev | grep -E "^(sd|vd|nvme|loop)[0-9a-z]*$" || true'
check_output "ReadWritePaths= opens one path under strict" '^ok$' \
  run -p ProtectSystem=strict -p ReadWritePaths=/var/tmp bash -c 'touch /var/tmp/x && echo ok'
touch /srv/f
check_output "InaccessiblePaths= hides a path" '^hidden$' \
  run -p InaccessiblePaths=/srv bash -c 'test -e /srv/f && echo visible || echo hidden'
check_output "NoNewPrivileges=: the setuid bit no longer grants root" 'NoNewPrivs:\s+1' \
  run -p NoNewPrivileges=yes grep NoNewPrivs /proc/self/status
check_output "systemd-analyze security scores a unit" 'Overall exposure level for chronyd\.service' \
  systemd-analyze security chronyd --no-pager

section "Unit file locations"
printf '[Service]\nExecStart=/bin/true\nType=oneshot\n' >/usr/lib/systemd/system/where.service
mkdir -p /run/systemd/system && cp /usr/lib/systemd/system/where.service /run/systemd/system/
systemctl daemon-reload
check_output "/run overrides /usr/lib" '/run/systemd/system/where\.service' systemctl show -p FragmentPath where
cp /usr/lib/systemd/system/where.service /etc/systemd/system/
systemctl daemon-reload
check_output "/etc overrides both" '/etc/systemd/system/where\.service' systemctl show -p FragmentPath where
check_output "systemd-delta lists the overridden file" '\[OVERRIDDEN\] /etc/systemd/system/where\.service' systemd-delta --no-pager

section "Managing services"
while IFS= read -r cmd; do
  check "$cmd (from the note)" bash -ec "$cmd"
done < <(blk 'Managing services' 1)
check "restart httpd mariadb (from the note)" bash -ec "$(blk 'Managing services' 2)"
check "both are active" systemctl is-active httpd mariadb
check_output "enable (from the note)" 'Created symlink' bash -ec "$(blk 'Managing services' 3 | sed -n 1p)"
check_output "disable (from the note)" 'Removed' bash -ec "$(blk 'Managing services' 3 | sed -n 2p)"
systemctl stop httpd mariadb
check "enable --now (from the note)" bash -ec "$(blk 'Managing services' 4)"
check "starts both" systemctl is-active httpd mariadb
check_output "and enables them" '^enabled$' systemctl is-enabled httpd
check_output "the type defaults to .service" 'httpd\.service' systemctl status httpd
check "status and status -l (from the note)" bash -ec "$(blk 'Managing services' 5)"
running=$(bash -ec "$(blk 'Managing services' 6)")
assert_match "list-units --state=running lists httpd" 'httpd\.service' "$running"
assert_no_match "but not an exited one-shot service" 'systemd-update-utmp\.service' "$running"
check_output "systemctl -t service alone includes exited ones" 'systemd-update-utmp\.service.* active +exited' systemctl -t service --no-pager
check_output "list-unit-files -t service (from the note)" 'httpd\.service +enabled' bash -ec "$(blk 'Managing services' 7)"
check_output "systemctl --failed (from the note)" '0 loaded units listed' bash -ec "$(blk 'Managing services' 8)"
check_fails "the braces (the correction): start stop restart reload httpd fails" \
  systemctl start stop restart reload httpd.service

section "Managing a remote host"
ssh-keygen -A >/dev/null
systemctl start sshd
ssh-keygen -q -t ed25519 -N '' -f ~/.ssh/id_ed25519
cat ~/.ssh/id_ed25519.pub >>~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys
printf 'Host *\n  StrictHostKeyChecking accept-new\n' >~/.ssh/config
check "systemctl -H over SSH (from the note, to root@localhost)" \
  bash -ec "$(blk 'Managing a remote host' | sed 's/<hostname>/root@localhost/')"
check_output "it talks to the remote systemd" '^active$' systemctl -H root@localhost is-active httpd
skip "-M for a systemd-machined container" "no nested container is registered here"

section "Analysing boot performance"
check_output "systemd-analyze blame" '\.service' systemd-analyze blame
check_output "critical-chain prints the note's header" 'The time when unit became active or started is printed after the "@" character' \
  systemd-analyze critical-chain
check "systemd-analyze plot (from the note)" bash -ec "$(blk 'Analysing boot' 3)"
check_output "writes an SVG" 'SVG' file systemd-analyze.svg

section "Slices, scopes and services"
check_output "systemd-cgls shows system.slice" 'system\.slice' systemd-cgls --no-pager
check_output "and the services in it" 'chronyd\.service' systemd-cgls --no-pager
check_output "systemd-cgtop (one batch iteration)" 'system\.slice' systemd-cgtop -b -n 1
for s in system user machine; do
  check_output "$s.slice starts with the default weight" '^CPUWeight=\[not set\]$' systemctl show -p CPUWeight "$s.slice"
done

section "Setting resource limits"
check "set-property (from the note)" bash -ec "$(blk 'Setting resource limits' 1)"
check_output "applies at once" '^CPUWeight=200$' systemctl show -p CPUWeight chronyd
check_output "and writes the drop-in the note names" 'CPUWeight=200' cat /etc/systemd/system.control/chronyd.service.d/50-CPUWeight.conf
check "--runtime (from the note)" bash -ec "$(blk 'Setting resource limits' 2)"
check "goes to /run/systemd/system.control" test -f /run/systemd/system.control/httpd.service.d/50-CPUWeight.conf
check_fails "and not to /etc" test -e /etc/systemd/system.control/httpd.service.d/50-CPUWeight.conf

section "Resource control properties"
printf '[Service]\nExecStart=/bin/sleep 60\nCPUShares=1024\nMemoryLimit=1G\n' >/etc/systemd/system/v1.service
systemctl daemon-reload
out=$(systemd-analyze verify v1.service 2>&1 || true)
assert_match "CPUShares= is accepted with a warning" 'Unit uses CPUShares=; please use CPUWeight= instead\. Support for CPUShares= will be removed soon' "$out"
assert_match "MemoryLimit= too" 'Unit uses MemoryLimit=; please use MemoryMax= instead' "$out"
check_output "CPUWeight defaults to 100 on the cgroup" '^100$' cat /sys/fs/cgroup/system.slice/cpu.weight
check_output "CPUWeight= takes 1 to 10000" 'CPUWeight=10000' bash -c 'systemd-run --wait -q -p CPUWeight=10000 true && echo CPUWeight=10000'
check_fails "and not 10001" systemd-run --wait -q -p CPUWeight=10001 true
check_fails "IOWeight= stops at 10000 too" systemd-run --wait -q -p IOWeight=10001 true
systemd-run -q --unit=lim -p MemoryMax=50M -p MemoryHigh=40M -p IOWeight=50 -p CPUQuota=200% sleep 60
sleep 1
cg=/sys/fs/cgroup/system.slice/lim.service
check_output "MemoryMax= is the hard limit (memory.max)" '^52428800$' cat $cg/memory.max
check_output "MemoryHigh= is memory.high" '^41943040$' cat $cg/memory.high
check_output "CPUQuota=200% allows two CPUs" '^200000 100000$' cat $cg/cpu.max
systemd-run -q --unit=noacct -p MemoryAccounting=no -p MemoryMax=50M sleep 60
sleep 1
check_output "a limit works with accounting off (the correction)" '^52428800$' \
  cat /sys/fs/cgroup/system.slice/noacct.service/memory.max
if [[ -e $cg/io.weight ]]; then
  check_output "IOWeight= applies with IOAccounting off" '^default 50$' cat $cg/io.weight
else
  skip "IOWeight= applies with IOAccounting off" "this kernel has no io.weight (no BFQ or io.cost)"
fi
check_output "CPU, memory and task accounting are on by default" \
  'CPUAccounting=yes.*MemoryAccounting=yes.*TasksAccounting=yes' \
  bash -c 'systemctl show -p CPUAccounting,MemoryAccounting,TasksAccounting lim | xargs'
blk 'Resource control properties' 1 >/etc/systemd/system/acct.service.d.conf
mkdir -p /etc/systemd/system/acc.service.d
printf '[Service]\nExecStart=/bin/sleep 60\n' >/etc/systemd/system/acc.service
blk 'Resource control properties' 1 >/etc/systemd/system/acc.service.d/acct.conf
blk 'Resource control properties' 2 >/etc/systemd/system/acc.service.d/io.conf
systemctl daemon-reload
check "the accounting and bandwidth blocks load" systemctl start acc
check_output "IOAccounting=yes is applied" '^IOAccounting=yes$' systemctl show -p IOAccounting acc
skip "IOWriteBandwidthMax=/var/log 5M takes effect" "/var/log is on the container's overlay, not a block device"
check_output "the cgroup version check (from the note)" '^cgroup2fs$' bash -ec "$(blk 'Resource control properties' 3 | grep -v '^#')"
