#!/usr/bin/env bash
# note: linux/distributions/nixos/hardening.md
# env: nixos
# nixos: hardening.nix
# timeout: 900
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/nixos.sh"

section "What is harder: the store is world-readable"
unit=$(readlink -f /etc/systemd/system/myapp.service)
assert_match "the unit file is in /nix/store" '^/nix/store/' "$unit"
check_output "any user can read the token in it" 'TOKEN=s3cret-token' runuser -u nobody -- cat "$unit"
check_output "sshd_config is a store symlink, as CIS tools trip over" '^/nix/store/' readlink -f /etc/ssh/sshd_config

section "SSH and access"
sshd=$(sshd -T 2>/dev/null | tr '[:upper:]' '[:lower:]')
for kv in 'passwordauthentication no' 'permitrootlogin no' 'kbdinteractiveauthentication no' \
  'x11forwarding no' 'maxauthtries 3' 'allowusers alice' 'clientaliveinterval 300' 'clientalivecountmax 2'; do
  assert_match "sshd runs with: $kv" "^$kv\$" "$sshd"
done
check_output "alice exists, in wheel" 'wheel' id -nG alice
check_output "execWheelOnly: only root and wheel may run sudo" '^4510 root wheel$' stat -c '%a %U %G' /run/wrappers/bin/sudo
# mutableUsers = false: what useradd does, and what the next activation does to it.
out=$(useradd bob 2>&1) && added=yes || added=no
assert_eq "useradd still works with mutableUsers = false (the note said it stops)" yes "$added"
check "bob exists until the next activation" id bob
before=$(grep '^alice:' /etc/shadow | cut -d: -f2)
check "chpasswd (like passwd) still changes alice's password" bash -c "echo 'alice:Changed-123' | chpasswd"
check "the hash in /etc/shadow changed" test "$(grep '^alice:' /etc/shadow | cut -d: -f2)" != "$before"
/run/current-system/activate >/dev/null 2>&1 || true
check_fails "the next activation removes the account added by hand" id bob
assert_eq "and puts alice's password back to the declared one" "$before" "$(grep '^alice:' /etc/shadow | cut -d: -f2)"

section "systemd sandboxing"
check "the sandboxed service runs in the container" systemctl is-active myapp.service
score=$(systemd-analyze security myapp.service --no-pager | sed -n 's/.*Overall exposure level for myapp.service: \([0-9.]*\).*/\1/p')
assert_match "systemd-analyze security scores it from 0 to 10" '^([0-9]|10)(\.[0-9])?$' "$score"
check "the note's directives give a low exposure (under 3): $score" awk -v s="$score" 'BEGIN { exit !(s < 3) }'
plain=$(systemd-analyze security --no-pager | awk '$1 == "nix-daemon.service" { print $2 }')
check "a unit without them scores higher (nix-daemon: $plain)" awk -v a="$score" -v b="$plain" 'BEGIN { exit !(b > a) }'
check "state directory is created by StateDirectory" test -d /var/lib/myapp
check_output "ProtectSystem=strict: /usr is read-only for the service" 'Read-only file system' \
  bash -c "systemd-run --wait --pipe -p ProtectSystem=strict touch /usr/x 2>&1; true"

section "Firewall"
rules=$(nft list ruleset)
assert_match "the nftables backend is used" 'table inet nixos-fw' "$rules"
assert_match "allowedTCPPorts become an accept rule" 'tcp dport \{ 22, 80, 443 \} accept' "$rules"
assert_match "extraInputRules lands in the input chain" 'ip saddr 10\.0\.0\.0/8 tcp dport 8080 accept' "$rules"
assert_no_match "allowPing = false: no echo-request accept" 'echo-request.*accept' "$rules"
assert_match "logRefusedConnections logs before dropping" 'log prefix "refused connection' "$rules"
bad="{ networking.nftables.enable = true; networking.firewall.extraCommands = \"iptables -A nixos-fw -j nixos-fw-accept\"; }"
out=$(NIXOS_MODULE="$bad" nixos_eval --host system.build.toplevel.drvPath 2>&1) && ok=yes || ok=no
assert_eq "extraCommands with nftables does not evaluate (the old block)" no "$ok"
assert_match "and says why" 'extraCommands is incompatible with the nftables based firewall' "$out"

section "Kernel and network (evaluated, not booted)"
check "the kernel block evaluates on a normal host" nixos_eval --host --block "Kernel and network" 1 system.build.toplevel.drvPath
sysctl=$(nixos_eval --host --block "Kernel and network" 1 'environment.etc."sysctl.d/60-nixos.conf".text')
assert_match "the sysctls are written to /etc/sysctl.d" 'kernel.kptr_restrict=2' "$sysctl"
assert_match "including the network ones" 'net.ipv4.tcp_syncookies=1' "$sysctl"
out=$(NIXOS_MODULE='{ pkgs, ... }: { boot.kernelPackages = pkgs.linuxPackages_hardened; }' \
  nixos_eval --host system.build.toplevel.drvPath 2>&1) && ok=yes || ok=no
assert_eq "linuxPackages_hardened no longer evaluates (the correction)" no "$ok"
assert_match "because it was removed" 'linuxPackages_hardened has been removed' "$out"

section "AppArmor and auditing (evaluated, not booted)"
check "the AppArmor block evaluates" nixos_eval --host --block "AppArmor" 1 system.build.toplevel.drvPath
check "the auditing block evaluates" nixos_eval --host --block "Auditing" 1 system.build.toplevel.drvPath
check_output "the rules include the generation-switch watch" 'system_generation' \
  nixos_eval --host --block "Auditing" 1 security.audit.rules

section "Automatic updates"
check_output "autoUpgrade installs a timer at 04:00" '04:00' systemctl show nixos-upgrade.timer -p TimersCalendar
start=$(systemctl show nixos-upgrade.service -p ExecStart --value | grep -o '/nix/store/[^ ;]*nixos-upgrade-start' | head -1)
script=$(cat "$start")
assert_match "with the note's flake" '--flake github:myorg/nixos-config' "$script"
# The note's correction: no flags, so each host builds the committed flake.lock.
assert_no_match "no --update-input: the host does not update nixpkgs by itself" '--update-input' "$script"
assert_no_match "no --no-write-lock-file either" '--no-write-lock-file' "$script"
check_output "nix.gc installs a weekly timer" 'OnCalendar=weekly' systemctl cat nix-gc.timer

section "Checking your work"
check_output "systemd-analyze security lists every unit" 'nix-daemon.service' systemd-analyze security --no-pager
check_output "nix-shell -p finds nixpkgs on a flake-built system" '/nix/store/' nix-instantiate --find-file nixpkgs
check_output "vulnix is in nixpkgs" '^"[0-9]' nix eval nixpkgs#vulnix.version
