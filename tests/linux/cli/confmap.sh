#!/usr/bin/env bash
# note: linux/cli/confmap.md
# env: leap-systemd
# ConfMap itself is a web page (npm, a browser): not run here. The test covers the
# daemon tools the note relies on, and its reload-versus-restart warning.
source "$NOTES_ROOT/tests/lib/assert.sh"

NOTE=linux/cli/confmap
zypper -n -q install --no-recommends nginx apache2 apache2-prefork apache2-utils openssh-server haproxy bind sudo \
  python3-PyYAML yq jq >/dev/null
cd "$(mktemp -d)"
mkdir -p /etc/nginx/conf.d
printf 'server {\n  listen 8081;\n  server_name app.example.com;\n}\n' >/etc/nginx/conf.d/app.conf
ssh-keygen -A >/dev/null
cp /etc/haproxy/haproxy.cfg /tmp/haproxy.cfg.orig 2>/dev/null || true

section "ConfMap"
skip "the ConfMap web page (npm run dev)" "a browser tool; it has no command line to test"

section "The effective configuration of a daemon"
while IFS= read -r line; do
  cmd=${line%%#*}
  check "${cmd%"${cmd##*[! ]}"}" bash -ec "$cmd >/dev/null 2>&1"
done < <(note_block "$NOTE" 'The effective configuration' 1)
out=$(nginx -T 2>/dev/null)
assert_match "nginx -T prints each file under a '# configuration file' line" '^# configuration file /etc/nginx/nginx\.conf:' "$out"
assert_match "including the included ones" '^# configuration file /etc/nginx/conf\.d/app\.conf:' "$out"
first=$(grep -n '^# configuration file' <<<"$out" | head -1)
assert_match "the main file comes first, in reading order" 'nginx\.conf:$' "$first"
check_output "sshd -T prints every effective option" '^passwordauthentication ' sshd -T

section "A practical workflow"
systemctl start nginx
check "the workflow (from the note)" bash -ec "$(note_block "$NOTE" 'A practical workflow' 1 | sed 's/^sudo //')"
check_output "step 2 shows where server_name comes from" 'configuration file /etc/nginx/conf\.d/app\.conf' \
  bash -c "$(note_block "$NOTE" 'A practical workflow' 1 | grep '^grep')"

section "Validating without a visualiser"
printf 'a:\n  b: [1, 2]\n' >file.yaml
echo '{"a": 1}' >file.json
while IFS= read -r line; do
  cmd=${line%%  #*}
  [[ $cmd == visudo* ]] && continue
  check "${cmd%"${cmd##*[! ]}"}" bash -ec "$cmd >/dev/null 2>&1"
done < <(note_block "$NOTE" 'Validating without' 1)
check_output "visudo -c fails on Leap 16: the vendor sudoers is 0444" 'bad permissions, should be mode 0440' \
  bash -c 'visudo -c 2>&1; true'
echo 'your.name ALL=(ALL) ALL' >/etc/sudoers.d/test && chmod 440 /etc/sudoers.d/test
check "visudo -cf on a drop-in works (from the note)" visudo -cf /etc/sudoers.d/test
printf 'a:\n  b: [1, 2\n' >file.yaml
check_fails "the YAML check fails on a broken file" python3 -c 'import yaml,sys; yaml.safe_load(open(sys.argv[1]))' file.yaml
check_fails "and so does yq" yq . file.yaml

# Reload versus restart with a broken configuration.
systemctl restart nginx
retry 10 curl -s -o /dev/null http://127.0.0.1:8081/
echo 'this is not valid;' >>/etc/nginx/conf.d/app.conf
check_fails "nginx -t catches the error" nginx -t
check_fails "nginx -t && systemctl reload: the reload does not run" bash -c 'nginx -t 2>/dev/null && systemctl reload nginx'
systemctl reload nginx 2>/dev/null || true
check "a reload with a broken configuration keeps nginx running the old one" \
  bash -c 'sleep 1; systemctl is-active nginx && curl -s -o /dev/null http://127.0.0.1:8081/'
check_fails "a restart with it leaves nothing listening" \
  bash -c 'systemctl restart nginx 2>/dev/null; sleep 1; curl -s -o /dev/null http://127.0.0.1:8081/'
