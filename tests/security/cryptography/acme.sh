#!/usr/bin/env bash
# note: security/cryptography/acme.md
# env: compose
# timeout: 1200
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/compose.sh"

# Pebble, the Let's Encrypt test CA, and its DNS server stand in for Let's Encrypt.
# Nothing here talks to a public CA. Versions are pinned here: versions.env has none.
PEBBLE_VERSION=2.10.0
LEGO_VERSION=v5.6.0
STEP_VERSION=0.31.0
STEP_CA_VERSION=0.30.2

NOTE=security/cryptography/acme
block() { note_block "$NOTE" "$@"; }
# c CMD: run CMD in the client container, where the ACME clients run.
c() { docker compose exec -T client bash -ec "$1"; }
PEBBLE=https://pebble:14000/dir

cat >pebble.json <<'JSON'
{
  "pebble": {
    "listenAddress": "0.0.0.0:14000",
    "managementListenAddress": "0.0.0.0:15000",
    "certificate": "/test/certs/localhost/cert.pem",
    "privateKey": "/test/certs/localhost/key.pem",
    "httpPort": 80,
    "tlsPort": 443,
    "ocspResponderURL": "",
    "externalAccountBindingRequired": false,
    "retryAfter": { "authz": 1, "order": 1 },
    "profiles": {
      "default": { "description": "90 days", "validityPeriod": 7776000 },
      "shortlived": { "description": "6 days", "validityPeriod": 518400 }
    }
  }
}
JSON
cat >compose.yaml <<YAML
services:
  challtestsrv:
    image: ghcr.io/letsencrypt/pebble-challtestsrv:$PEBBLE_VERSION
    command: -defaultIPv6 "" -http01 "" -https01 "" -tlsalpn01 "" -doh ""
  pebble:
    image: ghcr.io/letsencrypt/pebble:$PEBBLE_VERSION
    command: -config /cfg/pebble.json -dnsserver challtestsrv:8053
    environment:
      PEBBLE_VA_NOSLEEP: "1"
      PEBBLE_WFE_NONCEREJECT: "0"
    volumes: ["./pebble.json:/cfg/pebble.json:ro"]
  client:
    image: registry.opensuse.org/opensuse/leap:16.0
    command: sleep infinity
    working_dir: /w
    volumes: [".:/w"]
YAML
docker compose up -d --quiet-pull 2>/dev/null
docker compose cp pebble:/test/certs/pebble.minica.pem ./pebble.minica.pem 2>/dev/null
c 'zypper -n -q install --no-recommends python313-certbot python313-certbot-nginx nginx curl tar gzip python3 openssl findutils >/dev/null'
c "arch=\$(uname -m | sed 's/x86_64/amd64/; s/aarch64/arm64/')
   curl -fsSL --retry 5 --retry-all-errors https://github.com/go-acme/lego/releases/download/$LEGO_VERSION/lego_${LEGO_VERSION}_linux_\$arch.tar.gz | tar -xz -C /usr/local/bin lego
   curl -fsSL --retry 5 --retry-all-errors https://github.com/smallstep/cli/releases/download/v$STEP_VERSION/step_linux_${STEP_VERSION}_\$arch.tar.gz | tar -xz -C /usr/local/bin --strip-components=2 step_$STEP_VERSION/bin/step
   curl -fsSL --retry 5 --retry-all-errors https://github.com/smallstep/certificates/releases/download/v$STEP_CA_VERSION/step-ca_linux_${STEP_CA_VERSION}_\$arch.tar.gz | tar -xz -C /usr/local/bin step-ca"
# Pebble's DNS answers every name with the client's address, so validation reaches it.
ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$(docker compose ps -q client)")
c "curl -fsS -X POST -d '{\"ip\":\"$ip\"}' http://challtestsrv:8055/set-default-ipv4 >/dev/null"
retry 30 c "curl -fsS --cacert pebble.minica.pem $PEBBLE >/dev/null"
# Trust Pebble's API in both clients.
LEGO_ENV="LEGO_CA_CERTIFICATES=/w/pebble.minica.pem"
export_certbot="export REQUESTS_CA_BUNDLE=/w/pebble.minica.pem"

section "The flow and the key authorization"
# lego's exec provider in RAW mode hands the script the token and the key authorization.
# The script checks the note's formulas, then publishes the TXT value it computed itself:
# if that value is wrong, Pebble refuses the challenge.
cat >txt.sh <<'SH'
#!/bin/bash
set -e
[ "$1" = present ] || exit 0
domain=$3 token=$4 keyauth=$5
acct=$(find /w/.lego/accounts -name '*.key' | head -1)
thumb=$(python3 - "$acct" <<'PY'
import base64, hashlib, json, subprocess, sys
der = subprocess.run(["openssl", "pkey", "-in", sys.argv[1], "-pubout", "-outform", "DER"], capture_output=True, check=True).stdout
pt = der[-64:]  # P-256: x || y
b64 = lambda b: base64.urlsafe_b64encode(b).rstrip(b"=").decode()
jwk = json.dumps({"crv": "P-256", "kty": "EC", "x": b64(pt[:32]), "y": b64(pt[32:])}, separators=(",", ":"), sort_keys=True)
print(b64(hashlib.sha256(jwk.encode()).digest()))
PY
)
[ "$keyauth" = "$token.$thumb" ] && echo "keyauth-ok" >>/w/formula.log
value=$(printf %s "$keyauth" | openssl dgst -sha256 -binary | base64 | tr '+/' '-_' | tr -d '=')
curl -fsS -X POST -d "{\"host\":\"_acme-challenge.${domain#\*.}.\",\"value\":\"$value\"}" http://challtestsrv:8055/set-txt
SH
chmod +x txt.sh
check "lego, dns-01, a wildcard certificate (Pebble, exec provider)" c "$LEGO_ENV EXEC_PATH=/w/txt.sh EXEC_MODE=RAW \
  lego run --server $PEBBLE --email security@example.com --accept-tos --key-type EC256 \
  --dns exec --dns.resolvers challtestsrv:8053 --dns.propagation.wait 1s \
  --domains example.org --domains '*.example.org' --path /w/.lego 2>&1"
check_output "keyAuthorization = token . base64url(JWK thumbprint) (the correction)" 'keyauth-ok' cat formula.log
check_output "the TXT value base64url(SHA256(keyAuthorization)) was accepted: the wildcard is issued" \
  'DNS:\*\.example\.org' openssl x509 -in .lego/certificates/example.org.crt -noout -ext subjectAltName

section "The three challenges"
check "http-01 with lego (port 80)" c "$LEGO_ENV lego run --server $PEBBLE --email security@example.com --accept-tos \
  --http --domains web.example.com --path /w/.lego >/dev/null 2>&1"
check_fails "http-01 cannot get a wildcard: Pebble offers only dns-01 for it" \
  c "$LEGO_ENV lego run --server $PEBBLE --email security@example.com --accept-tos --http --domains '*.example.net' --path /w/.lego"
check "tls-alpn-01 with lego (port 443, ALPN acme-tls/1)" c "$LEGO_ENV lego run --server $PEBBLE --email security@example.com \
  --accept-tos --tls --domains tls.example.com --path /w/.lego >/dev/null 2>&1"

section "ARI and profiles"
check_output "lego uses ARI (RFC 9773) unless told not to" 'renewalInfo endpoint \(RFC9773\)' c 'lego run --help'
check "a short-lived certificate through an ACME profile" c "$LEGO_ENV lego run --server $PEBBLE --email security@example.com \
  --accept-tos --http --profile shortlived --domains short.example.com --path /w/.lego >/dev/null 2>&1"
check_output "it lasts 6 days (144 hours)" '^144$' c 'c=/w/.lego/certificates/short.example.com.crt
  echo $(( ($(date -d "$(openssl x509 -in $c -noout -enddate | cut -d= -f2)" +%s) - $(date -d "$(openssl x509 -in $c -noout -startdate | cut -d= -f2)" +%s) + 60) / 3600 ))'

section "Running ACME internally (step-ca)"
c 'echo "127.0.0.1 ca.internal.example.com service-01.internal.example.com" >>/etc/hosts; echo labpass >/root/pw'
check "step ca init --acme (from the note, with answers given as flags)" c \
  "$(block 'Running ACME internally' 1 | sed -n 1p) --deployment-type standalone --name Lab \
   --dns ca.internal.example.com --address :443 --provisioner admin@example.com --password-file /root/pw >/dev/null 2>&1"
check_output "it adds an ACME provisioner named acme" '"type": "ACME"' c 'cat $(step path)/config/ca.json'
c 'nohup step-ca $(step path)/config/ca.json --password-file /root/pw >/tmp/step-ca.log 2>&1 &'
check "step-ca answers at the note's directory URL" retry 30 c \
  'curl -fsS --cacert $(step path)/certs/root_ca.crt https://ca.internal.example.com/acme/acme/directory'
check "certbot --standalone against it (from the note)" c "export REQUESTS_CA_BUNDLE=\$(step path)/certs/root_ca.crt
  $(block 'Running ACME internally' 1 | sed -n '2,$p' | sed 's/-d service-01.internal.example.com$/-d service-01.internal.example.com --non-interactive --agree-tos -m security@example.com --no-eff-email/') >/dev/null 2>&1"
check_output "the certificate comes from the internal CA" 'Lab Intermediate CA' \
  c 'openssl x509 -in /etc/letsencrypt/live/service-01.internal.example.com/cert.pem -noout -issuer'
c 'pkill step-ca || true; certbot delete --non-interactive --cert-name service-01.internal.example.com >/dev/null 2>&1'

section "certbot, http-01"
c 'mkdir -p /srv/www && cat >/etc/nginx/vhosts.d/example.conf <<NGX
server {
    listen 80;
    server_name example.com www.example.com;
    root /srv/www;
}
NGX
nginx'
check "certbot --nginx (from the note, against Pebble)" c "$export_certbot
  $(block 'certbot, http-01' 1 | tr -d '\\\n') --server $PEBBLE --non-interactive >/dev/null 2>&1"
check_output "it edited the nginx configuration" 'ssl_certificate /etc/letsencrypt/live/example.com/fullchain.pem' \
  c 'cat /etc/nginx/vhosts.d/example.conf'
check_output "the certificate covers both names" 'DNS:example.com, DNS:www.example.com|DNS:www.example.com, DNS:example.com' \
  c 'openssl x509 -in /etc/letsencrypt/live/example.com/cert.pem -noout -ext subjectAltName'
check_output "certbot itself installs no timer: Leap ships it in a separate package" 'certbot-renew.timer' \
  c 'zypper -n -q install --no-recommends certbot-systemd-timer >/dev/null; rpm -ql certbot-systemd-timer'
# --dry-run talks to the Let's Encrypt staging server unless --server says otherwise:
# point it at Pebble, so the test never contacts a public CA.
check "certbot renew --dry-run (from the note), against Pebble" c "$export_certbot; $(block 'certbot, http-01' 2) --server $PEBBLE 2>&1"
check_output "--dry-run uses the Let's Encrypt staging server by default" 'staging' c 'certbot --help all | grep -A2 -- "--dry-run"'

section "lego, dns-01, wildcard"
check_fails "the lego v4 syntax (flags before run) is gone in lego v5" \
  c "lego --email security@example.com --dns cloudflare --domains example.com --accept-tos run"
check_output "the note's lego v5 command reaches the Cloudflare provider, which wants the token" 'CLOUDFLARE_DNS_API_TOKEN' \
  c "$LEGO_ENV; export $LEGO_ENV; $(block 'lego, dns-01, wildcard' 1 | grep -v '^export' | tr -d '\\\n') --server $PEBBLE --path /w/.lego 2>&1 || true"
skip "a real Cloudflare zone" "needs a Cloudflare account and token"
check "the staging lego line parses (from the note; --help instead of the rest)" \
  c "$(block 'Always test against staging' 1 | grep '^lego' | sed 's/ \.\.\.$/ --help/') >/dev/null"

section "The failure that actually happens"
c 'rm -f /tmp/deployed'
check "certbot renew --deploy-hook, with nothing due (from the note)" \
  c "$export_certbot; $(block 'The failure' 1 | grep '^certbot' | sed 's/systemctl reload nginx/touch \/tmp\/deployed/') >/dev/null 2>&1"
check_fails "nothing was renewed, so the deploy hook did not run" c 'test -e /tmp/deployed'
c 'mkdir -p /etc/letsencrypt/renewal-hooks/deploy && printf "#!/bin/sh\ntouch /tmp/dir-hook\n" >/etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh && chmod +x /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh'
check "after a forced renewal" c "$export_certbot; certbot renew --force-renewal --cert-name example.com \
  --deploy-hook 'touch /tmp/deployed' >/dev/null 2>&1"
check "the deploy hook ran" c 'test -e /tmp/deployed'
check "and so did the script in renewal-hooks/deploy" c 'test -e /tmp/dir-hook'
c 'nginx -s reload; grep -q example.com /etc/hosts || echo "127.0.0.1 example.com" >>/etc/hosts'
check_output "the outside expiry check passes for a 90-day certificate (from the note)" 'Certificate will not expire' \
  c "$(block 'The failure' 2 | grep -v '^#')"
c 'cd /w/.lego/certificates && (openssl s_server -accept 8443 -cert short.example.com.crt -key short.example.com.key -quiet </dev/null >/dev/null 2>&1 &) ; sleep 1'
check_fails "and fails for the 6-day certificate" \
  c "$(block 'The failure' 2 | grep -v '^#' | sed 's/example.com:443/127.0.0.1:8443/')"
