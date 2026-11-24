#!/usr/bin/env bash
# note: linux/ssh.md
# env: leap
# sshd runs in the container; 127.0.0.1 stands in for the note's 192.168.1.100.
source "$NOTES_ROOT/tests/lib/assert.sh"

NOTE=linux/ssh
zypper -n -q install --no-recommends openssh openssh-clients openssh-server >/dev/null
ssh-keygen -A >/dev/null
mkdir -p /etc/ssh/sshd_config.d
# OpenSSH 10 refuses a source for a while after failed logins (PerSourcePenalties).
# The test fails logins on purpose, from 127.0.0.1 each time.
printf 'PasswordAuthentication yes\nPerSourcePenalties no\n' >/etc/ssh/sshd_config.d/50-test.conf
useradd -m your.name && echo 'your.name:Secret-123' | chpasswd
/usr/sbin/sshd
mkdir -p ~/.ssh && chmod 700 ~/.ssh
echo 'StrictHostKeyChecking accept-new' >~/.ssh/config
# The password prompt of ssh and ssh-copy-id, answered by a script.
printf '#!/bin/sh\necho Secret-123\n' >/usr/local/bin/askpass && chmod +x /usr/local/bin/askpass
export SSH_ASKPASS=/usr/local/bin/askpass SSH_ASKPASS_REQUIRE=force
# ssh-keygen would take the passphrase from SSH_ASKPASS too: answer its prompts on stdin.
nopass() { env -u SSH_ASKPASS -u SSH_ASKPASS_REQUIRE "$@"; }
local_ip() { sed 's/192\.168\.1\.100/127.0.0.1/g'; }
batch() { ssh -o BatchMode=yes -o PasswordAuthentication=no "$@"; }

section "Passwordless login with a key pair"
# Enter, Enter, Enter: default file, empty passphrase twice.
check "ssh-keygen -t ed25519 -C (from the note)" nopass bash -c "printf '\n\n\n' | $(note_block "$NOTE" 'Passwordless login' 1)"
check_output "it wrote ~/.ssh/id_ed25519 with the comment" 'your\.name@example\.com' cat ~/.ssh/id_ed25519.pub
check_output "ed25519 is the default type of this ssh-keygen" '\(ED25519\)$' \
  nopass bash -c 'ssh-keygen -q -N "" -f /tmp/default </dev/null && ssh-keygen -lf /tmp/default.pub'
check "ssh-keygen -t rsa -b 4096 (from the note)" nopass bash -c "printf '\n\n\n' | $(note_block "$NOTE" 'Passwordless login' 2)"
check_output "a 4096-bit RSA key" '^4096 .*\(RSA\)$' ssh-keygen -lf ~/.ssh/id_rsa.pub
check_fails "before ssh-copy-id, key-only login fails" batch your.name@127.0.0.1 true
check "ssh-copy-id (from the note)" bash -c "$(note_block "$NOTE" 'Passwordless login' 3 | local_ip)"
check_output "now the key logs in, no password" '^your\.name$' batch your.name@127.0.0.1 whoami
check_output "the ed25519 key was appended to authorized_keys" '^ssh-ed25519 .* your\.name@example\.com$' cat ~your.name/.ssh/authorized_keys
useradd -m third && echo 'third:Secret-123' | chpasswd
ssh-copy-id third@127.0.0.1 >/dev/null 2>&1
check_output "without -i, ssh-copy-id takes the newest key (here the RSA one)" '^ssh-rsa ' cat ~third/.ssh/authorized_keys
useradd -m other && echo 'other:Secret-123' | chpasswd
check "by hand, without ssh-copy-id (from the note)" \
  bash -c "$(note_block "$NOTE" 'Passwordless login' 4 | local_ip | sed 's/your\.name@/other@/')"
check_output "that works too" '^other$' batch other@127.0.0.1 whoami
check_output "[~]/.ssh is 700 on the server" '^700$' stat -c %a ~other/.ssh
check_fails "the account must exist: a key does not create it" batch nobody-here@127.0.0.1 true

section "Testing the sshd configuration"
check "sshd -t accepts the config (from the note)" bash -ec "$(note_block "$NOTE" 'Testing the sshd' 1)"
echo 'NoSuchOption yes' >/etc/ssh/sshd_config.d/60-bad.conf
check_output "and reports an error in a drop-in" 'Bad configuration option: NoSuchOption' bash -c 'sshd -t 2>&1; true'
check_fails "with a non-zero exit" sshd -t
rm /etc/ssh/sshd_config.d/60-bad.conf
check_output "sshd -T prints the effective configuration (from the note)" '^passwordauthentication yes$' \
  bash -ec "$(note_block "$NOTE" 'Testing the sshd' 2)"
check "on Leap 16 the main file is /usr/etc/ssh/sshd_config" test -f /usr/etc/ssh/sshd_config
check_fails "and there is no /etc/ssh/sshd_config" test -e /etc/ssh/sshd_config

section "Client configuration"
{ note_block "$NOTE" 'Client configuration' 1; note_block "$NOTE" 'Client configuration' 3; } >~/.ssh/config
g=$(ssh -G webserver)
assert_match "HostName" '^hostname web-01\.example\.com$' "$g"
assert_match "User" '^user your\.name$' "$g"
assert_match "Port" '^port 2222$' "$g"
assert_match "IdentityFile" '^identityfile ~/\.ssh/id_ed25519_webserver$' "$g"
assert_match "Host * applies too" '^serveraliveinterval 60$' "$g"
{ note_block "$NOTE" 'Client configuration' 3; printf 'Host webserver\n    ServerAliveInterval 10\n'; } >~/.ssh/config
assert_match "first match wins: Host * first overrides the host's value" '^serveraliveinterval 60$' "$(ssh -G webserver)"
{ printf 'Host webserver\n    ServerAliveInterval 10\n'; note_block "$NOTE" 'Client configuration' 3; } >~/.ssh/config
assert_match "with Host * last, the host's value is used" '^serveraliveinterval 10$' "$(ssh -G webserver)"
