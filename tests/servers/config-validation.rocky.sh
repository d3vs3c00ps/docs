#!/usr/bin/env bash
# note: servers/config-validation.md
# env: priv:rocky
# MySQL rows of the note: Leap ships only MariaDB (config-validation.sh). Privileged: in
# an unprivileged container, running /usr/sbin/mysqld fails with "Operation not permitted".
source "$NOTES_ROOT/tests/lib/assert.sh"

NOTE=servers/config-validation
dnf -y -q install mysql8.4-server >/dev/null
line() { note_block "$NOTE" MySQL 1 | sed 's/ *# .*//' | sed -n "${1}p"; }

section "MySQL"
check "mysqld --validate-config (from the note)" bash -ec "$(line 1)"
printf '[mysqld]\nbogus_option=1\n' >/root/test-my.cnf
check_output "--validate-config reports an unknown option" "unknown variable 'bogus_option=1'" \
  bash -c "$(line 2) 2>&1; true"
check_fails "and fails (from the note)" bash -ec "$(line 2)"
printf '[mysqld]\nmax_connections=10\n' >/root/test-my.cnf
check "a valid file passes" bash -ec "$(line 2)"
check_output "the quick reference names the same command" '^\| MySQL 8\.0\.16\+ \| `mysqld --validate-config` \|$' \
  cat "$NOTES_ROOT/content/$NOTE.md"
