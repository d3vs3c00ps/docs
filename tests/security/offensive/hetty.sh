#!/usr/bin/env bash
# note: security/offensive/hetty.md
# env: leap
source "$NOTES_ROOT/tests/lib/assert.sh"

NOTE=security/offensive/hetty
cd "$(mktemp -d)"
# The container runs as root and has no sudo.
sudo() { "$@"; }
export -f sudo

section "Installation"
arch=$(uname -m)
[[ $arch == aarch64 ]] && rel=arm64 || rel=x86_64
check "the release binary (from the note)" \
  bash -ec "$(note_block "$NOTE" Installation 1 | sed -n '/^curl/,/hetty$/p' | sed "s/Linux_x86_64/Linux_$rel/")"
check_output "it is v0.7.0" '0\.7\.0' hetty --version
skip "brew and the container image" "brew needs macOS or Linuxbrew; the image is arm64-only (the note's warning)"

# Targets on 127.0.0.1 only: an HTTP API, and an HTTPS server with a self-signed certificate.
cat >api.py <<'EOF'
from http.server import BaseHTTPRequestHandler, HTTPServer
class H(BaseHTTPRequestHandler):
    def reply(self, code, body):
        self.send_response(code); self.end_headers(); self.wfile.write(body.encode())
    def do_GET(self): self.reply(200, "users: alice, bob" if self.path.startswith("/api/v1/users") else "ok")
    def do_POST(self): self.reply(500, "error: boom")
    def log_message(self, *a): pass
HTTPServer(("127.0.0.1", 9000), H).serve_forever()
EOF
python3 api.py &
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout tls.key -out tls.crt \
  -days 1 -subj /CN=localhost -addext subjectAltName=DNS:localhost 2>/dev/null
openssl s_server -quiet -www -accept 9443 -cert tls.crt -key tls.key >/dev/null 2>&1 &
# hetty checks the upstream certificate like any Go client: trust the test server's.
cp tls.crt /etc/pki/trust/anchors/test-upstream.crt && update-ca-certificates

check "hetty starts with no arguments (from the note)" bash -c "hetty >hetty.log 2>&1 & sleep 0.1"
retry 30 curl -sf -o /dev/null http://127.0.0.1:8080/
check_output "the admin interface answers on the proxy port" '<html' curl -s http://localhost:8080/

gql() { curl -s http://localhost:8080/api/graphql/ -H 'Content-Type: application/json' -d "$(jq -cn --arg q "$1" '{query: $q}')"; }
P() { curl -s -x http://localhost:8080 "$@"; }

section "Using it: projects"
P -o /dev/null http://127.0.0.1:9000/before-project
check_output "with no project open, logs are not available (as the note says)" 'project' \
  gql '{ httpRequestLogs { id } }'
project=$(note_block "$NOTE" 'Using it' 1 | grep -o '"[^"]*"' | tr -d '"')
check_output "the old name staging-api is refused (the correction)" 'alphanumeric or space' \
  gql 'mutation { createProject(name: "staging-api") { id } }'
created=$(gql "mutation { createProject(name: \"$project\") { id name } }")
assert_match "create the note's project (the admin UI calls the same API)" "\"name\":\"$project\"" "$created"
check_output "and open it" '"isActive":true' \
  gql "mutation { openProject(id: \"$(jq -r .data.createProject.id <<<"$created")\") { isActive } }"
check_output "the request made before the project was not stored" '^0$' \
  bash -c "$(declare -f gql); gql '{ httpRequestLogs { url } }' | jq '[.data.httpRequestLogs[] | select(.url | test(\"before-project\"))] | length'"

section "The CA certificate"
check "hetty created its CA on first run (from the note)" bash -ec "$(note_block "$NOTE" 'The CA certificate' 1)"
check_output "the CA is a CA certificate" 'CA:TRUE' openssl x509 -in ~/.hetty/hetty_cert.pem -noout -text
check_output "the key is not encrypted (as the note warns)" '^-----BEGIN (EC |RSA )?PRIVATE KEY-----' head -1 ~/.hetty/hetty_key.pem

section "Configuring a client"
check_output "curl -k through the proxy, HTTPS (from the note)" 'ok|s_server|<HTML|<html' \
  bash -ec "$(note_block "$NOTE" 'Configuring a client' 1 | sed 's|https://staging.example.com|https://localhost:9443|')"
check_output "hetty re-signed the site with its own CA" 'issuer=.*Hetty' \
  bash -c 'openssl s_client -proxy localhost:8080 -connect localhost:9443 -servername localhost </dev/null 2>/dev/null | openssl x509 -noout -issuer'
check_fails "without -k, an untrusted hetty CA is refused" P -sf -o /dev/null https://localhost:9443/
check "trust the CA, Leap (from the note)" bash -ec "$(note_block "$NOTE" 'The CA certificate' 2)"
check "then curl verifies through the proxy" P -sf -o /dev/null https://localhost:9443/
check "remove it (from the note)" bash -ec "$(note_block "$NOTE" 'The CA certificate' 3)"
check_fails "then it is refused again" P -sf -o /dev/null https://localhost:9443/
check_output "hetty cert install exists, with --firefox" '\-\-firefox' bash -c 'hetty cert install --help 2>&1'
check_output "and hetty cert uninstall" 'Uninstalls a certificate' bash -c 'hetty cert uninstall --help 2>&1'

section "Using it: search"
P -o /dev/null http://127.0.0.1:9000/api/v1/users
P -o /dev/null http://127.0.0.1:9000/health
P -o /dev/null -d x http://127.0.0.1:9000/api/v1/orders
# filter EXPR: set the proxy log search, print the matching URLs.
filter() {
  gql "mutation { setHttpRequestLogFilter(filter: {searchExpression: $(jq -Rn --arg e "$1" '$e')}) { searchExpression } }" >/dev/null
  gql '{ httpRequestLogs { url } }' | jq -r '.data.httpRequestLogs[].url' | sort -u
}
search() { note_block "$NOTE" 'Using it' 2 | sed -n "${1}p"; }
check_output "the POST that returned 500 (from the note)" '^http://127.0.0.1:9000/api/v1/orders$' filter "$(search 1)"
assert_no_match "and only it" 'users|health' "$(filter "$(search 1)")"
check_output "req.url =~ (from the note)" '^http://127.0.0.1:9000/api/v1/users$' filter "$(search 2)"
check_output "res.body =~ (from the note)" 'orders' filter "$(search 3)"
assert_match "a bare string searches everything" 'orders' "$(filter '"boom"')"
out=$(gql "mutation { setHttpRequestLogFilter(filter: {searchExpression: \"method:POST AND status_code:500\"}) { searchExpression } }")
assert_no_match "the old syntax matches nothing (the correction)" 'orders' "$(gql '{ httpRequestLogs { url } }') $out"

kill %1 %2 2>/dev/null || true
pkill hetty || true
