#!/usr/bin/env bash
# note: servers/mysql.md
# env: rocky-systemd
# timeout: 900
source "$NOTES_ROOT/tests/lib/assert.sh"

NOTE=servers/mysql
dnf -y -q install mysql8.4-server mysql8.4 cronie iproute gzip >/dev/null
block() { note_block "$NOTE" "$@"; }
systemctl enable --now mysqld >/dev/null 2>&1
mysql -u root -e "ALTER USER 'root'@'localhost' IDENTIFIED BY 'lost-password'"

section "Testing the configuration"
check "mysqld --validate-config (from the note)" bash -ec "$(block 'Testing the configuration' 1 | sed -n 1p)"
printf '[mysqld]\nbogus_option=1\n' >/root/test-my.cnf
check_fails "--defaults-file with an unknown option fails (from the note)" bash -ec "$(block 'Testing the configuration' 1 | sed -n 2p)"

section "Restart the server without authentication"
check_fails "with the password lost, root cannot log in" mysql -u root -e 'SELECT 1'
check "systemctl stop mysqld (from the note)" bash -ec "$(block 'Restart the server' 1)"
check_fails "there is no mysqld_safe on RHEL (the correction)" bash -c 'command -v mysqld_safe'
# Its output goes to a file: an open stdout would keep the check waiting.
check "start mysqld by hand as mysql (from the note)" \
  bash -ec "$(block 'Restart the server' 2 | sed 's/ &$/ >\/var\/log\/mysqld-manual.log 2>\&1 \&/')"
check "it comes up" retry 60 mysqladmin -u root ping
check_fails "with no TCP listener: networking is off" bash -c 'ss -ltn | grep -q ":3306 "'

section "Reset the password"
check "mysql -u root logs in with no password (from the note)" bash -ec "$(block 'Reset the password' 1) -e 'SELECT 1'"
check_output "ALTER USER fails before FLUSH PRIVILEGES (as the note says)" 'skip-grant-tables' \
  bash -c "mysql -u root -e \"ALTER USER 'root'@'localhost' IDENTIFIED BY 'x'\" 2>&1; true"
check_fails "the original UPDATE ... PASSWORD() form fails" \
  mysql -u root mysql -e "UPDATE user SET password=PASSWORD('x') WHERE user='root'"
check "FLUSH PRIVILEGES, then ALTER USER (from the note)" mysql -u root < <(block 'Reset the password' 2)
check_fails "systemctl start while the hand-started server runs fails (the correction)" \
  bash -c 'systemctl start mysqld && sleep 3 && systemctl is-active -q mysqld'
systemctl reset-failed mysqld 2>/dev/null || true
check "shut down the hand-started server, start the service (from the note)" \
  bash -ec "$(block 'Reset the password' 3 | sed 's/-p shutdown/-pnew-password shutdown/')"
check "mysqld runs under systemd again" retry 30 systemctl is-active -q mysqld
check "the new password works" mysql -u root -pnew-password -e 'SELECT 1'
check_fails "the old one does not" mysql -u root -plost-password -e 'SELECT 1'

section "Backing up without supplying a password"
mysql -u root -pnew-password 2>/dev/null <<'SQL'
CREATE DATABASE shop;
CREATE TABLE shop.orders (id INT PRIMARY KEY, item VARCHAR(20)) ENGINE=InnoDB;
INSERT INTO shop.orders VALUES (1, 'book');
CREATE EVENT shop.nightly ON SCHEDULE EVERY 1 DAY DO DELETE FROM shop.orders WHERE id < 0;
SQL
check "the backup user and its grants (from the note)" \
  bash -c "mysql -u root -pnew-password 2>/dev/null <<'SQL'
$(block 'Backing up without supplying a password' 1)
SQL"
useradd -m backup
block 'Backing up without supplying a password' 2 >/home/backup/.my.cnf
chown backup: /home/backup/.my.cnf
check "chmod 600 (from the note)" runuser -u backup -- bash -ec "cd ~ && $(block 'Backing up without supplying a password' 3)"
check_output "the option file is private" '^600$' stat -c %a /home/backup/.my.cnf
mkdir -p /backup/mysql && chown backup: /backup/mysql
cronline=$(block 'Backing up without supplying a password' 5)
dump=$(sed 's/^[0-9*]* [0-9*]* [0-9*]* [0-9*]* [0-9*]* //; s/\\%/%/g' <<<"$cronline")
check "the dump command from the cron line, as backup, with no password (from the note)" \
  runuser -u backup -- bash -ec "cd ~ && $dump"
f=$(find /backup/mysql -name '*-db.sql.gz' | head -1)
check_output "the file is named day-month" '/[0-9]{2}-[0-9]{2}-db\.sql\.gz$' echo "$f"
check_output "it has the table" 'CREATE TABLE `orders`' bash -c "gunzip -c '$f'"
check_output "and the event (--events)" 'CREATE.*EVENT `nightly`' bash -c "gunzip -c '$f'"
check_output "the dump runs to the end" 'Dump completed' bash -c "gunzip -c '$f' | tail -1"
check "the cron line installs (from the note)" bash -c "printf '%s\n' \"\$1\" | crontab -u backup - && crontab -u backup -l | grep -q 'mysqldump'" _ "$cronline"
# What cron does with %: the escaped line runs, the raw one is cut at the first %.
systemctl start crond
printf '%s\n' '* * * * * echo "$(date +\%d-\%m)" >/tmp/cron-escaped' '* * * * * echo "$(date +%d-%m)" >/tmp/cron-raw' | crontab -
check_output "with \\%, cron runs the date command (as the note says)" '^[0-9]{2}-[0-9]{2}$' \
  bash -c 'for i in $(seq 90); do [ -s /tmp/cron-escaped ] && break; sleep 1; done; cat /tmp/cron-escaped'
check_fails "with a bare %, the command is cut and fails" test -s /tmp/cron-raw
