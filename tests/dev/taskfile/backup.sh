#!/usr/bin/env bash
# note: dev/taskfile/backup.md
# env: compose
# timeout: 900
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/compose.sh"
source "$NOTES_ROOT/tests/versions.env"

NOTE=dev/taskfile/backup
block() { note_block "$NOTE" "$@"; }
rc() { "$@" >/dev/null 2>&1 && echo 0 || echo $?; }
# norm: replace timestamps, so the note's example output can be compared.
norm() { sed -E 's/[0-9]{8}-[0-9]{6}/STAMP/g'; }
count() { find backups -maxdepth 1 -name "$1-*.tar.gz" | wc -l | tr -d ' '; }

block 'The Taskfile' 1 >Taskfile.yml
mkdir -p data && echo hello >data/a.txt

section "The Taskfile"
assert_eq "task --list prints the note's help page" "$(block 'The Taskfile' 2)" "$(task --list 2>&1)"
check_fails "backup-dir is internal: not callable" task backup-dir
check_output "a variable can be changed on the command line" '^wrote \./backups/app-' task -s backup NAME=app
rm -rf backups

section "Back up a directory"
out=$(bash -c "$(block 'Back up a directory' 1)" 2>&1) && r=0 || r=$?
assert_eq "task backup: exit 0" 0 "$r"
assert_eq "the output shown in the note" "$(block 'Back up a directory' 2 | norm)" "$(norm <<<"$out")"
archive=$(find backups -name 'data-*.tar.gz')
assert_match "a timestamped name" '^backups/data-[0-9]{8}-[0-9]{6}\.tar\.gz$' "$archive"
check_output "paths are relative to SRC" '^\./a\.txt$' tar -tzf "$archive"
out=$(task backup MIN_FREE_MB=999999999 2>&1) && r=0 || r=$?
assert_eq "not enough free space: exit 201" 201 "$r"
assert_eq "the message shown in the note" "$(block 'Back up a directory' 3 | sed 's/1024/999999999/')" "$(grep -v 'is up to date' <<<"$out")"
assert_eq "and no new archive" 1 "$(count data)"
check_output "a missing SRC: its msg" 'Source directory ./nothing does not exist' bash -c 'task backup SRC=./nothing 2>&1; true'
if [[ $(id -u) == 0 ]]; then
  skip "a read-only BACKUP_DIR: its msg" "the runner is root here (macOS), and root can write anywhere"
else
  mkdir ro && chmod 555 ro
  check_output "a read-only BACKUP_DIR: its msg" 'Cannot write to ./ro' bash -c 'task backup BACKUP_DIR=./ro 2>&1; true'
  chmod 755 ro
fi
check_output "backup-dir: status skips mkdir when the directory exists" 'Task "backup-dir" is up to date' task backup
rm -rf backups
check_output "backup:daily runs when there is no archive from today" '^wrote ' task -s backup:daily
check_output "backup:daily: a second run the same day does nothing" 'Task "backup:daily" is up to date' task backup:daily

section "Keep the N newest archives"
rm -rf backups
for d in 1 2 3 4 5; do task -s backup STAMP="2026010$d-000000" KEEP=99 >/dev/null; done
assert_eq "five archives" 5 "$(count data)"
check_output "task prune PREFIX=data KEEP=3 (from the note)" "removed '\./backups/data-20260102-000000\.tar\.gz'" \
  bash -c "$(block 'Keep the N newest' 1)"
assert_eq "three left" 3 "$(count data)"
assert_eq "the three newest" "data-20260103-000000.tar.gz data-20260104-000000.tar.gz data-20260105-000000.tar.gz" \
  "$(find backups -name 'data-*.tar.gz' -printf '%f\n' | sort | tr '\n' ' ' | sed 's/ $//')"
check_output "backup prunes too" "removed '\./backups/data-20260103-000000\.tar\.gz'" task -s backup STAMP=20260106-000000 KEEP=3
assert_eq "a prefix with no archive: exit 0" 0 "$(rc task prune PREFIX=nothing)"
check_output "ls instead of find would fail with no match" 'No such file' bash -c 'ls backups/nothing-*.tar.gz 2>&1; true'

section "Dry run"
before=$(count app)
out=$(bash -c "$(block 'Dry run' 1)" 2>&1) && r=0 || r=$?
assert_eq "task --dry backup NAME=app: exit 0" 0 "$r"
assert_eq "the output shown in the note" "$(block 'Dry run' 2 | norm)" "$(norm <<<"$out")"
assert_eq "no archive written" "$before" "$(count app)"
for d in 1 2 3 4 5 6 7 8; do task -s backup NAME=app STAMP="2026020$d-000000" KEEP=99 >/dev/null; done
task --dry backup NAME=app >/dev/null 2>&1
assert_eq "nothing pruned in a dry run" 8 "$(count app)"
assert_eq "a dry run with a missing SRC fails, as a real run" 201 "$(rc task --dry backup SRC=/srv/missing)"
rm -f backups/app-*

section "Restore"
rm -rf backups data data.old && mkdir data && echo v1 >data/a.txt
task -s backup STAMP=20261105-093000 >/dev/null
echo v2 >data/a.txt
assert_eq "no ARCHIVE: exit 206" 206 "$(rc task restore)"
check_output "a missing file: its msg" 'No such archive: nope' bash -c 'task restore ARCHIVE=nope 2>&1; true'
echo junk >backups/junk.tar.gz
check_output "an unreadable archive: its msg" 'is not a readable tar.gz archive' bash -c 'task restore ARCHIVE=backups/junk.tar.gz 2>&1; true'
rm backups/junk.tar.gz
cmd=$(block 'Restore' 1)
assert_eq "no terminal: exit 205" 205 "$(rc bash -c "$cmd" </dev/null)"
assert_eq "and nothing changed" v2 "$(cat data/a.txt)"
if command -v script >/dev/null; then
  answer() { printf '%s\n' "$1" | script -qec "$cmd" /dev/null 2>&1; }
  out=$(answer n) && r=0 || r=$?
  assert_match "the question shown in the note" "$(block 'Restore' 2 | sed 's/[][?.]/\\&/g')" "$(tr -d '\r' <<<"$out")"
  assert_eq "answer n: data unchanged" v2 "$(cat data/a.txt)"
  out=$(answer y)
  assert_match "answer y: restored" 'restored \./backups/data-20261105-093000\.tar\.gz into \./data' "$out"
  assert_eq "the archive's content is back" v1 "$(cat data/a.txt)"
  assert_eq "the old content is in data.old" v2 "$(cat data.old/a.txt)"
else
  skip "answering the prompt in a terminal" "script(1) is not installed in the runner"
fi
echo v3 >data/a.txt
task -s backup STAMP=20261106-000000 >/dev/null
echo v4 >data/a.txt
check_output "task --yes restore:latest (from the note)" 'restored \./backups/data-20261106-000000\.tar\.gz' \
  bash -c "$(block 'Restore' 3)"
assert_eq "the newest archive is restored" v3 "$(cat data/a.txt)"

section "Prometheus TSDB snapshot"
mkdir prom-data
flag=$(block 'Prometheus TSDB snapshot' 1)
assert_eq "the flag in the note" "--web.enable-admin-api" "$flag"
cat >compose.yaml <<EOF
services:
  prometheus:
    image: prom/prometheus:$PROMETHEUS_VERSION
    user: "$(id -u):$(id -g)"
    command: [--config.file=/etc/prometheus/prometheus.yml, --storage.tsdb.path=/prometheus, $flag]
    volumes: [./prom-data:/prometheus]
    ports: ["19090:9090"]
  prometheus-noadmin:
    image: prom/prometheus:$PROMETHEUS_VERSION
    ports: ["19091:9090"]
  grafana:
    image: grafana/grafana:$GRAFANA_VERSION
    environment:
      GF_SECURITY_ADMIN_PASSWORD: test-admin-pw
    ports: ["13000:3000"]
EOF
docker compose up -d --quiet-pull >/dev/null 2>&1
wait_http http://localhost:19090/-/ready 120 || compose_logs prometheus
wait_http http://localhost:19091/-/ready 120
P="PROM_URL=http://localhost:19090"
# Wait for the first self-scrape, so the snapshot holds a block.
retry 60 bash -c 'curl -fsS "http://localhost:19090/api/v1/query?query=up" | jq -e ".data.result | length > 0"'
assert_eq "without the flag, the POST answers 500" 500 \
  "$(curl -s -o /dev/null -w '%{http_code}' -X POST http://localhost:19091/api/v1/admin/tsdb/snapshot)"
assert_eq "with the body shown in the note" '{"status":"error","errorType":"unavailable","error":"admin APIs disabled"}' \
  "$(curl -s -X POST http://localhost:19091/api/v1/admin/tsdb/snapshot)"
assert_eq "and the task stops: exit 201" 201 "$(rc task prometheus:snapshot PROM_URL=http://localhost:19091 PROM_DATA=./prom-data)"
check_output "the API answer shown in the note" '^\{"status":"success","data":\{"name":"[0-9]{8}T[0-9]{6}Z-[0-9a-f]+"\}\}$' \
  curl -fsS -X POST http://localhost:19090/api/v1/admin/tsdb/snapshot
rm -rf prom-data/snapshots/*
cmd=$(block 'Prometheus TSDB snapshot' 2 | sed "s|/var/lib/prometheus|./prom-data|")
out=$(bash -c "$cmd $P" 2>&1) && r=0 || r=$?
assert_eq "task prometheus:snapshot (from the note): exit 0" 0 "$r"
assert_match "it prints the snapshot name" 'snapshot [0-9]{8}T[0-9]{6}Z-[0-9a-f]+' "$out"
assert_match "and the archive" 'wrote \./backups/prometheus-[0-9]{8}-[0-9]{6}\.tar\.gz' "$out"
parch=$(find backups -name 'prometheus-*.tar.gz')
check_output "the archive holds a TSDB block" '/meta\.json$' tar -tzf "$parch"
assert_eq "the snapshot directory was deleted" "" "$(ls prom-data/snapshots)"
assert_eq "a wrong PROM_DATA: exit 201" 201 "$(rc task prometheus:snapshot "$P" PROM_DATA=/nonexistent)"
assert_eq "Prometheus down: exit 201" 201 "$(rc task prometheus:snapshot PROM_URL=http://localhost:19099 PROM_DATA=./prom-data)"

section "Grafana dashboard export"
wait_http http://localhost:13000/api/health 180 || compose_logs grafana
export GRAFANA_URL=http://localhost:13000 GRAFANA_ADMIN_PASSWORD=test-admin-pw
GRAFANA_TOKEN=$(bash -ec "$(block 'Grafana dashboard export' 1); echo \"\$GRAFANA_TOKEN\"")
assert_match "the note's block creates a token" '^glsa_' "$GRAFANA_TOKEN"
export GRAFANA_TOKEN
check_output "the token's service account is a Viewer" '"role":"Viewer"' \
  curl -fsS -u "admin:$GRAFANA_ADMIN_PASSWORD" "$GRAFANA_URL/api/serviceaccounts/search?query=backup"
curl -fsS -u "admin:$GRAFANA_ADMIN_PASSWORD" -H 'Content-Type: application/json' \
  -d '{"dashboard":{"uid":"task-backup-test","title":"Task backup test","panels":[]},"overwrite":true}' \
  "$GRAFANA_URL/api/dashboards/db" >/dev/null
cmd=$(block 'Grafana dashboard export' 2 | sed "s|https://grafana.example.com|$GRAFANA_URL|")
out=$(bash -c "$cmd" 2>&1) && r=0 || r=$?
assert_eq "task grafana:export (from the note): exit 0" 0 "$r"
assert_match "it exports the dashboard" 'exported task-backup-test' "$out"
assert_no_match "the token is not in the output" "$GRAFANA_TOKEN" "$out"
garch=$(find backups -name 'grafana-*.tar.gz')
mkdir gx && tar -xzf "$garch" -C gx
gjson=$(find gx -name task-backup-test.json)
check_output "the JSON is the dashboard model" '^Task backup test$' jq -r .title "$gjson"
check_fails "without Grafana's metadata" jq -e .meta "$gjson"
assert_eq "defer removed the temporary directory" "" "$(find backups -mindepth 1 -type d)"
assert_eq "no GRAFANA_TOKEN: exit 206" 206 "$(rc env -u GRAFANA_TOKEN task grafana:export GRAFANA_URL="$GRAFANA_URL")"
assert_eq "a bad token: exit 201" 201 "$(rc env GRAFANA_TOKEN=bad task grafana:export GRAFANA_URL="$GRAFANA_URL")"
curl -fsS -u "admin:$GRAFANA_ADMIN_PASSWORD" -X DELETE "$GRAFANA_URL/api/dashboards/uid/task-backup-test" >/dev/null
export FILE=$gjson
check_fails "import with the Viewer token fails (as the note says)" env GRAFANA_ADMIN_TOKEN="$GRAFANA_TOKEN" bash -ec "$(block 'Grafana dashboard export' 4)"
sa=$(curl -fsS -u "admin:$GRAFANA_ADMIN_PASSWORD" -H 'Content-Type: application/json' \
  -d '{"name":"restore","role":"Editor"}' "$GRAFANA_URL/api/serviceaccounts" | jq -r .id)
GRAFANA_ADMIN_TOKEN=$(curl -fsS -u "admin:$GRAFANA_ADMIN_PASSWORD" -H 'Content-Type: application/json' \
  -d '{"name":"restore-task"}' "$GRAFANA_URL/api/serviceaccounts/$sa/tokens" | jq -r .key)
export GRAFANA_ADMIN_TOKEN
check_output "import with an Editor token (from the note)" '"status":"success"' bash -ec "$(block 'Grafana dashboard export' 4)"
check_output "the dashboard is back" '"title":"Task backup test"' \
  curl -fsS -u "admin:$GRAFANA_ADMIN_PASSWORD" "$GRAFANA_URL/api/dashboards/uid/task-backup-test"

section "Run it from cron"
rm -rf backups
line=$(block 'Run it from cron' 1)
assert_match "the cron line runs backup:daily and prometheus:snapshot" 'task backup:daily prometheus:snapshot' "$line"
out=$(task -s backup:daily prometheus:snapshot "$P" PROM_DATA=./prom-data 2>&1) && r=0 || r=$?
assert_eq "both tasks in one invocation: exit 0" 0 "$r"
d=$(find backups -name 'data-*.tar.gz' | sed -E 's/.*data-//')
p=$(find backups -name 'prometheus-*.tar.gz' | sed -E 's/.*prometheus-//')
assert_eq "one STAMP for the whole run" "$d" "$p"
skip "the crontab line itself" "needs cron and /srv/backup on a real host; its task command is run above"
