#!/usr/bin/env bash
# note: linux/cli/journalctl.md
# env: leap-systemd
source "$NOTES_ROOT/tests/lib/assert.sh"

NOTE=linux/cli/journalctl
export SYSTEMD_PAGER=cat
zypper -n -q install --no-recommends openssh-server util-linux-systemd >/dev/null
# block HEADING [N]: a block of the note, one command per line, run with no pager.
block() { note_block "$NOTE" "$@"; }
logger -p user.notice "journal-test notice"
for p in crit err warning debug; do logger -p "user.$p" "journal-test $p"; done
journalctl --sync

section "View all logs"
check_output "journalctl prints the test entries" 'journal-test notice' bash -ec "$(block 'View all logs')"

section "Follow logs in real time"
( sleep 2; logger "journal-test followed" ) &
check_output "journalctl -f shows a new entry as it arrives" 'journal-test followed' \
  bash -c "timeout 5 $(block 'Follow logs') || true"

section "Logs from a specific boot"
check_output "--list-boots lists the current boot as 0" '^ *0 [0-9a-f]{32}' bash -ec "$(block 'specific boot' 1)"
check_output "-b 0 shows this boot" 'journal-test notice' bash -ec "$(block 'specific boot' 2)"
check_fails "-b -1 fails when there is no previous boot" journalctl -b -1

section "Filter by time"
while IFS= read -r cmd; do
  check "$cmd" bash -ec "$cmd"
done < <(block 'Filter by time')
check_output "--since today has today's entries" 'journal-test notice' journalctl --since today
check_output "a window in 2020 has no entries" '^-- No entries --$' \
  bash -ec "$(block 'Filter by time' | sed -n 3p)"

section "Filter by unit"
systemctl start sshd.service
retry 10 systemctl is-active sshd.service
journalctl --sync
units=$(block 'Filter by unit')
check_output "-u systemd-journald" 'systemd-journald' bash -ec "$(sed -n 1p <<<"$units")"
check_output "-u sshd.service shows the server starting" 'Server listening' bash -ec "$(sed -n 2p <<<"$units")"
check_output "a path selects what that program wrote" 'Server listening' bash -ec "$(sed -n 3p <<<"$units")"
check_output "/sbin/sshd works too: /sbin is a link to /usr/sbin" 'Server listening' journalctl /sbin/sshd

section "Add explanatory text"
check "-x is accepted (from the note)" bash -ec "$(block 'explanatory text')"
check_output "and adds explanations to systemd's own entries" '^░░ ' journalctl -x -u sshd.service

section "Filter by PID"
# systemd-cat sends stdout to the journal: the PID goes to a file instead.
systemd-cat -t pidtest bash -c 'echo "journal-test pid $$"; echo $$ >/tmp/pidtest'
pid=$(cat /tmp/pidtest)
journalctl --sync
check_output "_PID= selects one process" 'journal-test pid' bash -ec "$(block 'Filter by PID' | sed "s/42/$pid/")"

section "Filter by user"
useradd -u 1042 bob
runuser -u bob -- logger "journal-test from bob"
journalctl --sync
out=$(bash -ec "$(block 'Filter by user')")
assert_match "_UID=1042 shows bob's entry" 'journal-test from bob' "$out"
assert_no_match "and not root's" 'journal-test notice' "$out"

section "Filter by priority"
out=$(bash -ec "$(block 'Filter by priority' 1)")
assert_match "-p err includes err" 'journal-test err' "$out"
assert_match "and crit, which is more severe" 'journal-test crit' "$out"
assert_no_match "but not warning" 'journal-test warning' "$out"
assert_eq "-p 3 is the same as -p err" "$out" "$(journalctl -p 3)"
out=$(bash -ec "$(block 'Filter by priority' 2)")
assert_match "-p 2..4 includes crit" 'journal-test crit' "$out"
assert_match "and warning" 'journal-test warning' "$out"
assert_no_match "but not notice" 'journal-test notice' "$out"
# The table: each name maps to its number in journalctl's own parser.
while IFS='|' read -r _ num name _; do
  num=$(tr -d ' ' <<<"$num"); name=$(tr -d ' `' <<<"$name")
  [[ $num =~ ^[0-7]$ ]] || continue
  assert_eq "the table: -p $name is -p $num" "$(journalctl -p "$num" -o cat | md5sum)" "$(journalctl -p "$name" -o cat | md5sum)"
done < <(sed -n '/^| Priority/,/^$/p' "$NOTES_ROOT/content/$NOTE.md")

section "Kernel logs"
check "-k runs (from the note)" bash -ec "$(block 'Kernel logs')"
skip "kernel messages in the output" "a container's journald does not read the kernel log"

section "Filter by transport"
check_output "logger entries came in over syslog" 'journal-test notice' bash -ec "$(block 'Filter by transport')"
check_output "systemd-cat entries are stdout" 'journal-test pid' journalctl _TRANSPORT=stdout
transports=$(journalctl -F _TRANSPORT | sort | xargs)
assert_match "the transports seen here are among the note's list" '^((audit|driver|syslog|journal|stdout|kernel) ?)+$' "$transports"

section "Managing journal disk usage"
check_output "--disk-usage" 'take up' bash -ec "$(block 'disk usage' 1)"
check_output "--vacuum-size=100M" 'Vacuuming done' bash -ec "$(block 'disk usage' 2)"
check_output "--vacuum-time=1months" 'Vacuuming done' bash -ec "$(block 'disk usage' 3)"
check_fails "Leap 16 has no /etc/systemd/journald.conf" test -e /etc/systemd/journald.conf
check "the defaults are in /usr/lib/systemd/journald.conf" test -f /usr/lib/systemd/journald.conf
check "the drop-in (from the note)" bash -ec "$(block 'disk usage' 4)"
check_output "systemd-analyze cat-config shows it" 'SystemMaxUse=500M' systemd-analyze cat-config systemd/journald.conf
if [[ -d /var/log/journal ]]; then
  retry 5 bash -c 'journalctl -u systemd-journald -o cat | grep -Eq "System Journal .*max 500(\.0)?M"' || true
  check_output "journald applies the 500M limit to the persistent journal" 'System Journal .*max 500(\.0)?M' \
    bash -c 'journalctl -u systemd-journald -o cat | grep "Journal"'
else
  check_output "the journal is volatile here, so RuntimeMaxUse= applies, not 500M" 'Runtime Journal' \
    journalctl -u systemd-journald -o cat
fi
