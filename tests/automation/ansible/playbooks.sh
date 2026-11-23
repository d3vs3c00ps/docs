#!/usr/bin/env bash
# note: automation/ansible/playbooks.md
# env: ansible-systemd
# Three apache hosts, all 127.0.0.1 as the ansible user. The env is openSUSE, so the
# note's Red Hat tasks (dnf, httpd) get a syntax check and ansible-lint only.
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/automation/ansible/ansible-lib.bash"

NOTE=automation/ansible/playbooks
mkdir -p /work/pb && cd /work/pb
printf '[apache]\nsvr-apache-0[1:3]\n\n[all:vars]\nansible_host=127.0.0.1\nansible_user=ansible\n' >hosts
printf '[defaults]\ninventory = hosts\n' >ansible.cfg
dbg() { printf -- '- name: %s\n  ansible.builtin.debug:\n    msg: %s\n' "$1" "$2"; }
for r in lvm firewall apache; do
  mkdir -p roles/example.$r/tasks && dbg "role $r" "role $r" >roles/example.$r/tasks/main.yml
done
count() { /usr/bin/grep -c -- "$1" <<<"$2" || true; }

section "Playbooks"
note_block "$NOTE" Playbooks 1 >roles.yml
out=$(ansible-playbook roles.yml 2>&1)
assert_match "the roles playbook runs the three roles (from the note, stub roles)" 'role lvm.*role firewall.*role apache' "$(tr -d '\n' <<<"$out")"
check_output "  a tag on a role picks just that role" '"msg": "role apache"' ansible-playbook roles.yml --tags apache
check_fails "  and not the others" bash -c 'ansible-playbook roles.yml --tags apache | grep -q "role lvm"'
note_block "$NOTE" Playbooks 2 >install_apache.yml
check "the tasks playbook passes --syntax-check (from the note)" ansible-playbook install_apache.yml --syntax-check
sed 's/ansible\.builtin\.dnf/ansible.builtin.yum/' install_apache.yml >yum.yml
check_output "ansible.builtin.yum is now a redirect to dnf (the correction)" 'major revision of dnf' \
  bash -c 'ansible-playbook yum.yml -l svr-apache-01 2>&1; true'

section "Tasks and idempotence"
mkdir -p /tmp/src/bin && echo app >/tmp/src/bin/app && tar czf /tmp/app.tar.gz -C /tmp/src . && mkdir -p /opt/app && chown ansible /opt/app /tmp/app.tar.gz
{ echo '- hosts: svr-apache-01'; echo '  tasks:'; note_block "$NOTE" 'Tasks and idempotence' 1 | sed 's/^/    /'; } >extract.yml
check_output "creates: the first run extracts (from the note)" 'changed=1' ansible-playbook extract.yml
check_output "  the second run skips it: changed=0" 'changed=0' ansible-playbook extract.yml
printf '#!/bin/sh\necho "${STATE:-OK}"\n' >/usr/local/bin/cluster-health && chmod +x /usr/local/bin/cluster-health
{ echo '- hosts: svr-apache-01'; echo '  gather_facts: false'; echo '  tasks:'; note_block "$NOTE" 'Tasks and idempotence' 2 | sed 's/^/    /'; } >health.yml
check_output "changed_when: false reports ok, not changed (from the note)" 'ok=1 .*changed=0' ansible-playbook health.yml
sed -i 's|command: cluster-health|command: sh -c "STATE=DEGRADED cluster-health"|' health.yml
check_output "  failed_when fails on DEGRADED in stdout" 'failed=1' bash -c 'ansible-playbook health.yml; true'

section "Task ordering"
note_block "$NOTE" 'Task ordering' 1 >order.yml
out=$(ansible-playbook order.yml -l svr-apache-01 2>&1)
assert_match "pre_tasks, roles, tasks, post_tasks run in that order (from the note)" \
  'Runs before everything.*role apache.*Runs after the included roles.*Runs after everything' "$(tr -d '\n' <<<"$out")"
cat >phases.yml <<'EOF'
- hosts: svr-apache-01
  gather_facts: false
  pre_tasks:
    - {name: pre, ansible.builtin.command: "true", notify: h}
  tasks:
    - {name: main, ansible.builtin.command: "true", notify: h}
  post_tasks:
    - {name: post, ansible.builtin.debug: {msg: post}}
  handlers:
    - {name: h, ansible.builtin.debug: {msg: handler ran}}
EOF
out=$(ansible-playbook phases.yml 2>&1)
assert_match "handlers run at the end of each phase, not of the play (the correction)" \
  'TASK \[pre\].*RUNNING HANDLER \[h\].*TASK \[main\].*RUNNING HANDLER \[h\].*TASK \[post\]' "$(tr -d '\n' <<<"$out")"

section "Task execution"
printf -- '- hosts: apache\n  gather_facts: false\n  tasks:\n    - ansible.builtin.command: sleep 3\n' >sleep.yml
check_output "a task runs on all hosts in parallel: 3 hosts x 3 s take under 8 s" '^[0-7]$' \
  bash -c 's=$SECONDS; ansible-playbook sleep.yml >/dev/null; echo $((SECONDS - s))'
check_output "  with forks=1 they run one after another" '^(9|[1-9][0-9])$' \
  bash -c 's=$SECONDS; ansible-playbook -f 1 sleep.yml >/dev/null; echo $((SECONDS - s))'

section "Blocks"
{ echo '- hosts: svr-apache-01'; echo '  tasks:'; note_block "$NOTE" Blocks 1 | sed 's/^/    /'; } >block.yml
check "the when-block passes --syntax-check (from the note)" ansible-playbook block.yml --syntax-check
check_output "  on openSUSE the when skips the whole block" 'skipped=2' ansible-playbook block.yml
mkdir -p /opt/app && printf '#!/bin/sh\nexit 1\n' >/opt/app/upgrade.sh && printf '#!/bin/sh\necho rolled back\n' >/opt/app/rollback.sh && chmod +x /opt/app/*.sh
{ echo '- hosts: svr-apache-01'; echo '  gather_facts: false'; echo '  tasks:'; note_block "$NOTE" Blocks 2 | sed 's/^/    /'; } >rescue.yml
out=$(ansible-playbook rescue.yml 2>&1)
assert_match "a failed block runs rescue, then always (from the note)" 'TASK \[Roll back\].*Upgrade attempted' "$(tr -d '\n' <<<"$out")"
assert_match "  and the play counts as rescued, not failed" 'failed=0 .*rescued=1' "$out"

section "run_once"
{ note_block "$NOTE" run_once 1 | sed 's|command: /opt/app/migrate.sh|command: hostname|; s/^  tasks:/  gather_facts: false\n  tasks:/'; } >once.yml
out=$(ansible-playbook once.yml -v 2>&1)
assert_match "run_once runs on the first host only (from the note)" 'changed: \[svr-apache-01\]' "$out"
assert_no_match "  not on the others" 'svr-apache-0[23]\]' "$(/usr/bin/grep -A1 'TASK \[Initialise' <<<"$out")"

section "serial"
note_block "$NOTE" serial 1 | sed 's/ansible.builtin.service:/ansible.builtin.command: "true"/; /name: httpd/d; /state: restarted/d; s/^  tasks:/  gather_facts: false\n  tasks:/' >serial.yml
check_output "serial: 1 runs the play host by host: 3 batches (from the note)" '^3$' \
  bash -c 'ansible-playbook serial.yml | grep -c "^TASK \[Restart apache\]"'
for v in '30%:3' '[1, 10]:2' '[1, 100%]:2'; do
  sed "s/serial: 1/serial: ${v%:*}/" serial.yml >s2.yml
  check_output "serial: ${v%:*} on 3 hosts gives ${v##*:} batches (the table)" "^${v##*:}\$" \
    bash -c 'ansible-playbook s2.yml | grep -c "^TASK \[Restart apache\]"'
done
printf -- '- hosts: apache\n  tasks:\n    - ansible.builtin.debug: {msg: x}\n      serial: 1\n' >bad.yml
check_output "serial under a task is rejected (the correction)" 'conflicting action statements: .*serial' \
  bash -c 'ansible-playbook bad.yml --syntax-check 2>&1; true'

section "Delegation"
skip "win_command Add-DnsServerResourceRecordA (from the note)" "needs a Windows DNS server over WinRM"
useradd -m deploy && install -d -m 700 -o deploy -g deploy /home/deploy/.ssh &&
  install -m 600 -o deploy -g deploy /root/.ssh/id_ed25519.pub /home/deploy/.ssh/authorized_keys
sed -i '1i infra ansible_host=127.0.0.1 ansible_user=deploy' hosts
printf -- '- hosts: svr-apache-01\n  gather_facts: false\n  tasks:\n    - ansible.builtin.command: whoami\n      delegate_to: infra\n      register: w\n    - ansible.builtin.debug: {msg: "{{ inventory_hostname }} via {{ w.stdout }}"}\n' >deleg.yml
check_output "delegate_to runs the task on another host, inventory_hostname stays the target" '"msg": "svr-apache-01 via deploy"' \
  ansible-playbook deleg.yml
check_output "delegate_to: localhost runs on the control node" '"msg": "svr-apache-01 via root"' \
  bash -c 'sed "s/delegate_to: infra/delegate_to: localhost/" deleg.yml >dl.yml && ansible-playbook dl.yml'

section "Handlers"
mkdir -p hroles/web/{tasks,handlers,templates}
note_block "$NOTE" Handlers 1 | sed 's/name: httpd/name: apache2/' >hroles/web/handlers/main.yml
note_block "$NOTE" Handlers 2 | sed 's|/etc/httpd/conf/httpd.conf|/etc/apache2/test.conf|' >hroles/web/tasks/main.yml
echo '# {{ inventory_hostname }} v1' >hroles/web/templates/httpd.conf.j2
zypper -n -q in apache2 >/dev/null 2>&1 && systemctl start apache2
printf -- '- hosts: svr-apache-01\n  become: true\n  roles: [web]\n' >web.yml
export ANSIBLE_ROLES_PATH=$PWD/hroles
check_output "the template change notifies the handler (from the note, apache2 on openSUSE)" 'RUNNING HANDLER \[web : restart apache\]' \
  ansible-playbook web.yml
check_fails "  no change on the next run: the handler does not run" bash -c 'ansible-playbook web.yml | grep -q "RUNNING HANDLER"'
cat >many.yml <<'EOF'
- hosts: svr-apache-01
  gather_facts: false
  tasks:
    - {ansible.builtin.command: "true", notify: h}
    - {ansible.builtin.command: "true", notify: h}
    - {name: flush, ansible.builtin.meta: flush_handlers}
    - {name: after flush, ansible.builtin.debug: {msg: x}}
    - {ansible.builtin.command: "false"}
    - {ansible.builtin.command: "true", notify: h2}
  handlers:
    - {name: h, ansible.builtin.debug: {msg: h ran}}
    - {name: h2, ansible.builtin.debug: {msg: h2 ran}}
EOF
out=$(ansible-playbook many.yml 2>&1 || true)
check_output "two notifies, one handler run" '^1$' bash -c "grep -c 'RUNNING HANDLER \[h\]' <<<'$out'"
assert_match "meta: flush_handlers runs it early" 'RUNNING HANDLER \[h\].*TASK \[after flush\]' "$(tr -d '\n' <<<"$out")"
sed -i 's/command: "false"}/command: "true", notify: h2}\n    - {ansible.builtin.command: "false"}/' many.yml
check_fails "a failed task stops the play: pending handlers never run (the warning)" \
  bash -c 'ansible-playbook many.yml | grep -q "RUNNING HANDLER \[h2\]"'
check_output "  --force-handlers runs them anyway (the warning)" 'RUNNING HANDLER \[h2\]' \
  bash -c 'ansible-playbook many.yml --force-handlers; true'

section "Tags"
cat >site.yml <<'EOF'
- hosts: svr-apache-01
  gather_facts: false
  tasks:
    - {name: Config repos, ansible.builtin.debug: {msg: repos}, tags: configrepos}
    - {name: Install apache, ansible.builtin.debug: {msg: apache}, tags: installapache}
    - {name: Harden, ansible.builtin.debug: {msg: harden}, tags: secure-os}
    - {name: Always, ansible.builtin.debug: {msg: always}, tags: always}
    - {name: Never, ansible.builtin.debug: {msg: never}, tags: never}
EOF
check_output "always runs with --tags for another tag" 'TASK \[Always\]' ansible-playbook site.yml --tags configrepos
check_fails "  --skip-tags always skips it" bash -c 'ansible-playbook site.yml --skip-tags always | grep -q "TASK \[Always\]"'
check_fails "never does not run by default" bash -c 'ansible-playbook site.yml | grep -q "TASK \[Never\]"'
check_output "  it runs when asked by name" 'TASK \[Never\]' ansible-playbook site.yml --tags never

section "Controlling execution"
run_line() { bash -c "$(note_block "$NOTE" 'Controlling execution' "$1" | sed -n "${2:-1}p")" 2>&1; }
check_output "--syntax-check (from the note)" 'playbook: site.yml' run_line 1
printf -- '- hosts: svr-apache-01\n  gather_facts: false\n  tasks:\n    - {name: Write, ansible.builtin.copy: {dest: /tmp/chkd/chk, content: "new\\n"}}\n    - {name: Cmd, ansible.builtin.command: touch /tmp/cmd-ran}\n' >chk.yml
install -d -o ansible /tmp/chkd && echo old >/tmp/chkd/chk && chown ansible /tmp/chkd/chk
c=$(note_block "$NOTE" 'Controlling execution' 2)
out=$(cd /work/pb && bash <<<"${c//site.yml/chk.yml} --diff" 2>&1)
assert_match "--check --diff shows the change (from the note)" '-old\+new' "$(tr -d '\n' <<<"$out")"
check_output "  and writes nothing" '^old$' cat /tmp/chkd/chk
assert_match "  command is skipped in check mode (the note)" 'skipping: \[svr-apache-01\]' "$out"
assert_no_file "  so it really did not run" /tmp/cmd-ran
check_output "--diff alone applies and shows the diff (from the note)" '^\+new' \
  bash -c 'ansible-playbook chk.yml --diff 2>&1'
check_output "-l limits the hosts (from the note)" 'svr-apache-01' \
  bash -c "$(note_block "$NOTE" 'Controlling execution' 4) --list-hosts"
check_output "--list-hosts (from the note)" 'hosts \(1\)' run_line 5 1
check_output "--list-tasks (from the note)" 'Install apache' run_line 5 2
check_output "--list-tags (from the note)" 'TASK TAGS: \[.*configrepos' run_line 5 3
out=$(run_line 6 1)
assert_match "--tags=configrepos,installapache (from the note)" 'TASK \[Config repos\].*TASK \[Install apache\]' "$(tr -d '\n' <<<"$out")"
assert_no_match "  and not Harden" 'TASK \[Harden\]' "$out"
check_fails "--skip-tags=\"secure-os\" (from the note)" bash -c "$(note_block "$NOTE" 'Controlling execution' 6 | sed -n 2p) | grep -q 'TASK \[Harden\]'"
out=$(run_line 7)
assert_match "--start-at-task=\"Config repos\" (from the note)" 'TASK \[Config repos\]' "$out"
check_output "  --start-at-tasks (plural) is rejected (the correction)" '--start-at-tasks=Config repos could not be found' \
  bash -c 'ansible-playbook site.yml --start-at-tasks="Config repos" 2>&1; true'
check_output "--step asks before each task (from the note)" 'Perform task: TASK: Config repos' \
  bash -c "yes y | $(note_block "$NOTE" 'Controlling execution' 8) 2>&1"
check_output "-vvv shows the SSH command (from the note)" 'SSH: EXEC ssh' \
  bash -c "$(note_block "$NOTE" 'Controlling execution' 9 | sed 's/site.yml/chk.yml/') 2>&1"
