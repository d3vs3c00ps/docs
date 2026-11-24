#!/usr/bin/env bash
# note: dev/taskfile/troubleshooting.md
# env: task
source "$NOTES_ROOT/tests/lib/assert.sh"

NOTE=dev/taskfile/troubleshooting
block() { note_block "$NOTE" "$@"; }
newdir() { cd "$(mktemp -d)"; }
rc() { "$@" >/dev/null 2>&1 && echo 0 || echo $?; }

section "See what Task does"
newdir
block 'See what Task does' 1 >Taskfile.yml
out=$(task deploy 2>&1) && r=0 || r=$?
assert_eq "no deploy.conf: exit 0" 0 "$r"
assert_eq "and no output" "" "$out"
assert_eq "task -v deploy prints the note's two lines" "$(block 'See what Task does' 2)" "$(task -v deploy 2>&1)"
check_output "-n with no deploy.conf: the if: check still runs, nothing shown" '^$' bash -c 'task -n deploy 2>&1'
touch deploy.conf
assert_eq "-n with deploy.conf: the command as the note shows" 'task: [deploy] echo "deploying main"' "$(task -n deploy 2>&1)"
sed -i 's/sh: echo main/sh: echo main >>sh-ran.log; echo main/' Taskfile.yml
task -n deploy >/dev/null 2>&1
assert_file "-n still runs the sh: variables" sh-ran.log
printf 'version: "3"\ntasks:\n  st:\n    status: [touch status-ran]\n    cmds: [touch cmd-ran]\n  pre:\n    preconditions: [touch pre-ran]\n    cmds: [touch cmd-ran]\n' >checks.yml
task -t checks.yml -n st >/dev/null 2>&1 && task -t checks.yml -n pre >/dev/null 2>&1
assert_file "-n runs status checks" status-ran
assert_file "-n runs preconditions" pre-ran
assert_no_file "-n does not run cmds" cmd-ran
check_output "--summary shows vars and commands" 'commands:' task --summary deploy
printf 'version: "3"\ntasks:\n  s:\n    status: ["false"]\n    cmds: [echo s]\n' >st.yml
check_output "-v prints each status check" 'status command false exited non-zero' bash -c 'task -v -t st.yml s 2>&1'
check_output "-v prints why a command is skipped for the platform" 'not for current platform - ignored' \
  bash -c 'printf "version: \"3\"\ntasks:\n  p:\n    cmds:\n      - cmd: echo w\n        platforms: [windows]\n" >p.yml && task -v -t p.yml p 2>&1'
check_output "--list-all shows include namespaces" '\* inc:x' \
  bash -c 'mkdir -p inc && printf "version: \"3\"\ntasks:\n  x: echo x\n" >inc/Taskfile.yml && printf "version: \"3\"\nincludes:\n  inc: ./inc\n" >i.yml && task -t i.yml --list-all'

section "A task never runs"
newdir
block 'A task never runs' 1 >Taskfile.yml
printf 'a,b\n1,2\n' >data.csv
mapfile -t L < <(block 'A task never runs' 2 | sed 's/ *#.*//')
check_output "1: runs" 'gzip -kf data.csv' bash -c "${L[0]}"
check_output "2: up to date" 'task: Task "build" is up to date' bash -c "${L[1]}"
check_output "3: touch: still up to date" 'is up to date' bash -c "${L[2]}"
check_output "4: --force runs" 'gzip -kf' bash -c "${L[3]}"
check_output "5: rm -rf .task runs" 'gzip -kf' bash -c "${L[4]}"
assert_file "the checksum is in .task/checksum/build" .task/checksum/build
echo broken >data.csv.gz
check_output "an edited output is not seen" 'is up to date' task build
printf 'version: "3"\ntasks:\n  build:\n    sources: [in.txt]\n    cmds: ["echo build {{.MODE}}"]\n' >modes.yml
echo x >in.txt
task -t modes.yml build MODE=a >/dev/null 2>&1
check_output "MODE=b after MODE=a: up to date (one checksum per task)" 'is up to date' task -t modes.yml build MODE=b
printf 'version: "3"\ntasks:\n  build:\n    label: "build-{{.MODE}}"\n    sources: [in.txt]\n    cmds: ["echo build {{.MODE}}"]\n' >label.yml
task -t label.yml build MODE=a >/dev/null 2>&1
check_output "with label: build-{{.MODE}}, MODE=b runs" 'build b' task -t label.yml build MODE=b
printf 'version: "3"\ntasks:\n  j:\n    sources: [in.txt]\n    cmds: [echo j-ran]\n' >json.yml
rm -rf .task
task -t json.yml --list-all --json >/dev/null
check_output "the --json bug: j never ran, but is up to date" 'is up to date' task -t json.yml j
rm -rf .task
task -t json.yml --list-all --json --no-status >/dev/null
check_output "with --no-status, j runs" 'j-ran' task -t json.yml j
printf 'version: "3"\ntasks:\n  none:\n    sources: [nothing/*.c]\n    cmds: [echo none-ran]\n' >glob.yml
check_output "a sources glob that matches nothing: first run" 'none-ran' task -t glob.yml none
check_output "then up to date for ever" 'is up to date' task -t glob.yml none

section "A task always runs"
newdir
echo x >in.txt
printf 'version: "3"\ntasks:\n  p: echo phony\n  typo:\n    sources: [in.txt]\n    generates: [ou.txt]\n    cmds: [cp in.txt out.txt]\n  failing:\n    status: ["false"]\n    cmds: [echo failing-ran]\n' >Taskfile.yml
task p >/dev/null 2>&1
check_output "no sources, no status: runs every time" 'phony' task p
task typo >/dev/null 2>&1
check_output "a generates path that is never created: runs every time" 'cp in.txt' task typo
task failing >/dev/null 2>&1
check_output "a status command that fails: runs every time" 'failing-ran' task failing

section "The shell is not bash"
newdir
cat >Taskfile.yml <<'EOF'
version: "3"
tasks:
  multi:
    cmds:
      - |
        false
        echo after
  flags: 'echo "flags=$-"'
  or: 'false || true; echo after-or'
  plus: 'set +e; false; echo "after rc=$?"'
  pipe: 'false | true'
  pipefail:
    set: [pipefail]
    cmds: ['false | true']
  arr: 'a=(one two three); echo "arr=${a[1]} n=${#a[@]}"'
  assoc: 'declare -A m; m[k]=v; echo "assoc=${m[k]}"'
  regex: '[[ abc123 =~ ^[a-z]+([0-9]+)$ ]] && echo "re=${BASH_REMATCH[1]}"'
  procsub: 'cat <(echo procsub-ok)'
  readarr: 'mapfile -t L < <(printf "x\ny\n"); read -ra W <<< "p q r"; echo "m=${#L[@]} r=${W[2]}"'
  local: 'trap "echo trapped" EXIT; f() { local v=1; echo "local=$v"; }; f'
  random: 'echo "rand=$RANDOM"'
  expand: "S=abcdef; n=S; echo \"up=${S^^} sub=${S:1:3} ind=${!n}\" $'a\\tb'"
  misc: 'echo X=1 > s.sh; source ./s.sh; echo "src=$X"; pushd / >/dev/null && echo pushd-ok; set -x; echo traced'
  alias: 'alias ll="ls -l"; ll /'
  coproc: 'coproc cat'
  select: 'select x in a b; do break; done </dev/null'
  autocd: 'shopt -s autocd'
  empty: 'false | true; echo "bv=[$BASH_VERSION] ps=[${PIPESTATUS[0]}]"'
  glob: 'echo **/*.go'
  globstar:
    shopt: [globstar]
    cmds: ['echo **/*.go']
  export:
    cmds:
      - export FOO=bar
      - echo "foo=[$FOO]"
EOF
mkdir -p g/h && touch g/h/f.go
run() { task -s "$1" 2>&1 | tr '\n' ' '; echo "rc=${PIPESTATUS[0]}"; }
assert_match "set -e: the first failing line stops a multi-line command" '^task: Failed to run task "multi": exit status 1 rc=201$' "$(run multi)"
assert_match "errexit is on: \$- contains e" 'flags=[a-z]*e' "$(run flags)"
assert_match "false || true goes on" 'after-or' "$(run or)"
assert_match "set +e turns it off" 'after rc=1 ' "$(run plus)"
assert_match "pipefail is off: false | true succeeds" '^rc=0$' "$(run pipe)"
assert_match "set: [pipefail] turns it on" 'rc=201' "$(run pipefail)"
assert_match "arrays" 'arr=two n=3' "$(run arr)"
assert_match "declare -A" 'assoc=v' "$(run assoc)"
assert_match "[[ ]] and =~ with BASH_REMATCH" 're=123' "$(run regex)"
assert_match "process substitution" 'procsub-ok' "$(run procsub)"
assert_match "here-string, mapfile, read -ra" 'm=2 r=r' "$(run readarr)"
assert_match "local, trap" 'local=1 trapped' "$(run local)"
assert_match "\$RANDOM" 'rand=[0-9]+' "$(run random)"
assert_match "\${v^^}, \${v:1:3}, \${!name}, \$'\\t'" 'up=ABCDEF sub=bcd ind=abcdef a	b' "$(run expand)"
assert_match "source, pushd, set -x" 'src=1 pushd-ok \+ echo traced traced' "$(run misc)"
assert_match "alias fails" 'executable file not found.*rc=201' "$(run alias)"
assert_match "coproc fails" 'unhandled command node.*rc=201' "$(run coproc)"
assert_match "select fails" 'rc=201' "$(run select)"
assert_match "shopt -s autocd fails" 'unsupported option.*rc=201' "$(run autocd)"
assert_match "BASH_VERSION and PIPESTATUS are empty" 'bv=\[\] ps=\[\]' "$(run empty)"
assert_match "** is literal without globstar" '^\*\*/\*\.go rc=0$' "$(run glob)"
assert_match "shopt: [globstar] makes it recursive" '^g/h/f\.go rc=0$' "$(run globstar)"
assert_match "each cmds entry is a new shell: export is lost" 'foo=\[\]' "$(run export)"
block 'The shell is not bash' 1 >Taskfile.yml
assert_eq "printf -v: wrong in Task, right in bash -c (the note's output)" "$(block 'The shell is not bash' 2)" "$(task -s versions 2>&1)"

section "YAML and quoting traps"
newdir
yml() { printf 'version: "3"\nvars:\n  CMD: echo\n  V: x\ntasks:\n%s\n' "$1" >Taskfile.yml; rc task t; }
assert_eq "- {{.CMD}} build: YAML parse error, 109" 109 "$(yml '  t:
    cmds:
      - {{.CMD}} build')"
assert_eq "cmds: [echo \"{{.V}}\"]: YAML parse error, 109" 109 "$(yml '  t:
    cmds: [echo "{{.V}}"]')"
assert_eq "- echo key: value: invalid keys in command, 102" 102 "$(yml '  t:
    cmds:
      - echo key: value')"
check_output "and the message says so" 'invalid keys in command' bash -c 'task t 2>&1; true'
assert_eq "t: echo key: value: parse error, 109" 109 "$(yml '  t: echo key: value')"
check_output "mapping values are not allowed" 'mapping values are not allowed' bash -c 'task t 2>&1; true'
yml '  t:
    cmds:
      - echo "issue #42"' >/dev/null
check_output "- echo \"issue #42\": the shell gets a broken quote" 'reached EOF without closing quote' bash -c 'task t 2>&1; true'
block 'YAML and quoting traps' 1 >Taskfile.yml
assert_eq "the fixed forms all work" 'build
key: value
issue #42
echo works unquoted when it is not first' "$(task -s ok 2>&1)"
printf 'version: "3"\ntasks:\n  t:\n    cmds:\n      - >\n        echo one\n        two\n      - |\n        echo line1\n        echo line2\n' >Taskfile.yml
assert_eq "> joins lines, | keeps them" 'one two
line1
line2' "$(task -s t 2>&1)"
printf 'version: "3"\nvars:\n  MSG: "it'"'"'s; done"\ntasks:\n  bad: echo {{.MSG}}\n  good: echo {{.MSG | shellQuote}}\n' >Taskfile.yml
check_fails "a value with ' breaks the command" task -s bad
check_output "shellQuote fixes it" "^it's; done\$" task -s good

section "A variable is empty"
newdir
printf 'version: "3"\nvars:\n  VERSION: "1.0"\n  A: a\n  B:\n    sh: echo "[{{.A}}][{{.C}}]"\n  C: c\nenv:\n  E: from-env\ntasks:\n  case: echo "[{{.Version}}] [{{.VERSION}}]"\n  shvar: echo "[$VERSION] [{{.VERSION}}]"\n  order: echo "{{.B}}"\n  envv: echo "E=$E"\n  own:\n    vars: { NAME: task }\n    cmds: ["echo {{.NAME}}"]\n  args: echo "[{{.CLI_ARGS}}]"\n' >Taskfile.yml
check_output "case-sensitive, unknown is empty" '^\[\] \[1\.0\]$' task -s case
check_output "vars are not exported" '^\[\] \[1\.0\]$' task -s shvar
check_output "sh: sees only earlier variables" '^\[a\]\[\]$' task -s order
check_output "the process environment wins over env:" '^E=shell$' env E=shell task -s envv
check_output "the task's own vars win over the command line" '^task$' task -s own NAME=cli
check_output "CLI_ARGS needs --: without it, -v is a Task flag" '^\[\]$' task -s args
check_output "with --" '^\[-v\]$' task -s args -- -v

section "Paths in included Taskfiles"
newdir
P=$PWD
mkdir -p docs src
printf 'version: "3"\ntasks:\n  where:\n    cmds:\n      - pwd\n      - echo "TASKFILE_DIR={{.TASKFILE_DIR}} TASK_DIR={{.TASK_DIR}} ROOT_DIR={{.ROOT_DIR}} ROOT_TASKFILE={{.ROOT_TASKFILE}}"\n' >docs/Taskfile.yml
printf 'version: "3"\nincludes:\n  docs: ./docs/Taskfile.yml\n' >nodir.yml
check_output "without dir:, the included task runs in the root directory" "^$P\$" task -s -t nodir.yml docs:where
block 'Paths in included Taskfiles' 2 >Taskfile.yml
check_output "with dir: ./docs, it runs in docs/" "^$P/docs\$" task -s docs:where
check_output "the special variables" "TASKFILE_DIR=$P/docs TASK_DIR=$P/docs ROOT_DIR=$P ROOT_TASKFILE=$P/Taskfile.yml" task -s docs:where
check_output "task here from src/ prints src/ (USER_WORKING_DIR)" "^$P/src\$" bash -c "cd src && task -s here"
check_output "in docs/, task uses docs/Taskfile.yml alone" 'Task "docs:where" does not exist' bash -c "cd docs && task docs:where 2>&1; true"
check_output "task -d .. from docs/ uses the root Taskfile" "^$P/docs\$" bash -c "cd docs && task -s -d .. docs:where"

section "Exit codes"
newdir
assert_eq "100: no Taskfile" 100 "$(rc task)"
assert_eq "101: --init with a Taskfile" 101 "$(task --init >/dev/null; rc task --init)"
assert_eq "200: no such task" 200 "$(rc task nope)"
printf 'tasks:\n  t: echo x\n' >nov.yml
assert_eq "107: no version" 107 "$(rc task -t nov.yml t)"
printf 'version: "3"\ntasks:\n  fail: exit 7\n  pre:\n    preconditions: ["false"]\n    cmds: [echo x]\n  ask:\n    prompt: Sure?\n    cmds: [echo x]\n' >Taskfile.yml
assert_eq "201: a command failed" 201 "$(rc task fail)"
assert_eq "201: a precondition failed" 201 "$(rc task pre)"
assert_eq "205: prompt with no terminal" 205 "$(rc task ask </dev/null)"
assert_eq "-x: the command's own code" 7 "$(rc task -x fail)"
printf 'version: "3"\ntasks:\n  t:\n    cmds:\n      - echo a: b\n' >k.yml
assert_eq "102: valid YAML, invalid Taskfile" 102 "$(rc task -t k.yml t)"
printf 'version: "3"\ntasks:\n  t: [\n' >y.yml
assert_eq "109: YAML syntax error" 109 "$(rc task -t y.yml t)"
printf 'version: "3"\ntasks:\n  t:\n    requires:\n      vars:\n        - V\n        - name: E\n          enum: [a]\n    cmds: [echo x]\n' >r.yml
assert_eq "206: missing required variable" 206 "$(rc task -t r.yml t E=a)"
assert_eq "207: value not in enum" 207 "$(rc task -t r.yml t V=1 E=b)"

section "Experiments"
newdir
printf 'version: "3"\ntasks:\n  t: echo x\n' >Taskfile.yml
check_output "task --experiments (from the note)" '^\* GENTLE_FORCE: *off' bash -c "$(block 'Experiments' 1 | sed -n 1p | sed 's/ *#.*//')"
check_output "TASK_X_GENTLE_FORCE=1 (from the note)" 'GENTLE_FORCE: *on \(1\)' bash -c "$(block 'Experiments' 1 | sed -n 2p | sed 's/ *#.*//')"
out=$(TASK_X_GENTLE_FORECE=1 task --experiments 2>&1) && r=0 || r=$?
assert_eq "a typo is ignored: exit 0" 0 "$r"
assert_match "and the experiment stays off" 'GENTLE_FORCE: *off' "$out"
assert_eq "two experiments" 2 "$(task --experiments | grep -c '^\* ')"
check_fails "REMOTE_TASKFILES is not an experiment any more" bash -c 'task --experiments | grep -q REMOTE'
python3 -m http.server 18080 --bind 127.0.0.1 >/dev/null 2>&1 &
HTTP=$!
mkdir remote && printf 'version: "3"\ntasks:\n  hi: echo remote-hi\n' >remote/Taskfile.yml
printf 'version: "3"\nincludes:\n  r: http://127.0.0.1:18080/remote/Taskfile.yml\n' >inc.yml
retry 10 curl -fsS -o /dev/null http://127.0.0.1:18080/remote/Taskfile.yml
check_output "a remote include works with no TASK_X_ variable" 'remote-hi' task -s -y --insecure -t inc.yml r:hi
kill "$HTTP"

section "Taskfile versions"
newdir
printf 'version: "2"\ntasks:\n  default:\n    cmds: [echo hi]\n' >Taskfile.yml
out=$(task 2>&1) && r=0 || r=$?
assert_eq "version 2: exit 107" 107 "$r"
assert_eq "the note's message" "$(block 'Taskfile versions' 1 | sed "s|/work/Taskfile.yml|$PWD/Taskfile.yml|")" "$out"
printf 'version: "3.99"\ntasks:\n  default: echo hi\n' >Taskfile.yml
check_output "a newer version: the note's message" 'Schema version \(3\.99\.0\) is greater than the current version of Task \(3\.54\.0\)' bash -c 'task 2>&1; true'
assert_eq "and exit 107" 107 "$(rc task)"
printf 'version: "3.47"\ntasks:\n  default:\n    if: "true"\n    cmds: [echo hi]\n' >Taskfile.yml
check_output "version 3.47 with if: runs" '^hi$' task -s
printf 'version: 3\ntasks:\n  default: echo hi\n' >Taskfile.yml
check_output "version: 3 without quotes works" '^hi$' task -s
check_output "task --version" '3\.54\.0' task --version
