#!/usr/bin/env bash
# note: linux/cli/lnav.md
# env: rocky
# lnav and multitail come from EPEL, as the note installs them. lnav runs headless
# (-n), which prints the view instead of drawing it.
source "$NOTES_ROOT/tests/lib/assert.sh"

NOTE=linux/cli/lnav
export HOME=/root TERM=xterm
dnf -y -q install epel-release >/dev/null
dnf -y -q install --setopt=install_weak_deps=False make >/dev/null
cd "$(mktemp -d)"
mkdir -p /var/log/nginx
# Two logs whose lines interleave in time, as nginx writes them.
cat >/var/log/nginx/access.log <<'EOS'
10.0.0.2 - - [11/Aug/2026:08:59:58 +0000] "GET /healthcheck HTTP/1.1" 200 2 "-" "kube-probe/1.37"
10.0.0.1 - - [11/Aug/2026:09:00:01 +0000] "GET / HTTP/1.1" 200 512 "-" "curl/8"
10.0.0.2 - - [11/Aug/2026:09:00:03 +0000] "GET /healthcheck HTTP/1.1" 200 2 "-" "kube-probe/1.37"
10.0.0.1 - - [11/Aug/2026:09:30:05 +0000] "GET /api HTTP/1.1" 502 157 "-" "curl/8"
10.0.0.3 - - [11/Aug/2026:10:30:07 +0000] "GET /api HTTP/1.1" 500 157 "-" "curl/8"
10.0.0.1 - - [11/Aug/2026:10:30:09 +0000] "GET / HTTP/1.1" 200 512 "-" "curl/8"
EOS
cat >/var/log/nginx/error.log <<'EOS'
2026/08/11 09:00:02 [error] 7#7: *1 connect() failed (111: Connection refused) while connecting to upstream
2026/08/11 09:30:04 [error] 7#7: *2 upstream timed out (110: Connection timed out)
EOS
headless() { lnav -n "$@" 2>&1; }

section "Installation"
check "dnf install lnav (from the note, EPEL)" bash -ec "$(note_block "$NOTE" Installation 1 | sed -n 1p | sed 's/sudo dnf install/dnf -y -q install/; s/ *#.*//')"
check_output "lnav runs" '^lnav [0-9]' lnav -V

section "Viewing files"
check_output "one file (from the note)" 'connect\(\) failed' headless /var/log/nginx/error.log
out=$(headless /var/log/nginx/access.log /var/log/nginx/error.log)
order=$(grep -oE '09:00:01|09:00:02|09:00:03|09:30:04|09:30:05' <<<"$out" | xargs)
assert_eq "two files are merged in time order" "09:00:01 09:00:02 09:00:03 09:30:04 09:30:05" "$order"
cp /var/log/nginx/access.log old.log && gzip old.log && bzip2 -c /var/log/nginx/error.log >old2.log.bz2
check_output "a .gz file is read as is" 'healthcheck' headless old.log.gz
check_output "and a .bz2 file" 'upstream timed out' headless old2.log.bz2
check_output "the headless filter (from the note)" '/api' bash -ec "$(note_block "$NOTE" 'Viewing files' 3)"
check_fails "drops the health checks" bash -ec "$(note_block "$NOTE" 'Viewing files' 3) | grep -q healthcheck"

section "Container logs"
check_output "lnav reads a log from a pipe" 'healthcheck' bash -c 'cat /var/log/nginx/access.log | lnav -n'
skip "docker logs | lnav and docker:// URLs" "no Docker inside the test container"

section "Output of a command"
printf 'test:\n\t@echo "all 3 tests passed"\n' >Makefile
check_output "lnav -e runs the command and shows its output" 'all 3 tests passed' \
  bash -ec "$(note_block "$NOTE" 'Output of a command' 1 | sed 's/^lnav /lnav -n /')"

section "Keys worth knowing"
skip "the interactive keys" "they need a terminal; checked against lnav's docs/source/hotkeys.rst"

section "Filtering"
while IFS= read -r cmd; do
  out=$(headless -c "$cmd" /var/log/nginx/access.log)
  case $cmd in
    :filter-in*) assert_no_match "$cmd keeps only matching lines" '" 200 ' "$out" ;;
    :filter-out*) assert_no_match "$cmd drops matching lines" 'healthcheck' "$out" ;;
    :hide-lines-before*) assert_no_match "$cmd hides the earlier lines" '08:59:58' "$out"
      assert_match "and keeps the later ones" '10:30:07' "$out" ;;
    :hide-lines-after*) assert_no_match "$cmd hides the later lines" '10:30:07' "$out"
      assert_match "and keeps the earlier ones" '09:00:01' "$out" ;;
  esac
done < <(note_block "$NOTE" Filtering 1)
sed 's/" 502 /" 502 error /' /var/log/nginx/access.log >marked.log
check_output ":filter-in error keeps the matching line" 'error' headless -c ':filter-in error' marked.log

section "SQL over log files"
out=$(headless -c "$(note_block "$NOTE" 'SQL over' 1)" /var/log/nginx/access.log)
assert_match "top client IPs: 10.0.0.1 has 3 hits" '10\.0\.0\.1 +3' "$out"
out=$(headless -c "$(note_block "$NOTE" 'SQL over' 2)" /var/log/nginx/access.log)
assert_match "sc_status >= 500 finds the 500" '/api' "$out"
assert_no_match "and not the 200s" 'healthcheck' "$out"
check_output ".schema lists the access_log table" 'access_log' headless -c ';.schema' /var/log/nginx/access.log

section "multitail — the other approach"
check "dnf install multitail (from the note)" dnf -y -q install multitail
touch /var/log/syslog /var/log/auth.log /var/log/messages /var/log/secure
# Each command must start and keep running; a bad option makes multitail exit at once.
while IFS= read -r line; do
  cmd=${line%%#*}
  [[ $cmd == multitail* ]] || continue
  cmd=${cmd//kubectl logs -f deploy\/api/sleep 30}
  rc=0
  script -qec "stty cols 160 rows 40; timeout 3 $cmd" /dev/null >/dev/null 2>&1 </dev/null || rc=$?
  assert_eq "${cmd% } starts and keeps running" 124 "$rc"
done < <(note_block "$NOTE" multitail 1)
check_fails "an unknown colour scheme is an error" bash -c "script -qec 'timeout 3 multitail -cS nope /var/log/secure' /dev/null </dev/null >/dev/null 2>&1; [[ \$? == 124 ]]"
