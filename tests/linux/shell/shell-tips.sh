#!/usr/bin/env bash
# note: linux/shell/shell-tips.md
# env: leap
source "$NOTES_ROOT/tests/lib/assert.sh"

NOTE=linux/shell/shell-tips
zypper -n -q install --no-recommends openssh-clients >/dev/null
W=$(mktemp -d)
cd "$W"
# ibash LINES: feed LINES to an interactive bash, so history expansion is on.
ibash() { bash --norc -i <<<"$1" 2>&1 || true; }
# cmds BLOCK: the commands typed in a console block, without the '$ ' prompt.
cmds() { sed -n 's/^\$ //p' <<<"$1"; }

section "History expansion"
touch sample.test
out=$(ibash "$(cmds "$(note_block "$NOTE" "History expansion" 1)")")
assert_match '!$ expands to the last argument (from the note)' '^ls /tmp$' "$out"
out=$(ibash "$(printf 'echo foo foo\n'; note_block "$NOTE" "History expansion" 4 | sed -n 1p; printf 'echo foo foo\n'; note_block "$NOTE" "History expansion" 4 | sed -n 2p)")
assert_match '!!:s/foo/bar/ replaces the first one (from the note)' '^bar foo$' "$out"
assert_match '!!:gs/foo/bar/ replaces all (from the note)' '^bar bar$' "$out"
out=$(ibash "$(cmds "$(note_block "$NOTE" "History expansion" 3)")")
assert_match '!-2 runs the command before last (from the note)' '^ls'$'\n''sample\.test$' "$out"
out=$(ibash "$(printf 'echo one\n'; cmds "$(note_block "$NOTE" "History expansion" 2)" | sed -n 2p)")
assert_match 'sudo !! expands to sudo + the previous line' '^sudo echo one$' "$out"
# histverify works through readline, on a terminal only: check the option exists.
check "shopt -s histverify is a bash option" bash -c 'shopt -s histverify'

section "Redirection"
printf 'echo out\necho err >&2\n' >test.sh
blk=$(note_block "$NOTE" Redirection 1)
run() { sed -n "${1}p" <<<"$blk" | sed 's/ *#.*//'; }
bash -c "$(run 1)" 2>/dev/null; bash -c "$(run 1)" 2>/dev/null
assert_eq "> truncates" out "$(cat output.txt)"
bash -c "$(run 2)" 2>/dev/null
assert_eq ">> appends" "$(printf 'out\nout')" "$(cat output.txt)"
bash -c "$(run 3)" >/dev/null
assert_eq "2> sends stderr to a file" err "$(cat error.log)"
assert_eq "2>&1 sends stderr to stdout" "$(printf 'out\nerr')" "$(bash -c "$(run 4)" 2>/dev/null)"
assert_eq "2>/dev/null discards stderr" out "$(bash -c "$(run 5)" 2>&1)"
assert_eq "&>/dev/null discards both" "" "$(bash -c "$(run 6)" 2>&1)"
bash -c 'sh test.sh > file 2>&1'
assert_eq "cmd > file 2>&1: both in the file" "$(printf 'out\nerr')" "$(cat file)"
assert_eq "cmd 2>&1 > file: stderr still on the terminal" err "$(bash -c 'sh test.sh 2>&1 > file')"
assert_eq "and only stdout in the file" out "$(cat file)"

section "Conditional operators"
for i in 1 2; do
  blk=$(note_block "$NOTE" "Conditional operators" "$i")
  assert_eq "console block $i prints what the note shows" "$(grep -v '^\$' <<<"$blk")" "$(bash -c "$(cmds "$blk")")"
done

section "Exit codes"
blk=$(note_block "$NOTE" "Exit codes" 1)
assert_eq "true / false give 0 / 1 (from the note)" "$(grep -v '^\$' <<<"$blk")" "$(bash -c "$(cmds "$blk")")"
check_output "2: misuse of a builtin" '^2$' bash -c 'cd -Z 2>/dev/null; echo $?'
touch noexec
check_output "126: not executable" '^126$' bash -c './noexec 2>/dev/null; echo $?'
check_output "127: not found" '^127$' bash -c 'nosuchcommand 2>/dev/null; echo $?'
check_output "130: 128 + SIGINT (2)" '^130$' bash -c 'bash -c "kill -INT \$\$"; echo $?'

section "Removing a stale SSH host key"
mkdir -p ~/.ssh
ssh-keygen -q -t ed25519 -N '' -f hostkey
printf '192.168.0.21 %s\n192.168.0.22 %s\n' "$(cut -d' ' -f1,2 hostkey.pub)" "$(cut -d' ' -f1,2 hostkey.pub)" >~/.ssh/known_hosts
check "ssh-keygen -R (from the note)" bash -ec "$(note_block "$NOTE" "stale SSH host key" 2)"
check_fails "removes that host's entry" grep -q '^192\.168\.0\.22 ' ~/.ssh/known_hosts
check "and keeps the others" grep -q '^192\.168\.0\.21 ' ~/.ssh/known_hosts
check "and keeps a backup in known_hosts.old" grep -q '^192\.168\.0\.22 ' ~/.ssh/known_hosts.old

section "Job control"
touch app.log error.log
blk=$(note_block "$NOTE" "Job control" 1)
# Ctrl+Z needs a terminal: type the note's commands into bash on a pty, \x1a is Ctrl+Z.
out=$({
  for c in "tail -f app.log" "tail -f error.log"; do printf '%s\n' "$c"; sleep 1; printf '\x1a'; sleep 0.5; done
  printf 'jobs\n'; sleep 0.3; printf 'fg 2\n'; sleep 1; printf '\x1a'; sleep 0.5
  printf '%s\n' "$(cmds "$(note_block "$NOTE" "Job control" 2)")"; sleep 0.5
  printf 'kill %%1 %%2\n'; sleep 0.5; printf 'exit\n'; sleep 0.3; printf 'exit\n'; sleep 0.3
} | script -qec 'bash --norc -i' /dev/null | tr -d '\r') || true
while IFS= read -r line; do
  [[ $line == '$ '* || $line == '^Z' ]] && continue
  # shellcheck disable=SC2001 # a regex escape needs sed
  assert_match "bash prints: $line" "^$(sed 's/[][+.]/\\&/g' <<<"$line")\$" "$out"
done <<<"$blk"
assert_match "bg prints the note's line" '^\[2\]\+ tail -f error\.log &$' "$out"

section "Checking a script's syntax"
printf 'echo ok\n' >script.sh
check "bash -n on a good script (from the note)" bash -ec "$(note_block "$NOTE" "Checking a script" 1)"
printf 'if true; then\n' >script.sh
check_fails "fails on a syntax error" bash -ec "$(note_block "$NOTE" "Checking a script" 1)"
check_output "and runs nothing" '^$' bash -n -c 'echo should-not-run'

section "Finding and deleting files"
mk() { rm -rf t && mkdir -p t/a "t/b c" t/empty/inner && touch t/x.m4a "t/b c/y z.m4a" t/a/keep.txt; }
for i in 1 2 3; do
  mk
  check "find block $i, on ./t instead of / (from the note)" bash -ec "$(note_block "$NOTE" "Finding and deleting" "$i" | sed 's|find / |find ./t |')"
  assert_eq "block $i removes every .m4a, even with spaces" "" "$(find t -name '*.m4a')"
done
assert_file "and nothing else" t/a/keep.txt
for i in 4 5; do
  mk
  (cd t && bash -ec "$(note_block "$NOTE" "Finding and deleting" "$i")" 2>/dev/null) || true
  assert_no_file "block $i removes nested empty directories" t/empty
  assert_file "block $i keeps directories with files" t/a/keep.txt
done

section "Quoting"
assert_eq "double quotes expand, single quotes do not (from the note)" "$(printf 'Hi John\nHi $NAME')" \
  "$(bash -c "$(note_block "$NOTE" Quoting 1)")"

section "Command substitution"
out=$(cd /tmp && bash -c "$(note_block "$NOTE" "Command substitution" 1)")
assert_eq "\$( ) and backticks give the same (from the note)" "$(printf "I'm in /tmp\nI'm in /tmp")" "$out"
assert_eq "\$( ) nests" "x" "$(bash -c 'echo $(echo $(echo x))')"

section "Brace expansion"
while read -r expr _ expected; do
  assert_eq "$expr" "$expected" "$(bash -c "echo $expr")"
done < <(note_block "$NOTE" "Brace expansion" 1 | sed 's/ *->  */ -> /')
mkdir b && cd b && touch test.txt config.yml
export HOME=$PWD/home && mkdir home
blk=$(note_block "$NOTE" "Brace expansion" 2 | sed 's/ *#.*//')
check "mkdir -p ~/{work,image,private} (from the note)" bash -ec "$(sed -n 1p <<<"$blk")"
check "makes three directories" test -d home/work -a -d home/image -a -d home/private
for i in 2 3 4; do
  rm -f test.* config.yml* && touch test.txt config.yml
  bash -ec "$(sed -n "${i}p" <<<"$blk")"
  files[i]=$(find . -mindepth 1 -maxdepth 1 ! -name '*home*' -printf '%f\n' | sort | xargs)
done
assert_eq "mv test.{txt,md} renames the extension" "config.yml test.md" "${files[2]}"
assert_eq "mv test.txt{,.bak} appends .bak" "config.yml test.txt.bak" "${files[3]}"
assert_eq "cp config.yml{,.orig} makes a copy" "config.yml config.yml.orig test.txt" "${files[4]}"
cd "$W"
# shellcheck disable=SC2329 # called by the note's commands, through export -f
ssh() { echo "ssh $*"; }
export -f ssh
check_output "the host loop expands to four hosts (ssh replaced by echo)" 'apache-4.*uptime' \
  bash -ec "$(note_block "$NOTE" "Brace expansion" 3)"
assert_eq "one ssh per host" 4 "$(bash -c "$(note_block "$NOTE" "Brace expansion" 3)" | grep -c '^ssh -t your.name@apache-[1-4] sudo -- sh -c uptime$')"
unset -f ssh

section "Parameter substitution and slicing"
blk=$(note_block "$NOTE" "Parameter substitution" 1)
expected=$(sed -n 's/.*#=> \([^ ]*\).*/\1/p' <<<"$blk")
actual=$(bash -c "$(sed 1,2d <<<"$blk" | sed 's/ *#=>.*//' | sed "1i name=John")")
assert_eq "every #=> result is what bash prints (from the note)" "$expected" "$actual"

section "Reading a file line by line"
printf 'a  b\nc\\d\n' >file.txt
assert_eq "the loop keeps spaces and backslashes (from the note)" "$(cat file.txt)" "$(bash -c "$(note_block "$NOTE" "Reading a file" 1)")"
assert_eq "the original form runs, but the loop reads nothing" "" "$(bash -c '< file.txt | while read line; do echo "$line"; done')"

section "Monitoring one-liners"
blk=$(note_block "$NOTE" "Monitoring" 1)
check_output "free -m -l -t prints Low, High and Total (from the note)" 'Total:' bash -c "$(sed -n 1p <<<"$blk")"
check_output "free -l adds the Low line" '^Low:' bash -c "$(sed -n 1p <<<"$blk")"
check "ps | sort by memory (from the note)" bash -ec "set -o pipefail; $(sed -n 3p <<<"$blk" | sed 's/ *#.*//') >/dev/null"
check "ps | sort by CPU (from the note)" bash -ec "set -o pipefail; $(sed -n 4p <<<"$blk" | sed 's/ *#.*//') >/dev/null"
check_output "column 4 of ps aux is %MEM, column 3 is %CPU" '^USER +PID +%CPU +%MEM' bash -c 'ps aux | head -1'

section "Several commands on one line"
mkdir test test2 && touch test/test1.md test2/test2.md
blk=$(note_block "$NOTE" "Several commands" 1)
assert_eq "both ls run (from the note)" "$(grep -v '^\$' <<<"$blk")" "$(bash -c "$(cmds "$blk")")"
assert_eq "; runs the second even when the first fails" "x" "$(bash -c 'false ; echo x')"
