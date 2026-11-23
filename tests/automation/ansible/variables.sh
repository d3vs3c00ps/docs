#!/usr/bin/env bash
# note: automation/ansible/variables.md
# env: ansible-systemd
# The apache host is 127.0.0.1 as the ansible user. The note's Red Hat package tasks
# (dnf) run against a local stub module, dnf_stub, that only echoes its arguments.
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/automation/ansible/ansible-lib.bash"

NOTE=automation/ansible/variables
mkdir -p /work/var/library && cd /work/var
printf '[apache]\nsvr-apache-01\n\n[all:vars]\nansible_host=127.0.0.1\nansible_user=ansible\n' >hosts
printf '[defaults]\ninventory = hosts\nlibrary = library\n' >ansible.cfg
cat >library/dnf_stub.py <<'EOF'
#!/usr/bin/python
from ansible.module_utils.basic import AnsibleModule
m = AnsibleModule(argument_spec=dict(name=dict(type='raw'), state=dict(default='present'),
                                     enablerepo=dict()), supports_check_mode=True)
m.exit_json(changed=True, msg='dnf %s %s' % (m.params['name'], m.params['state']))
EOF
# play FILE: run it with dnf swapped for the stub; prints the output.
play() { sed -i 's/ansible\.builtin\.dnf:/dnf_stub:/' "$1"; ansible-playbook "$@" 2>&1 || true; }
# wrap: make a play for svr-apache-01 out of a task list (stdin).
wrap() { printf -- '- hosts: apache\n  gather_facts: %s\n  tasks:\n' "${1:-false}"; sed 's/^/    /'; }
flat() { tr -d '\n' <<<"$1"; }
export -f play note_block

section "Declaring variables"
{ note_block "$NOTE" 'Declaring variables' 1; printf '  tasks:\n    - ansible.builtin.debug: {msg: "{{ http_port }}/{{ https_port }}"}\n'; } >v1.yml
check_output "vars as key/value pairs (from the note)" '"msg": "80/443"' play v1.yml
{ note_block "$NOTE" 'Declaring variables' 2; printf '  tasks:\n    - ansible.builtin.debug: {msg: "{{ apache_ports[1].port }}"}\n'; } >v2.yml
check_output "vars as a list (from the note)" '"msg": "?443' play v2.yml
check "the package dictionary is valid YAML (from the note)" \
  bash -c "note_block $NOTE 'Declaring variables' 3 | /opt/ansible/bin/python3 -c 'import sys,yaml; d=yaml.safe_load(sys.stdin); assert d[\"package\"][\"enablerepo\"]==\"testing\"'"
check "the list of dictionaries with a list is valid YAML (from the note)" \
  bash -c "note_block $NOTE 'Declaring variables' 4 | /opt/ansible/bin/python3 -c 'import sys,yaml; d=yaml.safe_load(sys.stdin); assert d[0][\"apache\"][\"modules\"][2]==\"mod_ssl\"'"
{ printf -- '- hosts: apache\n  gather_facts: false\n'; note_block "$NOTE" 'Declaring variables' 5 | sed 's/^/  /'; } >v5.yml
out=$(play v5.yml -v)
assert_match "dict2items loops over the dictionary (from the note)" 'dnf httpd latest.*dnf mysql-server latest' "$(flat "$out")"
assert_match "  item.key is the dictionary key" "'key': 'apache'" "$out"
printf -- '- hosts: apache\n  gather_facts: false\n  vars:\n    pkg: {name: httpd, state: present}\n  tasks:\n    - ansible.builtin.set_fact:\n        pkg: "{{ pkg | combine({\x27state\x27: \x27latest\x27}) }}"\n    - ansible.builtin.debug: {msg: "{{ pkg }}"}\n' >combine.yml
check_output "to change one value, rewrite the whole dictionary (combine)" '"state": "latest"' play combine.yml

section "Variables in the inventory"
note_block "$NOTE" 'Variables in the inventory' 1 >inv.ini
printf '\n[all:vars]\nansible_host=127.0.0.1\nansible_user=ansible\n' >>inv.ini
check_output "inline host vars and [group:vars] (from the note)" '"protocol": "http"' \
  ansible -i inv.ini svr-apache-01 -m debug -a var=protocol
check_output "  svr-apache-02 sets its own protocol" '"protocol": "https"' \
  ansible -i inv.ini svr-apache-02 -m debug -a var=protocol
mkdir -p inventory/{group_vars,host_vars} && cp hosts inventory/hosts
printf 'motd: from group_vars\n' >inventory/group_vars/all.yml
printf 'motd: from host_vars\n' >inventory/host_vars/svr-apache-01.yml
check_output "group_vars/ and host_vars/ next to the inventory are read (the tree)" '"motd": "from host_vars"' \
  ansible -i inventory/hosts svr-apache-01 -m debug -a var=motd

section "Using variables"
check_output "debug ad-hoc (from the note)" '"msg": "var=80"' \
  bash -c "$(note_block "$NOTE" 'Using variables' 1 | sed 's/ansible apache/ansible -i inv.ini svr-apache-01/')"
note_block "$NOTE" 'Using variables' 2 | sed 's/^  tasks:/  gather_facts: false\n  vars: {http_port: 80}\n  tasks:/' >dbg.yml
check_output "debug in a playbook (from the note)" 'The listening port is 80' play dbg.yml
printf -- '- hosts: apache\n  gather_facts: false\n  vars:\n    apache_ports: [{protocol: http, port: 80}]\n  tasks:\n    - ansible.builtin.debug: {msg: "{{ apache_ports[0] }}"}\n    - ansible.builtin.debug: {msg: "{{ apache_ports[0].protocol }}"}\n' >idx.yml
out=$(play idx.yml)
assert_match "apache_ports[0] returns the whole entry (from the note)" '"port": 80, *"protocol": "http"' "$(flat "$out")"
assert_match "  apache_ports[0].protocol returns one field" '"msg": "http"' "$out"

section "Variable precedence"
mkdir -p roles/r/{defaults,vars,tasks}
printf 'v: role-defaults\n' >roles/r/defaults/main.yml
printf -- '- ansible.builtin.debug: {msg: "v={{ v }}"}\n' >roles/r/tasks/main.yml
# prec LAYERS: build a play with these layers on, print the winner.
prec() {
  local hostvar=; [[ $* == *host* ]] && hostvar=' v=inventory-host-var'
  printf '[apache]\nsvr-apache-01%s\n\n[apache:vars]\nv=inventory-group-var\n\n[all:vars]\nansible_host=127.0.0.1\nansible_user=ansible\n' "$hostvar" >prec.ini
  [[ $* == *group* ]] || sed -i '/^\[apache:vars\]/,+1d' prec.ini
  if [[ $* == *rolevars* ]]; then printf 'v: role-vars\n' >roles/r/vars/main.yml; else rm -f roles/r/vars/main.yml; fi
  { printf -- '- hosts: apache\n  gather_facts: false\n'
    [[ $* == *play* ]] && printf '  vars: {v: play-vars}\n'
    printf '  roles: [r]\n'; } >prec.yml
  ansible-playbook -i prec.ini prec.yml ${EXTRA:+-e v=extra-vars} 2>&1 | sed -n 's/.*"msg": "v=\(.*\)"/\1/p'
}
check_output "1-2: role defaults are the lowest variable layer" '^role-defaults$' prec
check_output "3: inventory group vars beat role defaults" '^inventory-group-var$' prec group
check_output "8: inventory host vars beat group vars" '^inventory-host-var$' prec group host
check_output "12: play vars beat inventory vars" '^play-vars$' prec group host play
check_output "15: role vars beat play vars" '^role-vars$' prec group host play rolevars
prec_e() { EXTRA=1 prec "$@"; }
check_output "22: -e beats everything" '^extra-vars$' prec_e group host play rolevars
printf -- '- hosts: apache\n  gather_facts: false\n  vars: {v: play}\n  tasks:\n    - {ansible.builtin.debug: {msg: "v={{ v }}"}, vars: {v: task}}\n    - ansible.builtin.set_fact: {v: set_fact}\n    - {ansible.builtin.debug: {msg: "v={{ v }}"}, vars: {v: task}}\n' >tv.yml
out=$(play tv.yml)
assert_match "17: task vars beat play vars" '"msg": "v=task"' "$out"
assert_match "19: set_fact beats task vars" '"msg": "v=set_fact"' "$out"
useradd -m deploy
check_output "1: -u on the command line loses to ansible_user in the inventory" '^ansible$' \
  bash -c 'ansible svr-apache-01 -u deploy -m command -a whoami 2>&1 | tail -1'

section "Lists"
check "fruit: two ways to write a list, both the same (from the note)" bash -c \
  "note_block $NOTE Lists 1 | awk 'BEGIN{RS=\"\"} {print > (\"/tmp/fruit\" NR \".yml\")}' &&
   [ \"\$(/opt/ansible/bin/python3 -c 'import yaml;print(yaml.safe_load(open(\"/tmp/fruit1.yml\")))')\" = \"\$(/opt/ansible/bin/python3 -c 'import yaml;print(yaml.safe_load(open(\"/tmp/fruit2.yml\")))')\" ]"
note_block "$NOTE" Lists 2 >lists.yml
check_output "the list demo prints the note's output (yaml result format)" \
  "$(note_block "$NOTE" Lists 3 | /usr/bin/grep 'msg:' | head -1)" \
  env ANSIBLE_CALLBACK_RESULT_FORMAT=yaml ansible-playbook -i localhost, -c local lists.yml
check_output "  second element" '^    msg: banana$' \
  env ANSIBLE_CALLBACK_RESULT_FORMAT=yaml ansible-playbook -i localhost, -c local lists.yml
note_block "$NOTE" Lists 4 >pkgs.yml
out=$(play pkgs.yml)
assert_match "the list of dictionaries drives a loop (from the note)" 'item=\{.*httpd.*item=\{.*php' "$(flat "$out")"

section "Dictionaries"
check "shopping: two ways to write a dictionary, both the same (from the note)" bash -c \
  "note_block $NOTE Dictionaries 1 | awk 'BEGIN{RS=\"\"} {print > (\"/tmp/shop\" NR \".yml\")}' &&
   [ \"\$(/opt/ansible/bin/python3 -c 'import yaml;print(yaml.safe_load(open(\"/tmp/shop1.yml\")))')\" = \"\$(/opt/ansible/bin/python3 -c 'import yaml;print(yaml.safe_load(open(\"/tmp/shop2.yml\")))')\" ]"
note_block "$NOTE" Dictionaries 2 >dloop.yml
check_output "a list of dictionaries in vars drives a loop (from the note)" 'dnf php present' play dloop.yml -v
note_block "$NOTE" Dictionaries 3 >dict.yml
check_output "the dict demo prints the note's output" '^    msg: tomato$' \
  env ANSIBLE_CALLBACK_RESULT_FORMAT=yaml ansible-playbook -i localhost, -c local dict.yml

section "Loops"
note_block "$NOTE" Loops 1 >l1.yml
check_output "loop over a simple list (from the note)" 'item=httpd.*item=php' bash -c 'play l1.yml | tr -d "\n"'
note_block "$NOTE" Loops 2 >l2.yml
check_output "loop_control: loop_var renames item (from the note)" 'item=httpd.*item=php' bash -c 'play l2.yml | tr -d "\n"'
printf -- '- hosts: apache\n  gather_facts: false\n  tasks:\n    - ansible.builtin.debug: {msg: "{{ item }}"}\n      with_items: [a, b]\n' >with.yml
out=$(play with.yml)
assert_match "with_items still works (the correction)" '"msg": "b"' "$out"
assert_no_match "  with no deprecation warning" 'DEPRECAT' "$out"
printf -- '- ansible.builtin.debug: {msg: "{{ outer }}-{{ item }}"}\n  loop: [1, 2]\n' >inner.yml
printf -- '- ansible.builtin.include_tasks: inner.yml\n  loop: [a, b]\n  loop_control: {loop_var: outer}\n' | wrap >nest.yml
check_output "loop_var lets include_tasks loop inside a loop (from the note)" '"msg": "a-1".*"msg": "a-2".*"msg": "b-1".*"msg": "b-2"' \
  bash -c 'play nest.yml | tr -d "\n"'
sed -i 's/{{ outer }}/{{ item }}/; ' inner.yml && sed -i 's/loop_control: {loop_var: outer}//' nest.yml
check_output "  without it, the inner loop warns that item is in use" "The variable 'item' is already in use" play nest.yml
printf -- '- dnf_stub: {name: [httpd, php]}\n' | wrap >one.yml
out=$(play one.yml -v)
assert_match "a list in name: runs the module once (the tip)" "dnf \['httpd', 'php'\] present" "$out"
assert_no_match "  with no per-item results" 'item=' "$out"

section "Conditions"
note_block "$NOTE" Conditions 1 | wrap true >c1.yml
check_output "when: ansible_os_family == 'RedHat' skips on openSUSE (from the note)" 'skipped=1' play c1.yml
sed -i "s/'RedHat'/'Suse'/" c1.yml
check_output "  and runs where it matches (os_family Suse)" 'changed=1' play c1.yml
note_block "$NOTE" Conditions 2 | wrap true >c2.yml
check_output "a list in when: with integer comparisons (from the note)" 'changed=1' play c2.yml
printf -- '- ansible.builtin.debug: {msg: yes}\n  when: ansible_python.version.major >= "3"\n' | wrap true >cstr.yml
check_output "  comparing to the string '3' fails (the note)" "not supported between instances of 'int' and 'str'|'>=' not supported" \
  bash -c 'play cstr.yml; true'
printf -- '- ansible.builtin.debug: {msg: newer}\n  when: ansible_distribution_version is version("8.0", ">=")\n' | wrap true >cver.yml
check_output "the version test (from the note, Leap 16.0 >= 8.0)" '"msg": "newer"' play cver.yml
check_output "  string comparison gets '10' < '9' wrong (the note)" '"msg": true' \
  ansible localhost -c local -m debug -a 'msg="{{ \"10\" < \"9\" }}"'

section "Operators"
for op in 'lt:<:1:2' 'le:<=:2:2' 'gt:>:3:2' 'ge:>=:2:2' 'eq:==:2:2' 'ne:!=:1:2'; do
  IFS=: read -r w s a b <<<"$op"
  check_output "$s and the word form $w agree (the table)" '"msg": "True True"' \
    ansible localhost -c local -m debug -a "msg=\"{{ $a $s $b }} {{ $a is $w $b }}\""
done

section "Conditions with search and match"
note_block "$NOTE" 'search and match' 1 | wrap true >m1.yml
check_output "match(\"RedHat\") skips on openSUSE (from the note)" 'skipped=1' play m1.yml
t() { ansible localhost -c local -m debug -a "msg=\"{{ '$1' is $2 }}\"" 2>&1; }
check_output "match anchors at the start: RedHat is match(\"Hat\") is false" '"msg": false' t RedHat 'match("Hat")'
for i in 2 3; do
  cond=$(note_block "$NOTE" 'search and match' $i | sed 's/^ *when: ansible_os_family //')
  check_output "RedHat $cond (from the note)" '"msg": true' t RedHat "${cond#is }"
done

section "Conditions testing files"
note_block "$NOTE" 'testing files' 1 | sed "s|'/opt/nfs'|'/proc'|" | wrap >f1.yml
check_output "'/proc' is mount (from the note, /proc for /opt/nfs)" 'changed=1' play f1.yml
for tst in directory:/tmp file:/etc/hosts link:/proc/self exists:/etc mount:/proc; do
  check_output "the $tst test (the list)" '"msg": true' \
    ansible localhost -c local -m debug -a "msg=\"{{ '${tst#*:}' is ${tst%%:*} }}\""
done
check_output "exist (no s) is not a test (the note)" "No test named 'exist'" \
  bash -c "ansible localhost -c local -m debug -a \"msg={{ '/etc' is exist }}\" 2>&1; true"
skip "file tests run on the control node, not the target" "here the control node and the target are the same machine"
note_block "$NOTE" 'testing files' 2 | sed 's|/opt/nfs|/proc|' | wrap >f2.yml
check_output "stat + register tests the path on the target (from the note)" 'changed=1' play f2.yml

section "Filters"
check_output "the listed filters all exist" '"msg": "True,abc,ABC,3,1.5,x,3,\[1, 2\],a,b,\[1\],\[1\],eA==,c,/a/b"' \
  ansible localhost -c local -m debug -a "msg=\"{{ 'yes' | bool }},{{ 'ABC' | lower }},{{ 'abc' | upper }},{{ '3' | int }},{{ '1.5' | float }},{{ ' x ' | trim }},{{ 'abc' | length }},{{ [1,1,2] | unique }},{{ ['a','b'] | join(',') }},{{ [1] | to_json }},{{ '[1]' | from_json }},{{ 'x' | b64encode }},{{ '/a/b/c' | basename }},{{ '/a/b/c' | dirname }}\""
check_output "default('present') fills an undefined value (from the note)" '"msg": "present"' \
  ansible localhost -c local -m debug -a "msg=\"{{ package.state | default('present') }}\"" -e '{"package": {}}'
printf -- '- ansible.builtin.file: {path: /tmp/omit-test, state: touch, mode: "{{ m | default(omit) }}"}\n' | wrap >omit.yml
check "default(omit) drops the parameter (from the note)" bash -c 'play omit.yml >/dev/null && test -f /tmp/omit-test'

section "Inclusion"
printf -- '- {name: child one, ansible.builtin.debug: {msg: one}}\n- {name: child two, ansible.builtin.debug: {msg: two}}\n' >child.yml
printf -- '- {name: imp, ansible.builtin.import_tasks: child.yml, tags: t}\n' | wrap >imp.yml
printf -- '- {name: inc, ansible.builtin.include_tasks: child.yml, tags: t}\n' | wrap >inc.yml
check_output "import_*: the tag is copied to every child task" 'child one.*TAGS: \[t\].*child two.*TAGS: \[t\]' \
  bash -c 'ansible-playbook imp.yml --list-tasks | tr -d "\n"'
check_fails "include_*: --list-tasks cannot see inside it (the note)" bash -c 'ansible-playbook inc.yml --list-tasks | grep -q "child one"'
check_fails "  and the tag stays on the include: the children do not run with --tags t" \
  bash -c 'ansible-playbook inc.yml --tags t | grep -q "TASK \[child one\]"'
check_output "--start-at-task cannot start inside an include (the note)" 'No matching task "child two" found' \
  bash -c 'ansible-playbook inc.yml --start-at-task "child two" 2>&1; true'
check_output "  it can inside an import" 'TASK \[child two\]' ansible-playbook imp.yml --start-at-task "child two"
printf -- '- ansible.builtin.import_tasks: child.yml\n  loop: [1, 2]\n' | wrap >imploop.yml
check_output "import_* cannot take a loop (the note)" "You cannot use loops on 'import_tasks' statements" \
  bash -c 'ansible-playbook imploop.yml 2>&1; true'

section "Templates"
mkdir -p templates /etc/httpd/sites-available
note_block "$NOTE" Templates 1 >templates/vhost.conf.j2
{ printf -- '- hosts: apache\n  become: true\n  gather_facts: false\n  vars: {http_port: 8080, http_site_name: blog.lab, http_site_path: /srv/www}\n  tasks:\n'
  note_block "$NOTE" Templates 2 | sed '1d; /notify:/d; /validate:/d; s/^/    /'; } >tpl.yml
check_output "the vhost template renders (from the note, without validate)" 'changed=1' play tpl.yml
check_output "  with the port and name filled in" '<VirtualHost \*:8080>' cat /etc/httpd/sites-available/vhosts.conf
check_output "  \${APACHE_LOG_DIR} is passed through for Apache to expand" 'ErrorLog \$\{APACHE_LOG_DIR\}/error.log' \
  cat /etc/httpd/sites-available/vhosts.conf
zypper -n -q in apache2 apache2-utils >/dev/null 2>&1
check_output "apachectl -t -f on a lone vhost file fails: -f expects a whole server config (the correction)" 'Syntax error|Invalid command|not defined|AH0' \
  bash -c 'apachectl -t -f /etc/httpd/sites-available/vhosts.conf 2>&1; true'
check_output "validate: stops a broken file from being installed" 'failed=1' bash -c \
  "printf -- '- hosts: apache\n  gather_facts: false\n  tasks:\n    - ansible.builtin.copy: {content: \"bad\", dest: /tmp/v.conf, validate: \"false %%s\"}\n' >val.yml && ansible-playbook val.yml; true"
assert_no_file "  the destination is not written" /tmp/v.conf

section "Loops in templates"
note_block "$NOTE" 'Loops in templates' 2 >templates/sites.j2
printf -- '- ansible.builtin.template: {src: sites.j2, dest: /tmp/sites.conf}\n  vars:\n' | wrap >sites.yml
note_block "$NOTE" 'Loops in templates' 1 | sed 's/^/        /' >>sites.yml
check "the loop renders (from the note)" bash -c 'play sites.yml >/dev/null'
check_output "  one VirtualHost per site" '^3$' bash -c 'grep -c "<VirtualHost" /tmp/sites.conf'
check_output "  in order" 'blog.lab.*wiki.lab.*chat.lab' bash -c 'grep ServerName /tmp/sites.conf | tr -d "\n"'
sed 's/{% endfor %}/{% endfor % }/' templates/sites.j2 >templates/bad.j2
check_output "{% endfor % } fails to render (the correction)" 'failed=1' \
  bash -c "sed 's/sites.j2/bad.j2/' sites.yml >bad.yml && play bad.yml; true"
printf 'start\n{%% for x in [1, 2] %%}\nline {{ x }}\n{%% endfor %%}\nend\n' >templates/ws.j2
printf -- '- ansible.builtin.template: {src: ws.j2, dest: /tmp/ws.out}\n' | wrap >ws.yml
play ws.yml >/dev/null
check_output "the template module trims the newline after a tag: no blank lines (the correction)" '^start line 1 line 2 end $' \
  bash -c 'tr "\n" " " </tmp/ws.out'
printf 'start\n  {%% for x in [1] %%}\nline\n  {%% endfor %%}\nend\n' >templates/ws.j2 && play ws.yml >/dev/null
check_output "  indentation before an indented tag stays" '^  line$' sed -n 2p /tmp/ws.out
printf 'start\n  {%%- for x in [1] %%}\nline\n  {%%- endfor %%}\nend\n' >templates/ws.j2 && play ws.yml >/dev/null
check_output "  {%- strips it, newline included (the tip)" '^startline' head -1 /tmp/ws.out
