#!/usr/bin/env bash
# note: servers/mongodb.md
# env: compose
# timeout: 1500
# MongoDB has no arm64 packages for openSUSE, so this test runs the note's own config
# files and shell commands in the official multi-arch image, on three hosts named as
# in the note. The note is about configuration and the shell, not about packaging.
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/compose.sh"

NOTE=servers/mongodb
MONGO_IMAGE=${MONGO_IMAGE:-mongo:8.0}
cat >compose.yaml <<EOF
services:
$(for h in mongo-01 mongo-02 mongo-03; do printf '  %s:\n    image: %s\n    hostname: %s\n    command: ["sleep", "infinity"]\n    init: true\n' "$h" "$MONGO_IMAGE" "$h"; done)
EOF
docker compose up -d --quiet-pull >/dev/null 2>&1

block() { note_block "$NOTE" "$@"; }
on() { local h=$1; shift; docker compose exec -T "$h" "$@"; }
# put HOST FILE: write stdin to FILE on HOST.
put() { docker compose exec -T "$1" sh -c "cat >'$2'"; }
# sh_on HOST PORT JS: run JS in mongosh on HOST:PORT.
sh_on() { on "$1" mongosh --quiet --port "$2" --eval "$3"; }
# primary PORT: wait until mongo-01 is primary on PORT.
primary() { retry 60 sh_on mongo-01 "$1" 'if (!db.hello().isWritablePrimary) quit(1)'; }

section "Replica set"
for h in mongo-01 mongo-02 mongo-03; do
  on "$h" mkdir -p /opt/mongodb
  block 'Replica set' 1 | put "$h" /etc/mongodb.conf
  check "$h: mongod starts with the INI config and forks (from the note)" on "$h" mongod --config /etc/mongodb.conf
done
check_output "rs.initiate() on the first node (from the note)" 'ok: 1' sh_on mongo-01 27017 "$(block 'Replica set' 3)"
primary 27017
check_fails "rs.add() on a secondary fails: only the primary adds members" \
  sh_on mongo-02 27017 'rs.add("mongo-03:27017")'
check "rs.add() from the primary (from the note)" sh_on mongo-01 27017 "$(block 'Replica set' 4)"
check_output "rs.status() shows three members (from the note)" '^3$' \
  sh_on mongo-01 27017 "$(block 'Replica set' 5).members.length"
check "two of them become SECONDARY" retry 60 sh_on mongo-01 27017 \
  'if (rs.status().members.filter(m => m.stateStr == "SECONDARY").length != 2) quit(1)'
check_fails "adding the node's own address fails (the correction)" sh_on mongo-01 27017 'rs.add("mongo-01:27017")'
# Typographic quotes, as the original had them: U+201C and U+201D.
lq=$'\xe2\x80\x9c' rq=$'\xe2\x80\x9d'
smart="rs.add(${lq}mongo-02:27017${rq})"
check_output "smart quotes are a syntax error (the correction)" 'SyntaxError' \
  bash -c "docker compose exec -T mongo-01 mongosh --quiet --eval '$smart' 2>&1; true"
check_fails "there is no legacy mongo shell" on mongo-01 sh -c 'command -v mongo'
check "mongosh is there" on mongo-01 sh -c 'command -v mongosh'
# The YAML form: restart the third node with it.
sh_on mongo-03 27017 'db.getSiblingDB("admin").shutdownServer()' >/dev/null 2>&1 || true
sleep 3
block 'Replica set' 2 | put mongo-03 /etc/mongodb.yaml
check "mongo-03 restarts with the YAML config (from the note)" on mongo-03 mongod --config /etc/mongodb.yaml
check "and is a SECONDARY again" retry 60 sh_on mongo-03 27017 'if (!db.hello().secondary) quit(1)'
for h in mongo-01 mongo-02 mongo-03; do
  sh_on "$h" 27017 'db.getSiblingDB("admin").shutdownServer({force: true})' >/dev/null 2>&1 || true
done
sleep 3
for h in mongo-01 mongo-02 mongo-03; do on "$h" rm -rf /opt/mongodb /var/log/mongodb.log; done

section "Config server"
on mongo-01 mkdir -p /opt/configdb
block 'Config server' 1 | grep -v '^replSet' | put mongo-01 /etc/orig.conf
check_output "the original config, with no replSet, does not start (the correction)" \
  'Cannot start a configsvr as a standalone server' \
  bash -c 'docker compose exec -T mongo-01 mongod --config /etc/orig.conf 2>&1; true'
for h in mongo-01 mongo-02 mongo-03; do
  on "$h" mkdir -p /opt/configdb /opt/mongodb
  block 'Config server' 1 | put "$h" /etc/mongodb_config.conf
  check "$h: the config server starts (from the note)" on "$h" mongod --config /etc/mongodb_config.conf
done
check_output "initiate the config server replica set (from the note)" 'ok: 1' \
  sh_on mongo-01 27019 "$(block 'Config server' 2)"
primary 27019

section "Shard"
for h in mongo-01 mongo-02 mongo-03; do
  block '### Shard' 1 | put "$h" /etc/mongodb_shard.conf
  check "$h: the shard server starts (from the note)" on "$h" mongod --config /etc/mongodb_shard.conf
done
check_output "initiate the shard's replica set (from the note)" 'ok: 1' sh_on mongo-01 27018 "$(block '### Shard' 2)"
primary 27018

section "mongos"
block 'mongos' 1 | put mongo-01 /etc/mongodb_mongos.conf
check "mongos starts on 27017 with configdb csrs/... (from the note)" on mongo-01 mongos --config /etc/mongodb_mongos.conf
check_output "a client on 27017 talks to mongos" 'isdbgrid' sh_on mongo-01 27017 'db.hello().msg'

section "Adding the shard's replica set to the cluster"
check "sh.addShard, sh.enableSharding, sh.status (from the note)" \
  sh_on mongo-01 27017 "$(block 'Adding the shard' 1)"
check_output "the shard is listed" 'rs0/mongo-01:27018,mongo-02:27018,mongo-03:27018' \
  sh_on mongo-01 27017 'JSON.stringify(db.adminCommand({listShards: 1}).shards)'
check "sh.shardCollection with a hashed key (from the note)" sh_on mongo-01 27017 "$(block 'Adding the shard' 2)"
check_output "the collection is sharded" 'userId' \
  sh_on mongo-01 27017 'JSON.stringify(db.getSiblingDB("config").collections.findOne({_id: "database_name.collection_name"}).key)'
check "rs.reconfig() on the shard's primary (from the note)" sh_on mongo-01 27018 "$(block 'Adding the shard' 4)"
check_output "the member's host is as set" 'mongo-01:27018' sh_on mongo-01 27018 'rs.conf().members[0].host'

section "The balancer"
check_output "sh.getBalancerState() (from the note)" '^true$' sh_on mongo-01 27017 "$(block 'The balancer' 1)"
check_output "sh.isBalancerRunning() (from the note)" 'mode' sh_on mongo-01 27017 "JSON.stringify($(block 'The balancer' 2))"
check "sh.stopBalancer() (from the note)" sh_on mongo-01 27017 "$(block 'The balancer' 3 | sed -n 2p)"
check_output "the balancer is off" '^false$' sh_on mongo-01 27017 'sh.getBalancerState()'
check "sh.startBalancer() (from the note)" sh_on mongo-01 27017 "$(block 'The balancer' 3 | sed -n 1p)"
check_output "the balancer is on" '^true$' sh_on mongo-01 27017 'sh.getBalancerState()'
check "sh.enableBalancing / sh.disableBalancing on a collection (from the note)" sh_on mongo-01 27017 \
  "$(block 'The balancer' 4 | sed 's/db_name.collection_name/database_name.collection_name/g')"
check_output "noBalance is set on the collection" '^true$' \
  sh_on mongo-01 27017 'db.getSiblingDB("config").collections.findOne({_id: "database_name.collection_name"}).noBalance'

section "Changing the chunk size"
block 'Changing the chunk size' 1 >chunk.js
check "use config, then updateOne with upsert (from the note)" \
  bash -c 'docker compose exec -T mongo-01 mongosh --quiet --port 27017 <chunk.js'
check_output "config.settings has the chunk size" '^32$' \
  sh_on mongo-01 27017 'db.getSiblingDB("config").settings.findOne({_id: "chunksize"}).value'
check_output "mongosh has no save() (the correction)" 'save is not a function' \
  bash -c "docker compose exec -T mongo-01 mongosh --quiet --port 27017 --eval 'db.getSiblingDB(\"config\").settings.save({_id: \"chunksize\", value: 16})' 2>&1; true"
check "configureCollectionBalancing sets a chunk size for one collection (as the note says)" \
  sh_on mongo-01 27017 'db.adminCommand({configureCollectionBalancing: "database_name.collection_name", chunkSize: 64})'
