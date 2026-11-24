#!/usr/bin/env bash
# note: servers/config-validation.md
# env: leap
# timeout: 1200
source "$NOTES_ROOT/tests/lib/assert.sh"

NOTE=servers/config-validation
cd "$(mktemp -d)"
zypper -n -q install --no-recommends apache2 apache2-utils bind chrony dhcp-server kea mariadb nginx \
  openldap2_6 postfix rsyslog squid openssh-server sudo systemd >/dev/null

# run HEADING LINE: run one line of the note's block under HEADING, comment removed.
line() { note_block "$NOTE" "$1" 1 | sed 's/ *# .*//' | sed -n "${2}p"; }
run() { bash -ec "$(line "$1" "$2")"; }
quick() { grep -F "| $1 |" "$NOTES_ROOT/content/$NOTE.md" | sed 's/.*| `\(.*\)` |$/\1/'; }

section "Apache"
check "apachectl configtest (from the note)" run Apache 1
check "httpd -t (from the note)" run Apache 2
check_output "apachectl -S dumps the vhost layout (from the note)" 'ServerRoot' run Apache 3
check_fails "there is no apache2ctl on Leap 16" command -v apache2ctl
echo 'NoSuchDirective on' >/etc/apache2/conf.d/bad.conf
check_fails "a bad directive fails configtest" run Apache 1
check_fails "and httpd -t" run Apache 2
rm /etc/apache2/conf.d/bad.conf

section "BIND"
mkdir -p /var/named
cat >/var/named/zone.example.com <<'EOF'
$TTL 3600
@   IN SOA ns1.example.com. admin.example.com. ( 1 3600 900 604800 300 )
    IN NS  ns1.example.com.
ns1 IN A   192.0.2.1
EOF
check "named-checkconf (from the note)" run BIND 1
check_output "named-checkzone (from the note)" 'OK' run BIND 2
sed '/SOA/d' /var/named/zone.example.com >/var/named/zone.broken
check_fails "a zone with no SOA fails" named-checkzone example.com /var/named/zone.broken
printf 'zone "broken.example" { type primary; file "/var/named/zone.broken"; };\n' >>/etc/named.conf
check "named-checkconf alone passes a config pointing at a broken zone" named-checkconf /etc/named.conf
check_fails "named-checkconf -z loads the zones and fails (as the note says)" named-checkconf -z /etc/named.conf
sed -i '/broken.example/d' /etc/named.conf

section "chrony"
check_output "chronyd -p reads /etc/chrony.conf, which Leap does not have" 'Could not open /etc/chrony.conf' \
  bash -c "$(line chrony 1) 2>&1; true"
leap_p=$(sed -n 's/.*`\(chronyd -p -f [^`]*\)`.*/\1/p' "$NOTES_ROOT/content/$NOTE.md")
read -ra leap_cmd <<<"$leap_p"
check_output "$leap_p prints the configuration (from the note)" '^driftfile ' "${leap_cmd[@]}"
echo 'servr 192.0.2.1' >/etc/chrony.d/bad.conf
check_output "a bad line in a drop-in fails with Invalid directive" 'Fatal error : Invalid directive servr' \
  bash -c "$leap_p 2>&1; true"
check_fails "with exit status 1" "${leap_cmd[@]}"
rm /etc/chrony.d/bad.conf
printf 'server 192.0.2.1 iburst\n' >good.conf
check_fails "chronyd -Q fails on a valid config with no reachable server (the correction)" timeout 60 chronyd -Q -f good.conf
check_output "because it measures, then gives up" 'No suitable source for synchronisation' \
  bash -c 'timeout 60 chronyd -Q -f good.conf 2>&1; true'

section "DHCPd"
mkdir -p /etc/dhcp /var/lib/dhcpd
printf 'subnet 192.0.2.0 netmask 255.255.255.0 {\n  range 192.0.2.10 192.0.2.20;\n}\n' >/etc/dhcp/dhcpd.conf
cp /etc/dhcp/dhcpd.conf /etc/dhcpd.conf
touch /var/lib/dhcpd/dhcpd.leases /var/lib/dhcp/db/dhcpd.leases
for n in 1 2 3 4; do
  check "$(line DHCPd "$n") (from the note)" run DHCPd "$n"
done
check_output "openSUSE's default lease file is /var/lib/dhcp/db/dhcpd.leases" '/var/lib/dhcp/db/dhcpd.leases' \
  bash -c 'dhcpd -T 2>&1'
sed -i 's/range 192.0.2.10 192.0.2.20;/range 192.0.2.10 192.0.2.20/' /etc/dhcp/dhcpd.conf
check_fails "a missing semicolon fails -t" run DHCPd 2
echo 'lease 192.0.2.10 { garbage' >/var/lib/dhcpd/dhcpd.leases
check_output "-T warns about a broken lease file" 'possibly corrupt lease file' bash -c "$(line DHCPd 4) 2>&1"
check "but exits 0 (as the note says)" run DHCPd 4
check "Kea (from the note)" bash -ec "$(note_block "$NOTE" DHCPd 2)"
echo '{ "Dhcp4": { ' >bad-kea.conf
check_fails "Kea fails on broken JSON" kea-dhcp4 -t bad-kea.conf

section "MySQL"
# What the service's first start creates: secure_file_priv's directory and the datadir.
mkdir -p /var/lib/mysql-files /var/lib/mysql && chown mysql: /var/lib/mysql
check "mariadbd --verbose --help (from the note)" bash -ec "$(line MySQL 3) 2>/dev/null"
printf '[mysqld]\nbogus_option=1\n' >/root/test-my.cnf
check_output "an unknown option fails, and only the error is left" "unknown variable 'bogus_option=1'" \
  bash -c 'mariadbd --defaults-file=/root/test-my.cnf --verbose --help 2>&1 1>/dev/null; true'
check_fails "with a non-zero status" bash -c 'mariadbd --defaults-file=/root/test-my.cnf --verbose --help 1>/dev/null 2>&1'
check_output "on MariaDB, mysqld is a deprecated name (as the note says)" 'Deprecated program name' \
  bash -c 'mysqld --verbose --help 2>&1 1>/dev/null; true'
check_output "MariaDB has no --validate-config" "unknown option '--validate-config'" \
  bash -c 'runuser -u mysql -- /usr/sbin/mariadbd --validate-config 2>&1; true'
skip "mysqld --validate-config" "MySQL is not in Leap; tested on Rocky (config-validation.rocky.sh)"

section "nginx"
check_output "nginx -t (from the note)" 'syntax is ok' bash -c "$(line nginx 1) 2>&1"
check_output "nginx -T dumps the full configuration (from the note)" '^# configuration file /etc/nginx/nginx.conf:' \
  bash -c "$(line nginx 2) 2>/dev/null"
echo 'bogus_directive on;' >/etc/nginx/conf.d/bad.conf
check_fails "a bad directive fails nginx -t" nginx -t
rm /etc/nginx/conf.d/bad.conf

section "OpenLDAP"
check_output "Leap's slapd.conf fails as shipped (as the note says)" 'Unrecognized database type \(mdb\)' \
  bash -c 'slapd -Tt 2>&1; true'
sed -i 's/^#\(modulepath\|moduleload back_mdb\)/\1/' /etc/openldap/slapd.conf
# -Tt opens the database: its directory must exist, as on a configured server.
mkdir -p /run/slapd   # systemd-tmpfiles makes it at boot; this container has no boot
check_output "with no data yet, -Tt fails to open the database (as the note says)" 'bi_db_open failed' \
  bash -c 'slapd -Tt 2>&1; true'
check "slapd -Tt -u checks the configuration only (from the note)" slapd -Tt -u
printf 'dn: dc=my-domain,dc=com\nobjectClass: dcObject\nobjectClass: organization\no: Example\ndc: my-domain\n' | slapadd >/dev/null 2>&1
check "slapd -Tt with the default config (from the note)" run OpenLDAP 1
check "slapd -Tt -f /etc/openldap/slapd.conf (from the note)" run OpenLDAP 2
cp /etc/openldap/slapd.conf bad-slapd.conf && echo 'bogusdirective yes' >>bad-slapd.conf
check_fails "a bad directive fails" slapd -Tt -f bad-slapd.conf
mkdir -p /etc/openldap/slapd.d
slaptest -f /etc/openldap/slapd.conf -F /etc/openldap/slapd.d >/dev/null 2>&1
check_output "slaptest -F checks a slapd.d directory (from the note)" 'config file testing succeeded' \
  bash -c "$(sed -n 's/.*`\(slaptest -F [^`]*\)`.*/\1/p' "$NOTES_ROOT/content/$NOTE.md") 2>&1"

section "Postfix"
check "postfix check (from the note)" run Postfix 1
postconf -e 'myhostname = mail.example.com'
check_output "postconf -n shows the changed setting (from the note)" '^myhostname = mail.example.com$' run Postfix 2
check "and leaves out the defaults: under a tenth of the full list" \
  bash -c '[ $(( $(postconf -n | wc -l) * 10 )) -lt "$(postconf 2>/dev/null | wc -l)" ]'
chmod 777 /etc/postfix/main.cf
check_output "postfix check reports problems such as a world-writable main.cf" 'group or other writable' \
  bash -c 'postfix check 2>&1; true'
chmod 644 /etc/postfix/main.cf

section "rsyslog"
check "rsyslogd -N 1 (from the note)" run rsyslog 1
echo 'this is not rsyslog syntax(' >/etc/rsyslog.d/bad.conf
check_fails "a bad line fails" run rsyslog 1
rm /etc/rsyslog.d/bad.conf

section "Squid"
check "squid -k parse (from the note)" run Squid 1
check_fails "squid -k check fails when Squid is not running (it checks a running instance)" run Squid 2
echo 'bogus_directive 1' >>/etc/squid/squid.conf
check_output "a bad directive: parse reports it" "unrecognized: 'bogus_directive'" bash -c 'squid -k parse 2>&1; true'
check_fails "and fails" run Squid 1
sed -i '/bogus_directive/d' /etc/squid/squid.conf

section "sshd"
ssh-keygen -A >/dev/null
check "sshd -t (from the note)" run sshd 1
check_output "sshd -T dumps the effective configuration (from the note)" '^port 22$' run sshd 2
mkdir -p /etc/ssh/sshd_config.d && echo 'NoSuchOption yes' >/etc/ssh/sshd_config.d/bad.conf
check_fails "a bad option fails sshd -t" run sshd 1
rm /etc/ssh/sshd_config.d/bad.conf

section "sudoers"
check_output "on Leap 16, visudo -c complains about the package's file mode (as the note says)" \
  'bad permissions, should be mode 0440' bash -c "$(line sudoers 1) 2>&1; true"
check_output "the file is 0444" '^444$' stat -c %a /usr/etc/sudoers
echo 'alice ALL=(ALL) ALL' >/etc/sudoers.d/admins && chmod 440 /etc/sudoers.d/admins
check "visudo -cf on one file (from the note)" run sudoers 2
echo 'alice ALL=(ALL' >/etc/sudoers.d/admins
check_fails "a broken file fails" run sudoers 2
rm /etc/sudoers.d/admins

section "systemd units"
mkdir -p /etc/systemd/system
printf '[Service]\nExecStart=/usr/bin/true\n' >/etc/systemd/system/myapp.service
check "systemd-analyze verify (from the note)" run 'systemd units' 1
printf 'FooBar=1\n' >>/etc/systemd/system/myapp.service
check_output "an unknown directive is reported" "Unknown key 'FooBar'" bash -c "$(line 'systemd units' 1) 2>&1"
check "but the exit status is 0 (the correction)" run 'systemd units' 1
printf '[Unit]\nRequires=nope.service\n[Service]\nExecStart=/usr/bin/true\n' >/etc/systemd/system/myapp.service
check_fails "a missing dependency fails" run 'systemd units' 1
printf '[Service]\nExecStart=/usr/bin/no-such-command\n' >/etc/systemd/system/myapp.service
check_fails "a command that is not executable fails" run 'systemd units' 1

section "syslog-ng"
# syslog-ng and rsyslog conflict: replace one with the other.
zypper -n -q remove rsyslog >/dev/null
zypper -n -q install --no-recommends syslog-ng >/dev/null
check "syslog-ng -svf (from the note)" run syslog-ng 1
echo 'this is not syslog-ng syntax(' >>/etc/syslog-ng/syslog-ng.conf
check_fails "a bad line fails" run syslog-ng 1
