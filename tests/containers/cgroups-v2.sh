#!/usr/bin/env bash
# note: containers/cgroups-v2.md
# env: leap-systemd
source "$NOTES_ROOT/tests/lib/assert.sh"

NOTE=containers/cgroups-v2
zypper -n -q install --no-recommends sudo >/dev/null
cd /work
# The env's cgroup-controllers unit can race systemd's own cgroup moves at boot;
# make sure the controllers this test needs really are enabled for children.
for c in cpu memory pids; do echo "+$c" > /sys/fs/cgroup/cgroup.subtree_control; done

section "The unified hierarchy"
# In a container the mount source is named "cgroup"; on a host, "cgroup2". Same filesystem.
check_output "mount shows one cgroup2 filesystem (from the note)" 'on /sys/fs/cgroup type cgroup2' \
  bash -ec "$(note_block "$NOTE" 'The unified hierarchy' 1 | sed -n 1p)"
check_output "/proc/self/cgroup is a single 0:: line" '^0::/' cat /proc/self/cgroup
assert_eq "it is the only line (v1 printed one per controller)" 1 "$(grep -c . /proc/self/cgroup)"

section "Controllers"
check_output "cgroup.controllers lists the controllers (from the note)" 'memory' \
  bash -ec "$(note_block "$NOTE" Controllers 1 | sed -n 1p)"
for c in cpu memory pids; do
  assert_match "the $c controller is available" "\b$c\b" "$(cat /sys/fs/cgroup/cgroup.controllers)"
done

section "Creating one by hand"
check "the note's block creates the cgroup and sets its limits" \
  bash -ec "$(note_block "$NOTE" 'Creating one by hand' 1 | grep -v 'cgroup.procs')"
assert_file "the demo cgroup exists" /sys/fs/cgroup/demo
assert_eq "memory.max holds the limit" 104857600 "$(cat /sys/fs/cgroup/demo/memory.max)"
assert_eq "pids.max holds the limit" 50 "$(cat /sys/fs/cgroup/demo/pids.max)"
check "moving a process in via cgroup.procs works" \
  bash -c 'echo $$ > /sys/fs/cgroup/demo/cgroup.procs && cat /sys/fs/cgroup/demo/memory.current'
check "watching it: memory.current and memory.events (from the note)" \
  bash -ec "$(note_block "$NOTE" 'Creating one by hand' 2)"
check "pids.max is a fork bomb defence: forks beyond the limit are refused" \
  bash -c 'echo $$ > /sys/fs/cgroup/demo/cgroup.procs
           for i in $(seq 80); do (sleep 0.2 &) 2>/dev/null; done
           sleep 1
           grep -q "max [1-9]" /sys/fs/cgroup/demo/pids.events'

section "The no-internal-process rule"
retry 10 bash -c '! grep -q . /sys/fs/cgroup/demo/cgroup.procs'
mkdir -p /sys/fs/cgroup/demo/child
echo "+memory" > /sys/fs/cgroup/demo/cgroup.subtree_control
check_fails "a cgroup with controlled children refuses processes (EBUSY)" \
  bash -c 'echo $$ > /sys/fs/cgroup/demo/cgroup.procs'
rmdir /sys/fs/cgroup/demo/child

section "Memory"
if [[ -f /sys/fs/cgroup/demo/memory.pressure ]]; then
  check_output "memory.pressure shows PSI some/full lines (from the note)" 'some avg10=' \
    bash -ec "$(note_block "$NOTE" 'Memory' 1 | sed -n 1p)"
else
  skip "memory.pressure shows PSI lines" "kernel built or booted without PSI"
fi
for f in memory.high memory.low memory.min memory.events; do
  assert_file "the table's $f interface file exists" /sys/fs/cgroup/demo/$f
done

section "CPU"
check "set cpu.max to half a core (from the note)" \
  bash -ec "$(note_block "$NOTE" 'CPU' 1 | sed -n 1p)"
assert_eq "cpu.max holds quota and period" "50000 100000" "$(cat /sys/fs/cgroup/demo/cpu.max)"
check "reset cpu.max to unlimited (from the note)" \
  bash -ec "$(note_block "$NOTE" 'CPU' 1 | sed -n 2p)"
assert_eq "max means unlimited" "max 100000" "$(cat /sys/fs/cgroup/demo/cpu.max)"
check_output "cpu.stat has the throttle counters" 'nr_throttled' cat /sys/fs/cgroup/demo/cpu.stat

section "PIDs and I/O"
assert_file "pids.current exists" /sys/fs/cgroup/demo/pids.current
if [[ -f /sys/fs/cgroup/demo/io.max ]]; then
  check "io.stat is readable" cat /sys/fs/cgroup/demo/io.stat
else
  skip "io.max / io.stat" "the io controller is not delegated in this container"
fi

section "systemd is the real interface"
check "systemd-cgls shows the tree" bash -c 'systemd-cgls --no-pager | head -5'
systemd-run --unit notes-demo.service sleep 300 >/dev/null 2>&1
check "systemctl set-property MemoryMax + CPUQuota (as the note shows)" \
  systemctl set-property notes-demo.service MemoryMax=2G CPUQuota=50%
assert_eq "MemoryMax=2G landed in memory.max" 2147483648 \
  "$(cat /sys/fs/cgroup/system.slice/notes-demo.service/memory.max)"
assert_eq "CPUQuota=50% landed in cpu.max" "50000 100000" \
  "$(cat /sys/fs/cgroup/system.slice/notes-demo.service/cpu.max)"
systemctl stop notes-demo.service

section "What changed from v1"
check_output "stat -fc %T reports cgroup2fs (from the note)" '^cgroup2fs$' \
  bash -ec "$(note_block "$NOTE" 'What changed from v1' 1 | sed -n 1p)"

# "Remove it with rmdir once empty" (the container is discarded anyway)
rmdir /sys/fs/cgroup/demo 2>/dev/null || true
