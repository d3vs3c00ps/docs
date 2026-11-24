#!/usr/bin/env bash
# note: automation/ansible/modules.md
# env: ansible-systemd
# The note's hosts all point at 127.0.0.1 here, as the ansible user.
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/automation/ansible/ansible-lib.bash"

NOTE=automation/ansible/modules
cd /work
mkdir -p /etc/ansible
printf '[apache]\nsvr-apache-01\nsvr-apache-02\n\n[all:vars]\nansible_host=127.0.0.1\nansible_user=ansible\n' >/etc/ansible/hosts
# A plain run: the note's lines without -i read the default inventory, /etc/ansible/hosts.

section "Modules"
check_output "ansible-doc <module> (from the note)" 'ansible.builtin.copy module copies' ansible-doc copy
check_output "ansible-doc -s prints a playbook snippet (from the note)" '^- name: Copy files' ansible-doc -s copy
check_fails "ansible-doc -l with no collection crashes in Ansible 15.0.0 (the correction)" ansible-doc -l
check_output "  google.cloud is the collection that breaks it" 'object has no attribute' \
  bash -c 'ansible-doc -l google.cloud 2>&1; true'
check_output "ansible-doc -l <collection> works (from the correction)" '^ansible\.builtin\.copy ' \
  bash -c 'ansible-doc -l ansible.builtin 2>/dev/null'
check_output "ansible.builtin holds under 100 modules: the rest live in collections" '^[0-9]{2}$' \
  bash -c 'ansible-doc -l ansible.builtin 2>/dev/null | wc -l'
check_output "ansible.builtin.yum is gone (the correction)" 'ansible.builtin.yum was not found' \
  bash -c 'ansible-doc ansible.builtin.yum 2>&1'
check_output "  ansible.builtin.dnf replaces it" 'MODULE.*ansible\.builtin\.dnf' ansible-doc ansible.builtin.dnf
check_output "  a yum task still runs: it is redirected to dnf (the correction)" 'major revision of dnf' \
  bash -c "printf -- '- hosts: svr-apache-01\n  gather_facts: false\n  tasks:\n    - ansible.builtin.yum: {name: x}\n' >yum.yml; ansible-playbook yum.yml 2>&1; true"
printf -- '- hosts: all\n  gather_facts: false\n  tasks:\n    - name: Short name\n      copy: {dest: /tmp/short, content: x}\n' >short.yml
check_output "a short module name still resolves" 'ok=1|changed=1' ansible-playbook short.yml -l svr-apache-01
check_output "  and ansible-lint asks for the FQCN" 'fqcn\[action-core\]' bash -c 'ansible-lint short.yml 2>&1; true'

section "command and shell"
check_output "command expands \$HOME but passes > as plain text (the correction)" '^/home/ansible > /tmp/redir$' \
  ansible svr-apache-01 -m command -a 'echo "$HOME > /tmp/redir"'
check_fails "  so no file is written" test -e /tmp/redir
check "shell runs the redirection" ansible svr-apache-01 -m shell -a 'echo hi > /tmp/redir'
check_output "  and the file exists" '^hi$' cat /tmp/redir

section "script and raw"
printf '#!/bin/sh\necho "from $(hostname) as $(id -un)"\n' >local.sh
check_output "script copies a local script to the target and runs it" 'from .* as ansible' \
  ansible svr-apache-01 -m script -a local.sh
check_output "raw works with no Python on the target" 'pong-raw' \
  ansible svr-apache-01 -m raw -a 'echo pong-raw' -e ansible_python_interpreter=/nonexistent/python
check_fails "  where a normal module fails" \
  ansible svr-apache-01 -m ping -e ansible_python_interpreter=/nonexistent/python
for m in command shell raw; do
  check_output "$m reports changed on every run" 'CHANGED' ansible svr-apache-01 -m $m -a 'true'
done
check_output "creates: makes command skip when the file exists (the warning)" 'skipped, since /tmp/marker exists' \
  bash -c "touch /tmp/marker && ansible svr-apache-01 -m command -a 'touch /tmp/marker creates=/tmp/marker'"
check_fails "  raw has no creates: option (the warning)" bash -c 'ansible-doc raw | grep -q "^ *creates"'
check_output "changed_when: false keeps raw from reporting changed" 'ok=1 .*changed=0' bash -c \
  "printf -- '- hosts: svr-apache-01\n  gather_facts: false\n  tasks:\n    - raw: \"true\"\n      changed_when: false\n' >raw.yml && ansible-playbook raw.yml"

section "Reading module documentation"
doc=$(ANSIBLE_NOCOLOR=1 ansible-doc community.general.lvg 2>&1)
assert_match "lvg is in community.general, at the top of plugins/modules (from the note)" \
  'MODULE community\.general\.lvg .*/community/general/plugins/modules/lvg\.py' "$doc"
assert_match "  = marks the required option vg (with colour off)" '(^|\n) *= vg ' "$doc"
assert_match "  pvs, pesize, force and state are documented" 'force .*pesize .*pvs .*state ' "$(tr -s '\n ' ' ' <<<"$doc")"
check_output "with colour on, ansible-doc shows required options in red instead" 'red indicates it is required' \
  bash -c 'ANSIBLE_FORCE_COLOR=1 ansible-doc community.general.lvg'

section "Ad-hoc commands"
check_output "-a alone runs the command module (the correction)" 'ansible FTW' \
  bash -c "$(note_block "$NOTE" 'Ad-hoc commands' 1)"
check_output "  command is the default module" 'DEFAULT_MODULE_NAME\(default\) = command' \
  bash -c 'ansible-config dump 2>/dev/null'
mapfile -t adhoc < <(note_block "$NOTE" 'Ad-hoc commands' 2 | /usr/bin/grep -v '^#\|^$')
check_output "without -b, zypper needs root (the correction)" 'Root privileges are required' \
  bash -c "${adhoc[0]/ -b/} 2>&1; true"
check_output "httpd is only a capability on openSUSE, apache2 is the package (the correction)" '^ +\| apache2 ' \
  bash -c 'zypper -n se -x --provides httpd'
check_output "zypper installs apache2 (from the note)" 'CHANGED' bash -c "${adhoc[0]}"
check_output "  apache2 is installed" '^apache2-' rpm -q apache2
check_output "service restarts apache2 (from the note)" 'CHANGED' bash -c "${adhoc[1]}"
check "  and apache2 is active" systemctl is-active -q apache2
check_output "shell du -hs /opt (from the note)" '/opt' bash -c "${adhoc[2]}"
while read -r line; do
  check_output "$line (from the note)" 'SUCCESS' bash -c "$line"
done < <(note_block "$NOTE" 'Ad-hoc commands' 3; note_block "$NOTE" 'Ad-hoc commands' 4)
check_output "setup lists the host's facts (from the note)" '"ansible_facts"' \
  bash -c "$(note_block "$NOTE" 'Ad-hoc commands' 5)"

section "Connection options"
useradd -m deploy && install -d -m 700 -o deploy -g deploy /home/deploy/.ssh &&
  install -m 600 -o deploy -g deploy /root/.ssh/id_ed25519.pub /home/deploy/.ssh/authorized_keys
ssh-keygen -q -t ed25519 -N '' -f ~/.ssh/backup_id && cat ~/.ssh/backup_id.pub >>/home/ansible/.ssh/authorized_keys
printf -- '- hosts: all\n  gather_facts: false\n  tasks:\n    - command: whoami\n' >site.yml
mapfile -t conn < <(note_block "$NOTE" 'Connection options' 1 | /usr/bin/grep -v '^#\|^$')
check_output "-u deploy (from the note)" 'SUCCESS' bash -c "${conn[0]} -l svr-apache-01"
check_output "  ansible-playbook -u deploy (from the note)" 'ok=1' bash -c "${conn[1]} -l svr-apache-01"
mv ~/.ssh/id_ed25519 ~/.ssh/id_ed25519.off
check_output "--private-key uses another key (from the note)" 'SUCCESS' bash -c "${conn[2]} -l svr-apache-01"
check_output "  ansible-playbook --private-key (from the note)" 'ok=1' bash -c "${conn[3]} -l svr-apache-01"
mv ~/.ssh/id_ed25519.off ~/.ssh/id_ed25519
check_output "--ask-pass prompts for the SSH password (from the note)" 'SSH password:' \
  bash -c "${conn[4]} -l svr-apache-01 </dev/null 2>&1; true"
check_output "--ask-become-pass prompts, then runs (from the note; sudo here needs no password)" 'SUCCESS' \
  bash -c "printf '\n' | ${conn[5]} -l svr-apache-01 2>&1"
