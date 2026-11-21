#!/usr/bin/env bash
# note: kubernetes/mlops/bento-intro.md
# env: kind
# timeout: 1200
# The lab shell is a pod (alpine + curl, unzip, redis-cli, httpie, bento), like the course's
# shpod. Part 3 uses a stand-in for Ollama that answers like /api/generate, fast or slow.
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/k8s.sh"
# shellcheck source=../../versions.env
source "$NOTES_ROOT/tests/versions.env"
use_test_namespace

NOTE=kubernetes/mlops/bento-intro
run() { bash -ec "$1" 2>&1; }
# lab CMD: run CMD in the lab shell, in /root.
lab() { kubectl exec -i lab -- bash -c "cd /root && $1" 2>&1; }
# put FILE CONTENT: write CONTENT to /root/FILE in the lab shell (as an argument: stdin was not reliable).
put() { kubectl exec lab -- sh -c 'printf "%s\n" "$2" >"/root/$1"' _ "$1" "$2"; }

kubectl run lab --image=alpine:3.22 -- sleep 3600 >/dev/null
kubectl wait --for=condition=Ready pod/lab --timeout=180s >/dev/null
arch=$(kubectl get pod lab -o jsonpath='{.spec.nodeName}' | xargs kubectl get node -o jsonpath='{.status.nodeInfo.architecture}')
check "the lab shell: curl, unzip (funzip), redis-cli, httpie, bento" kubectl exec lab -- sh -c \
  "apk add -q bash curl unzip redis httpie >/dev/null && curl -fsSL https://github.com/warpstreamlabs/bento/releases/download/v$BENTO_VERSION/bento_${BENTO_VERSION}_linux_$arch.tar.gz | tar -xz -C /usr/local/bin bento"

section "Downloading the data set"
check_output "curl | funzip: a harmless length error (from the note)" 'funzip error: invalid compressed data--length error' lab "$(note_block "$NOTE" 1); true"
check_output "head cities.csv: a CSV with city, population... (from the note)" '^"?city"?,.*"?population"?' lab "$(note_block "$NOTE" 2) | head -1"

section "Creating the Bento configuration"
check "bento create csv//redis_list (from the note)" lab "$(note_block "$NOTE" 3)"
check_output "the generated file has the (required) parameters (from the note)" '# No default \(required\)' lab "cat csv2redis.yaml"
put csv2redis.yaml "$(note_block "$NOTE" 4)"

section "Deploying Redis"
check "kubectl create deployment redis (from the note)" run "$(note_block "$NOTE" 5)"
check "kubectl expose (from the note)" run "$(note_block "$NOTE" 6)"
kubectl rollout status deploy/redis --timeout=180s >/dev/null
retry 60 lab "redis-cli -h redis PING | grep -q PONG"

section "Starting Bento"
out=$(lab "$(note_block "$NOTE" 7)" || true)
for m in 'Input type csv is now active' 'Output type redis_list is now active' 'Pipeline has terminated. Shutting down the service'; do
  check_output "the expected output: $m (from the note)" "$m" echo "$out"
done

section "Checking what's in Redis"
check_output "KEYS * (from the note)" '^cities$' lab "redis-cli -h redis $(note_block "$NOTE" 10 | sed "s/\*/'*'/")"
check_output "LLEN cities: approx. 50000 (from the note)" '^5[0-9]{4}$' lab "redis-cli -h redis $(note_block "$NOTE" 11)"
check_output "LINDEX cities 0: one city, as JSON" '"city":".*"population":' lab "redis-cli -h redis $(note_block "$NOTE" 12)"

section "Fun with Bloblang"
put csv2redis.yaml "$(printf '%s\n%s' "$(note_block "$NOTE" 4)" "$(note_block "$NOTE" 13)")"
check "DEL cities (from the note)" lab "$(note_block "$NOTE" 14)"
out=$(lab "$(note_block "$NOTE" 15)" || true)
check_output "it complains about cities with a decimal point in the population (from the note)" 'level=error .*strconv.ParseInt: parsing .*[0-9]\.0' echo "$out"
check_output "142 cities above 10 million (from the note)" '^142$' lab "$(note_block "$NOTE" 16)"

section "Consume the queue over HTTP"
check_output "bento create redis_list//http_server still writes port 6397 (the note's warning)" 'redis://.*:6397' \
  lab "bento create redis_list//http_server"
put redis2http.yaml "$(note_block "$NOTE" 17)"
# One session: the background bento ends with the kubectl exec that started it.
out=$(timeout 900 bash -c "$(declare -f lab); lab \"\$1\"" _ "$(note_block "$NOTE" 18)
sleep 3
$(note_block "$NOTE" 19 | sed 's/curl /curl --max-time 30 /'); echo; for i in \$(seq 141); do curl -s --max-time 10 http://localhost:4195/nextcity >/dev/null; done; echo code=\$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 http://localhost:4195/nextcity); pkill bento" || true)
check_output "curl /nextcity: one city (from the note)" '"city":"' echo "$out"
check_output "after all the cities, the request waits, then times out" 'code=(000|408|504)' echo "$out"

section "Query our LLM for each city (with a stand-in for Ollama)"
kubectl apply -f - >/dev/null <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata: {name: fake-ollama}
data:
  server.py: |
    import http.server, json, os, time
    class H(http.server.BaseHTTPRequestHandler):
        def do_POST(self):
            req = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            time.sleep(float(os.environ.get("DELAY", "0")))
            city = req["prompt"].split("mayor of ")[1].split("?")[0]
            body = json.dumps({"model": req["model"], "response": "Mayor of " + city, "done": True}).encode()
            self.send_response(200); self.send_header("Content-Type", "application/json"); self.end_headers(); self.wfile.write(body)
    http.server.ThreadingHTTPServer(("", 11434), H).serve_forever()
EOF
kubectl create deployment ollama --image=python:3.13-alpine -- python /app/server.py >/dev/null
kubectl patch deployment ollama --type=json -p '[{"op":"add","path":"/spec/template/spec/volumes","value":[{"name":"app","configMap":{"name":"fake-ollama"}}]},{"op":"add","path":"/spec/template/spec/containers/0/volumeMounts","value":[{"name":"app","mountPath":"/app"}]}]' >/dev/null
kubectl expose deployment ollama --port 11434 >/dev/null
kubectl rollout status deploy/ollama --timeout=180s >/dev/null
put branch.yaml "$(note_block "$NOTE" 24 | sed 's/paths: \["cities.csv"\]/paths: ["three.csv"]/')"
lab "head -4 cities.csv >three.csv" >/dev/null
out=$(lab "timeout 60 bento --config branch.yaml")
check_output "the branch processor adds mayor to the original message (from the note)" '"city":"[^"]+".*"mayor":"Mayor of [^"]+"' echo "$out"
check_output "(three cities in, three out)" '^3$' bash -c "grep -c '\"mayor\"' <<<\"\$1\"" _ "$out"
kubectl set env deployment/ollama DELAY=10 >/dev/null
kubectl rollout status deploy/ollama --timeout=180s >/dev/null
# The old pod can still answer for a moment after the rollout: wait until only the new one is left.
retry 120 bash -c "[ \"\$(kubectl get pods -l app=ollama -o name | wc -l)\" = 1 ]"
out=$(echo "DELAY in the stand-in: $(kubectl exec deploy/ollama -- printenv DELAY)"
  lab "s=\$(date +%s); curl -s -m 30 -d '{\"model\":\"m\",\"prompt\":\"the mayor of X?\"}' http://ollama:11434/api/generate; echo; echo direct request: \$((\$(date +%s)-s))s"
  lab "timeout 60 bento --config branch.yaml")
check_output "a slow model: context deadline exceeded, the http processor's default timeout (from the note)" \
  'context deadline exceeded \(Client.Timeout exceeded while awaiting headers\)' echo "$out"
