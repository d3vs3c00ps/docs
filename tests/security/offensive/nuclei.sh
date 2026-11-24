#!/usr/bin/env bash
# note: security/offensive/nuclei.md
# env: compose
# timeout: 1200
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/compose.sh"

NOTE=security/offensive/nuclei
# The Docker Hub images through Google's mirror: test runs share the anonymous pull limit.
NUCLEI_IMAGE=mirror.gcr.io/projectdiscovery/nuclei:v3.11.1
GIT_IMAGE=mirror.gcr.io/alpine/git:v2.49.1
TEMPLATES_VERSION=v10.5.1
# The community templates hold exploit payloads that the host's antivirus deletes. They
# stay in a named volume, never on a host path, and the volume is removed at the end.
VOL=notes-nuclei-templates-$COMPOSE_PROJECT_NAME
trap 'rc=$?; docker volume rm -f "$VOL" >/dev/null 2>&1 || true; _t_finish "$rc"' EXIT

# Targets on the project's private network, and nothing else. Dotted aliases: with
# single-label names, nuclei 3.11 sent the requests for both targets to one of them.
# an nginx that exposes
# its .git directory, an nginx that answers 200 for any path (a soft 404), and a Go
# server that imports net/http/pprof.
mkdir -p web/.git home
printf '[core]\n\trepositoryformatversion = 0\n\tbare = false\n[remote "origin"]\n\turl = https://example.com/app.git\n' >web/.git/config
echo '<h1>app</h1>' >web/index.html
echo '{"name": "app", "version": "1.2.3"}' >web/version.json
printf 'server {\n  listen 80;\n  root /usr/share/nginx/html;\n  location / { try_files $uri /index.html; }\n}\n' >soft404.conf
cat >main.go <<'EOF'
package main

import (
	"net/http"
	_ "net/http/pprof"
)

func main() { _ = http.ListenAndServe(":8080", nil) }
EOF
cat >compose.yaml <<EOF
services:
  web:
    image: mirror.gcr.io/library/nginx:1.29-alpine
    volumes: ["./web:/usr/share/nginx/html:ro"]
    networks: {default: {aliases: [web.test]}}
  clean:
    image: mirror.gcr.io/library/nginx:1.29-alpine
    volumes: ["./soft404.conf:/etc/nginx/conf.d/default.conf:ro"]
    networks: {default: {aliases: [clean.test]}}
  pprof:
    image: mirror.gcr.io/library/golang:1.27
    working_dir: /src
    volumes: ["./main.go:/src/main.go:ro"]
    command: go run main.go
  nuclei:
    image: $NUCLEI_IMAGE
    working_dir: /w
    volumes: [".:/w", "./home:/root"]
    # Use only the templates the test installs, never a download.
    environment: [DISABLE_NUCLEI_TEMPLATES_PUBLIC_DOWNLOAD=true]
    profiles: [tools]
EOF
# The other scans use this hand-written stand-in for the community git-config template,
# installed where nuclei looks for its default templates.
mkdir -p home/nuclei-templates/http
cat >home/nuclei-templates/http/git-config.yaml <<'EOF'
id: git-config
info:
  name: Git Configuration - Detect
  author: notes-test
  severity: medium
  tags: exposure,config,git,misconfig
http:
  - method: GET
    path:
      - "{{BaseURL}}/.git/config"
    matchers-condition: and
    matchers:
      - type: word
        words:
          - "[core]"
      - type: status
        status:
          - 200
EOF
docker compose up -d --quiet-pull web clean pprof 2>/dev/null
# Every scan from the test: no update check, no public interactsh server (-ni), and no
# DNS or WHOIS templates, which would query resolvers and servers on the internet.
# timeout: a two-target scan sometimes hangs after its last request (nuclei 3.11.1).
nuclei() { timeout 120 docker compose --progress quiet run --rm -T nuclei "$@" -duc -ni -ept dns,whois -nc; }
export -f nuclei
# url LINE: a note's command line, pointed at the test's targets.
url() { sed -e 's|https://staging.example.com|http://web.test|g' -e 's|https://prod.example.com|http://web.test|g'; }
retry 120 docker compose exec -T web wget -qO- http://pprof:8080/debug/pprof/
# With two targets, nuclei 3.11.1 now and then sends both requests over one connection
# and reports errors instead of findings, or hangs (about 1 run in 5 here). Scans of a
# target list get up to five tries; a real miss still fails.
five_tries() { local re=$1 out i; shift; for i in 1 2 3 4 5; do out=$("$@" 2>&1) && grep -Eq -- "$re" <<<"$out" && break; done; printf '%s\n' "$out"; }

section "Installation"
check_output "the pinned image is v3" 'v3\.11\.1' bash -c 'nuclei -version 2>&1'
check_output "-update-templates exists" '\-update-templates' bash -c 'nuclei -h 2>&1'
skip "nuclei -update-templates" "downloads through the GitHub API, which rate-limits shared test hosts; the test clones a pinned release instead (Template trust)"

section "Template trust"
docker volume create "$VOL" >/dev/null
clone=$(note_block "$NOTE" 'Template trust' 1 | grep -v '^nuclei' | grep -v '^#' | sed "s/v10\.5\.1/$TEMPLATES_VERSION/")
check "clone a pinned template release, in a volume (from the note)" \
  docker run --rm -v "$VOL:/w" -w /w --entrypoint sh "$GIT_IMAGE" -ec "$clone"
# nuclei with the volume, on the project's network, so it reaches the test's targets only.
nuclei_vol() { docker compose --progress quiet run --rm -T -v "$VOL:/w" nuclei "$@" -duc -ni -ept dns,whois -nc; }
export VOL
export -f nuclei_vol
total=$(nuclei_vol -t /w/reviewed-templates/ -tl 2>/dev/null | wc -l)
assert_match "the release has thousands of templates (about 13,700)" '^ *1[3-4][0-9]{3}$' "$total"
# "Review, delete what you do not want": keep only the exposure templates.
docker run --rm -v "$VOL:/w" -w /w/reviewed-templates --entrypoint sh "$GIT_IMAGE" -ec \
  'find . -mindepth 1 -maxdepth 1 ! -name http ! -name helpers -exec rm -rf {} +; find http -mindepth 1 -maxdepth 1 ! -name exposures -exec rm -rf {} +'
# The first scan can start before Docker DNS knows web.test: same retry as the scans below.
out=$(five_tries 'git-config.*http://web.test/\.git/config' bash -ec "$(note_block "$NOTE" 'Template trust' 1 | grep '^nuclei' | url | sed -e 's|\./reviewed-templates/|/w/reviewed-templates/|' -e 's|^nuclei|nuclei_vol|')")
assert_match "nuclei -t on the reviewed set (from the note)" 'git-config.*http://web.test/\.git/config' "$out"

section "Installation (template count)"
check_output "nuclei -tl | wc -l counts the installed templates (from the note)" '^ *[1-9][0-9]*$' \
  bash -ec "$(note_block "$NOTE" Installation 2 | grep -- '-tl')"

section "Basic use"
basic() { note_block "$NOTE" 'Basic use' 1 | sed -n "${1}p" | url; }
check_output "nuclei -u finds the exposed .git (from the note)" '\[git-config\].*\[medium\]' bash -ec "$(basic 1)"
printf 'http://web.test\nhttp://clean.test\n' >targets.txt
out=$(five_tries 'git-config.*http://web.test/' bash -ec "$(basic 2) 2>/dev/null")
assert_match "nuclei -l scans every target in the file (from the note)" 'git-config.*http://web.test/' "$out"
assert_no_match "and the clean nginx has no .git finding" 'git-config.*http://clean.test' "$out"
out=$(bash -c "$(basic 3) -silent 2>&1" || true)
assert_no_match "-severity critical,high leaves out the medium finding (from the note)" 'git-config' "$out"
check_output "-tags cve,exposure (from the note)" 'git-config' bash -ec "$(basic 4)"
check "-o results.txt -j (from the note)" bash -ec "$(basic 5)"
check_output "writes JSON lines with template-id and info.name" '^git-config: Git Configuration' \
  jq -r '.["template-id"] + ": " + .info.name' results.txt

section "Rate limiting"
check_output "the rate-limited run (from the note)" 'git-config' \
  five_tries git-config bash -ec "$(note_block "$NOTE" 'Rate limiting' 1)"
help=$(nuclei -h 2>&1)
assert_match "default -rate-limit is 150" 'rate-limit int .*\(default 150\)' "$help"
assert_match "default -c is 25" 'concurrency int .*\(default 25\)' "$help"
assert_match "default -bulk-size is 25" 'bulk-size int .*\(default 25\)' "$help"
assert_match "default -timeout is 10 seconds" 'timeout int .*seconds.*\(default 10\)' "$help"

section "As a CI gate"
gate() { note_block "$NOTE" 'As a CI gate' 1 | sed -n '/run: |/,$p' | sed 1d | sed 's/^    //' | url; }
out=$(bash -c "$(gate)" 2>/dev/null) && rc=0 || rc=$?
assert_eq "the gate fails on the exposed .git (from the note)" 1 "$rc"
assert_match "and prints the finding with jq" '^git-config: Git Configuration' "$out"
rm -f nuclei.json
out=$(bash -c "$(gate | sed 's|http://web.test|http://clean.test|')" 2>/dev/null) && rc=0 || rc=$?
assert_eq "it passes on a clean server" 0 "$rc"

section "Writing a template"
mkdir -p templates
note_block "$NOTE" 'Writing a template' 1 >templates/internal-debug-endpoint.yaml
tpl() { note_block "$NOTE" 'Writing a template' 2 | sed -n "${1}p" | url; }
check "nuclei -validate (from the note)" bash -ec "$(tpl 2)"
check_output "the template finds pprof on the Go server (from the note)" '\[internal-debug-endpoint\].*\[high\]' \
  bash -ec "$(tpl 1 | sed 's|http://web.test|http://pprof:8080|')"
check_output "and nothing on a soft-404 server (200 for any path)" '^$' \
  bash -ec "$(tpl 1 | sed 's|http://web.test|http://clean.test|') -silent"
sed '/- type: word/,$d' templates/internal-debug-endpoint.yaml >templates/status-only.yaml
check_output "a status: 200 matcher alone matches the soft 404 (as the note warns)" 'status-only|internal-debug-endpoint' \
  nuclei -u http://clean.test -t templates/status-only.yaml -silent
{ note_block "$NOTE" 'Writing a template' 1 | sed -e 's/internal-debug-endpoint/version-extract/' \
    -e 's|/debug/pprof/|/version.json|' -e '/- type: word/,$d' -e 's/matchers-condition: and//'
  note_block "$NOTE" 'Extractors' 1
} >templates/version.yaml
check "the extractor fits under the request (from the note)" nuclei -validate -t templates/version.yaml
check_output "and pulls the version out" '\[version-extract\].*\["1\.2\.3"\]' nuclei -u http://web.test -t templates/version.yaml

section "Out-of-band detection"
note_block "$NOTE" 'Out-of-band detection' 1 | sed '1i id: oob-test\ninfo:\n  name: OOB test\n  author: test\n  severity: info' >templates/oob.yaml
check "the interactsh template is valid (from the note)" nuclei -validate -t templates/oob.yaml
check_output "the default interactsh servers are public oast.* hosts" 'default: oast\.pro,oast\.live' bash -c 'nuclei -h 2>&1'
out=$(nuclei -u http://web.test -t templates/oob.yaml 2>&1 || true)
assert_no_match "-ni: the OAST template sends no request" 'HTTP connections: [1-9]' "$out"
check "nuclei -ni (from the note)" bash -ec "$(note_block "$NOTE" 'Out-of-band detection' 2 | grep -- ' -ni$' | url)"
skip "-iserver with your own server" "needs a self-hosted interactsh server; oast.example.com is a placeholder"
