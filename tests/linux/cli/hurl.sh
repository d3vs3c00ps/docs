#!/usr/bin/env bash
# note: linux/cli/hurl.md
# env: leap
# The note's files run against a local HTTPS server (hurl-server.py) that answers for
# api.example.com, example.com and staging.example.com through /etc/hosts, with a
# certificate from a test CA added to the system trust store.
source "$NOTES_ROOT/tests/lib/assert.sh"

NOTE=linux/cli/hurl
# The note documents hurl 8; Leap 16 ships 6.0. Proposed for tests/versions.env.
HURL_VERSION=8.1.0
cd "$(mktemp -d)"

section "Installation"
check_output "Leap 16 has a hurl package (6.0)" 'Version +: 6\.0' zypper -n info hurl
arch=$(uname -m)
curl -fsSL "https://github.com/Orange-OpenSource/hurl/releases/download/$HURL_VERSION/hurl-$HURL_VERSION-$arch-unknown-linux-gnu.tar.gz" | tar -xz
install "hurl-$HURL_VERSION-$arch-unknown-linux-gnu/bin/hurl" /usr/local/bin/hurl
check_output "hurl $HURL_VERSION runs" "^hurl $HURL_VERSION" hurl --version

# A CA, a server certificate for the note's hosts, and the hosts themselves.
openssl req -x509 -newkey rsa:2048 -nodes -days 30 -subj /CN=test-ca -keyout ca.key -out ca.crt 2>/dev/null
openssl req -newkey rsa:2048 -nodes -subj /CN=api.example.com -keyout srv.key -out srv.csr 2>/dev/null
printf 'subjectAltName=DNS:api.example.com,DNS:example.com,DNS:staging.example.com\n' >ext
openssl x509 -req -in srv.csr -CA ca.crt -CAkey ca.key -CAcreateserial -days 400 -extfile ext -out srv.crt 2>/dev/null
cp ca.crt /etc/pki/trust/anchors/hurl-test-ca.pem && update-ca-certificates 2>/dev/null
echo '127.0.0.1 api.example.com example.com staging.example.com' >>/etc/hosts
python3 "$NOTES_ROOT/tests/linux/cli/hurl-server.py" srv.crt srv.key &
retry 10 curl -fs https://api.example.com/health

section "A first file"
note_block "$NOTE" 'A first file' 1 >health.hurl
out=$(bash -ec "$(note_block "$NOTE" 'A first file' 2)" 2>&1)
while IFS= read -r line; do
  re=$(sed 's/[().]/\\&/g; s/[0-9][0-9.]*/[0-9.]+/g; s/ \+/ +/g' <<<"$line")
  assert_match "--test prints: $line" "^$re\$" "$out"
done < <(note_block "$NOTE" 'A first file' 3)

section "The format"
note_block "$NOTE" 'The format' 1 >users.hurl
check "POST with a body, headers and asserts passes" hurl --test --variable token=tok-123 users.hurl
check_fails "and fails with a wrong token" hurl --test --variable token=nope users.hurl

section "Chaining with captures"
note_block "$NOTE" 'Chaining' 1 >chain.hurl
check "login, capture the token, use it, clean up" hurl --test --variable password=s3cret chain.hurl
out=$(hurl --test --variable password=wrong chain.hurl 2>&1) || true
assert_match "a failure names the file and the line" 'chain\.hurl:[0-9]+:[0-9]+' "$out"
assert_match "and shows the actual value" 'actual value is <401>' "$out"

section "Variables"
printf 'GET https://{{host}}{{base_path}}/health\nHTTP 200\n' >api.hurl
TOKEN=tok-123
cmds=$(note_block "$NOTE" Variables 1)
check "--variable (from the note)" bash -ec "TOKEN=$TOKEN; $(sed -n 1p <<<"$cmds" | sed 's/api.hurl/--variable base_path= api.hurl/')"
note_block "$NOTE" Variables 2 | grep -v '^#' >staging.env
check "--variables-file (from the note)" bash -ec "$(sed -n 2p <<<"$cmds")"
printf 'GET https://api.example.com/users/42\nAuthorization: Bearer {{token}}\nHTTP 200\n' >api.hurl
check "HURL_SECRET_token reaches {{token}} (from the note)" bash -ec "TOKEN=$TOKEN; $(note_block "$NOTE" Variables 3)"
check "HURL_VARIABLE_token too" env HURL_VARIABLE_token=tok-123 hurl --test api.hurl
check_fails "the old HURL_token prefix no longer works in hurl 8" env HURL_token=tok-123 hurl --test api.hurl
printf 'GET https://api.example.com/users/42\nAuthorization: Bearer {{getenv "API_TOKEN"}}\nHTTP 200\n' >getenv.hurl
check_fails "{{getenv ...}} is rejected (the correction)" env API_TOKEN=tok-123 hurl --test getenv.hurl

section "Assertions"
cat >all.hurl <<'EOS'
GET https://api.example.com/page
HTTP 200
[Asserts]
status == 200
header "Content-Type" startsWith "text/html"
xpath "string(//title)" == "Hello"
regex "v(\\d+\\.\\d+)" == "1.2"
body contains "<title>Hello</title>"
body endsWith "</html>"
duration < 5000
certificate "Expire-Date" daysAfterNow > 30
cookie "session[Secure]" exists
cookie "session" == "abc"
status != 500
status > 199

GET https://api.example.com/users/42
Authorization: Bearer tok-123
HTTP 200
[Asserts]
jsonpath "$.id" isInteger
jsonpath "$.id" exists
jsonpath "$" isCollection
header "Content-Type" matches /^application\/json/
EOS
check "every query and predicate in the note works" hurl --test all.hurl
check "count is a filter: jsonpath ... count == 1" bash -c "printf 'POST https://api.example.com/users\nAuthorization: Bearer tok-123\n{\"name\": \"A\"}\nHTTP 201\n[Asserts]\njsonpath \"\$.roles\" count == 1\njsonpath \"\$.name\" isString\n' | hurl --test"
note_block "$NOTE" Assertions 1 >cert.hurl
check "the certificate and header checks (from the note)" hurl --test cert.hurl

section "In CI"
mkdir tests && cp health.hurl tests/ && printf 'GET https://{{host}}/users/42\nAuthorization: Bearer {{token}}\nHTTP 200\n' >tests/user.hurl
run=$(note_block "$NOTE" 'In CI' 1 | sed -n '/run: |/,/^$/p' | sed '1d; /^- /,$d; s/^    //')
check "the CI step's command, with the env it sets" env HURL_VARIABLE_host=staging.example.com HURL_SECRET_token=tok-123 bash -ec "$run"
check_output "writes a JUnit report" '<testsuites' cat results.xml
check_fails "the secret is not in the report" grep -q tok-123 results.xml
printf 'GET https://{{host}}/users/42\nAuthorization: Bearer {{token}}\nHTTP 500\n' >tests/user.hurl
out=$(env HURL_VARIABLE_host=staging.example.com HURL_SECRET_token=tok-123 bash -c "$run" 2>&1) || true
assert_match "--error-format long shows the response on failure" '"id": ?42' "$out"
assert_no_match "and hides the secret" 'tok-123' "$out"

pkill -f hurl-server.py
( sleep 3; python3 "$NOTES_ROOT/tests/linux/cli/hurl-server.py" srv.crt srv.key ) &
check "--retry waits for a service that is still starting (from the note)" bash -ec "$(note_block "$NOTE" 'In CI' 2)"
check "--retry-interval also takes 2s" hurl --test --retry 1 --retry-interval 2s health.hurl

section "Other useful flags"
printf 'GET https://api.example.com/health\nHTTP 200\n' >api.hurl
while IFS= read -r line; do
  cmd=${line%%#*}
  check "${cmd% *}" bash -ec "$cmd >/dev/null"
done < <(note_block "$NOTE" 'Other useful flags' 1)
check_output "--json gives a machine-readable result" '"success": ?true' bash -c 'hurl --json api.hurl'
check_output "--very-verbose shows the body" 'status' bash -c 'hurl --very-verbose api.hurl 2>&1'
