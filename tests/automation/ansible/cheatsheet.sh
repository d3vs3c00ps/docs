#!/usr/bin/env bash
# note: automation/ansible/cheatsheet.md
# env: ansible-systemd
# All hosts are 127.0.0.1 as the ansible user. chronyc keygen runs for real.
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/automation/ansible/ansible-lib.bash"

NOTE=automation/ansible/cheatsheet
mkdir -p /work/cs && cd /work/cs
printf '[servers]\nhost-01\nhost-02\nhost-03\n\n[apache]\napache-01\n\n[all:vars]\nansible_host=127.0.0.1\nansible_user=ansible\n' >hosts
printf '[defaults]\ninventory = hosts\n' >ansible.cfg
flat() { tr -d '\n' <<<"$1"; }
# lit TEXT: TEXT as an anchored regex that matches it literally.
# shellcheck disable=SC2001 # a bracket expression; ${var//} cannot escape a set of characters
lit() { printf '^%s$' "$(sed 's/[][\.*^$(){}+?|]/\\&/g' <<<"$1")"; }
# shown PLAY TASK: the yaml-format result of TASK in PLAY, on one line.
shown() { ANSIBLE_CALLBACK_RESULT_FORMAT=yaml ansible-playbook -i localhost, -c local "$1" 2>&1 | sed -n "/TASK \[$2\]/,/^\$/p" | sed '1d;/^$/d;s/ *$//' | tr -d '\n'; }

section "Excluding a host from its own group"
printf -- '- hosts: servers\n  gather_facts: false\n  vars:\n    %s\n  tasks:\n    - ansible.builtin.debug: {msg: "{{ chrony_ntp_peers | join(\x27,\x27) }}"}\n' \
  "$(note_block "$NOTE" 'Excluding a host' 1)" >peers.yml
out=$(ansible-playbook peers.yml 2>&1)
assert_match "host-01 gets the other two as peers (from the note)" 'host-01\] => \{    "msg": "host-02,host-03"' "$(flat "$out")"
assert_match "  host-02 too" 'host-02\] => \{    "msg": "host-01,host-03"' "$(flat "$out")"

section "Including a task file per distribution"
mkdir -p tasks/suse
printf -- '- ansible.builtin.debug: {msg: suse.yml}\n' >tasks/suse.yml
printf -- '- ansible.builtin.debug: {msg: redhat.yml}\n' >tasks/redhat.yml
{ printf -- '- hosts: host-01\n  tasks:\n'; note_block "$NOTE" 'per distribution' 1 | sed 's|"{{ ansible_os_family|"tasks/{{ ansible_os_family|; s/^/    /'; } >distro.yml
check_output "with_first_found falls back to suse.yml on Leap (from the note)" '"msg": "suse.yml"' ansible-playbook distro.yml
check_output "  ansible_distribution is 'openSUSE Leap' (with a space) on Leap" '"ansible_distribution": "openSUSE Leap"' \
  ansible host-01 -m setup -a filter=ansible_distribution
printf -- '- ansible.builtin.debug: {msg: most specific}\n' >"tasks/suse/opensuse leap_16.0.yml"
check_output "  the most specific file wins when it exists" '"msg": "most specific"' ansible-playbook distro.yml
printf -- '- hosts: host-01\n  gather_facts: false\n  tasks:\n    - ansible.builtin.include: tasks/suse.yml\n' >inc.yml
check_output "bare include is gone (the note)" "couldn't resolve module/action 'ansible.builtin.include'|removed" \
  bash -c 'ansible-playbook inc.yml 2>&1; true'

section "Extracting a registered variable across hosts"
zypper -n -q in chrony >/dev/null 2>&1
check_output "chronyc keygen 10 SHA512 2048 prints a key line" '^10 SHA512 HEX:' chronyc keygen 10 SHA512 2048
{ printf -- '- hosts: servers\n  gather_facts: false\n  tasks:\n'; note_block "$NOTE" 'Extracting a registered' 1 | sed 's/^/    /'; } >extract.yml
mkdir -p group_vars host_vars && printf 'chrony_generate_keys: false\n' >group_vars/all.yml
printf 'chrony_generate_keys: true\n' >host_vars/host-01.yml
out=$(ansible-playbook extract.yml -vv 2>&1 || true)
assert_match "the key is made on host-01 only (from the note)" 'skipping: \[host-02\]' "$out"
check_output "  and all three hosts find it in __chrony_key.0.stdout" '^3$' \
  bash -c "grep -c '\"__chrony_key.0.stdout\": \"10 SHA512 HEX:' <<<'$out'"
{ printf -- '- hosts: servers\n  gather_facts: false\n  tasks:\n'; note_block "$NOTE" 'Extracting a registered' 2 | sed 's/^/    /'; } >loop.yml
rm -rf host_vars group_vars && mkdir host_vars && printf 'chrony_generate_keys: true\n' >host_vars/host-02.yml
out=$(ansible-playbook loop.yml -vv 2>&1)
assert_match "the loop approach keeps the key (from the note)" '"__chrony_key": "10 SHA512 HEX:' "$out"
assert_match "  and no_log hides it while it is set" "output has been hidden due to the fact that 'no_log: true'" "$out"
rm -rf host_vars

sed "s/ansible_play_hosts | map('extract', hostvars, '__generated_chrony_key')/groups['all'] | map('extract', hostvars)/; s/| selectattr('stdout', 'defined') | list }}/| selectattr('__generated_chrony_key', 'search', 'stdout') | map(attribute='__generated_chrony_key') | list }}/" extract.yml >old.yml
mkdir -p group_vars host_vars && printf 'chrony_generate_keys: false\n' >group_vars/all.yml && printf 'chrony_generate_keys: true\n' >host_vars/host-01.yml
check_output "the original groups['all'] filter now fails (the correction)" "has no attribute '__generated_chrony_key'" \
  bash -c 'grep -q "groups\[.all.\]" old.yml && ansible-playbook old.yml 2>&1; true'
rm -rf host_vars group_vars

section "Sharing a variable between plays and hosts"
{ note_block "$NOTE" 'Sharing a variable' 1 | sed 's/^- hosts: localhost/- hosts: host-01/'
  printf -- '- hosts: host-02\n  gather_facts: false\n  tasks:\n    - ansible.builtin.debug: {msg: "resolv defined: {{ resolv is defined }}"}\n'; } >local.yml
out=$(ansible-playbook local.yml 2>&1)
assert_match "resolv is set on the host that ran the task (from the note)" '"msg": "/etc/resolv.conf"' "$out"
assert_match "  and not on the other host" '"msg": "resolv defined: False"' "$out"
{ note_block "$NOTE" 'Sharing a variable' 2; note_block "$NOTE" 'Sharing a variable' 3 | sed '1d'; } >share.yml
tail -1 /etc/resolv.conf >/tmp/resolv-last
want=$(sed 's/[][\.*^$(){}+?|]/\\&/g' /tmp/resolv-last)
check_output "add_host carries the value to the next play (from the note)" "\"msg\": \"$want\"" ansible-playbook share.yml
sed 's/__resolv: "{{ resolv.stdout }}"/__resolv: " {{ resolv.stdout }}"/' share.yml >space.yml
check_output "  with the original leading space it still works: the shell ignores it (the correction is wrong)" \
  "\"msg\": \"$want\"" ansible-playbook space.yml
printf -- '- hosts: host-01\n  gather_facts: false\n  tasks:\n    - ansible.builtin.add_host: {name: DUMMY_HOST, __resolv: " {{ \x27/etc/resolv.conf\x27 }}"}\n    - ansible.builtin.debug: {msg: "[{{ hostvars[\x27DUMMY_HOST\x27][\x27__resolv\x27] }}]"}\n' >sp2.yml
check_output "  but the space stays in the value" '"msg": "\[ /etc/resolv.conf\]"' ansible-playbook sp2.yml
check_fails "add_host hosts are gone in the next run" bash -c 'ansible-inventory --list | grep -q DUMMY_HOST'

section "Dumping all variables and facts for a host"
note_block "$NOTE" 'Dumping all variables' 1 >dump.yml
check "the dump play runs (from the note)" ansible-playbook dump.yml
check_output "  the vars file has the host's variables" '^ansible_host: 127\.0\.0\.1$' cat /tmp/apache-01_vars.txt
check_output "  the facts file has facts (gather_facts: true)" '^distribution: openSUSE Leap$' cat /tmp/apache-01_facts.txt
sed 's/gather_facts: true/gather_facts: false/' dump.yml >nofacts.yml && ansible-playbook nofacts.yml >/dev/null
check_output "  with gather_facts: false the facts dump is empty (the correction)" '^\{\}$' cat /tmp/apache-01_facts.txt

section "Determining a variable's type"
for v in '"3":str' '3:int' '[1]:list' '{}:dict'; do
  check_output "type_debug of ${v%:*} is ${v##*:} (from the note)" "\"msg\": \"${v##*:}\"" \
    ansible localhost -c local -m debug -a "msg={{ myvar | type_debug }}" -e "{\"myvar\": ${v%:*}}"
done

section "Lists"
note_block "$NOTE" 'Appending a value' 1 >append.yml
check_output "append with + ['citrus'] prints the note's output" "$(lit "$(note_block "$NOTE" 'Appending a value' 2 | tr -d '\n')")" shown append.yml 'Show list'
check_output "  fruit + 'citrus' (a string) is an error, not a per-character append" 'can only concatenate list|unsupported operand|failed=1' \
  bash -c "sed \"s/fruit + \\['citrus'\\]/fruit + 'citrus'/\" append.yml >str.yml && ansible-playbook -i localhost, -c local str.yml 2>&1; true"
note_block "$NOTE" 'Appending one list' 1 >combine.yml
check_output "fruit + vegetables prints the note's output" "$(lit "$(note_block "$NOTE" 'Appending one list' 2 | tr -d '\n')")" shown combine.yml 'Show list'
check_output "union deduplicates, + does not" '"msg": "\[1, 2, 3\] \[1, 2, 2, 3\]"' \
  ansible localhost -c local -m debug -a 'msg="{{ [1, 2] | union([2, 3]) }} {{ [1, 2] + [2, 3] }}"'

section "Dictionaries"
note_block "$NOTE" 'Adding entries' 1 >dict.yml
check_output "combine adds an entry: the note's output" "$(lit "$(note_block "$NOTE" 'Adding entries' 2 | tr -d '\n')")" shown dict.yml 'Show it'
printf -- '- hosts: localhost\n  gather_facts: false\n  vars:\n    config: {db: {host: h, port: 1}}\n  tasks:\n    - ansible.builtin.debug: {msg: "{{ config | combine({\x27db\x27: {\x27port\x27: 5432}}) }}"}\n    - ansible.builtin.debug:\n        msg: %s\n' "$(note_block "$NOTE" 'Adding entries' 3 | sed 's/^config: //')" >nested.yml
out=$(ansible-playbook -i localhost, -c local nested.yml 2>&1 | tr -d '\n ')
assert_match "combine replaces a nested dictionary by default" '"msg":\{"db":\{"port":5432\}\}' "$out"
assert_match "  recursive=true merges it (from the note)" '"msg":\{"db":\{"host":"h","port":5432\}\}' "$out"

section "Troubleshooting"
printf -- '- hosts: host-01\n  gather_facts: false\n  tasks:\n    - ansible.builtin.debug: {msg: deep, verbosity: 2}\n    - ansible.builtin.command: "true"\n' >v.yml
check_fails "-v hides verbosity: 2 debug messages" bash -c 'ansible-playbook v.yml -v | grep -q "\"msg\": \"deep\""'
check_output "-vv shows them (the table)" '"msg": "deep"' ansible-playbook v.yml -vv
check_output "-vvv shows the SSH commands (the table)" 'SSH: EXEC ssh' ansible-playbook v.yml -vvv
out=$(ansible-playbook v.yml -vvvv 2>&1)
assert_match "-vvvv adds plugin loading (the table)" 'Loading callback plugin' "$out"
assert_match "  and the command-line options (the table)" 'Positional arguments: v\.yml' "$out"
check_output "debug var=hostvars[inventory_hostname] (from the note)" '"ansible_host": "127.0.0.1"' \
  bash -c "$(note_block "$NOTE" Troubleshooting 1 | sed -n 2p | sed 's/<host>/host-01/')"
check_output "ansible-config dump --only-changed (from the note)" 'DEFAULT_HOST_LIST' \
  bash -c "$(note_block "$NOTE" Troubleshooting 1 | sed -n 5p)"
printf '[defaults]\ninventory = hosts\ncallbacks_enabled = profile_tasks\n' >ansible.cfg
check_output "callbacks_enabled = profile_tasks times each task (from the note)" '^command -+ [0-9.]+s$|ansible.builtin.command -+ [0-9.]+s' \
  ansible-playbook v.yml
check_output "  the short name resolves to ansible.posix.profile_tasks" 'profile_tasks' \
  bash -c 'ansible-doc -t callback ansible.posix.profile_tasks | head -1'
