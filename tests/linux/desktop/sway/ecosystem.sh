#!/usr/bin/env bash
# note: linux/desktop/sway/ecosystem.md
# env: leap
# timeout: 900
# Sway runs headless (see headless.bash): Waybar, grim, wl-clipboard and kanshi run
# against it. What needs a person (slurp, a lock screen, a login) is skipped.
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/linux/desktop/sway/headless.bash" waybar swayidle grim wl-clipboard kanshi file dbus-1 dbus-1-daemon
[[ -s /etc/machine-id ]] || dbus-uuidgen >/etc/machine-id   # Waybar starts a session bus, which needs one

NOTE=linux/desktop/sway/ecosystem
cd "$(mktemp -d)"
export LANG=C.UTF-8 HOME=$PWD
blk() { note_block "$NOTE" "$@"; }

section "Overview"
for p in foot waybar fuzzel mako swaylock swayidle grim slurp wl-clipboard kanshi \
  xdg-desktop-portal-wlr xdg-desktop-portal-gtk polkit-gnome pavucontrol brightnessctl wlsunset greetd tuigreet; do
  check "$p is packaged in Leap 16" zypper -n -q info "$p"
done
check_fails "cliphist is not (the note now says so)" bash -c 'zypper -n -q info cliphist | grep -q "^Name"'
check_fails "swayosd is not either" bash -c 'zypper -n -q info swayosd | grep -q "^Name"'

section "Bar: Waybar"
mkdir -p .config/waybar
blk 'Bar: Waybar' 1 >.config/waybar/config.jsonc
check "the Waybar config is valid JSON" jq -e . .config/waybar/config.jsonc
wrapped() { { echo '{'; blk 'Bar: Waybar' 2; echo '}'; } | jq -e .; }
check "the custom module snippet is valid JSON in an object" wrapped
blk 'Bar: Waybar' 3 >vpn-status.sh && chmod +x vpn-status.sh
check_output "vpn-status.sh prints one JSON line (no wg0 here)" '^\{"text":"no vpn","class":"down"\}$' bash -c './vpn-status.sh | jq -c .'
printf 'output * mode 1280x720\n' >sway.conf
sway_start sway.conf
dbus-run-session -- waybar -c .config/waybar/config.jsonc >waybar.log 2>&1 &
wb=$!
check "Waybar starts on Sway with the note's config" retry 10 grep -q 'Bar configured' waybar.log
grep -q 'Bar configured' waybar.log || sed 's/^/# /' waybar.log
check_fails "and reports no unknown module" grep -Ei 'unknown module|Disabling module' waybar.log
check "pkill -SIGUSR2 waybar (from the note)" bash -c "$(grep -o 'pkill -SIGUSR2 waybar' "$NOTES_ROOT/content/$NOTE.md" | head -1)"
sleep 1
check "Waybar is still running after SIGUSR2 (it reloads)" pgrep -x waybar
pkill -x waybar || true; kill $wb 2>/dev/null || true

section "Screenshots"
shots=$(blk Screenshots 1 | sed 's/#.*//')
# wl-copy stays in the background to serve the clipboard: keep it off the captured
# output, or the check waits for it forever. timeout guards grim the same way.
quiet() { timeout 30 bash -ec "$1" >/dev/null 2>&1 </dev/null; }
check "grim on all outputs (from the note)" quiet "$(sed -n 1p <<<"$shots")"
check_output "it wrote a PNG" 'PNG image data, 1280 x 720' file screenshot.png
check "grim -o the focused output, to the clipboard (from the note)" quiet "$(sed -n 4p <<<"$shots")"
check_output "the clipboard holds the PNG" 'PNG image data' bash -c 'timeout 10 wl-paste | file -'
skip "grim -g \"\$(slurp)\"" "slurp needs a person to draw the region"
blk Screenshots 2 >shot.conf
check "the Print bindings pass sway -C (from the note)" sway_check shot.conf

section "Lock and idle"
blk 'Lock and idle' 1 >idle.conf
check "the swayidle exec line passes sway -C (from the note)" sway_check idle.conf
check_output "swayidle has -w" '\-w' bash -c 'swayidle -h 2>&1; true'
check "output * power off (from the note)" swaymsg 'output * power off'
check_output "the output is off" '^false$' bash -c "swaymsg -t get_outputs | jq '.[0].power'"
swaymsg 'output * power on' >/dev/null
skip "swaylock" "it needs a person to type a password"

section "Clipboard"
{ echo 'set $mod Mod4'; blk Clipboard 1; } >clip.conf
check "the cliphist lines pass sway -C (from the note)" sway_check clip.conf
quiet 'echo hello | wl-copy'
check_output "wl-copy and wl-paste work" '^hello$' timeout 10 wl-paste

section "Screen sharing"
check_output "Leap's /etc/sway/config.d snippet imports the whole environment into systemd" '^ *systemctl --user import-environment$' \
  bash -c 'grep -rh "import-environment" /etc/sway/config.d/'
swaymsg exec 'env >$XDG_RUNTIME_DIR/sway.env' >/dev/null
retry 10 test -s "$XDG_RUNTIME_DIR/sway.env"
check_fails "the correction: Sway itself does not set XDG_CURRENT_DESKTOP" grep -q '^XDG_CURRENT_DESKTOP=' "$XDG_RUNTIME_DIR/sway.env"
check_output "Leap's session launcher sway-run.sh does" '^export XDG_CURRENT_DESKTOP=sway' cat /usr/bin/sway-run.sh

section "Display profiles: kanshi"
mkdir -p .config/kanshi && blk 'Display profiles' 1 >.config/kanshi/config
timeout 3 kanshi -c .config/kanshi/config >kanshi.log 2>&1 && rc=0 || rc=$?
assert_eq "kanshi reads the note's config and keeps running (killed by timeout)" 124 "$rc"
check_fails "with no parse error" grep -i 'error\|failed to parse' kanshi.log

section "Login"
check "the ~/.zprofile snippet is valid shell (from the note)" bash -n <(blk Login 1)
out=$(env -u WAYLAND_DISPLAY XDG_VTNR=2 bash -c "sway() { echo started; }; $(blk Login 1 | sed 's/exec sway/sway/')")
assert_eq "it does nothing on tty2" "" "$out"
out=$(env -u WAYLAND_DISPLAY -u XDG_CURRENT_DESKTOP XDG_VTNR=1 bash -c "sway() { echo \"started \$XDG_CURRENT_DESKTOP\"; }; $(blk Login 1 | sed 's/exec sway/sway/')")
assert_eq "it starts sway on tty1, with XDG_CURRENT_DESKTOP=sway" "started sway" "$out"
sway_stop
