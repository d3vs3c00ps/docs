#!/usr/bin/env bash
# note: automation/ansible/intro.md
# env: ansible-systemd
# A concept note: the YAML rules and the agentless/idempotent claims are what can run.
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/automation/ansible/ansible-lib.bash"

cd /work
play() { printf '%b' "$1" >p.yml && ansible-playbook -i 127.0.0.1, -u ansible p.yml 2>&1; }
# rejected DESC REGEX YAML: the playbook fails, with a message matching REGEX.
rejected() { local out rc=0; out=$(play "$3") || rc=$?; assert_match "$1" "$2" "rc=$rc $out"; }

section "Ansible concepts"
check_output "agentless: a host with only sshd and Python is managed (ping over SSH)" '"ping": "pong"' \
  ansible -i 127.0.0.1, -u ansible all -m ping
check_fails "  and no Ansible agent runs there" pgrep -f 'ansible.*agent'
printf -- '- hosts: all\n  become: true\n  gather_facts: false\n  tasks:\n    - copy: {dest: /etc/motd-test, content: "hi\\n"}\n' >idem.yml
check_output "idempotent: the first run changes the file" 'changed=1' ansible-playbook -i 127.0.0.1, -u ansible idem.yml
check_output "  the second run changes nothing" 'changed=0' ansible-playbook -i 127.0.0.1, -u ansible idem.yml

section "YAML"
rejected "tabs are not valid indentation" '^rc=[1-9].*Tabs are usually invalid in YAML' \
  '- hosts: all\n  gather_facts: false\n  tasks:\n\t- debug: msg=x\n'
rejected "msg: {{ var }} unquoted is invalid YAML (the tip)" '^rc=[1-9].*missing quotes around a template block' \
  '- hosts: all\n  gather_facts: false\n  vars: {v: 1}\n  tasks:\n    - debug:\n        msg: {{ v }}\n'
check_output "msg: \"{{ var }}\" quoted works" '"msg": 1' \
  play '- hosts: all\n  gather_facts: false\n  vars: {v: 1}\n  tasks:\n    - debug:\n        msg: "{{ v }}"\n'
check_output "a playbook without the ... end marker runs (the correction)" 'ok=1' \
  play '---\n- hosts: all\n  gather_facts: false\n  tasks:\n    - debug: msg=x\n'
check_output "  and one with it runs too" 'ok=1' \
  play '---\n- hosts: all\n  gather_facts: false\n  tasks:\n    - debug: msg=x\n...\n'
