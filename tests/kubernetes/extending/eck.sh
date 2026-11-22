#!/usr/bin/env bash
# note: kubernetes/extending/eck.md
# env: kind
# timeout: 3600
# Own cluster: ECK installs CRDs, a webhook and a cluster-wide operator. curl runs in a
# pod (ClusterIPs answer only in the cluster). Filebeat and Cerebro are not tested.
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/k8s.sh"
# shellcheck source=../../versions.env
source "$NOTES_ROOT/tests/versions.env"

NOTE=kubernetes/extending/eck
UPSTREAM=https://raw.githubusercontent.com/jpetazzo/container.training/565636291ec03abf1f2ab8bf6b935478e00e69a2
cd "$(mktemp -d)"
C=notes-eck
kind_cluster "$C"
printf 'kind: Cluster\napiVersion: kind.x-k8s.io/v1alpha4\nnodes: [{role: control-plane}, {role: worker}, {role: worker}, {role: worker}]\n' >kind.yaml
out=$(kind create cluster --name "$C" --image "$KIND_NODE_IMAGE" --config kind.yaml 2>&1) || { echo "$out"; kind_diag; exit 1; }
kubectl wait --for=condition=Ready nodes --all --timeout=180s >/dev/null
# run BLOCK: as the reader copies it, without the list indentation (the heredocs need it).
run() { bash -ec "$(dedent <<<"$1")" 2>&1; }
dedent() { awk 'NF{m=match($0,/[^ ]/)-1; if(min==""||m<min)min=m} {l[NR]=$0} END{for(i=1;i<=NR;i++)print substr(l[i],min+1)}'; }
# incluster CMD: run CMD in a curl pod, with CLUSTERIP and PASSWORD set.
# timeout: on a slow CI runner, kubectl run -i once never attached and hung the test.
incluster() {
  timeout 180 kubectl -n eck-demo run "curl-$RANDOM" --rm -i --restart=Never --quiet --image=curlimages/curl:8.17.0 \
    --env="CLUSTERIP=$CLUSTERIP" --env="PASSWORD=${PASSWORD:-}" --command -- sh -c "$1" 2>&1
}

section "The original files no longer work (the warning)"
check_output "the upstream eck-operator.yaml has v1beta1 CRDs" 'kind: CustomResourceDefinition' bash -c \
  "curl -fsSL $UPSTREAM/k8s/eck-operator.yaml | grep -A1 '^apiVersion: apiextensions.k8s.io/v1beta1'"
check_output "so the API server refuses it" 'no matches for kind "CustomResourceDefinition" in version "apiextensions.k8s.io/v1beta1"' \
  bash -c "kubectl apply --dry-run=server -f $UPSTREAM/k8s/eck-operator.yaml 2>&1; true"

section "Persistent Volume provisioner and default StorageClass"
check "install the local path provisioner (from the note)" run "$(note_block "$NOTE" 2)"
check_output "the local-path StorageClass is there (from the note)" '^local-path ' run "$(note_block "$NOTE" 3)"
check "annotate it as the default (from the note)" run "$(note_block "$NOTE" 4)"
check_output "(default) next to its name (from the note)" '^local-path \(default\) ' run "$(note_block "$NOTE" 5)"
kubectl -n local-path-storage rollout status deploy/local-path-provisioner --timeout=180s >/dev/null

section "Install the ElasticSearch operator"
assert_match "the note pins the tested ECK" "eck/$ECK_VERSION/crds.yaml" "$(note_block "$NOTE" 6)"
check "kubectl create the CRDs, apply the operator (from the note)" run "$(note_block "$NOTE" 6)"
check "the operator StatefulSet is ready (from the note)" kubectl -n elastic-system rollout status sts/elastic-operator --timeout=300s
check_output "a ValidatingWebhookConfiguration (from the note)" '^elastic-webhook.k8s.elastic.co ' kubectl get validatingwebhookconfigurations
check_output "CRDs for Elasticsearch, Kibana, APM, Beats, Agent, Logstash (from the note)" \
  'agents.agent.*apmservers.apm.*beats.beat.*elasticsearches.elasticsearch.*kibanas.kibana.*logstashes.logstash' \
  bash -c "$(note_block "$NOTE" 7) | grep k8s.elastic.co | sort | tr '\n' ' '"

section "Create an ElasticSearch resource"
check "create the eck-demo namespace (from the note)" run "$(note_block "$NOTE" 8)"
check "switch to it (from the note)" run "$(note_block "$NOTE" 9)"
assert_match "the note pins the tested Elasticsearch" "version: $ELASTIC_STACK_VERSION" "$(note_block "$NOTE" 10)"
check "the Elasticsearch resource (from the note)" run "$(note_block "$NOTE" 10)"
check "the operator reports green, through the CRD (from the note)" retry 900 bash -c \
  "[ \"\$(kubectl get es demo -o jsonpath='{.status.health}/{.status.phase}')\" = green/Ready ]"
check_output "kubectl get es (from the note)" "^demo +green +1 +$ELASTIC_STACK_VERSION +Ready" bash -c "timeout 5 $(note_block "$NOTE" 12) 2>/dev/null | tail -1; true"
check_output "the operator pod matches stern's 'operator' query (from the note)" '^elastic-operator-0$' \
  kubectl -n elastic-system get pods -o jsonpath='{.items[*].metadata.name}'

section "Connecting to our cluster"
CLUSTERIP=$(bash -c "{ $(note_block "$NOTE" 13)
} >/dev/null; echo \$CLUSTERIP")
check_output "CLUSTERIP of demo-es-http (from the note)" '^10\.[0-9.]+$' echo "$CLUSTERIP"
check_output "curl without credentials: an authentication error (from the note)" '"type":"security_exception".*"status":401' \
  incluster "$(note_block "$NOTE" 14)"
PASSWORD=$(bash -c "$(note_block "$NOTE" 15); echo \$PASSWORD")
check_output "the elastic user's password, from the Secret (from the note)" '^[A-Za-z0-9]{16,}$' echo "$PASSWORD"
check_output "curl -u elastic:\$PASSWORD: You Know, for Search (from the note)" '"tagline" : "You Know, for Search"' \
  incluster "$(note_block "$NOTE" 16)"

section "Deploying an instance of Kibana"
check "the Kibana resource (from the note)" run "$(note_block "$NOTE" 20)"
check "Kibana becomes green" retry 900 bash -c "[ \"\$(kubectl get kibana demo -o jsonpath='{.status.health}')\" = green ]"
check_output "on a NodePort (from the note)" '^demo-kb-http +NodePort ' kubectl get services demo-kb-http
# Kibana reports green a little before /api/status answers 200.
check_output "it connects to Elasticsearch, and asks for the same user/password (from the note)" '^200$' \
  retry_out 40 incluster "curl -s -m 10 -o /dev/null -w '%{http_code}\n' -u elastic:\$PASSWORD http://demo-kb-http:5601/api/status | grep -x 200"

section "Scaling up the cluster"
kubectl patch es demo --type=json -p '[{"op":"replace","path":"/spec/nodeSets/0/count","value":3}]' >/dev/null
check "count: 3 gives three Elasticsearch nodes (as kubectl edit in the note)" retry 900 bash -c \
  "[ \"\$(kubectl get es demo -o jsonpath='{.status.availableNodes}/{.status.health}')\" = 3/green ]"
check_output "_cat/health: 3 nodes, green" ' green +3 +3 ' retry_out 5 incluster "curl -s -u elastic:\$PASSWORD http://\$CLUSTERIP:9200/_cat/health"
