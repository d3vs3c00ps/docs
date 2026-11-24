#!/usr/bin/env bash
# note: servers/apache.md
# env: rocky-systemd
# The RHEL rows of the note. The rest runs on Leap (apache.sh).
source "$NOTES_ROOT/tests/lib/assert.sh"

NOTE=servers/apache
dnf -y -q install httpd >/dev/null
block() { note_block "$NOTE" "$@" | sed 's/ *# .*//'; }
systemctl enable --now httpd >/dev/null 2>&1

section "Testing the configuration"
check_output "apachectl configtest (from the note)" 'Syntax OK' bash -c "$(block 'Testing the configuration' 1 | sed -n 1p) 2>&1"
check_output "httpd -t (from the note)" 'Syntax OK' bash -c "$(block 'Testing the configuration' 1 | sed -n 2p) 2>&1"
check_output "apachectl -S is refused on RHEL (as the note says)" 'option is not supported' \
  bash -c "$(block 'Testing the configuration' 1 | sed -n 3p) 2>&1; true"
check_output "httpd -S works" 'ServerRoot' bash -c 'httpd -S 2>&1'

section "Useful commands"
pid=$(systemctl show -p MainPID --value httpd)
check "apachectl -k graceful (from the note)" bash -ec "$(block 'Useful commands' 1 | sed -n 1p)"
sleep 2
assert_eq "the parent process keeps running" "$pid" "$(systemctl show -p MainPID --value httpd)"
check "the unit is httpd on RHEL (as the note says)" bash -ec "$(block 'Useful commands' 1 | sed -n 2p | sed 's/apache2/httpd/')"

section "Choosing an MPM"
check_output "httpd -V (from the note): event is the default" '^Server MPM: +event' bash -ec "$(block 'Choosing an MPM' 1)"
check_output "the MPM is picked in conf.modules.d/00-mpm.conf" '^#LoadModule mpm_prefork_module' cat /etc/httpd/conf.modules.d/00-mpm.conf
sed -i 's/^LoadModule mpm_event_module/#&/; s/^#\(LoadModule mpm_prefork_module\)/\1/' /etc/httpd/conf.modules.d/00-mpm.conf
systemctl restart httpd
check_output "uncommenting prefork's line switches to it" '^Server MPM: +prefork' httpd -V
