#!/usr/bin/env bash
# note: linux/storage/disk-io-performance.md
# env: rocky-systemd
# The commands that repeat forever get a count, so the test ends. The device is the
# container's first virtual disk instead of nvme0n1.
source "$NOTES_ROOT/tests/lib/assert.sh"

NOTE=linux/storage/disk-io-performance
block() { note_block "$NOTE" "$@" | sed 's/^sudo //'; }
DISK=$(lsblk -dno NAME | grep -E '^(vd|sd|nvme)' | head -1)

section "The first look: iostat"
check "dnf install sysstat (from the note)" bash -ec "$(block 'The first look' 1 | grep dnf | sed 's/dnf install/dnf -y -q install/')"
out=$(iostat -xz 2 2)
for col in r_await w_await aqu-sz %util r/s w/s rkB/s wkB/s; do
  assert_match "iostat -xz has the $col column" "[[:space:]]${col//\//\\/}([[:space:]]|$)" "$out"
done
assert_eq "iostat -xz 2 2 prints two reports" 2 "$(grep -c '^Device' <<<"$out")"
check_output "-y leaves out the first report, the one since boot" '^Device' iostat -xzy 2 1

section "Which process is responsible"
dnf -y -q install iotop strace lsof >/dev/null
check_output "dnf install iotop gives iotop-c on Rocky 10" '^iotop-c' rpm -qf "$(command -v iotop)"
check_output "iotop -obn (from the note, one iteration)" 'DISK READ' bash -ec "$(block 'Which process' 1 | sed -n 3p | sed 's/-obn 5/-obn 1/; s/#.*//')"
check "iotop -o and -oPa are valid in batch mode" bash -c 'iotop -ob -n 1 >/dev/null && iotop -oPab -n 1 >/dev/null'
check_output "pidstat -d (from the note, one sample)" 'kB_rd/s' bash -ec "$(block 'Which process' 2 | sed -n 1p | sed 's/2 .*/2 1/')"
sleep 300 &
check_output "pidstat -d -p with pgrep -d, (from the note)" 'sleep' \
  bash -ec "$(block 'Which process' 2 | sed -n 2p | sed "s/postgres/'sleep 300'/; s/-d 2 -p/-d 2 1 -p/")"
kill %1
io=$(cat /proc/self/io)
for f in rchar wchar read_bytes write_bytes; do assert_match "/proc/<pid>/io has $f" "^$f:" "$io"; done
head -c 50M /dev/urandom >cached && cat cached >/dev/null
out=$(python3 -c 'open("cached","rb").read(); print(open("/proc/self/io").read())')
rchar=$(sed -n 's/^rchar: //p' <<<"$out"); read_bytes=$(sed -n 's/^read_bytes: //p' <<<"$out")
# read_bytes also counts Python's own start-up files: allow a little.
check "a cached 50 MB read: rchar $rchar, read_bytes only $read_bytes (under 10 MB)" \
  test "$rchar" -gt 50000000 -a "$read_bytes" -lt 10000000

section "Pressure stall information"
check_output "/proc/pressure/io has some and full lines" '^full avg10=[0-9.]+ avg60=[0-9.]+ avg300=[0-9.]+ total=[0-9]+$' \
  bash -ec "$(block 'Pressure stall' 1)"
systemd-run --unit myapp sleep 300 >/dev/null
check_output "per service io.pressure (from the note)" '^some avg10=' bash -ec "$(block 'Pressure stall' 2)"
systemctl stop myapp

section "Historical data"
check "enable sysstat and its collection timer (from the note)" bash -ec "$(block 'Historical data' 1 | sed -n 1p)"
/usr/lib64/sa/sa1 1 2
day=$(date +%d)
check "the daily file is /var/log/sa/saDD" test -f "/var/log/sa/sa$day"
check_output "sar -d -p reads today's file, by device name" "$DISK" sar -d -p
check_output "sar -d -p -f reads another day's file (as in the note)" 'Average' sar -d -p -f "/var/log/sa/sa$day"
check_output "sar -b reads the overall I/O rates" 'tps' sar -b
# The original 'sar -d -p 1' and 'sar -b 1' sample live, every second, without end.
check_fails "the original sar -b 1 never stops (killed after 4 s)" timeout 4 sar -b 1
check_output "the note now shows today's file, not a live sample" '^sar -d -p +#' block 'Historical data' 1

section "Filesystem and layer effects"
check_output "lsblk -t" 'SCHED' lsblk -t
check_output "the scheduler file lists the choices, [current] in brackets" '\[' cat "/sys/block/$DISK/queue/scheduler"
check_output "rotational is 0 or 1" '^[01]$' cat "/sys/block/$DISK/queue/rotational"
check "fstrim.timer exists" systemctl cat fstrim.timer
skip "cryptsetup status, /proc/mdstat" "no encrypted volume or md RAID in a container"

section "A diagnostic sequence"
sleep 300 &
pid=$!
seq=$(block 'A diagnostic sequence' 1 | sed "s/<pid>/$pid/g; s/iostat -xz 2 3/iostat -xz 1 2/; s/iotop -oPa/iotop -oPab -n 1/; s/strace -c -p $pid/timeout -s INT 2 strace -c -p $pid/")
/usr/lib64/sa/sa1 1 1 2>/dev/null || true
check "the sequence runs (yesterday's sar file may be missing)" bash -c "$(sed '/sar -d -p -f/d' <<<"$seq")"
check_output "date +%d -d yesterday gives the day of the file name" '^[0-3][0-9]$' date +%d -d yesterday
kill $pid
check "the D-state filter (from the note)" bash -ec "$(block 'A diagnostic sequence' 2)"
