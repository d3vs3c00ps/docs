#!/usr/bin/env bash
# note: automation/ansible/installation.md
# env: ansible-systemd
# Ansible comes from the env image (pip, in a venv). The AWX Operator line needs a
# Kubernetes cluster and is not run.
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/automation/ansible/ansible-lib.bash"

NOTE=automation/ansible/installation
mkdir -p /work/proj && cd /work/proj

section "Installation"
check_output "Python on the control node is 3.13 or later (ansible-core 2.22 needs it)" \
  '^Python 3\.(1[3-9]|[2-9][0-9])\.' python3 --version
check_output "the pip line names the ansible package (from the note)" 'pip install ansible$' \
  note_block "$NOTE" Installation 2
check_output "ansible-core 2.22 is installed" 'core 2\.22\.' ansible --version
check_output "the ansible package brings collections, such as community.general" '^community\.general ' \
  bash -c 'ansible-galaxy collection list 2>/dev/null'

section "Directory layout"
assert_no_file "pip creates no /etc/ansible (the correction)" /etc/ansible
check_output "with no ansible.cfg, Ansible runs on defaults" 'CONFIG_FILE\(\) = None' \
  bash -c 'cd / && ansible-config dump 2>/dev/null'
check "ansible-config init --disabled writes a commented file (from the correction)" \
  bash -c 'ansible-config init --disabled >full.cfg 2>/dev/null && grep -q "^;forks=5" full.cfg'
rm -f full.cfg

# The search order: ANSIBLE_CONFIG, ./ansible.cfg, ~/.ansible.cfg, /etc/ansible/ansible.cfg.
printf '[defaults]\ntimeout = 33\n' >~/.ansible.cfg
printf '[defaults]\nforks = 7\n' >ansible.cfg
check_output "./ansible.cfg wins over ~/.ansible.cfg" 'CONFIG_FILE\(\) = /work/proj/ansible.cfg' \
  bash -c 'ansible-config dump 2>/dev/null'
check_fails "and the files are not merged: timeout from ~/.ansible.cfg is not used" \
  bash -c 'ansible-config dump --only-changed 2>/dev/null | grep -q "DEFAULT_TIMEOUT.* = 33"'
check_output "ANSIBLE_CONFIG wins over both" 'CONFIG_FILE\(\) = /root/.ansible.cfg' \
  bash -c 'ANSIBLE_CONFIG=~/.ansible.cfg ansible-config dump 2>/dev/null'
mkdir -p /work/open && cp ansible.cfg /work/open/ && chmod 777 /work/open
check_output "an ansible.cfg in a world-writable directory is ignored" 'world writable directory.*ignoring it' \
  bash -c 'cd /work/open && ansible-config dump 2>&1'
rm -f ~/.ansible.cfg ansible.cfg

section "Configuring Ansible"
check_output "forks is 5 by default" 'DEFAULT_FORKS\(default\) = 5' bash -c 'ansible-config dump 2>/dev/null'
note_block "$NOTE" 'Configuring Ansible' 2 >ansible.cfg
check_output "the note's settings are all read (ansible-config dump --only-changed, from the note)" \
  'CACHE_PLUGIN\(.*\) = jsonfile' bash -c "$(note_block "$NOTE" 'Configuring Ansible' 3 | sed -n 1p) 2>/dev/null"
dump=$(bash -c "$(note_block "$NOTE" 'Configuring Ansible' 3 | sed -n 1p)" 2>/dev/null)
for key in DEFAULT_GATHERING CACHE_PLUGIN_TIMEOUT HOST_KEY_CHECKING pipelining ssh_args result_format; do
  assert_match "  $key comes from ./ansible.cfg" "(^|[[:space:]])$key\\(/work/proj/ansible.cfg\\)" "$dump"
done
check "ansible-config view prints the file (from the note)" \
  bash -c "$(note_block "$NOTE" 'Configuring Ansible' 3 | sed -n 2p) | grep -q '^gathering = explicit'"
cat >play.yml <<'EOF'
- hosts: all
  gather_facts: false
  tasks:
    - command: echo hi
      register: r
    - debug:
        var: r.stdout_lines
EOF
check_output "with the note's settings, a play over SSH (pipelining) prints YAML results" '^ +- hi$' \
  ansible-playbook -i '127.0.0.1,' -u ansible play.yml
sed -i 's/^callback_result_format = yaml/stdout_callback = yaml/' ansible.cfg
check_output "the original stdout_callback = yaml now stops the play (the correction)" \
  "community.general.yaml' callback plugin has been removed" bash -c 'ansible-playbook -i 127.0.0.1, -u ansible play.yml 2>&1; true'
check "the facts cache directory is used" bash -c \
  'sed -i "s/^stdout_callback = yaml/callback_result_format = yaml/" ansible.cfg &&
   ansible -i 127.0.0.1, -u ansible all -m setup >/dev/null 2>&1 && ls /tmp/ansible_facts/ | grep -q 127.0.0.1'
