#!/usr/bin/env bash
# note: servers/nginx.md
# env: leap-systemd
# timeout: 900
source "$NOTES_ROOT/tests/lib/assert.sh"

NOTE=servers/nginx
cd "$(mktemp -d)"
zypper -n -q install --no-recommends nginx curl apache2-utils python3 >/dev/null
block() { note_block "$NOTE" "$@"; }
conf=/etc/nginx/conf.d/test.conf
# site HTTP-LEVEL SERVER-LEVEL: a test server on port 8080, with extra directives.
site() {
  printf '%s\nserver {\n  listen 8080;\n  root /srv/www/test;\n%s\n  location /ok { return 200 "ok\\n"; }\n}\n' "$1" "$2" >"$conf"
  nginx -t -q && systemctl reload nginx && sleep 1
}
mkdir -p /srv/www/test && echo hello >/srv/www/test/index.html
systemctl enable --now nginx >/dev/null 2>&1

section "Testing the configuration"
check_output "nginx -t (from the note)" 'syntax is ok' bash -c "$(block 'Testing the configuration' 1 | sed -n 1p) 2>&1"
check_output "nginx -t -c (from the note)" 'test is successful' bash -c "$(block 'Testing the configuration' 1 | sed -n 2p) 2>&1"

section "Clearing the cache"
# A backend that answers with a counter, and a caching proxy in front of it.
python3 -c '
import http.server
n = 0
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        global n; n += 1
        self.send_response(200); self.send_header("Cache-Control", "max-age=3600"); self.end_headers()
        self.wfile.write(b"version %d\n" % n)
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", 9001), H).serve_forever()' &
check_fails "Leap has no /var/cache/nginx (as the note says)" test -d /var/cache/nginx
mkdir -p /var/cache/nginx
site 'proxy_cache_path /var/cache/nginx/test keys_zone=test:1m;' \
  '  location /c { proxy_pass http://127.0.0.1:9001; proxy_cache test; }'
first=$(curl -s http://localhost:8080/c)
assert_eq "the first answer is cached" "$first" "$(curl -s http://localhost:8080/c)"
check_output "the cache is on disk under /var/cache/nginx" '.' find /var/cache/nginx/ -type f
check "find -delete (from the note)" bash -ec "$(block 'Clearing the cache' 1)"
check_fails "the response is fetched again, even before a reload" bash -c "curl -s http://localhost:8080/c | grep -qx '$first'"
check "systemctl reload nginx (from the note)" bash -ec "$(block 'Clearing the cache' 2)"
rm -f "$conf"

section "server_tokens"
site '' ''
check_output "by default the Server header has the version" '^Server: nginx/[0-9.]+' bash -c "curl -sI http://localhost:8080/ok | tr -d '\r'"
site "$(block 'server_tokens' 1)" ''
check_output "server_tokens off (from the note): Server: nginx, no version" '^Server: nginx$' bash -c "curl -sI http://localhost:8080/ok | tr -d '\r'"

section "Limiting concurrent connections per IP"
# A slow download keeps each connection busy.
head -c 20M /dev/zero >/srv/www/test/big
lc=$(block 'concurrent connections' 1)
site "$(sed -n 1p <<<"$lc")" "  limit_rate 200k;
  $(sed -n 2p <<<"$lc")"
for _ in $(seq 20); do curl -s -o /dev/null http://localhost:8080/big & done
sleep 2
check_output "with 20 downloads running, a 21st connection gets 503" '^503$' \
  curl -s -o /dev/null -w '%{http_code}' http://localhost:8080/big
pkill -x curl || true
sleep 1
check_output "once they are closed, a request passes again" '^200$' curl -s -o /dev/null -w '%{http_code}' http://localhost:8080/ok

section "Limiting request rate per IP"
# A static file: a `return` answers in the rewrite phase, before limit_req runs.
lr=$(block 'request rate' 1)
site "$(sed -n 1p <<<"$lr")" "  $(sed -n 2p <<<"$lr")"
check_output "1000 fast requests: some are refused" 'Non-2xx responses: +[1-9]' ab -q -n 1000 -c 20 http://127.0.0.1:8080/index.html
check_output "with 503 by default (as the note says)" '" 503 ' bash -c 'tail -200 /var/log/nginx/access.log'
check_output "the burst of 200 passes" '^200$' bash -c 'sleep 2; for i in $(seq 200); do curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:8080/index.html & done | sort | uniq -c | awk "\$2 == 200 { print \$1 }"'
site "$(sed -n 1p <<<"$lr")" "  $(sed -n 2p <<<"$lr")
  limit_req_status 429;"
ab -q -n 1000 -c 20 http://127.0.0.1:8080/index.html >/dev/null 2>&1
check_output "limit_req_status 429 changes the code" '" 429 ' bash -c 'tail -200 /var/log/nginx/access.log'
printf 'limit_req_zone $binary_remote_addr zone=bad:10m;\n' >"$conf"
check_fails "a zone with no rate= is refused: the rate is set only there" nginx -t
rm -f "$conf"

section "Increasing the maximum upload size"
site '' ''
head -c 2M /dev/zero >upload
check_output "by default (1m), a 2 MB upload gets 413" '^413$' \
  curl -s -o /dev/null -w '%{http_code}' --data-binary @upload http://localhost:8080/ok
check_output "with the text Request Entity Too Large" '413 Request Entity Too Large' \
  curl -s --data-binary @upload http://localhost:8080/ok
site "$(block 'maximum upload size' 1)" ''
check_output "client_max_body_size 20M (from the note): it passes" '^200$' \
  curl -s -o /dev/null -w '%{http_code}' --data-binary @upload http://localhost:8080/ok
