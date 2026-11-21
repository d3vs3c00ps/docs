#!/usr/bin/env bash
# note: observability/prometheus/backup.md
# env: compose
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/compose.sh"

NOTE=observability/prometheus/backup
P=http://localhost:9090
q_at() { curl -fsS "$P/api/v1/query" --data-urlencode "query=$1" --data-urlencode "time=$2" | jq -c .data.result; }

# The lab of the quickstart note.
note_block observability/prometheus/quickstart "Run it with Docker Compose" 1 >compose.yaml
note_block observability/prometheus/quickstart "Run it with Docker Compose" 2 >prometheus.yml
docker compose up -d --quiet-pull 2>/dev/null
wait_http "$P/-/ready" 90

section "Turn on the admin API"
check_output "without the flag, the snapshot is refused (from the note)" \
  "$(note_block "$NOTE" "Turn on the admin API" 2 | sed 's/[][{}]/./g')" \
  bash -c "$(note_block "$NOTE" "Turn on the admin API" 1)"
python3 - compose.yaml "$(note_block "$NOTE" "Turn on the admin API" 3)" <<'EOF'
import sys
path, new = sys.argv[1], sys.argv[2]
old = """    command:
      - --config.file=/etc/prometheus/prometheus.yml
      - --storage.tsdb.path=/prometheus
      - --web.enable-lifecycle
"""
s = open(path).read()
assert old in s
open(path, "w").write(s.replace(old, new.rstrip("\n") + "\n", 1))
EOF
docker compose up -d 2>/dev/null
retry 60 curl -fsS "$P/-/ready" || true
check_output "the flag is on" 'web.enable-admin-api.*true' \
  bash -c "curl -fsS $P/api/v1/status/flags | jq -r 'to_entries[] | \"\(.key) \(.value)\"'"
# T: the time of a sample scraped by this Prometheus (not one replayed from before the
# restart), with an older one before it.
retry 90 bash -c "curl -fsS $P/api/v1/query --data-urlencode 'query=count_over_time(up{job=\"node\"}[25s]) >= 2' | jq -e '.data.result | length > 0'" || true
T=$(curl -fsS "$P/api/v1/query" --data-urlencode 'query=timestamp(up{job="node"})' | jq -r '.data.result[0].value[1] | tonumber | floor')
sleep 16

section "Take a snapshot"
out=$(bash -ec "$(note_block "$NOTE" "Take a snapshot" 1)")
SNAP=$(tail -1 <<<"$out")
assert_match "the snapshot has a name (from the note)" '^[0-9]{8}T[0-9]{6}Z-[0-9a-f]+$' "$SNAP"
check "it is in /prometheus/snapshots/<name>" docker compose exec prometheus test -d "/prometheus/snapshots/$SNAP"
check_output "it holds a block with the head data" 'meta.json' docker compose exec prometheus find "/prometheus/snapshots/$SNAP"
export SNAP
check "copy it out, delete it, tar it (from the note)" bash -ec "$(note_block "$NOTE" "Take a snapshot" 2)"
check_output "the copy has the block" 'meta.json' find "backup/$SNAP"
assert_file "the tarball exists" "prometheus-$SNAP.tar.gz"
check_fails "the snapshot is gone from the data folder" docker compose exec prometheus test -d "/prometheus/snapshots/$SNAP"

section "Restore a snapshot"
# Lose everything: the volume is deleted, a new empty one is created.
docker compose down -v 2>/dev/null
docker compose up -d 2>/dev/null
retry 60 curl -fsS "$P/-/ready" || true
assert_eq "the old data is lost" "[]" "$(q_at 'up{job="node"}' "$T")"
check "stop, replace the data folder, start (from the note)" bash -ec "$(note_block "$NOTE" "Restore a snapshot" 1)"
retry 60 curl -fsS "$P/-/ready" || true
check_output "every file belongs to nobody" '^$' docker compose exec prometheus find /prometheus ! -user nobody
verify=$(note_block "$NOTE" "Restore a snapshot" 2)
retry 30 bash -ec "${verify/-10 minutes/@$T} | grep -q 1" || {
  echo "# diagnostics: up{job=node} around T=$T after the restore"
  curl -s "$P/api/v1/query_range" --data-urlencode 'query=up{job="node"}' --data-urlencode "start=$((T - 300))" \
    --data-urlencode "end=$((T + 300))" --data-urlencode step=15 | jq -c '.data.result[] | [.values[0], .values[-1], (.values | length)]' | sed 's/^/#   /'
  docker compose exec prometheus promtool tsdb list /prometheus | sed 's/^/#   /'
}
check_output "the old data is back (from the note, at the time before the backup)" '^1$' \
  bash -ec "${verify/-10 minutes/@$T}"
check_output "promtool tsdb list shows the block (from the note)" '^[0-9A-Z]{26}' \
  bash -ec "$(note_block "$NOTE" "Restore a snapshot" 3)"

section "Back up the configuration"
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com
check "git init, add, commit (from the note)" bash -ec "$(note_block "$NOTE" "Back up the configuration" 1)"
check_output "the file is in the commit" '^prometheus.yml$' git -C prometheus-config ls-files

section "Backfill old data"
# The note's timestamps are an example. Move them to one day ago: inside the retention,
# and older than the 3 hours of the head block.
t1=$(($(date +%s) - 86400))
t2=$((t1 + 3600))
note_block "$NOTE" "Backfill old data" 1 | sed -e "s/ 1793865600\$/ $t1/" -e "s/ 1793869200\$/ $t2/" >backfill.om
check_output "the file ends with # EOF" '^# EOF$' tail -1 backfill.om
check "promtool create-blocks-from openmetrics, move, restart (from the note)" \
  bash -ec "$(note_block "$NOTE" "Backfill old data" 2)"
retry 60 curl -fsS "$P/-/ready" || true
check_output "the backfilled value is there at its time" '"42"\]' q_at 'backup_test_value{source="backfill"}' "$t1"
check_output "and the second one" '"43"\]' q_at 'backup_test_value{source="backfill"}' "$t2"
check_fails "promtool refuses a file without # EOF" bash -c \
  "head -n -1 backfill.om >bad.om && docker compose cp bad.om prometheus:/tmp/bad.om && docker compose exec prometheus promtool tsdb create-blocks-from openmetrics /tmp/bad.om /tmp/out"
