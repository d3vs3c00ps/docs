#!/usr/bin/env bash
# note: security/offensive/naabu.md
# env: compose
# timeout: 900
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/compose.sh"

NOTE=security/offensive/naabu
NAABU_IMAGE=mirror.gcr.io/projectdiscovery/naabu:v2.7.0
HTTPX_IMAGE=mirror.gcr.io/projectdiscovery/httpx:v1.12.0
block() { note_block "$NOTE" "$@"; }

# Targets on the project's private network only: an nginx, and a box with an "etcd" and
# a "kubelet" port open. The note's ranges are replaced by these host names.
cat >compose.yaml <<EOF2
services:
  web:
    image: mirror.gcr.io/library/nginx:1.29-alpine
  node:
    image: mirror.gcr.io/library/busybox:1.37
    command: sh -c 'nc -lk -p 2379 -e echo & nc -lk -p 10250 -e echo & nc -lk -p 22 -e echo & wait'
  naabu:
    image: $NAABU_IMAGE
    working_dir: /w
    volumes: [".:/w"]
    profiles: [tools]
  httpx:
    image: $HTTPX_IMAGE
    profiles: [tools]
EOF2
pull "$NAABU_IMAGE" "$HTTPX_IMAGE"
docker compose up -d --quiet-pull web node 2>/dev/null
# -duc: no update check. naabu resolves names with public resolvers, not Docker's, so
# the targets are given as IP addresses, as in the note.
naabu() { docker compose --progress quiet run --rm -T naabu "$@" -duc; }
httpx() { docker compose --progress quiet run --rm -T httpx "$@"; }
export -f naabu httpx
retry 30 docker compose exec -T web wget -qO /dev/null http://localhost/
ip() { docker compose exec -T "$1" hostname -i | tr -d '\r '; }
WEB=$(ip web) NODE=$(ip node)
# A /28 around the two targets stands in for the note's /24: the project's own network.
NET=$(awk -F. '{ printf "%s.%s.%s.%d/28", $1, $2, $3, int($4 / 16) * 16 }' <<<"$WEB")
[[ $(awk -F. '{ print int($4 / 16) }' <<<"$WEB") == $(awk -F. '{ print int($4 / 16) }' <<<"$NODE") ]]
export WEB NODE NET
# hosts LINE: a note's command line, pointed at the test's own targets.
hosts() { sed -e "s|-host 10\.0\.0\.1|-host $WEB|" -e "s|10\.0\.0\.0/24|$NET|g" -e "s|10\.0\.0\.0/16|$NODE|" \
  -e "s|203\.0\.113\.0/24 198\.51\.100\.0/24|$WEB/32 $NODE/32|"; }
run() { bash -ec "$(hosts <<<"$1")"; }
w=${WEB//./\\.} n=${NODE//./\\.}

section "Installation"
check_output "the v2 module path resolves (from the note)" '^github.com/projectdiscovery/naabu/v2 v2\.' \
  docker run --rm mirror.gcr.io/library/golang:1.27 go list -m github.com/projectdiscovery/naabu/v2@latest
check_output "the pinned image is 2.7.0" '2\.7\.0' bash -c 'naabu -version 2>&1'

section "Basic use"
b=$(block 'Basic use' 1)
check_output "-host one host (from the note)" "^$w:80\$" run "$(sed -n 1p <<<"$b") -silent"
out=$(run "$(sed -n 2p <<<"$b") -silent")
assert_match "-host a range finds the other host's port 22" "(^|\n)$n:22(\$|\n)" "$out"
assert_no_match "  but not 2379: with no -p, naabu scans the top 100 ports only" ':2379' "$out"
printf '%s\n' "$WEB" "$NODE" >targets.txt
check_output "-list targets.txt (from the note)" "^$w:80\$" run "$(sed -n 3p <<<"$b") -silent"
check_output "-top-ports 1000 (from the note)" "^$n:22\$" run "$(sed -n 5p <<<"$b") -silent"
out=$(run "$(sed -n 6p <<<"$b") -silent")
assert_match "-p 22,80,443,8080-8090 (from the note)" "$w:80" "$out"
assert_no_match "and nothing outside that list" ':2379' "$out"
# On the one node, not the /28: all ports on 16 addresses is about a million probes.
check_output "-p - scans all ports, so it finds 10250 (from the note)" "^$n:10250\$" run "$(sed -n 7p <<<"$b" | sed 's/ *#.*//; s|10\.0\.0\.0/24|'"$NODE"'|') -silent"
o=$(block 'Basic use' 2)
check_output "-silent prints host:port only (from the note)" '^[0-9.]+:[0-9]+$' run "$(sed -n 1p <<<"$o" | sed 's/ *#.*//')"
check "-json -o results.json (from the note)" run "$(sed -n 2p <<<"$o")"
check_output "JSON lines with ip and port" '"port":80' cat results.json
check "-o open-ports.txt (from the note)" run "$(sed -n 3p <<<"$o")"
check_output "plain host:port lines" "^$w:80\$" cat open-ports.txt

section "Scan types"
check_output "the help lists SYN and CONNECT, CONNECT by default" 'type of port scan \(SYN/CONNECT\) \(default "c"\)' bash -c 'naabu -h 2>&1'
check_output "-s c (from the note)" "^$w:80\$" run "$(block 'Scan types' 1 | sed 's/ *#.*//') -silent"
check_output "as root, with no -s, naabu 2.7 still runs a CONNECT scan (the correction)" 'Running CONNECT scan' \
  bash -c 'naabu -host "$WEB" -p 80 -v 2>&1'
check_output "-s s gives a SYN scan, as root in the container" "^$w:80\$" bash -c 'naabu -host "$WEB" -p 80 -s s -silent'

section "Rate control"
check_output "the rate-limited run (from the note)" "^$n:2379\$" run "$(block 'Rate control' 1) -silent -p 2379"
help=$(naabu -h 2>&1)
assert_match "-rate is packets per second, default 1000" 'rate int +packets to send per second \(default 1000\)' "$help"
assert_match "-c workers, default 25" 'c int .*\(default 25\)' "$help"
assert_match "-timeout: a bare number is milliseconds" 'bare number is milliseconds' "$help"
assert_match "-retries, default 3" 'retries int .*\(default 3\)' "$help"
assert_match "naabu has its own -sV service probe" '-sV, -service-version' "$help"

section "Chaining"
chain=$(block 'Chaining' 1 | grep -v '^#' | sed -n 1,2p | sed 's/ *\\$//' | tr -d '\n')
check_output "naabu -silent | httpx -silent, the first two stages (from the note)" "^http://$w(:80)?\$" bash -c "$chain"
skip "the nuclei stage of the chain" "nuclei needs its template set, tested in offensive/nuclei with hand-written templates"
check_output "-nmap-cli hands open ports to nmap (from the note)" 'nginx' \
  run "$(block 'Chaining' 2 | grep -v '^#' | sed 's|-host 10.0.0.0/24|-host 10.0.0.1 -p 80|')"

section "Attack surface inventory"
block 'Attack surface inventory' 1 | hosts >surface.sh
check "first run (from the note)" bash surface.sh
docker compose exec -d node nc -lk -p 8080 -e echo
sleep 1
out=$(bash surface.sh)
assert_match "the second run reports the new port under NEW" "=== NEW since last run ===
$n:8080" "$out"

section "Kubernetes and cloud"
out=$(run "$(block 'Kubernetes and cloud' 1 | grep -v '^#')")
assert_match "the etcd port is found (from the note)" "$n:2379" "$out"
assert_match "and the kubelet port" "$n:10250" "$out"

section "Configuration"
mkdir -p cfg
block 'Configuration' 1 | sed "s/- 10\.0\.0\.1 .*/- $WEB/" >cfg/config.yaml
out=$(naabu -config /w/cfg/config.yaml -host "$WEB,$NODE" -silent)
assert_no_match "exclude-hosts in config.yaml leaves the host out (from the note)" "^$w:" "$out"
assert_match "and the other host is scanned with the config's top-ports" "^$n:22\$" "$out"
