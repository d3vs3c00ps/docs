#!/usr/bin/env bash
# note: servers/apache.md
# env: leap-systemd
# timeout: 1200
source "$NOTES_ROOT/tests/lib/assert.sh"

NOTE=servers/apache
cd "$(mktemp -d)"
zypper -n -q install --no-recommends apache2 curl >/dev/null
block() { note_block "$NOTE" "$@" | sed 's/ *# .*//'; }
conf=/etc/apache2/conf.d/test.conf
# apply FILE-CONTENT: write it as the test's config and restart Apache.
apply() { printf '%s\n' "$1" >"$conf" && restart; }
# Many restarts in a row hit systemd's start limit; reset it each time.
restart() { systemctl reset-failed apache2; systemctl restart apache2; }
status() { curl -s -o /dev/null -w '%{http_code}' "$1"; }
echo 'ServerName localhost' >/etc/apache2/conf.d/servername.conf
echo hello >/srv/www/htdocs/index.html
systemctl enable --now apache2 >/dev/null 2>&1

section "Testing the configuration"
check_fails "apachectl is not installed with apache2 on Leap 16 (as the note says)" command -v apachectl
check_fails "and there is no apache2ctl (the correction)" bash -c 'zypper -n -q se --provides apache2ctl | grep -q apache2'
zypper -n -q install --no-recommends apache2-utils >/dev/null
check_output "apachectl configtest (from the note)" 'Syntax OK' bash -c "$(block 'Testing the configuration' 1 | sed -n 1p) 2>&1"
check_output "apachectl -S (from the note)" 'ServerRoot' bash -c "$(block 'Testing the configuration' 1 | sed -n 3p) 2>&1"
printf '<VirtualHost *:80>\nServerName a.example.com\n</VirtualHost>\n<VirtualHost *:80>\nServerName a.example.com\n</VirtualHost>\n' >"$conf"
check_output "configtest passes two vhosts with the same ServerName" 'Syntax OK' bash -c 'apachectl configtest 2>&1'
check_output "and -S lists both, so the overlap is visible" '^2$' \
  bash -c 'apachectl -S 2>&1 | grep -c "namevhost a.example.com"'
rm -f "$conf"

section "ServerTokens"
for t in Full:'Apache/2\.4\.[0-9]+ \(' OS:'Apache/2\.4\.[0-9]+ \(' Minimal:'Apache/2\.4\.[0-9]+$' \
  Minor:'Apache/2\.4$' Major:'Apache/2$' Prod:'Apache$'; do
  apply "ServerTokens ${t%%:*}"
  check_output "ServerTokens ${t%%:*}" "^Server: ${t#*:}" bash -c "curl -sI http://localhost/ | tr -d '\r'"
done
rm -f "$conf"
restart
check_output "Leap's packaged config already sets ServerTokens Prod" '^Server: Apache$' bash -c "curl -sI http://localhost/ | tr -d '\r'"
check_output "in /etc/apache2/global.conf" '^ServerTokens Prod' bash -c 'grep -rh "^ServerTokens" /etc/apache2/'
printf '<VirtualHost *:80>\nServerName v.example.com\nServerTokens Prod\n</VirtualHost>\n' >"$conf"
check_output "ServerTokens cannot be set per virtual host" 'ServerTokens cannot occur within <VirtualHost> section' bash -c 'apachectl configtest 2>&1; true'
rm -f "$conf"

section "ServerSignature"
# A directory listing (mod_autoindex) is a server-generated page with the footer.
mkdir -p /srv/list && touch /srv/list/a
listing=$'Alias /list /srv/list\n<Directory /srv/list>\n    Options Indexes\n    Require all granted\n</Directory>'
apply "$listing"$'\nServerSignature On'
check_output "On: a footer with the server and ServerName" '<address>Apache Server at localhost Port 80</address>' curl -s http://localhost/list/
apply "$listing"$'\nServerSignature EMail\nServerAdmin admin@example.com'
check_output "EMail: the footer links to ServerAdmin" '<address>Apache Server at <a href="mailto:admin@example.com">localhost</a>' curl -s http://localhost/list/
apply "$listing"$'\n'"$(block 'ServerSignature' 1)"
check_fails "Off (from the note): no footer" bash -c 'curl -s http://localhost/list/ | grep -q "<address>"'

section "mod_evasive"
check "install and enable (from the note)" bash -ec "$(block 'mod_evasive' 1 | sed 's/zypper install/zypper -n -q install --no-recommends/')"
check_output "the module file is mod_evasive24.so" 'mod_evasive24\.so' rpm -ql apache2-mod_evasive
check_output "the package has a default config in conf.d" '^<IfModule mod_evasive24\.c>' cat /etc/apache2/conf.d/mod_evasive.conf
block 'mod_evasive' 2 >/etc/apache2/conf.d/mod_evasive.conf
mkdir -p /var/log/mod_evasive && chown wwwrun: /var/log/mod_evasive
restart
check_output "the module is loaded" 'evasive24_module' bash -c 'apachectl -M 2>/dev/null'
# One connection with keep-alive: all requests go to the same child, which counts them.
check_output "more than DOSPageCount requests to one page in a second get 403" '403' \
  curl -s -o /dev/null -w '%{http_code}\n' http://localhost/index.html http://localhost/index.html \
  http://localhost/index.html http://localhost/index.html http://localhost/index.html http://localhost/index.html
check "a log file is written in DOSLogDir" retry 5 bash -c 'ls /var/log/mod_evasive/dos-* >/dev/null'
# The original: `a2enmod evasive` and <IfModule mod_evasive20.c>.
check_output "a2enmod evasive (the original) loads nothing" '^$' \
  bash -c 'a2enmod evasive && a2dismod evasive24 && systemctl reset-failed apache2 && systemctl restart apache2 && apachectl -M 2>/dev/null | grep evasive; true'
a2dismod evasive
a2enmod evasive24
# A DOSWhitelist entry for 127.0.0.1 shows whether the block's settings apply.
flood() {
  local u=() i
  for i in $(seq 8); do u+=("http://localhost/index.html?$i"); done
  curl -s -o /dev/null -w '%{http_code}\n' "${u[@]}"
}
block 'mod_evasive' 2 | sed 's|</IfModule>|    DOSWhitelist 127.0.0.1\n</IfModule>|' >/etc/apache2/conf.d/mod_evasive.conf
restart
check_fails "with IfModule mod_evasive24.c, the whitelist applies: no 403" bash -c 'flood | grep -q 403'
sed -i 's/mod_evasive24.c/mod_evasive20.c/' /etc/apache2/conf.d/mod_evasive.conf
restart
check_output "an IfModule mod_evasive20.c block passes configtest" 'Syntax OK' bash -c 'apachectl configtest 2>&1'
check_output "but its settings are skipped: the whitelist is ignored (the correction)" '403' flood
a2dismod evasive24
rm -f /etc/apache2/conf.d/mod_evasive.conf
restart

section "Limiting connections"
apply "$(block 'Limiting connections' 1)"
check_output "the directives load" 'Syntax OK' bash -c 'apachectl configtest 2>&1'
check "Apache restarts with them" systemctl is-active apache2
apply "MaxClients 150"
check "MaxClients still works as an alias" systemctl is-active apache2
rm -f "$conf"

section "Access control"
mkdir -p /srv/private && echo secret >/srv/private/index.html
apply $'Alias /private /srv/private\n'"$(block 'Access control' 1 | sed 's|<Directory />|<Directory /srv/private>|')"
check_output "Require all denied gives 403" '^403$' status http://localhost/private/
apply $'Alias /private /srv/private\n<Directory /srv/private>\n    Require all granted\n</Directory>'
check_output "Require all granted gives 200" '^200$' status http://localhost/private/
check_output "the default config already denies / (Leap)" 'Require all denied' \
  bash -c 'grep -A8 "<Directory />" /etc/apache2/httpd.conf'
printf 'Alias /private /srv/private\n%s\n' "$(block 'Access control' 2 | sed 's|<Directory />|<Directory /srv/private>|')" >"$conf"
check_output "the 2.2 syntax fails without mod_access_compat" "Invalid command 'Order'" bash -c 'apachectl configtest 2>&1; true'
a2enmod access_compat
check_output "and loads with it" 'Syntax OK' bash -c 'apachectl configtest 2>&1'
a2dismod access_compat
rm -f "$conf"

section "Options and AllowOverride"
apply "$(block 'Options and AllowOverride' 1)"
check "the Options block (from the note) loads" systemctl is-active apache2
useradd -r other
echo mine >/srv/www/htdocs/mine.txt && echo theirs >/srv/theirs.txt && chown other /srv/theirs.txt
ln -s mine.txt /srv/www/htdocs/same.txt
ln -s /srv/theirs.txt /srv/www/htdocs/other.txt
chown -h root /srv/www/htdocs/same.txt /srv/www/htdocs/other.txt
apply "$(block 'Options and AllowOverride' 1 | sed 's|<Directory />|<Directory /srv/www/htdocs>|; s|AllowOverride None|AllowOverride None\n    Require all granted|')"
check_output "SymLinksIfOwnerMatch: a link to a file with the same owner is served" '^200$' status http://localhost/same.txt
check_output "a link to another owner's file is refused" '^403$' status http://localhost/other.txt
printf '<Directory /srv/www/htdocs>\n    AllowOverride SymLinksIfOwnerMatch\n</Directory>\n' >"$conf"
check_output "AllowOverride does not take Options values (the correction)" 'Illegal override option SymLinksIfOwnerMatch' \
  bash -c 'apachectl configtest 2>&1; true'
check_fails "it is a syntax error" apachectl configtest
printf '<Directory /srv/www/htdocs>\n    AllowOverride AuthConfig FileInfo Indexes Limit Options=Indexes,SymLinksIfOwnerMatch\n</Directory>\n' >"$conf"
check_output "the directive groups the note lists are accepted" 'Syntax OK' bash -c 'apachectl configtest 2>&1'
rm -f "$conf"
restart

section "Useful commands"
pid=$(systemctl show -p MainPID --value apache2)
check "apachectl -k graceful (from the note)" bash -ec "$(block 'Useful commands' 1 | sed -n 1p)"
sleep 2
assert_eq "the parent process keeps running" "$pid" "$(systemctl show -p MainPID --value apache2)"
check "systemctl reload apache2 (from the note)" bash -ec "$(block 'Useful commands' 1 | sed -n 2p)"

section "Choosing an MPM"
check_output "httpd -V shows the MPM (from the note)" '^Server MPM: +prefork' bash -ec "$(block 'Choosing an MPM' 1)"
check_fails "openSUSE's a2enmod has no -m option (the correction)" a2enmod -m event
zypper -n -q install --no-recommends apache2-event >/dev/null
sed -i 's/^APACHE_MPM=.*/APACHE_MPM="event"/' /etc/sysconfig/apache2
restart
check_output "APACHE_MPM=\"event\": the event binary runs" 'httpd-event' bash -c 'ps -eo comm | sort -u'
check_output "httpd -V then reports event" '^Server MPM: +event' httpd -V
# With two MPMs installed, name the one to use.
sed -i 's/^APACHE_MPM=.*/APACHE_MPM="prefork"/' /etc/sysconfig/apache2
restart

section "MaxSpareServers"
apply $'MinSpareServers 10\nMaxSpareServers 5'
check "Apache starts with MaxSpareServers below MinSpareServers" systemctl is-active apache2
# Idle children: with MaxSpareServers 5 applied, Apache would stop all but 5.
check "it keeps at least MinSpareServers (10) idle children, so 5 was raised" \
  retry 20 bash -c '[ "$(pgrep -c -P "$(systemctl show -p MainPID --value apache2)")" -ge 10 ]'
check_fails "and logs nothing about it (silently)" bash -c 'journalctl -u apache2 --no-pager | grep -q MaxSpareServers'
skip "the new value is MinSpareServers + 1" "the effective value is not visible from outside; it is in prefork.c (prefork_run)"
rm -f "$conf"

section "ExtendedStatus"
a2enmod status
apply $'<Location /server-status>\n    SetHandler server-status\n    Require local\n</Location>'
check_output "with mod_status loaded, ExtendedStatus is on by default (the correction)" '^Total Accesses' \
  curl -s 'http://localhost/server-status?auto'
apply $'ExtendedStatus Off\n<Location /server-status>\n    SetHandler server-status\n    Require local\n</Location>'
check_fails "ExtendedStatus Off removes the per-request details" bash -c "curl -s 'http://localhost/server-status?auto' | grep -q '^Total Accesses'"
