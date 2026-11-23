#!/usr/bin/env bash
# note: linux/cli/kill.md
# env: leap-systemd
# timeout: 900
source "$NOTES_ROOT/tests/lib/assert.sh"

NOTE=linux/cli/kill
zypper -n -q install --no-recommends psmisc go >/dev/null
cd "$(mktemp -d)"

section "SIGHUP"
# A daemon that writes a PID file and logs each reload.
cat >daemon.sh <<'EOS'
echo $$ >/run/service.pid
trap 'echo reloaded >>/tmp/reloads' HUP
while :; do sleep 0.2; done
EOS
bash daemon.sh &
retry 5 test -s /run/service.pid
n=0
while IFS= read -r line; do
  n=$((n + 1))
  check "${line%%#*}" bash -ec "$line"
  check "the daemon reloaded ($n) and kept running" \
    retry 5 bash -c "[[ \$(grep -c reloaded /tmp/reloads) == $n ]] && kill -0 \$(cat /run/service.pid)"
done < <(note_block "$NOTE" SIGHUP 1)
check_output "/var/run is a link to /run" '^/run$' readlink -f /var/run
kill "$(cat /run/service.pid)"

section "Killing a process"
# An interactive shell, as in the note: script gives it a terminal, so job control is on.
mkfifo in
script -qfc 'bash --norc -i' /dev/null <in >out.txt 2>&1 &
exec 3>in
note_block "$NOTE" 'Killing a process' 1 >&3
echo 'pstree -p $$ >/tmp/tree; ps j -A >/tmp/ps' >&3
retry 10 test -s /tmp/ps
sleep 1
shell=$(pgrep -f -x 'bash --norc -i')
check_output "pstree shows both sleeps under the shell" "sleep\([0-9]+\)" cat /tmp/tree
header=$(head -1 /tmp/ps | tr -s ' ')
assert_eq "ps j -A has the note's columns" "$(note_block "$NOTE" 'Killing a process' 2 | grep PPID | tr -s ' ')" "$header"
# shellcheck disable=SC2009 # ps shows PGID and SID; pgrep does not
read -r s1 g1 sid1 < <(ps -o pid=,pgid=,sid= -C sleep | grep -w 3600 || ps -o pid=,pgid=,sid= -p "$(pgrep -fx 'sleep 3600')")
assert_eq "each background job is its own process group (PGID = PID)" "$s1" "$g1"
assert_eq "in the shell's session" "$shell" "$sid1"

section "Killing every process in a process group"
setsid bash -c 'sleep 500 & sleep 501 & wait' &
sleep 1
leader=$(pgrep -fx 'bash -c sleep 500 & sleep 501 & wait')
check "kill -SIGTERM -- -PGID (from the note)" bash -ec "$(note_block "$NOTE" 'process group' 1 | sed "s/-2121/-$leader/")"
check "every process in the group is gone" retry 5 bash -c '! pgrep -fx "sleep 50[01]"'
setsid bash -c 'sleep 502 & wait' &
sleep 1
leader=$(pgrep -fx 'bash -c sleep 502 & wait')
check "a positive PID signals only that process" kill -SIGTERM "$leader"
check "the rest of the group survives" pgrep -fx 'sleep 502'
pkill -fx 'sleep 502'
setsid bash -c 'sleep 503 & wait' &
sleep 1
leader=$(pgrep -fx 'bash -c sleep 503 & wait')
check_fails "with the group first and no --, kill reads it as a signal number" kill "-$leader"
check "kill -- -PGID sends SIGTERM to the group" kill -- "-$leader"
check "the group is gone" retry 5 bash -c '! pgrep -fx "sleep 503"'

section "Killing every process in a session"
out=$(bash -c "$(note_block "$NOTE" 'in a session' 1 | sed -n 's/^\$ //p' | sed "s/2104/$shell/")")
assert_match "pgrep -s lists the shell" "^$shell bash" "$out"
assert_match "and its jobs" 'sleep 3600' "$out"
check "pkill -s (from the note)" bash -ec "$(note_block "$NOTE" 'in a session' 2 | sed "s/2104/$shell/")"
check "the jobs are gone" retry 5 bash -c '! pgrep -fx "sleep 360[01]"'
check "the interactive shell ignores SIGTERM and is still there" kill -0 "$shell"
check "pkill -KILL -s ends the session" bash -c "pkill -KILL -s $shell; ! kill -0 $shell 2>/dev/null || { sleep 1; ! kill -0 $shell 2>/dev/null; }"
exec 3>&-

section "Why is this running at all?"
check "go install witr (from the note)" bash -ec "$(note_block "$NOTE" 'Why is this running' 1 | sed -n 1p | sed 's/ *#.*//')"
export PATH=$PATH:$HOME/go/bin
systemd-run -q --unit=web -p WorkingDirectory=/tmp python3 -m http.server 8080 >/dev/null
retry 10 bash -c 'ss -tln | grep -q :8080'
out=$(witr python3 2>&1) || true
assert_match "witr NAME names the unit" 'Source +: web\.service \(systemd\)' "$out"
assert_match "and walks the ancestry back to PID 1" 'systemd \(pid 1\) → python3' "$out"
assert_match "and prints the unit file" 'Unit File +: /run/systemd/transient/web\.service' "$out"
while IFS= read -r label; do
  assert_match "the output has the note's '$label' field" "^$label +:" "$out"
done < <(note_block "$NOTE" 'Why is this running' 3 | sed -n 's/^\([A-Z][A-Za-z ]*[a-z]\) *:.*/\1/p')
out=$(witr --port 8080 2>&1) || true
assert_match "witr --port 8080 finds the unit" 'web\.service' "$out"
assert_match "and warns that it runs as root" 'Warnings[^•]*(• [^•]*)*• Process is running as root' "$(tr '\n' ' ' <<<"$out")"
systemd-run -q --unit=holder bash -c 'exec 3>/tmp/held; sleep 600' >/dev/null
sleep 1
out=$(witr --file /tmp/held 2>&1) || true
assert_match "witr --file finds the process that holds a file open" 'holder\.service' "$out"
skip "witr --container redis" "no container runtime in the test container"
skip "brew install witr" "Homebrew is not tested; the formula exists on formulae.brew.sh"

pid=$(systemctl show -p MainPID --value web.service)
manual=$(note_block "$NOTE" 'Why is this running' 5 | sed "s/<pid>/$pid/")
check_output "the manual way: ss -tlnp shows the PID" "pid=$pid" bash -c "$(sed -n 1p <<<"$manual")"
check_output "and ps -o unit= gives the unit for systemctl status" 'web\.service' bash -c "$(sed -n 2p <<<"$manual")"
