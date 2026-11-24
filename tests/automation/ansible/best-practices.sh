#!/usr/bin/env bash
# note: automation/ansible/best-practices.md
# env: ansible-systemd
# Conventions are prose; what runs here: naming limits, inventory layout and merging,
# host patterns, role parameters, play order, the sample ansible.cfg and .gitignore.
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/automation/ansible/ansible-lib.bash"

NOTE=automation/ansible/best-practices
mkdir -p /work/bp && cd /work/bp
vars_all='ansible_host=127.0.0.1\nansible_user=ansible'
flat() { tr -d '\n' <<<"$1"; }

section "Naming"
check "a collection name with _ is accepted" ansible-galaxy collection init example.my_tools --init-path /tmp/col
check_output "  one with - is refused (collections: [a-zA-Z0-9_])" 'Invalid collection name|is not a valid|invalid' \
  bash -c 'ansible-galaxy collection init example.my-tools --init-path /tmp/col 2>&1; true'
check_output "a variable name cannot begin with a digit" 'not a valid variable name|Invalid variable name' \
  bash -c "ansible localhost -c local -m set_fact -a '1var=x' 2>&1; true"
check_output "  nor contain -" 'not a valid variable name|Invalid variable name' \
  bash -c "ansible localhost -c local -m set_fact -a 'my-var=x' 2>&1; true"
mkdir -p roles/nginx/{tasks,vars,meta}
printf -- '---\n__nginx_package: nginx\n' >roles/nginx/vars/main.yml
printf -- '---\n- name: Show the package\n  ansible.builtin.debug:\n    msg: "{{ __nginx_package }}"\n' >roles/nginx/tasks/main.yml
printf -- '---\ngalaxy_info:\n  author: a\n  description: b\n  license: MIT\n  min_ansible_version: "2.14"\n  platforms: [{name: EL, versions: ["9"]}]\ndependencies: []\n' >roles/nginx/meta/main.yml
check_output "__nginx_package in the nginx role passes ansible-lint's var-naming (the table)" '^$' \
  bash -c 'cd roles/nginx && ansible-lint -q . 2>&1 | grep "var-naming" || true'

section "Inventory"
mkdir -p inv/default/group_vars/all inv/qualif/group_vars
note_block "$NOTE" 'General' 1 | sed 's/ansible_host=[^ ]*/ansible_host=127.0.0.1 ansible_user=ansible/' >inv/default/hosts
check_output "aliases: the inventory lists mysql-01..apache-02 (from the note)" 'apache-02.*mysql-01|mysql-01.*apache-02' \
  bash -c 'ansible-inventory -i inv/default --graph | tr -d "\n"'
check_output "  each alias keeps its own ansible_host" '"ansible_host": "127.0.0.1"' ansible-inventory -i inv/default --host mysql-01
for v in 1 2 3; do echo "var$v: default$v" >inv/default/group_vars/all/var$v; done
echo 'var2: qualif2' >inv/qualif/group_vars/all.yml
printf '[postgresql]\npg-projectname-01\npg-server-01\n\n[projectname]\npg-projectname-01\napp-01\n\n[all:vars]\n%b\n' "$vars_all" >inv/qualif/hosts
check_output "group_vars files with no extension are read (var1, var2, var3)" '"var1": "default1"' \
  ansible-inventory -i inv/default --host mysql-01
out=$(ansible-inventory -i inv/default -i inv/qualif --host mysql-01)
assert_match "several inventories merge, the later one wins: var2 (the table)" '"var2": "qualif2"' "$out"
assert_match "  var3 keeps the default" '"var3": "default3"' "$out"
check_output "  given the other way round, the first one loses" '"var2": "default2"' \
  ansible-inventory -i inv/qualif -i inv/default --host mysql-01
mkdir -p inv/preprod/group_vars/all && printf '[all:vars]\n%b\n[g]\nh1\n' "$vars_all" >inv/preprod/hosts
printf 'from_vault_file: yes\n' >inv/preprod/group_vars/all/password.vault.preprod
check_output "a group_vars file named password.vault.preprod is ignored: .preprod is not a YAML extension (the correction)" '^ignored$' \
  bash -c 'ansible-inventory -i inv/preprod --host h1 | grep -q from_vault_file && echo read || echo ignored'
printf 'MySecretMasterKey\n' >inv/preprod/vaultid.preprod
check_output "a vault key file inside the inventory directory is read as an inventory: its content becomes a host (the correction)" \
  'MySecretMasterKey' bash -c 'ansible-inventory -i inv/preprod --list 2>&1'
rm inv/preprod/vaultid.preprod

section "Groups and host patterns"
for p in "$(note_block "$NOTE" 'host patterns' 1)" "$(note_block "$NOTE" 'host patterns' 2)"; do
  cmd=$(sed -n 's/^\$ //p' <<<"$p"); want=$(sed '1d' <<<"$p" | tr -d '\n')
  # shellcheck disable=SC2001 # a bracket expression; ${var//} cannot escape a set of characters
  check_output "$cmd (from the note)" "^$(sed 's/[][()]/\\&/g' <<<"$want")\$" \
    bash -c "$cmd | tr -d '\n'"
done
check_output "union with : (the table)" 'hosts \(3\)' ansible -i inv/qualif --list-hosts 'postgresql:projectname'
check_output "exclusion of one host (the table)" 'hosts \(1\)' ansible -i inv/qualif --list-hosts 'postgresql:!pg-server-01'
check_output "all (the table)" 'hosts \(3\)' ansible -i inv/qualif --list-hosts all

section "Roles"
check_output "molecule cannot create roles any more: use ansible-galaxy role init (the correction)" "No such command 'role'" \
  bash -c 'molecule init role x 2>&1; true'
mkdir -p roles/applicationXXX/tasks
note_block "$NOTE" 'Differentiating actions' 1 >roles/applicationXXX/tasks/main.yml
printf -- '- {name: install, ansible.builtin.debug: {msg: installing}}\n' >roles/applicationXXX/tasks/installation.yml
printf -- '- {name: uninstall, ansible.builtin.debug: {msg: uninstalling}}\n' >roles/applicationXXX/tasks/uninstallation.yml
printf '[appxxx]\napp-01\n\n[all:vars]\n%b\n' "$vars_all" >hosts
note_block "$NOTE" 'Differentiating actions' 2 | sed 's/^  roles:/  gather_facts: false\n  roles:/' >appxxx.yml
out=$(ansible-playbook -i hosts appxxx.yml 2>&1)
assert_match "action: as a role parameter warns: it is a reserved name (the correction)" "Found variable using reserved name 'action'" "$out"
sed -i 's/action/app_action/g' roles/applicationXXX/tasks/main.yml appxxx.yml
out=$(ansible-playbook -i hosts appxxx.yml 2>&1)
assert_match "  with app_action it picks the installation tasks" '"msg": "installing"' "$out"
assert_match "  and skips the uninstallation" 'TASK \[applicationXXX : uninstall\]..*skipping' "$(flat "$out")"

section "Playbooks"
for r in namespace.collection.role_name example.apache.apache_install logrotate; do
  mkdir -p "roles/$r/tasks" && printf -- '- {name: "%s", ansible.builtin.debug: {msg: "role %s"}}\n' "$r" "$r" >"roles/$r/tasks/main.yml"
done
note_block "$NOTE" 19 | sed 's/^  hosts: all/  hosts: all\n  gather_facts: false/; s/- namespace.collection.role_name/- role: namespace.collection.role_name/' >base.yml
out=$(ansible-playbook -i hosts base.yml 2>&1 || true)
assert_match "pre_tasks, then roles in order, then post_tasks (from the note, stub roles)" \
  'before the roles.*role namespace.collection.role_name.*role example.apache.apache_install.*role logrotate.*after the roles' "$(flat "$out")"
mkdir -p roles/user_create/tasks
printf -- '- {name: Create, ansible.builtin.debug: {msg: "user {{ user_name }}"}}\n' >roles/user_create/tasks/main.yml
note_block "$NOTE" 20 | sed 's/^  hosts: pprod/  hosts: appxxx\n  gather_facts: false/' >users.yml
out=$(ansible-playbook -i hosts users.yml 2>&1 || true)
assert_match "the same role three times with different values runs three times (from the note)" \
  'user anakin.*user luke.*user jarjar' "$(flat "$out")"
check_output "ansible-lint asks to name plays (the rule)" 'name\[play\]' bash -c 'ansible-lint -q appxxx.yml 2>&1; true'

section "Ansible configuration"
mkdir -p proj && cd proj && mkdir -p roles plugins/filters inventories/default inventories/dev
note_block "$NOTE" 'Ansible configuration' 1 >ansible.cfg
cp ansible.cfg fixed.cfg
# The original sample, as the corrections describe it.
sed -i 's|^inventory                   = .*|inventory                   = inventories/default:inventories/dev|; s/^callback_result_format      = yaml/stdout_callback             = yaml/' ansible.cfg
sed -i 's/^\(ssh_args *= -o ForwardAgent=yes\) -o ServerAliveInterval=60 -o ControlMaster=auto -o ControlPersist=15m$/\1\n                              -o ServerAliveInterval=60\n                              -o ControlMaster=auto\n                              -o ControlPersist=15m/' ansible.cfg
printf 'local ansible_host=127.0.0.1 ansible_user=ansible\n' >inventories/default/hosts
printf -- '- hosts: all\n  gather_facts: false\n  tasks:\n    - {name: Echo, ansible.builtin.command: echo hi}\n' >p.yml
check_output "the sample stdout_callback = yaml stops the play (the correction)" "callback plugin has been removed" \
  bash -c 'ansible-playbook p.yml 2>&1; true'
sed -i 's/^stdout_callback             = yaml/callback_result_format      = yaml/' ansible.cfg
check_output "inventory = a:b is read as one path, not two (the correction)" 'Unable to parse .*inventories/default:inventories/dev' \
  bash -c 'ansible-playbook p.yml 2>&1; true'
sed -i 's|^inventory                   = .*|inventory                   = inventories/default,inventories/dev|' ansible.cfg
check_output "  a comma separates inventory paths" 'inventories/default.*inventories/dev' \
  bash -c "ansible-config dump 2>/dev/null | grep '^DEFAULT_HOST_LIST'"
out=$(ansible-playbook p.yml 2>&1 || true)
assert_match "with callback_result_format = yaml the sample config runs" 'ok=1 .*changed=1' "$out"
assert_match "  the timer callback prints the play time" 'Playbook run took' "$out"
assert_match "  profile_tasks prints per-task timing" 'Echo -+ [0-9.]+s' "$out"
check_output "the multi-line ssh_args keeps only its first line (the correction)" '^ssh_args\(.*\) = -o ForwardAgent=yes$' \
  bash -c "ansible-config dump 2>/dev/null | grep '^ssh_args('"
cp fixed.cfg ansible.cfg
check_output "  the note's one-line ssh_args: all four options reach ssh" 'ForwardAgent=yes -o ServerAliveInterval=60 -o ControlMaster=auto -o ControlPersist=15m' \
  bash -c 'ansible-playbook p.yml -vvv 2>&1 | grep "SSH: EXEC"'
check_output "OpenSSH 10 accepts ServerAliveInterval=60s as 60 seconds (the correction)" '^serveraliveinterval 60$' \
  bash -c 'ssh -o ServerAliveInterval=60s -G localhost </dev/null 2>&1 | grep -i serveraliveinterval'

section "Dependencies"
printf -- 'roles:\n  - name: geerlingguy.apache\n    version: "3.2.0"\ncollections:\n  - name: community.general\n    version: ">=7.0.0"\n' >roles/requirements.yml
check_output "ansible-galaxy install -r installs into roles_path = roles (from the note)" 'geerlingguy.apache \(3\.2\.0\) was installed' \
  bash -c "$(note_block "$NOTE" Dependencies 1 | sed -n 1p) 2>&1"
check "  the role is in ./roles" test -d roles/geerlingguy.apache
check_output "  the same command also handles the collections, so the second line is optional" 'community\.general|Nothing to do|All requested collections' \
  bash -c "$(note_block "$NOTE" Dependencies 1 | sed -n 1p) 2>&1"
cd /work/bp

section "Use existing modules"
check_fails "ansible-doc -l | grep vmware fails in Ansible 15.0.0: -l crashes (the correction)" \
  bash -c 'set -o pipefail; ansible-doc -l 2>/dev/null | grep -q vmware'
check_output "  ansible-doc -l community.vmware works" '^community\.vmware\.' bash -c 'ansible-doc -l community.vmware 2>/dev/null'
mkdir -p library && printf '#!/usr/bin/python\nfrom ansible.module_utils.basic import AnsibleModule\nAnsibleModule(argument_spec={}).exit_json(changed=False, msg="local module")\n' >library/my_mod.py
printf -- '- hosts: appxxx\n  gather_facts: false\n  tasks:\n    - {name: Mine, my_mod: {}}\n' >lib.yml
check_output "a module in the project's library/ directory is found" '"msg": "local module"|ok=1' \
  bash -c 'ansible-playbook -i hosts lib.yml -v'

section ".gitignore"
git init -q gi && cd gi && note_block "$NOTE" '.gitignore' 1 >.gitignore
for f in x.retry .vault_pass a.vault key.pem collections/c roles/galaxy/r .venv/x; do
  check "git ignores $f (from the note)" git check-ignore -q "$f"
done
check_fails "  it does not ignore vaultid.preprod, the vault key file of the inventory example (the correction)" \
  git check-ignore -q inventories/preprod/vaultid.preprod
check_fails "  the encrypted password.vault.preprod stays tracked" git check-ignore -q inventories/preprod/group_vars/all/password.vault.preprod
cd /work/bp

section "Tests"
check_output "ansible-lint is installed (from the note)" 'ansible-lint [0-9]' ansible-lint --version
check_output "yamllint comes with ansible-lint (from the note)" '^yamllint [0-9]' bash -c 'yamllint --version || /opt/ansible/bin/yamllint --version'
