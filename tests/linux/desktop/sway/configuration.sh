#!/usr/bin/env bash
# note: linux/desktop/sway/configuration.md
# env: leap
# timeout: 900
# Sway runs headless (see headless.bash). Bindings are read from its debug log;
# outputs are virtual (HEADLESS-n). Keyboards, touchpads and media keys are not there.
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/linux/desktop/sway/headless.bash" foot

NOTE=linux/desktop/sway/configuration
cd "$(mktemp -d)"
export LANG=C.UTF-8
blk() { note_block "$NOTE" "$@"; }
nodes() { swaymsg -t get_tree | jq -r "$1"; }
foot_count() { nodes '[.. | select(.app_id? == "foot")] | length'; }
more_foot() { (($(foot_count) > $1)); }
# open_foot [ARGS]: open a terminal and wait until Sway shows it.
open_foot() {
  local n
  n=$(foot_count)
  foot "$@" >>"$XDG_RUNTIME_DIR/foot.log" 2>&1 &
  retry 20 more_foot "$n"
}

section "Variables and keybindings"
{ blk Variables 1; blk Keybindings 1; blk Keybindings 2; blk Modes 1; } >main.conf
check "variables, bindings, media keys and the system mode pass sway -C (from the note)" sway_check main.conf
sway_start main.conf
while IFS='|' read -r keys cmd; do
  assert_eq "$keys runs $cmd" "$cmd" "$(sway_bound "$keys")"
done <<'KEYS'
Mod4+Return|exec foot
Mod4+d|exec fuzzel
Mod4+Shift+q|kill
Mod4+Shift+c|reload
Mod4+h|focus left
Mod4+Shift+h|move left
XF86AudioRaiseVolume|exec wpctl set-volume -l 1.0 @DEFAULT_AUDIO_SINK@ 5%+
XF86MonBrightnessDown|exec brightnessctl set 5%-
Mod4+Shift+e|mode "(l)ock  (e)xit  (s)uspend  (r)eboot  (p)oweroff"
KEYS
check_output "the system mode exists" '\(l\)ock  \(e\)xit' swaymsg -t get_binding_modes
swaymsg 'mode "(l)ock  (e)xit  (s)uspend  (r)eboot  (p)oweroff"' >/dev/null
check_output "Escape is bound in it, back to default" 'mode "default"' grep -A0 'Bound Escape to command' "$SWAY_LOG"
sway_stop
printf 'set $mod Mod4   # the Super / Windows key\nbindsym $mod+Return exec foot\n' >old.conf
check "a trailing comment on set: sway -C reports nothing" sway_check old.conf
sway_start old.conf
assert_eq "but \$mod+Return is not bound (the warning)" "" "$(sway_bound 'Mod4+Return')"
check_output "the variable holds the comment" "Bound Mod4 to command \`# the Super" cat "$SWAY_LOG"
sway_stop
printf 'output * pos 0 0  # comment\n' >old.conf
check_fails "a trailing comment after pos is an error" sway_check old.conf
printf 'bindsym --release Mod4+x exec true\nbindsym --to-code Mod4+y exec true\nbindsym --no-repeat Mod4+z exec true\n' >flags.conf
check "--release, --to-code and --no-repeat are bindsym flags" sway_check flags.conf

section "Workspaces on an azerty keyboard"
{ blk Variables 1; blk azerty 1; } >azerty.conf
check "the azerty key names pass sway -C (from the note)" sway_check azerty.conf
sway_start azerty.conf
assert_eq "\$mod+eacute goes to workspace 2" "workspace number 2" "$(sway_bound 'Mod4+eacute')"
assert_eq "\$mod+agrave goes to workspace 10" "workspace number 10" "$(sway_bound 'Mod4+agrave')"
sway_stop
{ blk Variables 1; blk azerty 2; } >codes.conf
check "the bindcode lines pass sway -C (from the note)" sway_check codes.conf
sway_start codes.conf
assert_eq "bindcode \$mod+10 goes to workspace 1" "workspace number 1" "$(sway_bound 'Mod4+10')"
sway_stop
{ sed 's|^include.*||' /etc/sway/config; blk azerty 1; } >both.conf
sway_start both.conf
check_output "with the default config, \$mod+minus overwrites the scratchpad binding (the warning)" \
  "Overwriting binding 'Mod4\+minus'.*workspace number 6.*scratchpad show" cat "$SWAY_LOG"
sway_stop

section "Input devices"
blk "Input devices" 1 >input.conf
check "the input blocks pass sway -C (from the note)" sway_check input.conf
printf 'input type:keyboard {\n    xkb_layout "fr,us"\n    xkb_options grp:alt_shift_toggle\n}\n' >layouts.conf
check "two layouts with grp:alt_shift_toggle pass sway -C" sway_check layouts.conf
printf 'input type:keyboard xkb_layout nosuchlayout\n' >bad.conf
check_fails "sway -C does check the layout" sway_check bad.conf

section "Outputs"
blk Outputs 1 >outputs.conf
check "the output blocks pass sway -C (from the note)" sway_check outputs.conf
{ echo 'set $term foot'; sed 's/eDP-1/HEADLESS-1/; s/DP-2/HEADLESS-2/' outputs.conf; } >heads.conf
sway_start heads.conf
swaymsg create_output >/dev/null
out() { swaymsg -t get_outputs | jq -r ".[] | select(.name == \"$1\") | $2"; }
check_output "eDP-1 (HEADLESS-1) at scale 1.5 is 1706 logical pixels wide" '^1706$' out HEADLESS-1 .rect.width
check_output "DP-2 (HEADLESS-2) starts at x = 1706, next to it (the correction)" '^1706$' out HEADLESS-2 .rect.x
check_output "with the mode from the note" '^3840x2160$' out HEADLESS-2 '"\(.current_mode.width)x\(.current_mode.height)"'
sway_stop
blk Outputs 2 >desc.conf
check "an output matched by its description passes sway -C (from the note)" sway_check desc.conf

section "Window rules"
{ blk "Window rules" 1; blk "Window rules" 2; } >rules.conf
check "the window rules pass sway -C (from the note)" sway_check rules.conf
# The note's rules, with foot standing in for firefox.
{ echo 'set $term foot'; sed 's/app_id="firefox"/app_id="foot"/' rules.conf; } >live.conf
sway_start live.conf
open_foot
check_output "assign sends the window to workspace 2" '^2$' \
  nodes '.. | select(.type? == "workspace") | select([.. | select(.app_id? == "foot")] | length > 0) | .name'
open_foot --title Picture-in-Picture
check_output "for_window [title=...] floating enable, sticky enable" '^floating_con true$' \
  nodes '.. | select(.name? == "Picture-in-Picture") | "\(.type) \(.sticky)"'
check_output "a native window has an app_id and no class" '^foot null$' \
  nodes '[.. | select(.app_id? == "foot")][0] | "\(.app_id) \(.window_properties.class)"'
skip "XWayland windows have a class and no app_id" "no Xwayland in the test image"
sway_stop

section "Autostart"
blk Autostart 1 >auto.conf
check "the autostart lines pass sway -C (from the note)" sway_check auto.conf
printf 'exec echo x >>%s/exec.txt\nexec_always echo x >>%s/always.txt\n' "$PWD" "$PWD" >count.conf
sway_start count.conf
swaymsg reload >/dev/null
sleep 1
assert_eq "exec ran once" 1 "$(wc -l <exec.txt)"
assert_eq "exec_always ran at start and again at reload" 2 "$(wc -l <always.txt)"
sway_stop
printf 'exec_always "true; exec true"   # restart, never run twice\n' >old.conf
sway_start old.conf
check_output "the old trailing comment: its comma starts a new, invalid command" "Unknown/invalid command 'never'" cat "$SWAY_LOG"
sway_stop

section "Splitting the config"
mkdir -p ~/.config/sway/config.d
blk "Splitting" 1 >~/.config/sway/config
printf 'set $x one\n' >~/.config/sway/config.d/10-vars.conf
printf 'bindsym Mod4+F1 exec echo $x\nbindsym Mod4+F2 exec echo $y\n' >~/.config/sway/config.d/20-use.conf
printf 'set $y two\n' >~/.config/sway/config.d/30-late.conf
sway_start ~/.config/sway/config
assert_eq "files are read in order: 10 sets \$x before 20 uses it" "exec echo one" "$(sway_bound 'Mod4+F1')"
assert_eq "a variable set in a later file is not replaced" 'exec echo $y' "$(sway_bound 'Mod4+F2')"
check_output "the /etc include is read too" '50-openSUSE.conf' cat "$SWAY_LOG"
sway_stop

section "Checking before reload"
printf 'set $term foot\n' >~/.config/sway/config
printf 'set $term foot\nnot_a_command\n' >~/.config/sway/config.new
c=$(blk "Checking before reload" 1 | sed 's/ *#.*//')
check "sway -C on the default path (from the note)" bash -ec "$(sed -n 1p <<<"$c")"
check_fails "sway -C -c on a broken file fails (from the note)" bash -ec "$(sed -n 2p <<<"$c")"
