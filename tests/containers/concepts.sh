#!/usr/bin/env bash
# note: containers/concepts.md
# env: priv:leap
source "$NOTES_ROOT/tests/lib/assert.sh"

NOTE=containers/concepts
cd "$(mktemp -d)"
zypper -n -q install --no-recommends libcap-progs >/dev/null

section "1. Namespaces — what a process can see"
check "ls -l /proc/self/ns/ (from the note)" bash -ec "$(note_block "$NOTE" 'Namespaces' 1 | sed -n 1p)"
ns=$(ls /proc/self/ns/)
for n in pid mnt net uts ipc user cgroup time; do
  assert_match "the $n namespace from the table exists" "^$n\$" "$ns"
done
check_output "lsns lists this shell's namespaces" 'bash' lsns
check_output "lsns -p works on a PID" 'mnt' bash -c 'lsns -p $$'

# nsenter: enter the namespaces of an unshared process, as the note does for containers.
unshare --pid --net --mount --uts --ipc --fork --mount-proc sleep 300 &
UPID=$!
retry 10 bash -c "ls /proc/$UPID/task/*/children | head -1 >/dev/null"
INNER=$(pgrep -P "$UPID" sleep || echo "$UPID")
check_output "nsenter -t <pid> -n shows that namespace's interfaces (lo only)" \
  '1: lo' nsenter -t "$INNER" -n ip addr
check_output "nsenter -t <pid> -a enters all namespaces" '^1$' \
  bash -c "nsenter -t $INNER -a sh -c 'ls /proc | grep -c \"^1\$\"'"
kill "$UPID" 2>/dev/null || true

section "2. The user namespace, specifically"
check_output "/proc/self/uid_map of the initial namespace maps everything" \
  '^ *0 +0 +4294967295$' cat /proc/self/uid_map
check_output "an unshared user namespace maps root to the outside UID" '^ *0 +0 +1$' \
  unshare --user --map-root-user cat /proc/self/uid_map

section "4. Capabilities, seccomp and LSMs"
check_output "capsh --print shows the current capability sets" 'Current:' capsh --print
check_output "grep Cap /proc/self/status (from the note)" 'CapEff' \
  bash -ec "$(note_block "$NOTE" 'Capabilities' 1 | sed -n 2p)"

section "Putting it together: unshare by hand"
# The note's block is an interactive shell; run its inspection commands non-interactively.
check_output "inside: the hostname can diverge from the host's" '^inner$' \
  unshare --pid --net --mount --uts --ipc --fork --mount-proc \
  bash -c 'hostname inner && hostname'
assert_no_match "outside: the hostname did not change" '^inner$' "$(hostname)"
check_output "inside: the first process is PID 1" '^ *1 ' \
  unshare --pid --net --mount --uts --ipc --fork --mount-proc ps -o pid,comm
check_output "inside: ip addr shows only loopback" '^1: lo' \
  unshare --pid --net --mount --uts --ipc --fork --mount-proc ip addr
