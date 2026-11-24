#!/usr/bin/env bash
# note: servers/vaultwarden-docker.md
# env: compose
# timeout: 900
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/compose.sh"

NOTE=servers/vaultwarden-docker
block() { note_block "$NOTE" "$@"; }

section "nginx reverse proxy"
check "mkdir nx-data (from the note)" bash -ec "$(block 'nginx reverse proxy' 1)"
block 'nginx reverse proxy' 2 >nx-data/vaultwarden.conf
check_output "the server block uses http2 on, not listen ... http2" '^  http2 on;$' cat nx-data/vaultwarden.conf

section "Self-signed certificate"
block 'Self-signed certificate' 1 >nx-data/req.conf
check "openssl req (from the note)" bash -ec "$(block 'Self-signed certificate' 2)"
check_output "the certificate has the SAN" 'DNS:vaultwarden\.example\.com' openssl x509 -in nx-data/vaultwarden.crt -noout -ext subjectAltName
check_output "and is valid for 730 days" 'notAfter' openssl x509 -in nx-data/vaultwarden.crt -noout -enddate
check_output "with the placeholder subject, no real organisation" 'O ?= ?Example Corp' openssl x509 -in nx-data/vaultwarden.crt -noout -subject

section "MariaDB and Vaultwarden data"
check "mkdir mb-data (from the note)" bash -ec "$(block 'MariaDB' 1)"
check "mkdir vw-data (from the note)" bash -ec "$(block 'Vaultwarden data' 1)"

section "Compose file"
# Placeholders filled in. container_name is dropped: names are global on the shared
# Docker host, and other tests may run at the same time.
block 'Compose file' 1 | sed '/container_name:/d;
  s/<root password>/rootpw/; s/<database user password>/vwpw/; s/<database name>/vw/; s/<database user>/vw/;
  s|mysql://<user>:<password>@mariadb/vw|mysql://vw:vwpw@mariadb/vw|;
  s/"<argon2 hash of the admin token>"/"@HASH@"/' >docker-compose.yml
check_output "the DATABASE_URL placeholder is filled" 'mysql://vw:vwpw@mariadb/vw' cat docker-compose.yml
docker compose pull -q >/dev/null 2>&1
# vaultwarden hash reads the password from a terminal and panics on a pipe, so type it
# into a pseudo-terminal, with the note's own `docker run --rm -it` command.
hash_cmd=$(sed -n 's/.*`\(docker run --rm -it vaultwarden\/server \/vaultwarden hash\)`.*/\1/p' "$NOTES_ROOT/content/$NOTE.md")
assert_match "the note gives the hash command" '/vaultwarden hash$' "$hash_cmd"
vw_hash() { { sleep 3; printf 'admin-pass\n'; sleep 2; printf 'admin-pass\n'; sleep 5; } | script -qec "$hash_cmd" /dev/null | tr -d '\r'; }
check_output "vaultwarden hash makes an Argon2 PHC string (from the note)" '^ADMIN_TOKEN=.\$argon2id\$' vw_hash
hash=$(vw_hash | sed -n "s/^ADMIN_TOKEN='\(.*\)'$/\1/p")
# The note: in a Compose file, each $ of the hash is written $$.
cp docker-compose.yml compose.tmpl
sed "s|@HASH@|${hash//\$/\$\$}|" compose.tmpl >docker-compose.yml
check_output "with the hash pasted as is, Compose reads its \$ parts as variables" 'variable is not set' \
  bash -c "sed 's|@HASH@|$hash|' compose.tmpl >raw.yml && docker compose -f raw.yml config 2>&1 >/dev/null"
check "docker compose up -d (from the note)" bash -ec "$(block 'Compose file' 2)"
check "the vault answers through nginx on 443" wait_http https://localhost/alive 120 -k
check_output "the web vault is served at /" '<title[^>]*>Vaultwarden Web</title>' curl -sk https://localhost/
check_output "over HTTP/2" '^HTTP/2 200' curl -sk --http2 -I https://localhost/
check_output "the admin panel is at /admin/" '^200$' curl -sk -o /dev/null -w '%{http_code}' https://localhost/admin/
check "the admin token logs in" bash -c "curl -sk -o /dev/null -w '%{http_code}' -d 'token=admin-pass' https://localhost/admin/ | grep -qx '303\|200'"
check_output "Vaultwarden uses MariaDB: its tables are there" '^users$' \
  docker compose exec -T mariadb mariadb -uvw -pvwpw vw -N -e 'show tables'
check_output "with SIGNUPS_ALLOWED false, registration is refused" 'Registration not allowed' \
  curl -sk -H 'Content-Type: application/json' -d '{"email":"a@example.com","name":"a"}' \
  https://localhost/identity/accounts/register/send-verification-email
check_output "nginx passes the client address on" 'X-Real-IP' cat nx-data/vaultwarden.conf

section "ADMIN_TOKEN should be a hash"
sed 's|@HASH@|plaintext-token|' compose.tmpl >docker-compose.yml
docker compose up -d vaultwarden >/dev/null 2>&1
check "with a plaintext token, Vaultwarden logs a warning" \
  retry 30 bash -c 'docker compose logs vaultwarden 2>&1 | grep -qi "plain text .ADMIN_TOKEN"'

section "listen ... http2 is deprecated"
sed 's/listen 443 ssl;/listen 443 ssl http2;/; /http2 on;/d' nx-data/vaultwarden.conf >old.conf
docker compose cp old.conf nginx:/tmp/old.conf >/dev/null
check_output "nginx warns about the original listen ... http2 form" 'the "listen \.\.\. http2" directive is deprecated' \
  docker compose exec -T nginx sh -c 'printf "events {}\nhttp { include /tmp/old.conf; }\n" >/tmp/t.conf; nginx -t -c /tmp/t.conf 2>&1'
