#!/usr/bin/env bash
# note: kubernetes/mlops/bento-cnpg.md
# env: kind
# timeout: 1500
# Own cluster: the CNPG operator and its CRDs are cluster-wide. Bento runs in a lab pod with a
# small CSV. The Grafana part is not tested.
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/k8s.sh"
# shellcheck source=../../versions.env
source "$NOTES_ROOT/tests/versions.env"

NOTE=kubernetes/mlops/bento-cnpg
cd "$(mktemp -d)"
C=notes-cnpg
kind_cluster "$C"
out=$(kind create cluster --name "$C" --image "$KIND_NODE_IMAGE" 2>&1) || { echo "$out"; kind_diag; exit 1; }
kubectl wait --for=condition=Ready nodes --all --timeout=180s >/dev/null
run() { bash -ec "$1" 2>&1; }
lab() { kubectl exec -i lab -- sh -c "cd /root && $1" 2>&1; }
put() { kubectl exec lab -- sh -c 'printf "%s\n" "$2" >"/root/$1"' _ "$1" "$2"; }
dedent() { awk 'NF{m=match($0,/[^ ]/)-1; if(min==""||m<min)min=m} {l[NR]=$0} END{for(i=1;i<=NR;i++)print substr(l[i],min+1)}'; }
psql() { kubectl exec db-1 -c postgres -- psql -tA -F' ' app -c "$1" 2>&1; }

section "Installing CNPG"
assert_match "the note pins the tested release" "download/v$CNPG_VERSION/cnpg-$CNPG_VERSION.yaml" "$(note_block "$NOTE" 1)"
check "the release manifest (from the note)" run "$(note_block "$NOTE" 1)"
check "the operator is ready" kubectl -n cnpg-system rollout status deploy/cnpg-controller-manager --timeout=300s

section "Provisioning a Postgres cluster"
note_block "$NOTE" 2 >db.yaml
# The operator's webhook may need a few more seconds after the rollout.
check "the minimal manifest (from the note)" retry 60 kubectl apply -f db.yaml
check "the cluster becomes healthy" retry 600 bash -c \
  "kubectl get cluster db -o jsonpath='{.status.phase}' | grep -qx 'Cluster in healthy state'"
# "healthy" can come a moment before db-rw accepts connections.
retry 120 kubectl exec db-1 -c postgres -- pg_isready -q -h db-rw.default -p 5432
check_output "a Secret db-app with a uri field (from the note)" '^postgresql://app:[^@]+@db-rw\.default:5432/app$' bash -c \
  "kubectl get secret db-app -o jsonpath='{.data.uri}' | base64 -d"

section "Creating a table"
URI=$(kubectl get secret db-app -o jsonpath='{.data.uri}' | base64 -d)
# A table created as postgres (the original's way) cannot be written by app.
psql "create table pg_owned (a int)" >/dev/null
check_output "a table created as postgres: app may not insert (the correction)" 'permission denied for table pg_owned' \
  bash -c "kubectl exec db-1 -c postgres -- psql '$URI' -c 'insert into pg_owned values (1)' 2>&1; true"
check "psql as app, with the Secret's uri, runs the note's statement (from the note)" bash -c \
  "$(note_block "$NOTE" 4 | sed 's/ -it / -i /; s/ -- psql / -c postgres -- psql /') -c \"\$1\"" _ "$(note_block "$NOTE" 3 | dedent)"
check_output "the table exists, owned by app" '^cities app$' psql "select tablename, tableowner from pg_tables where tablename='cities'"

section "Configuring Bento to write to SQL"
kubectl run lab --image=alpine:3.22 --env="DSN=$(kubectl get secret db-app -o jsonpath='{.data.uri}' | base64 -d)" -- sleep 3600 >/dev/null
kubectl wait --for=condition=Ready pod/lab --timeout=180s >/dev/null
arch=$(kubectl get node "$C-control-plane" -o jsonpath='{.status.nodeInfo.architecture}')
lab "apk add -q curl >/dev/null && curl -fsSL --max-time 300 https://github.com/warpstreamlabs/bento/releases/download/v$BENTO_VERSION/bento_${BENTO_VERSION}_linux_$arch.tar.gz | tar -xz -C /usr/local/bin bento" >/dev/null || { echo "bento download failed" >&2; exit 1; }
put cities.csv "$(printf 'city,population\n'; for i in $(seq 20); do echo "city-$i,$((i * 1000))"; done)"
put csv2sql.yaml "$(cat <<EOF
input:
  csv:
    paths: ["cities.csv"]
output:
  sql_insert:
    driver: postgres
    dsn: "\${DSN}"
    table: cities
    columns: [city, population]
    args_mapping: root = [ this.city, this.population.number() ]
    init_statement: |
$(note_block "$NOTE" 3 | dedent | sed 's/^/      /')
EOF
)"
# Bento logs a failed insert and still exits 0: fail on an error line.
check "sql_insert, with driver postgres and the Secret's uri as dsn (from the note)" bash -c \
  "$(declare -f lab); out=\$(lab 'timeout 300 bento --config csv2sql.yaml'); echo \"\$out\" | grep -m5 'level=error' && exit 1; true"
check_output "the rows are in PostgreSQL" '^20 210000$' psql "select count(*), sum(population) from cities"
check "init_statement makes it safe to run again (CREATE TABLE IF NOT EXISTS)" lab "timeout 300 bento --config csv2sql.yaml"
check_output "(and the second run adds 20 more rows)" '^40$' psql "select count(*) from cities"
check_output "the dns field of the original does not exist: Bento refuses it (the correction)" 'field dns not recognised|dns' \
  lab "sed 's/dsn:/dns:/' csv2sql.yaml >bad.yaml; bento lint bad.yaml; true"
