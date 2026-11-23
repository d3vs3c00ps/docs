#!/usr/bin/env bash
# note: automation/ansible/inventory.md
# env: ansible-systemd
# The note's hosts all point at 127.0.0.1 here. WinRM needs a Windows host: not run.
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/automation/ansible/ansible-lib.bash"

NOTE=automation/ansible/inventory
cd /work
note_block "$NOTE" 'The inventory' 1 >~/alternative_inventory
# Reachable copy: every host is this machine, as the ansible user.
{ note_block "$NOTE" 'The inventory' 1; printf '\n[all:vars]\nansible_host=127.0.0.1\nansible_user=ansible\n'; } |
  sed 's/ansible_host=ntp.test.lab//' >hosts

section "The inventory"
graph=$(bash -c "$(note_block "$NOTE" 'The inventory' 3 | sed -n 1p)" 2>&1)
assert_match "--graph: dns-01 and ntp are ungrouped (from the note)" '@ungrouped:.*dns-01.*ntp' "$(tr -d '\n' <<<"$graph")"
assert_match "  apache is a group of groups: apache_pub, apache_admin" '@apache:.*@apache_pub:.*svr-apache-01.*@apache_admin:.*svr-apache-02' "$(tr -d '\n' <<<"$graph")"
check_output "--graph --vars shows the alias's ansible_host (from the note)" 'ansible_host = ntp.test.lab' \
  bash -c "$(note_block "$NOTE" 'The inventory' 3 | sed -n 2p)"
check_output "--list prints JSON (from the note)" '"hostvars"' \
  bash -c "$(note_block "$NOTE" 'The inventory' 3 | sed -n 3p)"
check_output "inline # comments in INI are allowed: the host names stay clean" '"dns-01"' \
  ansible-inventory -i ~/alternative_inventory --list
check_output "-i picks another inventory (from the note, on the reachable copy)" 'svr-apache-0[12] \| SUCCESS' \
  bash -c "$(note_block "$NOTE" 'The inventory' 2 | sed 's|~/alternative_inventory|hosts|')"
mkdir -p inventory && cp hosts inventory/10-hosts.ini &&
  printf 'all:\n  hosts:\n    yaml-host:\n      ansible_host: 127.0.0.1\n      ansible_user: ansible\n' >inventory/20-more.yml
check_output "an inventory directory mixes INI and YAML files (the tip)" 'yaml-host.*svr-apache-01|svr-apache-01.*yaml-host' \
  bash -c 'ansible-inventory -i inventory/ --graph | tr -d "\n"'

section "Connecting to hosts"
check "ssh-keygen -t ed25519 makes a key pair (from the note, without prompts)" \
  bash -c "$(note_block "$NOTE" 'Connecting to hosts' 1) -N '' -f /tmp/k -q && test -f /tmp/k.pub"
skip "ssh-copy-id (from the note)" "it needs a password login; this env installs the key when the image is built"
useradd -m deploy && install -d -m 700 -o deploy -g deploy /home/deploy/.ssh &&
  install -m 600 -o deploy -g deploy /root/.ssh/id_ed25519.pub /home/deploy/.ssh/authorized_keys &&
  echo 'deploy ALL=(ALL) NOPASSWD: ALL' >/etc/sudoers.d/deploy
check_output "by default Ansible connects as the current user (root here, refused: no key)" 'UNREACHABLE|Permission denied' \
  bash -c 'ansible -i 127.0.0.1, all -m ping 2>&1; true'
printf '%s ansible_host=127.0.0.1\n' "$(note_block "$NOTE" 'Connecting to hosts' 3)" >deploy.ini
check_output "ansible_user=deploy in the inventory (from the note)" '^deploy$' \
  ansible -i deploy.ini svr-apache-01 -m command -a whoami
{ note_block "$NOTE" 'Connecting to hosts' 4 | sed 's/hosts: apache/hosts: all/'; printf '  gather_facts: false\n  tasks:\n    - command: whoami\n      register: w\n    - debug: {var: w.stdout}\n    - command: whoami\n      become: false\n      register: u\n    - debug: {var: u.stdout}\n'; } >deploy.yml
out=$(ansible-playbook -i 127.0.0.1, deploy.yml 2>&1)
assert_match "remote_user: deploy in the play (from the note)" '"u.stdout": "deploy"' "$out"
assert_match "  and become: true runs the tasks as root" '"w.stdout": "root"' "$out"
skip "Windows and WinRM" "needs a Windows host with WinRM; the harness runs Linux containers only"
check_output "the WinRM bootstrap script is at the new address (the note's link)" '^200$' \
  curl -s -o /dev/null -w '%{http_code}' https://raw.githubusercontent.com/ansible/ansible-documentation/devel/examples/scripts/ConfigureRemotingForAnsible.ps1
check_output "  and gone from the old one" '^404$' \
  curl -s -o /dev/null -w '%{http_code}' https://raw.githubusercontent.com/ansible/ansible/devel/examples/scripts/ConfigureRemotingForAnsible.ps1

section "Testing connectivity"
while read -r line; do
  check_output "$line (from the note)" 'SUCCESS' bash -c "${line/ansible /ansible -i hosts }"
done < <(note_block "$NOTE" 'Testing connectivity' 1)
check_output "'apache:!svr-apache-02' leaves only svr-apache-01 (from the note)" '^ +svr-apache-01$' \
  bash -c "$(note_block "$NOTE" 'Testing connectivity' 2 | sed 's/ansible /ansible -i hosts /; s/-m ping/--list-hosts/')"
check_fails "  svr-apache-02 is not in it" \
  bash -c "$(note_block "$NOTE" 'Testing connectivity' 2 | sed 's/ansible /ansible -i hosts /; s/-m ping/--list-hosts/') | grep -q svr-apache-02"
check_output "ping fails without a Python interpreter, so it checks more than ICMP" 'MODULE FAILURE|Failed|No such file' \
  bash -c 'ansible -i hosts dns-01 -m ping -e ansible_python_interpreter=/nonexistent/python 2>&1; true'

section "Facts"
printf -- '- hosts: dns-01\n  tasks: []\n' >facts.yml
check_output "a play gathers facts by default" 'Gathering Facts' ansible-playbook -i hosts facts.yml
printf -- '- hosts: dns-01\n  gather_facts: false\n  tasks: []\n' >nofacts.yml
check_fails "gather_facts: false skips it" bash -c 'ansible-playbook -i hosts nofacts.yml | grep -q "Gathering Facts"'
check_output "setup returns ansible_default_ipv4 and the distribution (from the note)" '"ansible_distribution": "openSUSE Leap"' \
  bash -c "$(note_block "$NOTE" 'The setup module' 1 | sed -n 's/^\$ //p' | head -1 | sed 's/ansible /ansible -i hosts /')"
filtered=$(bash -c "$(note_block "$NOTE" 'The setup module' 2 | sed 's/ansible /ansible -i hosts /')")
assert_match "the filter keeps only ansible_distribution* (from the note)" '"ansible_distribution_major_version": "16"' "$filtered"
assert_no_match "  and drops the rest" 'ansible_default_ipv4' "$filtered"
for f in ansible_os_family ansible_distribution ansible_distribution_major_version ansible_default_ipv4; do
  check_output "the fact $f exists" "\"$f\"" ansible -i hosts dns-01 -m setup
done
