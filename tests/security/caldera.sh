#!/usr/bin/env bash
# note: security/caldera.md
# env: rocky
# timeout: 1500
source "$NOTES_ROOT/tests/lib/assert.sh"

NOTE=security/caldera
block() { note_block "$NOTE" "$@"; }
# Everything runs inside this container: the server on localhost, one agent next to it,
# and no operation is started, so no ability runs.
# Go lets the server compile the Sandcat agent; without it the download is an error text.
dnf -y -q install --setopt=install_weak_deps=False python3-pip gcc python3-devel golang >/dev/null 2>&1
cd /opt
API=http://localhost:8888/api/v2
api() { curl -s -H 'KEY: ADMIN123' "$API/$1"; }
# Caldera logs through Rich, which wraps at 80 columns off a terminal and splits long lines.
export API COLUMNS=300
export -f api
start() { (cd /opt/caldera && python3 server.py "$@" >/tmp/caldera.log 2>&1 &); retry 180 curl -s -o /dev/null http://localhost:8888/; }
stop() { pkill -f 'server.py' || true; sleep 3; }

section "Running the server"
run=$(block 'Running the server' 1)
check "git clone --recursive and pip install (from the note)" \
  bash -ec "python3 -m venv /opt/venv && source /opt/venv/bin/activate && $(grep -v '^python' <<<"$run") >/dev/null 2>&1"
export PATH=/opt/venv/bin:$PATH
check_output "server.py has --insecure and --build" '--insecure.*--build|--build.*--insecure' \
  bash -c 'cd /opt/caldera && python3 server.py --help 2>&1 | tr "\n" " "'
skip "--build" "builds the Vue UI with npm; the test uses the REST API only"
start --insecure
check_output "python server.py --insecure serves the API (from the note)" '"application":"Caldera"|application' api health
# login USER PASSWORD: the status of an API call made with the session cookie /enter gives.
login() { curl -s -c /tmp/jar -o /dev/null -d "username=$1&password=$2" http://localhost:8888/enter &&
  curl -s -b /tmp/jar -o /dev/null -w '%{http_code}' "$API/health"; }
export -f login
check_output "--insecure: red / admin logs in (from the note)" '^200$' login red admin
check_output "a wrong password does not" '^40[13]$' login red wrong
check_output "and the config now holds Argon2 hashes, not the clear text" 'red: \$argon2id\$' \
  bash -c "sed -n '/^users:/,/^[a-z]/p' /opt/caldera/conf/default.yml"

section "An operation"
adv=$(api adversaries | jq -r '.[].name')
for p in Check Discovery Collection Thief; do
  assert_match "the $p profile exists (from the note)" "^$p\$" "$adv"
done
assert_no_match "there is no Hunter profile (the correction)" '^Hunter$' "$adv"

section "Plugins"
for p in stockpile atomic response emu manx debrief; do
  check "plugin $p is in the clone" test -d "/opt/caldera/plugins/$p"
done

section "Agents"
mkdir -p /tmp/agent && cd /tmp/agent
agent=$(block 'Agents' 1 | sed 's|caldera.internal|localhost|g')
check "download Sandcat and start it in the red group (from the note)" \
  bash -ec "$(sed '$d' <<<"$agent"); $(tail -1 <<<"$agent") >/tmp/agent.log 2>&1 &"
file /tmp/agent/splunkd | grep -q ELF || head -c 300 /tmp/agent/splunkd
check "the agent checks in" retry 60 bash -c "curl -s -H 'KEY: ADMIN123' $API/agents | jq -e '.[] | select(.group == \"red\")'"
check_output "under the name the note warns about" 'splunkd' bash -c "api agents | jq -r '.[].exe_name'"
pkill -f splunkd || true
cd /opt

section "Custom abilities"
mkdir -p /opt/caldera/plugins/stockpile/data/abilities/discovery
block 'Custom abilities' 1 >/opt/caldera/plugins/stockpile/data/abilities/discovery/8b7c2f1e-4a3d-4e5f-9a1b-2c3d4e5f6a7b.yml
stop
start --insecure
check_output "the ability loads from the stockpile directory (from the note)" '^T1613 Enumerate Kubernetes service accounts$' \
  bash -c "api abilities | jq -r '.[] | select(.ability_id == \"8b7c2f1e-4a3d-4e5f-9a1b-2c3d4e5f6a7b\") | \"\(.technique_id) \(.name)\"'"

section "conf/local.yml"
stop
block 'Running the server' 2 >/opt/caldera/conf/local.yml
check_output "a local.yml with only users stops the server (the correction)" 'encoding without a string argument' \
  bash -c 'cd /opt/caldera && timeout 120 python3 server.py 2>&1; true'
rm /opt/caldera/conf/local.yml
check_output "after --insecure runs, a normal start cannot read the saved state (the warning)" 'Failed to decrypt saved Caldera' \
  bash -c 'cd /opt/caldera && timeout 120 python3 server.py 2>&1 | tr -s " \n" " "; true'
rm -f /opt/caldera/conf/local.yml
start --fresh || { tail -40 /tmp/caldera.log; false; }
check "without --insecure, the first start writes conf/local.yml (from the note)" test -s /opt/caldera/conf/local.yml
check_fails "with a random red API key, not ADMIN123" grep -q '^api_key_red: ADMIN123$' /opt/caldera/conf/local.yml
check_output "  the file keeps only an Argon2 hash of the API key (the note)" '^api_key_red: .?\$argon2id\$' cat /opt/caldera/conf/local.yml
# The clear token is printed once, under "Red:", in this first start's log.
key=$(sed -n '/Red:/,/Blue:/s/.*API_TOKEN: *\([A-Za-z0-9_-]*\).*/\1/p' /tmp/caldera.log | head -1)
[[ -n $key ]] || grep -n -A8 'Red:' /tmp/caldera.log | sed 's/^/# log: /'
check_output "  the first start prints the red API token in its log (the note)" '^[A-Za-z0-9_-]{20,}$' echo "$key"
stop
# Set the users from the note's block in the generated file, keep the rest.
block 'Running the server' 2 >/tmp/users.yml
python3 -c '
import yaml
c = yaml.safe_load(open("/opt/caldera/conf/local.yml"))
c["users"] = yaml.safe_load(open("/tmp/users.yml"))["users"]
yaml.safe_dump(c, open("/opt/caldera/conf/local.yml", "w"))'
start
check_output "the red user logs in with the note's password" '^200$' login red a-real-password
check_output "and red / admin no longer works" '^40[13]$' login red admin
check_output "the default API key is refused" '^401$' curl -s -o /dev/null -w '%{http_code}' -H 'KEY: ADMIN123' "$API/health"
check_output "the generated one works" '^200$' curl -s -o /dev/null -w '%{http_code}' -H "KEY: $key" "$API/health"
stop
