#!/usr/bin/env bash
# note: linux/cli/top.md
# env: leap
# Interactive keys run through `script`, which gives top a terminal.
source "$NOTES_ROOT/tests/lib/assert.sh"

NOTE=linux/cli/top
export TERM=xterm
useradd -m alice
runuser -u alice -- sleep 3001 &
sleep 3002 &
root_pid=$!
sleep 1
alice_pid=$(pgrep -u alice -x sleep)
batch() { top -b -n 1 -w 512 "$@"; }
# keys STRING: type the keys into an interactive top, one per second, then q.
keys() {
  { sleep 2; for ((i = 0; i < ${#1}; i++)); do printf '%s' "${1:i:1}"; sleep 1; done; printf q; } |
    script -qfec "stty cols 160 rows 40; top" /dev/null >/dev/null 2>&1
}

section "Command-line options"
while IFS= read -r line; do
  cmd=${line%%#*}
  # shellcheck disable=SC2086 # split the note's options into words
  case $cmd in
    *-U*|*-u*) out=$(batch ${cmd#top}) ;;
    *-p*) out=$(batch -p "$alice_pid,$root_pid") ;;
    *-d*) continue ;;
    *) out=$(bash -c "$cmd -w 512") ;;
  esac
  case $cmd in
    *-U* | *-u*)
      assert_match "${cmd% } shows alice's process" "^ *$alice_pid +alice " "$out"
      assert_no_match "and not root's" "^ *$root_pid " "$out" ;;
    *-p*)
      assert_match "-p shows the listed PIDs" "^ *$root_pid " "$out"
      assert_no_match "and nothing else" '^ *1 ' "$out" ;;
    *) assert_match "top -b -n 1 prints one snapshot" '^top - ' "$out" ;;
  esac
done < <(note_block "$NOTE" 'Command-line options' 1)
start=$SECONDS; batch -d 5 -n 2 >/dev/null
check "-d 5 waits 5 seconds between refreshes" test $((SECONDS - start)) -ge 5

assert_match "without -c, the program name only" "^ *$root_pid .* sleep$" "$(batch)"
assert_match "-c shows the full command line" "^ *$root_pid .* sleep 3002$" "$(batch -c)"
keys cW
check "W writes ~/.config/procps/toprc" test -f ~/.config/procps/toprc
assert_match "the saved layout shows the command line" "^ *$root_pid .* sleep 3002$" "$(batch)"
assert_match "and -c reverses the saved state" "^ *$root_pid .* sleep$" "$(batch -c)"
mv ~/.config/procps/toprc ~/.toprc
assert_match "an old ~/.toprc is still read" "^ *$root_pid .* sleep 3002$" "$(batch)"
rm ~/.toprc

check "the batch-mode snapshot (from the note)" bash -ec "$(note_block "$NOTE" 'Command-line options' 2)"
check_output "it has the summary" '^Tasks: ' cat /tmp/load-snapshot.txt

section "Tasks"
kill -STOP "$root_pid"
bash -c 'sleep 0.1 & exec sleep 3003' &
parent=$!
sleep 1
zombie=$(ps -o pid= --ppid "$parent" | tr -d ' ')
tasks=$(batch | sed -n 2p)
fields=$(note_block "$NOTE" Tasks 1 | sed 's/[0-9]\+/[0-9]+/g')
assert_match "the tasks line has the note's fields" "^$fields\$" "$tasks"
assert_match "the stopped process is counted" ' [1-9][0-9]* stopped' "$tasks"
assert_match "the zombie is counted" ' 1 zombie' "$tasks"
kill -9 "$zombie"
check_output "kill -9 does not remove a zombie" '^Z' ps -o stat= -p "$zombie"
kill "$parent"
sleep 1
check_output "once the parent exits, the zombie goes to PID 1 (or is already reaped)" '^ *1$|^$' \
  bash -c "ps -o ppid= -p $zombie || true"
kill -CONT "$root_pid"

section "CPU"
check_output "the CPU line has the note's eight fields" \
  'us, +[0-9.]+ sy, +[0-9.]+ ni, +[0-9.]+ id, +[0-9.]+ wa, +[0-9.]+ hi, +[0-9.]+ si, +[0-9.]+ st' batch

section "Memory"
snap=$(batch)
mem=$(grep '^MiB Mem' <<<"$snap")
# Batch mode marks a number too wide for its column with a + instead of a space.
pattern() { sed 's/ *[0-9.]\+ */ *[0-9.]+[+ ]*/g'; }
fields=$(note_block "$NOTE" Memory 1 | pattern)
assert_match "the memory line has the note's format" "^$fields" "$mem"
swap=$(grep '^MiB Swap' <<<"$snap")
fields=$(note_block "$NOTE" Swap 1 | pattern)
assert_match "the swap line has the note's format" "^$fields" "$swap"
num() { grep -o "[0-9.]\+[+ ]*$1" <<<"$2" | grep -o '^[0-9.]\+'; }
total=$(num total "$mem") used=$(num used "$mem") free=$(num free "$mem")
cache=$(num buff/cache "$mem") avail=$(num avail "$swap")
check "used is total minus avail Mem ($total - $avail ~ $used)" \
  awk -v t="$total" -v a="$avail" -v u="$used" 'BEGIN { d = t - a - u; exit !(d < 2 && d > -2) }'
check "free + used + buff/cache is more than total" \
  awk -v t="$total" -v f="$free" -v u="$used" -v c="$cache" 'BEGIN { exit !(f + u + c > t) }'
