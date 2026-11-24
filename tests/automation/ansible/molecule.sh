#!/usr/bin/env bash
# note: automation/ansible/molecule.md
# env: ansible-systemd
# timeout: 900
# Molecule runs against this machine over SSH (the note's "host you already have").
# The Docker driver needs Docker and molecule-plugins: not run.
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/automation/ansible/ansible-lib.bash"

NOTE=automation/ansible/molecule
cd /work
mol() { molecule "$@" 2>&1 | grep -v 'Another version of'; return "${PIPESTATUS[0]}"; }
export -f mol

section "Creating a role and a scenario"
check "ansible-galaxy role init, then molecule init scenario (from the note)" \
  bash -c "$(note_block "$NOTE" 'Creating a role' 1)"
cd my_first_role
check_output "  it adds the files shown in the note" "^$(note_block "$NOTE" 'Creating a role' 2 | sed 's/[│├└─ ]//g' | sed -n '3,$p' | sort | tr '\n' ' ')\$" \
  bash -c 'ls molecule/default | sort | tr "\n" " "'
check_output "molecule init role is gone (the correction)" "No such command 'role'" bash -c 'molecule init role x 2>&1; true'
sed -i 's/yournamespace\.yourcollection\.yourrole/example.my_first_role/' molecule/default/converge.yml
check_output "without a namespace, Molecule stops (the warning)" 'does not follow current galaxy requirements' \
  bash -c 'mol converge; true'
note_block "$NOTE" 'Creating a role' 3 | sed -n 's/^  \(namespace\|role_name\):/  \1:/p' >/tmp/ns
sed -i "/^galaxy_info:/r /tmp/ns" meta/main.yml
check_output "  with namespace and role_name in meta/main.yml it goes on" 'example\.my_first_role|Executed: Successful|converge' \
  bash -c 'mol syntax'

section "The molecule.yml file"
mol_yml=molecule/default/molecule.yml
for key in dependency ansible scenario; do
  check_output "the generated molecule.yml has $key: (the table)" "^$key:" cat $mol_yml
done
for key in driver platforms provisioner verifier; do
  check_fails "  and no $key: (the correction)" grep -q "^$key:" $mol_yml
done
note_block "$NOTE" 'The molecule.yml file' 1 | sed 's/192\.0\.2\.10/127.0.0.1/' >molecule/default/inventory.yml
check_output "the generated file has the placeholder inventory (the note)" '/path/to/inventory.yml' cat $mol_yml
sed -i "s|--inventory=/path/to/inventory.yml|$(note_block "$NOTE" 'The molecule.yml file' 2 | grep -o -- '--inventory=.*')|" $mol_yml
check_output "  replaced by the note's --inventory line" 'MOLECULE_SCENARIO_DIRECTORY\}/inventory.yml' cat $mol_yml
check_output "the generated verify.yml targets hosts: instance (the note)" '^  hosts: instance$' cat molecule/default/verify.yml
cat >tasks/main.yml <<'EOF'
- name: Install apache2
  become: true
  community.general.zypper:
    name: apache2
- name: Start apache2
  become: true
  ansible.builtin.service:
    name: apache2
    state: started
EOF
out=$(mol test)
assert_match "molecule test runs the note's sequence" 'scenario test matrix: dependency, cleanup, destroy, syntax, create, prepare, converge, idempotence, side_effect, verify, cleanup, destroy' "$out"
assert_match "  converge changes the instance" 'instance +: ok=[0-9]+ +changed=[1-9]' "$out"
assert_match "  idempotence: the second run changes nothing" 'idempotence\] Executed: Successful' "$out"
assert_match "  verify passes" 'verify\] Executed: Successful' "$out"
check_output "  the role really ran on the host" 'active' systemctl is-active apache2

section "Usage"
check_output "molecule converge (from the note)" 'converge\] Executed: Successful' mol converge
check_output "molecule converge --scenario-name default (from the note)" 'converge\] Executed: Successful' mol converge --scenario-name default
check "molecule init scenario opensuse adds a second scenario (from the note)" \
  bash -c "molecule init scenario opensuse >/dev/null 2>&1 && test -f molecule/opensuse/molecule.yml"
check_output "  --scenario-name prod with no such scenario fails" 'prod' bash -c 'mol converge --scenario-name prod; true'
help=$(molecule --help 2>/dev/null)
for c in $(sed -n '/^### The other important commands/,/^`molecule test`/p' "$NOTES_ROOT/content/$NOTE.md" | grep -o '^| `[a-z-]*`' | tr -d '|` '); do
  assert_match "molecule $c exists (the table)" "^  $c " "$help"
done
check_output "test --destroy=never is an option (the tip)" '\-\-destroy \[always\|never\]' bash -c 'molecule test --help 2>/dev/null'
printf -- '- name: Not idempotent\n  ansible.builtin.command: "true"\n' >tasks/main.yml
check_output "a task that always changes fails the idempotence step" 'Idempotence test failed|idempotence.*(fail|Fail)' \
  bash -c 'mol test --destroy=never; true'

section "Verifying with the ansible verifier"
note_block "$NOTE" 'ansible verifier' 1 | sed 's/httpd/apache2/g' >molecule/default/verify.yml
check_output "the note's verify.yml passes (apache2 for httpd on openSUSE)" 'verify\] Executed: Successful' mol verify
systemctl stop apache2
check_output "  and fails when the service is stopped" 'failed=1' bash -c 'mol verify; true'
