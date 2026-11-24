#!/usr/bin/env bash
# note: linux/desktop/sway/basics.md
# env: leap
# timeout: 900
# Sway runs headless (see headless.bash): IPC, bindings, layouts and windows (foot)
# work without a screen. What needs a real screen or keyboard is not checked.
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/linux/desktop/sway/headless.bash" foot python3-i3ipc

NOTE=linux/desktop/sway/basics
cd "$(mktemp -d)"
export LANG=C.UTF-8
# nodes FILTER: jq FILTER on the container tree.
nodes() { swaymsg -t get_tree | jq -r "$1"; }
# open_foot: open a terminal and wait until Sway shows one more foot window.
foot_count() { nodes '[.. | select(.app_id? == "foot")] | length'; }
more_foot() { (($(foot_count) > $1)); }
open_foot() {
  local n
  n=$(foot_count)
  foot >>"$XDG_RUNTIME_DIR/foot.log" 2>&1 &
  retry 20 more_foot "$n"
}

section "Compositor, not window manager"
printf 'set $term foot\n' >min.conf
sway_start min.conf
check_output "there is no restart command" "invalid command .restart" bash -c 'swaymsg restart 2>&1; true'
sway_stop

section "Configuration file"
first_config() {
  rm -rf ~/.sway ~/.config/sway ~/.i3 ~/.config/i3
  local f
  for f in "$@"; do mkdir -p "$(dirname "$f")" && printf '# %s\n' "$f" >"$f"; done
  env -u SWAYSOCK -u WAYLAND_DISPLAY sway -d >"$SWAY_LOG" 2>&1 &
  SWAYSOCK=$XDG_RUNTIME_DIR/sway-ipc.$(id -u).$!.sock
  retry 20 swaymsg -t get_version
  swaymsg -t get_config | jq -r .config | head -1
  sway_stop
}
assert_eq "[~]/.sway/config comes first" "# $HOME/.sway/config" \
  "$(first_config ~/.sway/config ~/.config/sway/config ~/.i3/config)"
assert_eq "then ~/.config/sway/config" "# $HOME/.config/sway/config" \
  "$(first_config ~/.config/sway/config ~/.i3/config ~/.config/i3/config)"
assert_eq "then ~/.i3/config" "# $HOME/.i3/config" "$(first_config ~/.i3/config ~/.config/i3/config)"
assert_eq "then ~/.config/i3/config" "# $HOME/.config/i3/config" "$(first_config ~/.config/i3/config)"
assert_match "then /etc/sway/config" 'Default config for sway' "$(first_config)"
check "copy the default (from the note)" bash -ec "$(note_block "$NOTE" "Configuration file" 1)"
check "the copy is the default" cmp /etc/sway/config ~/.config/sway/config
check_output "the default ends with the include lines (openSUSE)" \
  '^include /etc/sway/config.d/\*.conf include ~/.config/sway/config.d/\*$' bash -c 'tail -2 /etc/sway/config | xargs -d "\n"'
check "sway -C accepts the default config" sway_check /etc/sway/config

section "Reload with an error"
printf 'set $term foot\n' >reload.conf
sway_start reload.conf
printf 'mode "added" {\n    bindsym Escape mode default\n}\nnot_a_command\n' >>reload.conf
check_output "swaymsg reload with a bad line" '"success": true' swaymsg reload
check_output "the error is reported" "Unknown/invalid command 'not_a_command'" cat "$SWAY_LOG"
check_output "the rest of the new config is applied (the correction)" '"added"' swaymsg -t get_binding_modes
check "sway -C finds the bad line first" bash -c '! sway_check reload.conf'
sway_stop

section "The container tree"
sway_start /etc/sway/config
while IFS='|' read -r key cmd; do
  assert_eq "Mod4+$key runs $cmd" "$cmd" "$(sway_bound "Mod4+$key")"
done <<'KEYS'
b|splith
v|splitv
s|layout stacking
w|layout tabbed
e|layout toggle split
a|focus parent
Shift+space|floating toggle
space|focus mode_toggle
Shift+minus|move scratchpad
minus|scratchpad show
KEYS
sway_stop
sway_start min.conf
open_foot
swaymsg splitv >/dev/null
open_foot
check_output "\$mod+v, then a terminal: the two windows are in a splitv container" '^splitv 2$' \
  nodes '.. | select(.nodes? and ([.nodes[] | select(.app_id == "foot")] | length) == 2) | "\(.layout) \(.nodes | length)"'
check_output "the new one is below" '^true$' \
  nodes '[.. | select(.app_id? == "foot")] | .[1].rect.y > .[0].rect.y'
swaymsg focus parent >/dev/null
check_output "\$mod+a: focus parent selects the container of both" '^2$' nodes '.. | select(.focused? == true) | .nodes | length'

section "Floating and scratchpad"
swaymsg focus child >/dev/null
swaymsg floating toggle >/dev/null
check_output "floating toggle makes the window float" 'floating_con' nodes '.. | select(.focused? == true) | .type'
swaymsg move scratchpad >/dev/null
check_output "move scratchpad hides it in __i3_scratch" '^1$' \
  nodes '.. | select(.name? == "__i3_scratch") | .floating_nodes | length'
swaymsg scratchpad show >/dev/null
check_output "scratchpad show brings it back, visible" '^true$' \
  nodes '.. | select(.focused? == true) | .visible'

section "Workspaces and outputs"
note_block "$NOTE" "Workspaces and outputs" 1 >ws-note.conf
check "the workspace lines pass sway -C (from the note)" sway_check ws-note.conf
sway_stop
# The note's lines with headless names: DP-2 is HEADLESS-2, plugged in later.
{ cat min.conf; sed 's/eDP-1/HEADLESS-1/g; s/DP-2/HEADLESS-2/g' ws-note.conf; } >ws.conf
sway_start ws.conf
swaymsg workspace 2 >/dev/null
ws2() { swaymsg -t get_workspaces | jq -r '.[] | select(.name == "2") | .output'; }
check_output "with only HEADLESS-1, workspace 2 uses the second output listed" '^HEADLESS-1$' ws2
open_foot
swaymsg workspace 1 >/dev/null
swaymsg create_output >/dev/null
check_output "once the first output listed is plugged in, workspace 2 (with its window) moves there" '^HEADLESS-2$' ws2

section "Inspecting the session with IPC"
blk=$(note_block "$NOTE" "Inspecting the session" 1)
for t in get_outputs get_inputs get_workspaces get_tree; do
  check_output "swaymsg -t $t returns JSON (from the note)" '^[\[{]' bash -ec "$(grep -E -- "-t $t( |\$)" <<<"$blk" | sed 's/ *#.*//')"
done
swaymsg '[app_id="foot"] focus' >/dev/null
check_output "the jq line prints the app_id of the focused window (from the note)" '^foot$' \
  bash -ec "$(grep 'jq -r' <<<"$blk")"
sub=$(grep 'subscribe' <<<"$blk" | sed 's/ *#.*//')
timeout 15 bash -c "$sub" >events.json 2>&1 &
mon=$!
timeout 5 swaymsg -t subscribe '["window"]' >one.json 2>&1 &
one=$!
sleep 1
open_foot
open_foot
check "without -m, swaymsg subscribe exits after one event" wait "$one"
check_output "with -m it keeps listening: two new windows, two events (from the note)" '^[2-9]' \
  bash -c "sleep 1; grep -c '\"change\": \"new\"' events.json"
kill "$mon" 2>/dev/null || true
blk=$(note_block "$NOTE" "Inspecting the session" 2)
check "swaymsg output ... scale 1.25 (from the note, on HEADLESS-1)" bash -ec "$(sed -n 1p <<<"$blk" | sed 's/eDP-1/HEADLESS-1/')"
check_output "the scale is applied" '^1.25$' bash -c "swaymsg -t get_outputs | jq -r '.[] | select(.name == \"HEADLESS-1\") | .scale'"
check "swaymsg '[app_id=\"foot\"] floating enable' (from the note)" bash -ec "$(sed -n 2p <<<"$blk")"
check_output "every foot window floats" '^true$' nodes '[.. | select(.app_id? == "foot") | .type] | all(. == "floating_con")'
check_output "Python i3ipc talks to Sway as to i3" 'sway version' \
  python3 -c 'import i3ipc; print(i3ipc.Connection().get_version().human_readable and "sway version")'
check_output "and reads the tree" 'foot' \
  python3 -c 'import i3ipc; print([w.app_id for w in i3ipc.Connection().get_tree().descendants()])'
skip "the X11 to Wayland tool table" "lists tool names; ecosystem.sh tests the tools that run headless"
sway_stop
