#!/usr/bin/env bash
# note: dev/taskfile/advanced.md
# env: task
source "$NOTES_ROOT/tests/lib/assert.sh"

NOTE=dev/taskfile/advanced
block() { note_block "$NOTE" "$@"; }
# newdir: a fresh project directory, as the current directory.
newdir() { cd "$(mktemp -d)"; }
# rc CMD...: print CMD's exit code.
rc() { "$@" >/dev/null 2>&1 && echo 0 || echo $?; }

section "Static, dynamic and typed values"
newdir
block 'Static, dynamic and typed values' >Taskfile.yml
check_output "list index, map key and sh: (no git repository: 'none')" '^shop none first-port=8080 cpu=2$' task -s show
git init -q . && git -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m init
check_output "sh: gives the command's output, without the newline" "^shop $(git rev-parse --short HEAD) first-port" task -s show
printf 'version: "3"\ntasks:\n  t: echo "[{{.NOPE}}] [{{.NOPE | default "x"}}]"\n' >Taskfile.yml
check_output "an unknown variable is empty, with no error; default gives a fallback" '^\[\] \[x\]$' task -s t

section "Precedence"
newdir
block 'Precedence' >Taskfile.yml
check_output "global vars: the command line wins" '^MODE=prod$' task -s global-default MODE=prod
check_output "task vars: the command line is ignored" '^MODE=release$' task -s task-value MODE=prod
check_output "the default pattern: the command line wins" '^MODE=prod$' task -s template-default MODE=prod
check_output "the default pattern: no MODE= gives the global value, not the default" '^MODE=debug$' task -s template-default
check_output "the default applies when nothing else sets MODE" '^MODE=release$' \
  bash -c "sed '/^vars:/,/^\$/d' Taskfile.yml >noglobal.yml && task -s -t noglobal.yml template-default"
check_output "a vars: on a task: call is like the command line" '^MODE=release$' \
  bash -c 'cat Taskfile.yml - >t2.yml <<EOF
  caller:
    cmds:
      - task: task-value
        vars: { MODE: prod }
EOF
task -s -t t2.yml caller'

section "Pass a list or a map with ref"
newdir
block 'Pass a list or a map' >Taskfile.yml
check_output "ref keeps the list" '^first=api count=2$' task -s
sed 's/^            ref: .SERVICES$/          SERVICES: "{{.SERVICES}}"/; /^          SERVICES:$/d' Taskfile.yml >str.yml
check_output "a template instead turns it into a string" 'count=[0-9]{2,}' task -s -t str.yml

section "Environment: env and dotenv"
newdir
block 'Environment' 1 >Taskfile.yml
printf 'DB_HOST=db.example.com\nREGION=us-east-1\n' >.env
printf 'DB_HOST=localhost\n' >.env.local
assert_eq "the output shown in the note" "$(block 'Environment' 2)" "$(task -s show 2>&1)"
check_output "the process environment wins" '^REGION=x ' env REGION=x task -s show
check_output "TASK_X_ENV_PRECEDENCE=1 reverses this" '^REGION=eu-west-1 ' env REGION=x TASK_X_ENV_PRECEDENCE=1 task -s show
rm .env.local
check_output "a missing dotenv file is skipped" 'DB_HOST=db.example.com' task -s show
mkdir inc && printf 'version: "3"\ndotenv: [.env]\ntasks:\n  x: echo x\n' >inc/Taskfile.yml
printf 'version: "3"\nincludes:\n  inc: ./inc\n' >withinc.yml
check_fails "dotenv: in an included Taskfile is an error" task -t withinc.yml inc:x
check_output "and the error says so" '[Dd]otenv' bash -c 'task -t withinc.yml inc:x 2>&1; true'

section "Includes"
newdir
block 'Includes' 1 >Taskfile.yml
mkdir -p docs taskfiles
block 'Includes' 2 >taskfiles/Docker.yml
printf 'version: "3"\ntasks:\n  build: pwd\n  up: { cmds: [{ task: ":root-task" }] }\n' >docs/Taskfile.yml
printf 'version: "3"\ntasks:\n  lint: echo lint\n  debug: echo debug\n' >taskfiles/Tools.yml
printf 'version: "3"\ntasks:\n  helper: echo helper\n' >taskfiles/Helpers.yml
printf '  root-task: echo root-task\n  use-helper:\n    cmds: [{ task: helpers:helper }]\n' >tail.yml
printf 'tasks:\n' >>Taskfile.yml && cat tail.yml >>Taskfile.yml
check_output "backend:build" '^building backend$' task -s backend:build
check_output "frontend:build" '^building frontend$' task -s frontend:build
check_output "dir: ./docs runs docs:build in docs/" "/docs\$" task -s docs:build
check_output "the alias d:build" "/docs\$" task -s d:build
check "optional: no Taskfile.local.yml, no error" task --list-all
check_output "flatten: task lint" '^lint$' task -s lint
check_fails "excludes: debug is not included" task -s debug
check_fails "internal: helpers:helper cannot be called directly" task -s helpers:helper
check_output "but another task can call it" '^helper$' task -s use-helper
check_fails "internal: hidden from --list-all" bash -c 'task --list-all | grep -q helpers:helper'
check_output "task: :root-task calls the root Taskfile" '^root-task$' task -s docs:up
sed -i 's/IMAGE: .{{.IMAGE | default "app"}}./IMAGE: app/' taskfiles/Docker.yml
check_output "a plain value in the included file wins over includes: vars" '^building app$' task -s backend:build
printf 'version: "3"\nincludes:\n  docs: ./docs\n' >nodir.yml
check_output "without dir:, included tasks run in the root Taskfile's directory" "^$PWD\$" task -s -t nodir.yml docs:build
printf 'version: "3"\nincludes:\n  tools:\n    taskfile: ./taskfiles/Tools.yml\n    flatten: true\ntasks:\n  lint: echo root\n' >clash.yml
check_fails "flatten: fails when the name exists in the root Taskfile" task -t clash.yml lint

section "sources and generates"
newdir
block 'and `generates`' 1 >Taskfile.yml
mkdir -p src && echo 'a();' >src/a.js && echo 'test();' >src/a.test.js
check_output "first run" 'xargs cat > dist/bundle\.js' task bundle
assert_eq "the bundle leaves out the test file" 'a();' "$(cat dist/bundle.js)"
check_output "second run: up to date" 'task: Task "bundle" is up to date' task bundle
assert_file "the checksum is in .task/checksum/<task>" .task/checksum/bundle
assert_eq "--status: exit 0 when up to date" 0 "$(rc task --status bundle)"
touch src/a.js
check_output "checksum: touch does not trigger a run" 'is up to date' task bundle
echo 'test2();' >src/a.test.js
check_output "an excluded file does not trigger a run" 'is up to date' task bundle
echo 'b();' >src/a.js
assert_eq "--status: non-zero when a source changed" 1 "$(rc task --status bundle)"
task bundle >/dev/null 2>&1
echo changed >dist/bundle.js
check_output "checksum does not see a changed output file" 'is up to date' task bundle
rm dist/bundle.js
check_output "a missing output triggers a run" 'xargs cat > dist/bundle\.js' task bundle
check_output "--force runs anyway (from the note)" 'xargs cat > dist/bundle\.js' bash -c "$(block 'and `generates`' 2 | sed -n 2p | sed 's/ *#.*//')"
sed -i 's/^    sources:/    method: timestamp\n    sources:/' Taskfile.yml
task bundle >/dev/null 2>&1
check_output "timestamp: up to date after a run" 'is up to date' task bundle
sleep 1 && touch src/a.js
check_output "timestamp: touch triggers a run" 'xargs cat > dist/bundle\.js' task bundle
printf 'version: "3"\ntasks:\n  tag:\n    sources: [src/a.js]\n    cmds: ["echo tag={{.CHECKSUM}}"]\n' >ck.yml
check_output "{{.CHECKSUM}} is a hash of the sources" '^tag=[0-9a-f]{8,}$' task -s -t ck.yml tag

section "status"
newdir
block '`status`' 1 >Taskfile.yml
check_output "first run installs the tool" 'chmod \+x bin/tool' task install-tool
check_output "the tool works" '^tool 1\.0$' bin/tool
check_output "second run: up to date" 'is up to date' task install-tool
rm bin/tool
check_output "a failed status check runs the task again" 'chmod \+x bin/tool' task install-tool

section "Conditions"
newdir
block 'Conditions' 1 >Taskfile.yml
assert_eq "requires: missing VERSION, exit 206" 206 "$(rc task deploy ENV=prod)"
assert_eq "requires: value not in enum, exit 207" 207 "$(rc task deploy ENV=test VERSION=1.2)"
check_output "the enum message shown in the note" "ENV has an invalid value : 'test' \(allowed values : \[dev staging prod\]\)" \
  bash -c 'task deploy ENV=test VERSION=1.2 2>&1; true'
assert_eq "preconditions: release.txt missing, exit 201" 201 "$(rc task deploy ENV=prod VERSION=1.2)"
check_output "and the msg is printed" "release.txt is missing. Run 'task release' first." bash -c 'task deploy ENV=prod VERSION=1.2 2>&1; true'
touch release.txt
check_output "prod: the if: command runs" 'sending a notification' task deploy ENV=prod VERSION=1.2
out=$(task deploy ENV=dev VERSION=1.2 2>&1) && r=0 || r=$?
assert_eq "dev: exit 0" 0 "$r"
assert_no_match "dev: the if: command is skipped" 'sending' "$out"
check_output "an empty VERSION counts as present" 'deploying  to dev' task deploy ENV=dev VERSION=
assert_eq "--interactive with no terminal: still exit 206" 206 "$(rc task --interactive deploy </dev/null)"
printf 'version: "3"\ntasks:\n  t:\n    if: test -f nothing\n    cmds: [echo ran]\n' >if.yml
out=$(task -t if.yml t 2>&1) && r=0 || r=$?
assert_eq "a task-level if: that fails: exit 0" 0 "$r"
assert_no_match "and nothing runs" 'ran' "$out"

section "Run a task once"
newdir
block 'Run a task once' 1 >Taskfile.yml
assert_eq "run: once: setup runs once" 1 "$(task -s check 2>&1 | grep -c '^setup$')"
sed -i '/run: once/d' Taskfile.yml
assert_eq "without it, setup runs twice" 2 "$(task -s check 2>&1 | grep -c '^setup$')"
printf 'version: "3"\ntasks:\n  default:\n    cmds:\n      - task: g\n        vars: { V: "1" }\n      - task: g\n        vars: { V: "2" }\n      - task: g\n        vars: { V: "2" }\n  g:\n    run: when_changed\n    cmds: ["echo g{{.V}}"]\n' >wc.yml
assert_eq "when_changed: once per set of variables" "g1 g2" "$(task -s -t wc.yml | tr '\n' ' ' | sed 's/ $//')"

section "Loops"
newdir
block 'Loops' 1 >Taskfile.yml
expected='list one
list two
var a.txt
var b.txt
split x
split y
matrix linux/amd64
matrix linux/arm64
matrix darwin/amd64
matrix darwin/arm64
ping api
ping worker'
assert_eq "every loop form, in order" "$expected" "$(task -s loops 2>&1)"
printf 'version: "3"\ntasks:\n  t:\n    vars: { W: "p q" }\n    cmds:\n      - for: { var: W }\n        cmd: echo "[{{.ITEM}}]"\n' >split.yml
assert_eq "a string variable is split on spaces" "[p] [q]" "$(task -s -t split.yml t | tr '\n' ' ' | sed 's/ $//')"
mkdir -p in && touch in/1.txt in/2.txt
printf 'version: "3"\ntasks:\n  t:\n    method: none\n    sources: [in/*.txt]\n    cmds:\n      - for: sources\n        cmd: echo "src {{.ITEM}}"\n' >src.yml
assert_eq "for: sources loops over the files" "src in/1.txt src in/2.txt" "$(task -s -t src.yml t | tr '\n' ' ' | sed 's/ $//')"

section "Platforms"
newdir
block 'Platforms' 1 >Taskfile.yml
check_output "linux-only runs on Linux" "^on linux/$(uname -m | sed 's/x86_64/amd64/; s/aarch64/arm64/')\$" task -s linux-only
mkdir docs && touch docs/index.html
# No desktop in the container: the Linux command is xdg-open, and it is not installed.
check_output "open-docs runs only the Linux command" 'xdg-open docs/index.html' bash -c 'task open-docs 2>&1; true'
check_fails "and not the darwin or windows ones" bash -c 'task open-docs 2>&1 | grep -Eq "\] (open|start) "'
printf 'version: "3"\ntasks:\n  w:\n    platforms: [windows]\n    cmds: [echo win]\n' >w.yml
assert_eq "a task for another platform: exit 0, no output" "0:" "$(out=$(task -t w.yml w 2>&1) && echo "0:$out" || echo "$?:$out")"

section "Prompts, defer and errors"
newdir
block 'Prompts, defer and errors' 1 >Taskfile.yml
assert_eq "prompt, no terminal: exit 205" 205 "$(rc task reset-db </dev/null)"
check_output "no terminal: the message suggests --yes" 'not a terminal. Use --yes' bash -c 'task reset-db </dev/null 2>&1; true'
check_output "--yes runs it" 'database reset' task --yes reset-db
tty_answer() { printf '%s\n' "$1" | script -qec "task reset-db" /dev/null >/dev/null 2>&1; echo $?; }
assert_eq "a terminal, answer y: runs" 0 "$(tty_answer y)"
assert_eq "a terminal, answer yes: runs" 0 "$(tty_answer yes)"
assert_eq "a terminal, answer n: exit 205" 205 "$(tty_answer n)"
assert_eq "a terminal, Enter (default N): exit 205" 205 "$(tty_answer '')"
out=$(task -s work 2>&1) && r=0 || r=$?
assert_eq "work: ignore_error keeps going, exit 0" 0 "$r"
assert_match "the command after the error ran" 'still running' "$out"
assert_match "EXIT_CODE is empty on success" '^exit code was $' "$(grep 'exit code was' <<<"$out")"
assert_no_file "defer removed tmp-work" tmp-work
printf 'version: "3"\ntasks:\n  t:\n    cmds:\n      - mkdir -p d\n      - defer: rm -rf d\n      - defer: echo first-registered\n      - defer: echo "code={{.EXIT_CODE}}"\n      - exit 3\n' >fail.yml
out=$(task -s -t fail.yml t 2>&1) && r=0 || r=$?
assert_eq "a failing command: exit 201" 201 "$r"
assert_match "defers run in reverse order, with EXIT_CODE" 'code=3.*first-registered' "$(tr '\n' ' ' <<<"$out")"
assert_no_file "and the cleanup ran" d
printf 'version: "3"\ntasks:\n  t:\n    ignore_error: true\n    cmds:\n      - exit 1\n      - task: inner\n      - echo after\n  inner:\n    cmds: [exit 2, echo inner-after]\n' >ie.yml
out=$(task -s -t ie.yml t 2>&1) && r=0 || r=$?
assert_eq "ignore_error on a task: the caller goes on, exit 0" 0 "$r"
assert_match "the caller's next command ran" 'after' "$out"
assert_no_match "the called task did not inherit it: it stopped at its error" 'inner-after' "$out"

section "Templating functions"
newdir
block 'Templating functions' 1 >Taskfile.yml
expected="$(date +%Y-%m-%d)
linux $(uname -m | sed 's/x86_64/amd64/; s/aarch64/arm64/') $(nproc) bin/app
a,b,c
HELLO x fallback
dist/linux/app c.txt .gz
it's done; really
functions 3.54.0"
assert_eq "every function line" "$expected" "$(task -s functions 2>&1)"
sed -i 's/echo {{.MSG | shellQuote}}/echo {{.MSG}}/' Taskfile.yml
check_fails "without shellQuote, the ' in MSG breaks the command" task -s functions

section "Command-line flags"
newdir
cat >Taskfile.yml <<'EOF'
version: "3"
tasks:
  build:
    desc: Build it
    sources: [in.txt]
    cmds: ['echo "built $(cat in.txt)"']
  lint:
    desc: Lint it
    cmds: [sleep 1, echo lint-done]
  test:
    desc: Test it
    cmds: [echo test-done]
  fail: exit 7
EOF
echo one >in.txt
check_output "--list --json | jq (from the note)" '^build	Build it$' bash -c "$(block 'Command-line flags' 1 | sed -n 1p)"
assert_no_file "--no-status: no checksum saved" .task/checksum/build
task --list --json >/dev/null
assert_file "without --no-status, --list --json saves the checksum (the warning)" .task/checksum/build
check_output "and build then says up to date, though it never ran" 'is up to date' task build
rm -rf .task
check_output "--parallel: test finishes before lint (from the note)" 'test-done.*lint-done' \
  bash -c "$(block 'Command-line flags' 1 | sed -n 2p) 2>&1 | tr '\n' ' '"
(timeout 5 bash -c "$(block 'Command-line flags' 1 | sed -n 3p)" >watch.log 2>&1 &)
retry 10 grep -q 'built one' watch.log
echo two >in.txt
retry 10 grep -q 'built two' watch.log
check_output "--watch: runs again when a source changes" 'built one.*built two' bash -c 'tr "\n" " " <watch.log'
check_output "--summary shows the commands" 'commands:' task --summary build
printf 'version: "3"\ntasks:\n  nosrc: echo nosrc-ran\n  a: exit 1\n  b: sleep 2; touch b-done\n  both:\n    deps: [a, b]\n    cmds: [echo never]\n' >ff.yml
out=$(timeout 3 task -t ff.yml --watch nosrc 2>&1) && r=0 || r=$?
assert_eq "--watch without sources: still waiting after 3 s" 124 "$r"
assert_eq "and it ran once" 1 "$(grep -c '^nosrc-ran$' <<<"$out")"
task -t ff.yml both >/dev/null 2>&1 || true
assert_file "without -F, the other dependency finishes" b-done
rm -f b-done
task -t ff.yml -F both >/dev/null 2>&1 || true
sleep 3
assert_no_file "-F stops the other dependency" b-done
check_output "--dry prints the command" 'task: \[build\] echo' task --dry --force build
assert_no_match "--dry runs nothing" '^built' "$(task --dry --force build 2>&1)"
check_output "-v prints when a task starts" 'task: "test" started' task -v test
check_output "-v prints why a task is skipped" 'if condition not met - skipped' \
  bash -c 'printf "version: \"3\"\ntasks:\n  s:\n    if: \"false\"\n    cmds: [echo s]\n" >skip.yml && task -v -t skip.yml s 2>&1'
assert_eq "without -x: exit 201" 201 "$(rc task fail)"
assert_eq "-x: the command's own exit code" 7 "$(rc task -x fail)"
mkdir -p home && printf 'version: "3"\ntasks:\n  hi: echo global-taskfile\n' >home/Taskfile.yml
check_output "-g uses \$HOME/Taskfile.yml" '^global-taskfile$' env HOME="$PWD/home" task -s -g hi

section "Configuration: .taskrc.yml"
newdir
printf 'version: "3"\ntasks:\n  default: echo hi\n' >Taskfile.yml
block 'Configuration' 1 >.taskrc.yml
assert_eq "the note's .taskrc.yml is read: silent" hi "$(task 2>&1)"
check_output "it enables GENTLE_FORCE" 'GENTLE_FORCE: *on' task --experiments
check_output "two experiments in v3.54.0" '^\* ENV_PRECEDENCE:' task --experiments
assert_eq "exactly two" 2 "$(task --experiments | grep -c '^\* ')"
check_output "TASK_SILENT=false wins over the file" 'task: \[default\] echo hi' env TASK_SILENT=false task
check_output "-v on the command line wins over the file" 'task: "default" started' task -v
H=$(mktemp -d)
mkdir -p "$H/.config/task" "$H/proj"
printf 'version: "3"\ntasks:\n  default: echo hi\n' >"$H/proj/Taskfile.yml"
printf 'silent: true\n' >"$H/.config/task/taskrc.yml"
assert_eq "XDG taskrc.yml (no dot) is read" hi "$(cd "$H/proj" && HOME=$H XDG_CONFIG_HOME=$H/.config task 2>&1)"
printf 'silent: false\n' >"$H/.taskrc.yml"
check_output "the home .taskrc.yml wins over the XDG file" 'task: \[default\]' bash -c "cd $H/proj && HOME=$H XDG_CONFIG_HOME=$H/.config task"
printf 'silent: true\n' >"$H/proj/.taskrc.yml"
assert_eq "the project .taskrc.yml wins over the home one" hi "$(cd "$H/proj" && HOME=$H XDG_CONFIG_HOME=$H/.config task 2>&1)"
check_output "TASK_X_GENTLE_FORCE=1 turns the experiment on" 'GENTLE_FORCE: *on' env TASK_X_GENTLE_FORCE=1 task --experiments
