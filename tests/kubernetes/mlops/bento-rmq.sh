#!/usr/bin/env bash
# note: kubernetes/mlops/bento-rmq.md
# env: kind
# timeout: 1800
# Own cluster: cert-manager and the RabbitMQ operators are cluster-wide. Bento runs in a lab pod,
# with a small CSV. The Ollama consumer and the KEDA RabbitMQ scaler are not tested.
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/k8s.sh"
# shellcheck source=../../versions.env
source "$NOTES_ROOT/tests/versions.env"

NOTE=kubernetes/mlops/bento-rmq
cd "$(mktemp -d)"
C=notes-rmq
kind_cluster "$C"
kind create cluster --name "$C" --image "$KIND_NODE_IMAGE" >/dev/null 2>&1
kubectl wait --for=condition=Ready nodes --all --timeout=180s >/dev/null
export -f retry
BLB=https://raw.githubusercontent.com/jpetazzo/beyond-load-balancers/main/rabbitmq
run() { bash -ec "$1" 2>&1; }
lab() { kubectl exec -i lab -- sh -c "cd /root && $1" 2>&1; }
dedent() { awk 'NF{m=match($0,/[^ ]/)-1; if(min==""||m<min)min=m} {l[NR]=$0} END{for(i=1;i<=NR;i++)print substr(l[i],min+1)}'; }
put() { kubectl exec lab -- sh -c 'printf "%s\n" "$2" >"/root/$1"' _ "$1" "$2"; }
queue() { kubectl exec mq-server-0 -c rabbitmq -- rabbitmqctl list_queues -q name messages_ready messages_unacknowledged 2>/dev/null | awk '$1=="q1" {print $1, $2, $3}'; }

section "The Bitnami chart no longer works (the correction)"
check_output "its operator image is gone from Docker Hub" 'manifest unknown|not found|no such manifest' bash -c \
  "docker manifest inspect docker.io/bitnami/rabbitmq-cluster-operator:2.16.1-debian-12-r0 2>&1; true"

section "Installing the RabbitMQ operator"
inst=$(note_block "$NOTE" 1)
assert_match "the note pins the tested operator" "cluster-operator/releases/download/$RABBITMQ_OPERATOR_VERSION/" "$inst"
assert_match "and the tested topology operator" "messaging-topology-operator/releases/download/$RABBITMQ_TOPOLOGY_VERSION/" "$inst"
check "the operators, and cert-manager (from the note)" run "$inst"
check "the operators are ready" bash -c \
  "kubectl -n rabbitmq-system wait deploy --all --for=condition=Available --timeout=600s"

section "Deploying a simple RabbitMQ cluster"
check_output "kubectl apply on the whole directory fails without the Prometheus CRDs (the note's remark)" 'no matches for kind "ServiceMonitor"' \
  bash -c "kubectl apply -f $BLB/servicemonitor.yml 2>&1; true"
check "cluster.yml and queue.yml (from the note)" bash -c "kubectl apply -f $BLB/cluster.yml && retry 120 kubectl apply -f $BLB/queue.yml"
check "a RabbitmqCluster called mq (from the note)" retry 600 bash -c \
  "kubectl get rabbitmqcluster mq -o jsonpath='{.status.conditions[?(@.type==\"AllReplicasReady\")].status}' | grep -qx True"
check_output "a Secret mq-default-user with connection_string (from the note)" '^amqp://' bash -c \
  "kubectl get secret mq-default-user -o jsonpath='{.data.connection_string}' | base64 -d"
check "a durable Queue q1 (from the note)" retry 180 bash -c "kubectl get queue q1 -o jsonpath='{.status.conditions[0].status}' | grep -qx True"
check_output "rabbitmqctl list_queues: q1, empty (from the note)" '^q1 0 0$' bash -c "$(declare -f queue); queue"

section "Sending messages to RabbitMQ"
AMQP_URL=$(kubectl get secret mq-default-user -o jsonpath='{.data.connection_string}' | base64 -d)
kubectl run lab --image=alpine:3.22 --env="AMQP_URL=$AMQP_URL" -- sleep 3600 >/dev/null
kubectl wait --for=condition=Ready pod/lab --timeout=180s >/dev/null
arch=$(kubectl get node "$C-control-plane" -o jsonpath='{.status.nodeInfo.architecture}')
lab "apk add -q curl >/dev/null && curl -fsSL --max-time 300 https://github.com/warpstreamlabs/bento/releases/download/v$BENTO_VERSION/bento_${BENTO_VERSION}_linux_$arch.tar.gz | tar -xz -C /usr/local/bin bento" >/dev/null || { echo "bento download failed" >&2; exit 1; }
put cities.csv "$(printf 'city,population\n'; for i in $(seq 20); do echo "city-$i,$i"; done)"
put csv2amqp.yaml "$(printf 'input:\n  csv:\n    paths: ["cities.csv"]\n%s\n' "$(note_block "$NOTE" 2 | dedent)")"
check "the CSV importer with the amqp_0_9 output, and AMQP_URL from the Secret (from the note)" lab "timeout 300 bento --config csv2amqp.yaml"
check_output "the messages are in q1 (from the note)" '^q1 20 0$' bash -c "$(declare -f queue); queue"

section "Acknowledgements"
input=$(note_block "$NOTE" 4 | dedent)
put slow.yaml "$(printf '%s\npipeline:\n  processors:\n    - sleep:\n        duration: 1h\noutput:\n  drop: {}\n' "$input")"
lab "setsid bento --config slow.yaml </dev/null >/dev/null 2>&1 & sleep 1" >/dev/null
check "a slow consumer takes messages: they are unacknowledged, not deleted (from the note)" retry 60 bash -c \
  "$(declare -f queue); queue | awk '\$3>0{ok=1} END{exit !ok}'"
check_output "(nothing is lost: ready + unacknowledged = 20)" '^20$' bash -c "$(declare -f queue); queue | awk '{print \$2+\$3}'"
lab "pkill -9 bento; true" >/dev/null
check "the consumer crashes: its messages are requeued automatically (from the note)" retry 60 bash -c \
  "$(declare -f queue); [ \"\$(queue)\" = 'q1 20 0' ]"
put fast.yaml "$(printf '%s\noutput:\n  stdout: {}\n' "$input")"
out=$(lab "timeout 20 bento --config fast.yaml; true")
check_output "the amqp_0_9 input reads them (from the note)" '^city-1,1$|"city":"city-1"' bash -c "grep -m1 'city-1\\b' <<<\"\$1\"" _ "$out"
check_output "once they reach the output, they are acknowledged and deleted (from the note)" '^q1 0 0$' bash -c "$(declare -f queue); queue"
