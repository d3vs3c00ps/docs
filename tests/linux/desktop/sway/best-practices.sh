#!/usr/bin/env bash
# note: linux/desktop/sway/best-practices.md
# env: leap-systemd
# timeout: 900
# A headless Sway (see headless.bash) inside a systemd container, with root's user
# manager standing in for a desktop login: the session target and Waybar as a service.
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/linux/desktop/sway/headless.bash" foot waybar dbus-1-tools

NOTE=linux/desktop/sway/best-practices
H="Run helpers as systemd user services"
cd "$(mktemp -d)"
export LANG=C.UTF-8
systemctl start user@0.service
# The user manager's runtime directory, so `systemctl --user` works from Sway's exec.
export XDG_RUNTIME_DIR=/run/user/0 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/0/bus
uctl() { systemctl --user "$@"; }
export -f uctl
# unit FILE BLOCK: write a unit block of the note to the file its first line names.
unit() {
  local f
  f=$(note_block "$NOTE" "$H" "$1" | sed -n '1s/^# //p')
  f=${f/#\~/$HOME}
  mkdir -p "$(dirname "$f")"
  note_block "$NOTE" "$H" "$1" | sed 1d >"$f"
  echo "$f"
}

section "Never lose the escape keys"
sway_start /etc/sway/config
assert_eq "\$mod+Return opens a terminal" 'exec $term' "$(sway_bound 'Mod4+Return' | sed 's/\$\$/$/')"
assert_eq "\$mod+Shift+c reloads" reload "$(sway_bound 'Mod4+Shift+c')"
check_output "\$mod+Shift+e opens openSUSE's system mode (exit is in it)" '^mode "What to do\?' sway_bound 'Mod4+Shift+e'
sway_stop

section "Export the session environment"
check_output "openSUSE's /etc/sway/config.d snippet imports the environment" '^ *systemctl --user import-environment' \
  bash -c "cat /etc/sway/config.d/*"
target=$(unit 1)
waybar_unit=$(unit 3)
check "the units pass systemd-analyze verify (from the note)" systemd-analyze --user verify "$target" "$waybar_unit"
{ echo 'set $term foot'; note_block "$NOTE" "Export the session environment" 1; } >sway.conf
# Sway does not set XDG_CURRENT_DESKTOP: the session launcher does (sway-run.sh on Leap).
export XDG_CURRENT_DESKTOP=sway
sway_start sway.conf
unset XDG_CURRENT_DESKTOP
check "the distribution-style snippet runs (from the note)" \
  retry 10 bash -c "uctl show-environment | grep -q '^SWAYSOCK=$SWAYSOCK$'"
check_output "the check from the note shows the variables" 'WAYLAND_DISPLAY=wayland' \
  bash -ec "$(note_block "$NOTE" "Export the session environment" 2)"
check_output "XDG_CURRENT_DESKTOP=sway from the launcher reaches systemd" '^XDG_CURRENT_DESKTOP=sway$' \
  bash -c "uctl show-environment | grep XDG_CURRENT_DESKTOP"
sway_stop
uctl unset-environment DISPLAY WAYLAND_DISPLAY SWAYSOCK XDG_CURRENT_DESKTOP

section "$H"
check "the waybar unit's ExecStart exists" test -x /usr/bin/waybar
check "systemctl --user enable --now waybar.service (from the note)" \
  bash -ec "$(note_block "$NOTE" "$H" 4 | grep enable)"
{ echo 'set $term foot'; note_block "$NOTE" "$H" 2 | grep '^exec'; note_block "$NOTE" "$H" 5; } >session.conf
sway_start session.conf
check "the exec line starts sway-session.target" retry 15 uctl is-active sway-session.target
check "which pulls in graphical-session.target" uctl is-active graphical-session.target
check "and Waybar runs as a service" retry 15 uctl is-active waybar.service
check_output "with the session variables" 'SWAYSOCK=' bash -c "tr '\0' '\n' </proc/\$(uctl show -P MainPID waybar)/environ"
check_output "its output is in the journal (from the note)" 'waybar' \
  bash -c "journalctl --user -u waybar --no-pager | head -20"
pid=$(uctl show -P MainPID waybar)
kill -9 "$pid"
check "Restart=on-failure restarts Waybar after a crash" \
  retry 15 bash -c "uctl is-active waybar.service && [[ \$(uctl show -P MainPID waybar) != $pid ]]"
retry 15 uctl is-active waybar.service || uctl status waybar.service --no-pager | sed 's/^/# /'
check "ExecReload sends SIGUSR2" retry 10 uctl reload waybar.service
check_output "and Waybar reloads its config" 'Reloading' bash -c "sleep 1; journalctl --user -u waybar --no-pager"
sway_stop
# In this headless Sway 1.10, swaymsg loses the IPC connection at exit ("Unable to
# receive IPC response") and the && part never runs. Not confirmed either way here.
skip "on exit, the shutdown line stops sway-session.target" "headless Sway 1.10 closes IPC before swaymsg gets the shutdown event; needs a real session"
uctl stop sway-session.target
check "stopping sway-session.target stops graphical-session.target" retry 15 bash -c '! uctl is-active graphical-session.target'
check "and Waybar, which is PartOf it" retry 15 bash -c '! uctl is-active waybar.service'

section "Prefer native Wayland applications"
printf 'for_window [shell="xwayland"] title_format "[X] %%title"\n' >x.conf
assert_eq "the XWayland marker rule is the one in the note" \
  "$(grep -o 'for_window \[shell="xwayland"\] title_format "\[X\] %title"' "$NOTES_ROOT/content/$NOTE.md")" "$(cat x.conf)"
check "and passes sway -C" sway_check x.conf
skip "Chromium and Electron under XWayland" "needs a browser and XWayland; not in the test image"

section "NVIDIA"
skip "the NVIDIA warning bar (Sway 1.12)" "needs NVIDIA hardware, and Leap 16 ships Sway 1.10; from the Sway 1.12 release notes"

section "Debugging"
blk=$(note_block "$NOTE" Debugging 1)
check "sway -d 2> ~/sway.log (from the note, stopped after 3 s)" \
  bash -c "env -u WAYLAND_DISPLAY -u SWAYSOCK timeout -k 2 3 $(sed -n 1p <<<"$blk" | sed 's/ *#.*//') >/dev/null </dev/null; true"
check_output "writes a debug log" '\[DEBUG\]' head -50 ~/sway.log
printf 'set $term foot\n' >min.conf
sway_start min.conf
check_output "swaymsg -t get_version (from the note)" 'sway version|"human_readable"' bash -c "$(sed -n 2p <<<"$blk")"
check_output "journalctl --user -b (from the note)" 'waybar' bash -c "$(sed -n 3p <<<"$blk" | sed 's/ *#.*//') --no-pager"
check_output "WAYLAND_DEBUG=1 foot traces the protocol (from the note)" 'wl_display' \
  bash -c "timeout -k 2 3 env $(sed -n 4p <<<"$blk" | sed 's/ *#.*//') 2>&1 </dev/null; true"
sway_stop
