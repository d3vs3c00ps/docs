#!/usr/bin/env bash
# note: automation/ansible/vault.md
# env: ansible-systemd
# Password prompts read from stdin here (no terminal): Ansible warns and goes on.
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/automation/ansible/ansible-lib.bash"

NOTE=automation/ansible/vault
mkdir -p /work/vault && cd /work/vault
printf '[apache]\nsvr-apache-01 ansible_host=127.0.0.1 ansible_user=ansible\n' >hosts
printf '[defaults]\ninventory = hosts\n' >ansible.cfg
line() { note_block "$NOTE" "$1" "${3:-1}" | sed -n "${2}p"; }
secret() { printf 'db_password: s3cr3t-value\n' >secret-vars.yml; }
export -f secret
# on_tty INPUT CMD: run CMD on a pseudo-terminal, typing INPUT's lines one by one after a pause.
on_tty() { { sleep 3; while IFS= read -r l; do printf '%s\n' "$l"; sleep 1; done <<<"$1"; } | script -qec "$2" /dev/null; }
is_vault() { head -1 "${1:-secret-vars.yml}" | grep -q '^\$ANSIBLE_VAULT;1\.[12];AES256'; }
echo 'first-pass' >very_secret_password_file && echo 'second-pass' >stronger_secret_password_file
chmod 600 very_secret_password_file stronger_secret_password_file

section "Ansible Vault"
mkdir -p /tmp/nocrypto/cryptography && echo 'raise ImportError("hidden by the test")' >/tmp/nocrypto/cryptography/__init__.py
secret
check_output "without cryptography, ansible-vault stops: no pure-Python fallback (the correction)" 'requires the cryptography library' \
  bash -c 'PYTHONPATH=/tmp/nocrypto ansible-vault encrypt secret-vars.yml --vault-password-file very_secret_password_file 2>&1; true'
check_fails "  and the file stays plain" is_vault
check_output "cryptography comes with ansible-core (a pip dependency)" '^Requires:.*cryptography' /opt/ansible/bin/pip show ansible-core

section "Managing the master password"
check "encrypt prompts for the password (from the note, password on stdin)" \
  bash -c "printf 'pw\npw\n' | $(line 'master password' 1) && head -1 secret-vars.yml | grep -q AES256"
check_output "  the prompt asked twice: New and Confirm" 'Confirm New Vault password' \
  bash -c "secret; printf 'pw\npw\n' | $(line 'master password' 1) 2>&1"
secret
check "encrypt with --vault-password-file (from the note)" bash -c "$(line 'master password' 1 2) && head -1 secret-vars.yml | grep -q AES256"
check_output "rekey to a new password file (from the note)" 'Rekey successful' bash -c "$(note_block "$NOTE" 'master password' 3 | tr -d '\\\n') 2>&1"
check_output "  the new password opens it" 's3cr3t-value' ansible-vault view secret-vars.yml --vault-password-file stronger_secret_password_file
check_fails "  the old one does not" ansible-vault view secret-vars.yml --vault-password-file very_secret_password_file
printf '#!/bin/sh\necho second-pass\n' >get-pass.sh && chmod 700 get-pass.sh
check_output "an executable password file is run and its stdout used (the warning)" 's3cr3t-value' \
  ansible-vault view secret-vars.yml --vault-password-file ./get-pass.sh

section "Encrypting a file"
rm -f secret-vars.yml
printf '#!/bin/sh\nprintf "api_key: from-editor\\n" >"$1"\necho "$1" >/tmp/editor-path\n' >/usr/local/bin/fake-editor && chmod +x /usr/local/bin/fake-editor
export EDITOR=fake-editor
check_output "create needs a terminal: without one it stops (the correction)" 'not a tty, editor cannot be opened' \
  bash -c "printf 'pw\npw\n' | $(note_block "$NOTE" 'Encrypting a file' 1) 2>&1; true"
check "create opens the editor and saves encrypted (from the note)" \
  bash -c "$(declare -f on_tty); on_tty \$'pw\\npw' '$(note_block "$NOTE" 'Encrypting a file' 1)' && head -1 secret-vars.yml | grep -q AES256"
check_output "  view shows the plain text (from the note)" 'api_key: from-editor' \
  bash -c "printf 'pw\n' | $(note_block "$NOTE" 'Encrypting a file' 3) 2>/dev/null"
secret
check "encrypt an existing file (from the note)" bash -c "printf 'pw\npw\n' | $(note_block "$NOTE" 'Encrypting a file' 2) && head -1 secret-vars.yml | grep -q AES256"

section "Editing and decrypting"
check "edit (from the note)" bash -c "printf 'pw\n' | $(note_block "$NOTE" 'Editing and decrypting' 1)"
check_output "  the editor got a temporary file, not the vault file (the note)" '/ansible-local-[^/]+/tmp[^/]+\.yml$' cat /tmp/editor-path
check "  the vault file is still encrypted after the edit" is_vault
check_output "  and holds the edit" 'from-editor' bash -c "printf 'pw\n' | ansible-vault view secret-vars.yml 2>/dev/null"
check_fails "  the temporary file is gone" test -e "$(cat /tmp/editor-path)"
check_output "decrypt writes the plain text back (from the note)" '^api_key: from-editor$' \
  bash -c "printf 'pw\n' | $(note_block "$NOTE" 'Editing and decrypting' 2) 2>/dev/null; cat secret-vars.yml"

section "Encrypting a single value"
out=$(bash -c "$(note_block "$NOTE" 'single value' 1 | sed -n 's/^\$ //p') --vault-password-file very_secret_password_file" 2>&1)
assert_match "encrypt_string prints a !vault block (from the note)" 'mysql_admin_password: !vault \|' "$out"
assert_match "  with the 1.1 AES256 header" '^ +\$ANSIBLE_VAULT;1\.1;AES256$' "$out"
assert_no_match "  it no longer prints Encryption successful (the correction)" 'Encryption successful' "$out"
printf 'x: 1\n' >vars.yml && /usr/bin/grep -v 'Encryption successful' <<<"$out" >>vars.yml
printf -- '- hosts: apache\n  gather_facts: false\n  vars_files: [vars.yml]\n  tasks:\n    - ansible.builtin.debug: {msg: "{{ mysql_admin_password }}"}\n' >str.yml
check_output "debug of a vaulted value prints \$REDACTED\$ (new in ansible-core 2.22)" '"msg": "\$REDACTED\$"' \
  ansible-playbook str.yml --vault-password-file very_secret_password_file
sed -i 's|ansible.builtin.debug: {msg: "{{ mysql_admin_password }}"}|ansible.builtin.copy: {content: "{{ mysql_admin_password }}", dest: /tmp/str.out}|' str.yml
check_output "  the task still gets the decrypted value" '^mysql_unbreakable_password$' \
  bash -c 'ansible-playbook str.yml --vault-password-file very_secret_password_file >/dev/null && cat /tmp/str.out'
check "  the rest of the file stays readable YAML (the note)" grep -q '^x: 1$' vars.yml
cmd=$(grep -o "ansible-vault encrypt_string --stdin-name '[a-z_]*'" "$NOTES_ROOT/content/$NOTE.md")
check_output "--stdin-name reads the value from stdin (the warning)" 'mysql_admin_password: !vault' \
  bash -c "printf 'from-stdin' | $cmd --vault-password-file very_secret_password_file 2>&1"

section "Vault IDs"
rm -f secret-vars-prod.yml secret-vars-dev.yml
check "create --vault-id prod@file (from the note, on a terminal)" script -qec "$(line 'Vault IDs' 1)" /dev/null
check_output "  the header carries the label: 1.2 and prod" '^\$ANSIBLE_VAULT;1\.2;AES256;prod$' head -1 secret-vars-prod.yml
check "create --vault-id dev@prompt (from the note)" on_tty $'devpw\ndevpw' "$(line 'Vault IDs' 2)"
check_output "  labelled dev" ';dev$' head -1 secret-vars-dev.yml

section "Running playbooks with vaults"
secret && ansible-vault encrypt secret-vars.yml --vault-password-file very_secret_password_file
printf -- '- hosts: apache\n  gather_facts: false\n  vars_files: [secret-vars.yml]\n  tasks:\n    - ansible.builtin.debug: {msg: "{{ db_password | upper }}"}\n' >site.yml
check_output "--ask-vault-pass (from the note)" 'S3CR3T-VALUE' bash -c "printf 'first-pass\n' | $(line 'Running playbooks' 1) 2>&1"
check_output "--vault-password-file (from the note)" 'S3CR3T-VALUE' bash -c "$(line 'Running playbooks' 2)"
check_output "--vault-id prod@prompt (from the note)" 'S3CR3T-VALUE' bash -c "printf 'first-pass\n' | $(line 'Running playbooks' 3) 2>&1"
printf 'dev_secret: dev-secret\n' >d.yml && ansible-vault encrypt --vault-id dev@very_secret_password_file d.yml
printf 'prod_secret: prod-secret\n' >p.yml && ansible-vault encrypt --vault-id prod@stronger_secret_password_file p.yml
printf -- '- hosts: apache\n  gather_facts: false\n  vars_files: [d.yml, p.yml]\n  tasks:\n    - ansible.builtin.debug: {msg: "{{ dev_secret | upper }}+{{ prod_secret | upper }}"}\n' >site.yml
out=$(printf 'first-pass\nsecond-pass\n' | bash -c "$(note_block "$NOTE" 'Running playbooks' 2)" 2>&1)
assert_match "two --vault-id at once open both files (from the note)" '"msg": "DEV-SECRET\+PROD-SECRET"' "$out"
assert_match "  each prompt names its id" 'Vault password \(dev\).*Vault password \(prod\)' "$(tr -d '\n' <<<"$out")"

section "What Vault does not do"
secret && ansible-vault encrypt secret-vars.yml --vault-password-file very_secret_password_file
printf -- '- hosts: apache\n  gather_facts: false\n  vars_files: [secret-vars.yml]\n  tasks:\n    - ansible.builtin.command: echo {{ db_password }}\n    - ansible.builtin.command: echo {{ db_password }}\n      no_log: true\n' >leak.yml
out=$(ansible-playbook leak.yml -v --vault-password-file very_secret_password_file 2>&1)
assert_no_match "task output masks a vaulted value, even its stdout (new in ansible-core 2.22)" 's3cr3t-value' "$out"
assert_match "  no_log: true hides the whole result" 'output has been hidden due to the fact that .no_log: true' "$out"
printf -- '- hosts: apache\n  gather_facts: false\n  vars_files: [secret-vars.yml]\n  tasks:\n    - ansible.builtin.template: {src: t.j2, dest: /tmp/rendered}\n    - ansible.builtin.command: echo {{ db_password | upper }}\n' >t.yml
echo 'pw={{ db_password }}' >t.j2
out=$(ansible-playbook t.yml -v --vault-password-file very_secret_password_file 2>&1)
check_output "a rendered template holds the plain value (the note)" '^pw=s3cr3t-value$' cat /tmp/rendered
assert_match "a value changed by a filter is no longer masked (the correction)" 'S3CR3T-VALUE' "$out"
src=/opt/ansible/lib64/python3.13/site-packages/ansible/parsing/vault/__init__.py
check "Vault 1.1 is AES-256 in CTR mode with a PBKDF2 key (the link text)" \
  bash -c "grep -q 'modes.CTR' $src && grep -q 'PBKDF2HMAC' $src && grep -q 'iterations=10000' $src"
