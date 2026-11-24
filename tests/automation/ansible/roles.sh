#!/usr/bin/env bash
# note: automation/ansible/roles.md
# env: ansible-systemd
# The apache host is 127.0.0.1 as the ansible user. Galaxy lines need the network.
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/automation/ansible/ansible-lib.bash"

NOTE=automation/ansible/roles
mkdir -p /work/ro && cd /work/ro
printf '[apache]\nsvr-apache-01\n\n[all:vars]\nansible_host=127.0.0.1\nansible_user=ansible\n' >hosts
printf '[defaults]\ninventory = hosts\n' >ansible.cfg
role() { # role NAME TASK-MSG [META-DEPS]
  mkdir -p "roles/$1"/{tasks,meta}
  printf -- '- ansible.builtin.debug: {msg: "%s"}\n' "$2" >"roles/$1/tasks/main.yml"
  printf 'dependencies: [%s]\n' "${3:-}" >"roles/$1/meta/main.yml"
}

section "Creating a role"
check "ansible-galaxy init --offline (from the note)" bash -c "$(note_block "$NOTE" 'Creating a role' 1)"
want=$(note_block "$NOTE" 'Creating a role' 2 | sed 's/ *#.*//; s/[│├└─ ]//g; s|/$||; /^$/d' | sort | tr '\n' ' ')
got=$(cd roles && find syslog-ng | sed 's|.*/||' | sort | tr '\n' ' ')
check "  it makes the tree shown in the note ($got)" test "$want" = "$got"

section "The directories"
mkdir -p roles/dv/{defaults,vars,tasks}
printf 'conf: default\nconst: role-vars\n' >roles/dv/defaults/main.yml
printf 'const: role-vars\n' >roles/dv/vars/main.yml
printf -- '- ansible.builtin.debug: {msg: "{{ conf }}/{{ const }}"}\n' >roles/dv/tasks/main.yml
printf -- '- hosts: apache\n  gather_facts: false\n  roles:\n    - {role: dv, vars: {}}\n' >dv.yml
printf -- '- hosts: apache\n  gather_facts: false\n  vars: {conf: caller, const: caller}\n  roles: [dv]\n' >dv2.yml
check_output "defaults/ is used when the caller sets nothing" '"msg": "default/role-vars"' ansible-playbook dv.yml
check_output "  play vars override defaults/, not vars/ (the tip)" '"msg": "caller/role-vars"' ansible-playbook dv2.yml

section "meta/main.yml"
note_block "$NOTE" 'meta/main.yml' 1 >roles/syslog-ng/meta/main.yml
printf -- '- name: Placeholder\n  ansible.builtin.debug:\n    msg: syslog-ng\n' >roles/syslog-ng/tasks/main.yml
check_output "the meta file passes ansible-lint's meta checks (from the note)" 'Passed|^$' \
  bash -c 'cd roles/syslog-ng && ansible-lint -q . 2>&1 | grep -E "^(meta|schema)|Passed" || true'
role common common-ran
role web web-ran common
role db db-ran common
printf -- '- hosts: apache\n  gather_facts: false\n  roles: [web, db]\n' >deps.yml
out=$(ansible-playbook deps.yml 2>&1)
assert_match "a dependency runs before the role that needs it" 'common-ran.*web-ran' "$(tr -d '\n' <<<"$out")"
check_output "  once per play, though two roles need it (the warning)" '^1$' bash -c "grep -c 'common-ran' <<<'$out'"
printf 'allow_duplicates: true\ndependencies: []\n' >roles/common/meta/main.yml
check_output "  allow_duplicates: true in its meta runs it each time" '^2$' \
  bash -c 'ansible-playbook deps.yml | grep -c common-ran'

section "Ansible Galaxy"
check_output "ansible-galaxy search apache (from the note)" 'Found [0-9]+ roles matching' \
  bash -c "$(note_block "$NOTE" 'Ansible Galaxy' 1 | sed -n 1p)"
check_output "ansible-galaxy install geerlingguy.apache (from the note)" 'geerlingguy.apache .* was installed successfully' \
  bash -c "$(note_block "$NOTE" 'Ansible Galaxy' 1 | sed -n 2p) 2>&1"
check_output "ansible-galaxy list shows it (from the note)" 'geerlingguy\.apache, ' \
  bash -c "$(note_block "$NOTE" 'Ansible Galaxy' 1 | sed -n 4p) 2>/dev/null"
check_output "ansible-galaxy remove (from the note)" 'successfully removed' \
  bash -c "$(note_block "$NOTE" 'Ansible Galaxy' 1 | sed -n 3p)"
note_block "$NOTE" 'Ansible Galaxy' 2 >requirements.yml
out=$(bash -c "$(note_block "$NOTE" 'Ansible Galaxy' 3)" 2>&1)
assert_match "install -r requirements.yml installs the pinned role (from the note)" 'geerlingguy.apache \(3\.2\.0\) was installed' "$out"
assert_match "  and handles the collections section too" 'community\.general|Nothing to do|All requested collections' "$out"
check_output "  the role is at the pinned version" 'geerlingguy\.apache, 3\.2\.0' bash -c 'ansible-galaxy list 2>/dev/null'

section "Using roles"
role example.apache role-apache
role example.lvm role-lvm
note_block "$NOTE" 'Using roles' 1 | sed 's/^  tasks:/  gather_facts: false\n  pre_tasks: []\n  tasks:/' >use.yml
sed -i 's/^  tasks:/  tasks:\n    - {name: first task, ansible.builtin.debug: {msg: first-task}}/' use.yml
out=$(ansible-playbook use.yml 2>&1)
assert_match "roles: runs before tasks:, include_role where it stands (from the note)" 'role-apache.*first-task.*role-lvm' "$(tr -d '\n' <<<"$out")"
printf -- '- hosts: apache\n  gather_facts: false\n  tasks:\n    - ansible.builtin.debug: {msg: before}\n    - ansible.builtin.import_role: {name: example.lvm}\n    - ansible.builtin.debug: {msg: after}\n' >imp.yml
check_output "import_role runs between two tasks (the note)" 'before.*role-lvm.*after' bash -c 'ansible-playbook imp.yml | tr -d "\n"'

section "Collections"
check_output "ansible-galaxy collection list (from the note)" '^community\.general ' \
  bash -c "$(note_block "$NOTE" Collections 1 | sed -n 3p) 2>/dev/null"
check_output "ansible-galaxy collection install community.general (from the note)" 'community.general|Nothing to do|already installed' \
  bash -c "$(note_block "$NOTE" Collections 1 | sed -n 1p) 2>&1"
check_output "ansible.builtin is part of ansible-core itself" 'ansible/modules/copy.py' bash -c 'ansible-doc ansible.builtin.copy | head -1'
zypper -n -q in lvm2 >/dev/null 2>&1
if img=$(mktemp /var/tmp/pv.XXXX) && truncate -s 64M "$img" && dev=$(losetup -f --show "$img" 2>/dev/null); then
  { printf -- '- hosts: apache\n  become: true\n  gather_facts: false\n  tasks:\n'; note_block "$NOTE" Collections 2 | sed "s|/dev/sdb1|$dev|; s/^/    /"; } >lvg.yml
  check_output "community.general.lvg creates the volume group (from the note, on a loop device)" 'changed=1' ansible-playbook lvg.yml
  check_output "  vgs shows it" '^ *data ' vgs --noheadings data
  vgremove -f data >/dev/null 2>&1; pvremove -f "$dev" >/dev/null 2>&1; losetup -d "$dev"
else
  skip "community.general.lvg (from the note)" "no loop device in this container"
fi
