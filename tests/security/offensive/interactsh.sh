#!/usr/bin/env bash
# note: security/offensive/interactsh.md
# env: compose
# timeout: 900
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/compose.sh"

NOTE=security/offensive/interactsh
V=v1.4.1
block() { note_block "$NOTE" "$@"; }
TOKEN=test-token-for-a-private-server
# A private interactsh server on the project's network stands in for oast.example.com.
# No public interactsh server, no ACME: -skip-acme turns HTTPS off.
cat >compose.yaml <<EOF2
services:
  oast:
    image: mirror.gcr.io/projectdiscovery/interactsh-server:$V
    entrypoint: ["sh", "-c"]
    command: ["interactsh-server -domain oast.example.com -ip \$\$(hostname -i) -token $TOKEN -skip-acme"]
    # The server's domain as its name: payloads use the host the client registered with, and
    # interactsh-client 1.4.1 fails on a one-label host ("no Host in request URL").
    networks: {default: {aliases: [oast.example.com]}}
  client:
    image: mirror.gcr.io/projectdiscovery/interactsh-client:$V
    working_dir: /w
    volumes: [".:/w"]
    command: ["-server", "http://oast.example.com", "-token", "$TOKEN", "-ps", "-json", "-o", "interactions.json", "-pi", "1"]
EOF2
docker compose up -d --quiet-pull oast 2>/dev/null
retry 30 docker compose exec -T oast sh -c 'wget -qO- http://127.0.0.1/ >/dev/null'
client() { docker compose --progress quiet run --rm -T --entrypoint interactsh-client client "$@"; }

section "The client"
help=$(client -h 2>&1)
for f in -json -o -n -dns-only -v -server -token; do
  assert_match "client flag $f (from the note)" "^ +(-[a-z-]+, )?${f}[ ,]" "$help"
done
assert_match "the default servers are the public oast.* list the note gives" \
  'default "oast\.pro,oast\.live,oast\.site,oast\.online,oast\.fun,oast\.me"' "$help"
check_output "the image runs (from the note)" 'Current Version: 1\.4\.1' \
  bash -c "$(block 'The client' 1 | grep '^docker' | sed "s|projectdiscovery/interactsh-client:$V|mirror.gcr.io/&|") -version 2>&1"

section "Running your own server"
shelp=$(docker compose run --rm -T --entrypoint interactsh-server oast -h 2>&1)
for f in -domain -ip -token -auth -skip-acme; do
  assert_match "server flag $f (from the note)" "^ +(-[a-z]+, )?$f " "$shelp"
done
assert_match "-token turns authentication on with a given token" 'enable authentication to server using given token' "$shelp"
assert_match "-auth alone generates a random one" 'enable authentication to server using random generated token' "$shelp"
check_output "without the token, registration is refused" '[Uu]nauthori|401|invalid token|token' \
  bash -c 'timeout 30 docker compose --progress quiet run --rm -T --entrypoint interactsh-client client -server http://oast.example.com -n 1 2>&1 | grep -i "register\|FTL"; true'
docker compose up -d client 2>/dev/null
retry 30 test -s interactsh_payload.txt || { compose_logs client; compose_logs oast; false; }
PAYLOAD=$(head -1 interactsh_payload.txt)
assert_match "with the token, the client gets a payload under the server's domain" '^[a-z0-9]+\.oast\.example\.com$' "$PAYLOAD"

section "Testing egress filtering"
SIP=$(docker compose exec -T oast hostname -i | tr -d '\r ')
egress=$(block 'Testing egress filtering' 1 | grep -v '^#' | sed "s/c8f3k2m1\.oast\.example\.com/$PAYLOAD/")
# A host with no egress filtering, whose resolver can reach the server: the "Yes, Yes" row.
check "the note's curl and dig, from an unfiltered host" \
  docker run --rm --network "${COMPOSE_PROJECT_NAME}_default" mirror.gcr.io/library/alpine:3.22 \
  sh -c "apk add -q curl bind-tools >/dev/null && echo 'nameserver $SIP' >/etc/resolv.conf && $egress"
retry 20 grep -q '"protocol":"http"' interactions.json
check_output "the client saw the DNS interaction" '"protocol":"dns"' cat interactions.json
check_output "and the HTTP one" '"protocol":"http"' cat interactions.json
check_output "with the payload's correlation ID" "\"unique-id\":\"${PAYLOAD%%.*}\"" cat interactions.json
# A host with HTTP egress blocked: only its resolver reaches out, the "Yes, No" row.
before=$(grep -c '"protocol":"http"' interactions.json)
check_fails "with HTTP egress blocked, curl fails (as the note expects)" \
  docker run --rm --network none mirror.gcr.io/library/alpine:3.22 wget -q -T 5 -O /dev/null "http://$PAYLOAD/"
docker run --rm --network "${COMPOSE_PROJECT_NAME}_default" --dns "$SIP" mirror.gcr.io/library/alpine:3.22 nslookup "$PAYLOAD" >/dev/null 2>&1 || true
sleep 3
assert_eq "no new HTTP interaction" "$before" "$(grep -c '"protocol":"http"' interactions.json)"

section "With nuclei"
skip "nuclei -iserver -itoken" "the flags are checked in offensive/nuclei; a real OAST finding needs a target that calls back"
