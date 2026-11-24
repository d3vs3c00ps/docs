#!/usr/bin/env bash
# note: linux/desktop/sway/customization.md
# env: leap
# timeout: 900
# Sway runs headless (see headless.bash). Colors, fonts and themes are not looked at:
# the test checks that the lines are accepted and do what they say on the layout.
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/linux/desktop/sway/headless.bash" foot waybar dconf glib2-tools gsettings-desktop-schemas dbus-1 dbus-1-daemon
[[ -s /etc/machine-id ]] || dbus-uuidgen >/etc/machine-id   # dbus-run-session and Waybar need one

NOTE=linux/desktop/sway/customization
cd "$(mktemp -d)"
export LANG=C.UTF-8
blk() { note_block "$NOTE" "$@"; }
nodes() { swaymsg -t get_tree | jq -r "$1"; }
foot_count() { nodes '[.. | select(.app_id? == "foot")] | length'; }
more_foot() { (($(foot_count) > $1)); }
open_foot() {
  local n
  n=$(foot_count)
  foot >>"$XDG_RUNTIME_DIR/foot.log" 2>&1 &
  retry 20 more_foot "$n"
}

section "Gaps and borders"
blk "Gaps and borders" 1 >gaps.conf
check "the gaps and borders block passes sway -C (from the note)" sway_check gaps.conf
printf 'smart_borders on                     # no border either\n' >old.conf
check_fails "the old block, with comments at the end of lines, does not (the correction)" sway_check old.conf
{ echo 'set $term foot'; cat gaps.conf; } >live.conf
sway_start live.conf
open_foot
check_output "one window: smart_gaps and smart_borders leave no gap" '^0 0 1280 720$' \
  nodes '[.. | select(.app_id? == "foot")][0].rect | "\(.x) \(.y) \(.width) \(.height)"'
open_foot
check_output "two windows: the gaps come back (outer 2 + inner 6)" '^8 8$' \
  nodes '[.. | select(.app_id? == "foot")][0].rect | "\(.x) \(.y)"'
check_output "pixel 2: a 2-pixel border and no title bar" '^pixel 2 0$' \
  nodes '[.. | select(.app_id? == "foot")][0] | "\(.border) \(.current_border_width) \(.deco_rect.height)"'
swaymsg floating enable >/dev/null
check_output "a window made floating later keeps its tiled border (no title bar)" '^pixel 0$' \
  nodes '.. | select(.focused? == true) | "\(.border) \(.deco_rect.height)"'
skip "default_floating_border normal on a window that opens floating" "needs an app that opens a dialog; foot does not"
sway_stop

section "Window colors"
blk "Window colors" 1 >colors.conf
check "the client.* lines pass sway -C (from the note)" sway_check colors.conf
printf 'set $blue #89b4fa\nclient.focused $blue $blue #1e1e2e $blue $blue\n' >palette.conf
check "colors as Sway variables (One palette for every tool)" sway_check palette.conf

section "Fonts"
blk Fonts 1 >font.conf
check "the font line passes sway -C (from the note)" sway_check font.conf

section "Wallpaper"
mkdir -p ~/Pictures && touch ~/Pictures/wallpaper.jpg ~/Pictures/wide.jpg
blk Wallpaper 1 >bg.conf
check "the wallpaper lines pass sway -C (from the note)" sway_check bg.conf
for mode in fill fit stretch center tile; do
  printf 'output * bg ~/Pictures/wallpaper.jpg %s\n' "$mode" >m.conf
  check "bg mode $mode is accepted" sway_check m.conf
done
printf 'output * bg ~/Pictures/wallpaper.jpg nosuchmode\n' >m.conf
check_fails "an unknown mode is not" sway_check m.conf
{ echo 'set $term foot'; blk Wallpaper 1 | sed -n 2p; } >live.conf
sway_start live.conf
check "Sway starts swaybg itself" retry 10 pgrep -x swaybg
check_output "with the solid color" "swaybg .*-c #1e1e2e" pgrep -a swaybg
sway_stop

section "GTK theme, dark mode and cursor"
g=$(blk "GTK theme" 1)
out=$(dbus-run-session -- bash -c "$g && for k in color-scheme gtk-theme icon-theme cursor-theme font-name; do gsettings get org.gnome.desktop.interface \$k; done" 2>/dev/null)
assert_eq "the gsettings lines set every key (from the note)" \
  "$(printf "'prefer-dark'\n'Adwaita-dark'\n'Adwaita'\n'Adwaita'\n'Inter 10'")" "$out"
blk "GTK theme" 2 >cursor.conf
check "the seat cursor line passes sway -C (from the note)" sway_check cursor.conf

section "Qt applications"
check "the Qt profile lines are valid shell (from the note)" bash -n -c "$(blk "Qt applications" 1)"
assert_eq "QT_QPA_PLATFORM lists Wayland first, then xcb" 'wayland;xcb' "$(bash -c "$(blk "Qt applications" 1); echo \$QT_QPA_PLATFORM")"

section "Styling Waybar"
mkdir -p ~/.config/waybar
blk "Styling Waybar" 1 >~/.config/waybar/style.css
note_block linux/desktop/sway/ecosystem "Bar: Waybar" 1 >~/.config/waybar/config.jsonc
sway_start live.conf
dbus-run-session -- waybar >waybar.log 2>&1 &
wb=$!
sleep 4
check "Waybar runs with the note's style.css" kill -0 "$wb"
check_output "and reads it" 'style.css' grep -i 'Using CSS file' waybar.log
check_fails "with no CSS error" grep -iE 'parsing error|css.*error|error.*css' waybar.log
kill "$wb" 2>/dev/null || true
sway_stop
