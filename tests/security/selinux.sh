#!/usr/bin/env bash
# note: security/selinux.md
# env: rocky
source "$NOTES_ROOT/tests/lib/assert.sh"

NOTE=security/selinux
# The Docker host's kernel has no SELinux, so nothing here can label files or load a
# policy. The tools work offline on the policy file and the policy store, and -n/-N
# keep semodule and semanage from trying to load anything.
dnf -y -q install --setopt=install_weak_deps=False selinux-policy-targeted policycoreutils-python-utils \
  setools-console libselinux-utils audit >/dev/null
P=$(ls /etc/selinux/targeted/policy/policy.*)
# cmds HEADING [N]: the commands of a block, without their "$ " or "# " prompt and output.
cmds() { note_block "$NOTE" "$1" "${2:-1}" | sed -n 's/^[$#] //p'; }
# out HEADING [N]: the output lines of the same block.
out() { note_block "$NOTE" "$1" "${2:-1}" | grep -vE '^([$#] |$)'; }
# has_lines EXPECTED ACTUAL: every line of EXPECTED is a line of ACTUAL.
has_lines() { local l; while IFS= read -r l; do grep -qxF -- "$l" <<<"$2" || { echo "missing: $l"; return 1; }; done <<<"$1"; }
cd "$(mktemp -d)"

section "Operating modes"
skip "setenforce, and labels in permissive mode (the correction)" "needs a kernel with SELinux enabled; the Docker host's kernel has none"

section "Current status"
check_output "sestatus runs (here it reports disabled)" '^SELinux status: +disabled' sestatus

section "Users"
check "semanage login -l prints the note's mappings" has_lines "$(out 'Users' | grep -v '^Login Name')" "$(semanage login -l)"

section "Types"
check_output "the policy has user_home_t (the correction)" '^ +user_home_t$' seinfo -t user_home_t "$P"
check_output "and no home_user_t" '^Types: 0$' seinfo -t home_user_t "$P"

section "What it actually buys you"
check_output "setools-console provides sesearch (from the note)" 'sesearch' bash -c "$(note_block "$NOTE" 'What it actually buys you' 1) >/dev/null; command -v sesearch"
rules=$(bash -c "$(note_block "$NOTE" 'What it actually buys you' 2) $P")
check "the note's sesearch output lines are in the real output (from the note)" \
  has_lines "$(note_block "$NOTE" 'What it actually buys you' 3)" "$rules"
check_fails "httpd_t cannot write httpd_sys_content_t" grep -q 'httpd_sys_content_t:file' <<<"$rules"
check_output "but can read it, through the httpd_content_type attribute" 'allow httpd_t httpd_content_type:file .*open read' \
  sesearch --allow -s httpd_t -t httpd_sys_content_t -c file -p read "$P"
check_output "httpd_t may read user_tmp_t but never open it: the example's Forbidden" '\{ append getattr ioctl lock read \}' \
  sesearch --allow -s httpd_t -t user_tmp_t -c file "$P"
check_fails "no rule gives httpd_t open on user_tmp_t (outside a boolean)" \
  bash -c "sesearch --allow -s httpd_t -t user_tmp_t -c file -p open '$P' | grep -v '\\]:True'"

section "A worked example"
skip "cp relabels, mv keeps the label; restorecon and chcon" "needs a kernel with SELinux enabled to store labels; the Docker host's kernel has none"

section "Restoring the default context"
check_output "matchpathcon gives the note's answer (from the note)" \
  "^$(out 'Restoring the default context' 1 | sed 's/\./\\./g; s/ \{1,\}/[[:space:]]+/')\$" bash -c "$(cmds 'Restoring the default context' 1)"
check_output "selabel_lookup gives the same context (from the note)" 'system_u:object_r:httpd_sys_content_t:s0' \
  bash -c "$(note_block "$NOTE" 'Restoring the default context' 2)"

section "Setting a context yourself"
check_output "/usr/share is usr_t (from the note)" 'system_u:object_r:usr_t:s0' bash -c "$(cmds 'Setting a context yourself' 1)"
check_output "/srv/web defaults to var_t before semanage" 'object_r:var_t:s0' matchpathcon /srv/web/selinux/index.html
check "semanage fcontext -a (from the note, with -N: no policy reload)" \
  bash -c "$(cmds 'Setting a context yourself' 5 | sed 's/semanage fcontext/semanage fcontext -N/')"
check_output "the rule lands in file_contexts.local" '^/srv/web\(/\.\*\)\? +system_u:object_r:httpd_sys_content_t:s0' \
  cat /etc/selinux/targeted/contexts/files/file_contexts.local
check_output "now the default context is httpd_sys_content_t" 'object_r:httpd_sys_content_t:s0' matchpathcon /srv/web/selinux/index.html
check "semanage fcontext -d undoes it (from the note)" \
  bash -c "$(cmds 'Setting a context yourself' 7 | grep semanage | sed 's/semanage fcontext/semanage fcontext -N/')"
check_output "back to var_t" 'object_r:var_t:s0' matchpathcon /srv/web/selinux/index.html

section "Booleans"
check "semanage boolean -l | grep httpd prints the note's lines (from the note)" \
  has_lines "$(out 'Booleans' 3)" "$(bash -c "$(cmds 'Booleans' 3)")"
check_output "getsebool needs SELinux enabled" 'SELinux is disabled' bash -c 'getsebool -a 2>&1; true'
skip "setsebool -P" "needs a kernel with SELinux enabled"

section "Troubleshooting denials"
t=$(date +%s)
echo "type=AVC msg=audit($t.123:400): avc:  denied  { open } for  pid=2792 comm=\"httpd\" path=\"/var/www/html/selinux/selinux.html\" dev=\"dm-0\" ino=12345 scontext=system_u:system_r:httpd_t:s0 tcontext=unconfined_u:object_r:user_tmp_t:s0 tclass=file permissive=0" \
  >/var/log/audit/audit.log
chmod 600 /var/log/audit/audit.log
check_output "ausearch -m AVC -ts recent finds the denial (from the note)" 'avc: +denied +\{ open \}' \
  bash -c "$(cmds 'Troubleshooting denials' 1)"
# With SELinux disabled, audit2why and audit2allow need the policy file (-p).
check_output "audit2why names the boolean (from the note)" 'boolean httpd_read_user_content was set incorrectly' \
  bash -c "$(cmds 'Troubleshooting denials' 2 | sed -n 1p) -p $P"
check "audit2allow -M builds a module (from the note)" bash -c "$(cmds 'Troubleshooting denials' 2 | sed -n 2p) -p $P"
check_output "the .te file allows what was denied" 'allow httpd_t user_tmp_t:file open;' cat mylocalpolicy.te
check "semodule -i installs it (from the note, with -n: no reload)" \
  bash -c "$(cmds 'Troubleshooting denials' 2 | sed -n 3p | sed 's/semodule /semodule -n /')"
check_output "semodule -l lists it" '^mylocalpolicy$' semodule -l
before=$(sesearch --dontaudit "$P" | wc -l)
check "semodule -DB rebuilds without dontaudit rules (-n: no reload)" semodule -n -DB
assert_eq "the rebuilt policy has no dontaudit rule" 0 "$(sesearch --dontaudit "$P" | wc -l)"
check "semodule -B restores them" semodule -n -B
assert_eq "the dontaudit rules are back" "$before" "$(sesearch --dontaudit "$P" | wc -l)"
