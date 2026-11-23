#!/usr/bin/env bash
# note: linux/desktop/sway/nixos.md
# env: nixos
# timeout: 2400
# A desktop does not run in a container: the blocks are evaluated as a normal host,
# with home-manager (release-26.05, pinned) for the user side. The Sway config
# home-manager writes is then checked with the real sway -C, on the headless backend.
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/nixos.sh"
source "$NOTES_ROOT/tests/versions.env"

NOTE=linux/desktop/sway/nixos
cd "$(mktemp -d)"
W=$PWD
TOP=system.build.toplevel.drvPath
evm() { NIXOS_MODULE="{ notes, pkgs, lib, ... }: { imports = [ $1 ]; }" nixos_eval --host "$2"; }
evj() { evm "$1" "$2" | jq -c "${3:-.}"; }
m() { echo "(notes.module \"$1\" ${2:-1})"; }
SYSM=$(m "System side" 1)

section "System side"
check "the system block evaluates" evm "$SYSM" $TOP
check_output "polkit is on" '^true$' evm "$SYSM" security.polkit.enable
check_output "dconf is on" '^true$' evm "$SYSM" programs.dconf.enable
check "swaylock has a PAM entry" evm "$SYSM" 'security.pam.services.swaylock.text'
check_output "the wlr portal is on" '^true$' evm "$SYSM" xdg.portal.wlr.enable
check_output "and a GTK portal is in extraPortals" 'xdg-desktop-portal-gtk' evm "$SYSM" xdg.portal.extraPortals
nixconf=$(nix-store --realise "$(evm "$SYSM" 'environment.etc."sway/config.d/nixos.conf".source.drvPath' | tr -d '"')" 2>/dev/null | head -1)
check_output "/etc/sway/config.d/nixos.conf exports the environment" 'import-environment|dbus-update-activation-environment' cat "$nixconf"
wrap=$(nix-store --realise "$(evm "$SYSM" programs.sway.package.drvPath | tr -d '"')" 2>/dev/null | head -1)
# The wrapper has two layers; the inner shell script, in the closure, sets the variable.
check_output "the sway wrapper sets XDG_CURRENT_DESKTOP=sway" 'export XDG_CURRENT_DESKTOP=sway' \
  bash -c "nix-store -qR '$wrap' | sed 's|\$|/bin/sway|' | xargs grep -ah XDG_CURRENT_DESKTOP 2>/dev/null; true"
check_output "extraPackages replaces the default list" '^\["brightnessctl","foot","grim","slurp","swayidle","swaylock","wl-clipboard","wmenu"\]$' \
  evj "$SYSM" programs.sway.extraPackages 'map(sub("^/nix/store/[a-z0-9]+-"; "") | sub("-[0-9].*"; "")) | sort'
check_output "greetd runs tuigreet with --cmd sway" 'tuigreet --time --remember --cmd sway' \
  evm "$SYSM" services.greetd.settings.default_session.command
out=$(NIXOS_MODULE='{ pkgs, ... }: { environment.systemPackages = [ pkgs.greetd.tuigreet ]; }' nixos_eval --host $TOP 2>&1) && ok=yes || ok=no
assert_eq "the old pkgs.greetd.tuigreet still evaluates" yes "$ok"
assert_match "with a rename warning" 'tuigreet' "$(grep -i 'warning' <<<"$out")"

section "User side with home-manager"
hm=$(nix eval --impure --raw --expr "builtins.fetchTarball \"https://github.com/nix-community/home-manager/archive/$HOME_MANAGER_REV.tar.gz\"")
HMBASE="$hm/nixos { users.users.alice.isNormalUser = true; home-manager.useGlobalPkgs = true; }"
mkdir user && head -c 100 /dev/zero >user/wallpaper.jpg && echo '/* */' >user/waybar.css
user() {   # user N FILE: the Nth home-manager block of a section, as a module file
  { note_block "$NOTE" "$1" "$2"; } >"user/$3"
}
user 'User side with home-manager' 1 main.nix
hmuser() { echo "{ home-manager.users.alice = { imports = [ $* ]; home.stateVersion = \"26.05\"; }; }"; }
HMM="$SYSM $HMBASE $(hmuser "$W/user/main.nix")"
check "the system block plus the home-manager block evaluate" evm "$HMM" $TOP
sed 's/checkConfig = false;/checkConfig = true;/' user/main.nix >user/check.nix
out=$(evm "$SYSM $HMBASE $(hmuser "$W/user/check.nix")" $TOP 2>&1) && ok=yes || ok=no
assert_eq "the correction: checkConfig = true with package = null does not build" no "$ok"
assert_match "home-manager says it needs a package" 'checkConfig requires non-null' "$out"
# home-manager writes the file through .source (its .text is null): build it.
hmconf() { nix-store --realise "$(evm "$1" 'home-manager.users.alice.xdg.configFile."sway/config".source.drvPath' | tr -d '"')" 2>>"$W/build.log" | head -1; }
cfg=$(hmconf "$HMM") || true
check "home-manager builds the Sway config" test -s "$cfg"
swaybin=$(nix-store --realise "$(evm "$SYSM" programs.sway.package.drvPath | tr -d '"')" 2>/dev/null | head -1)
headless() { env XDG_RUNTIME_DIR="$(mktemp -d)" WLR_BACKENDS=headless WLR_RENDERER=pixman WLR_LIBINPUT_NO_DEVICES=1 "$@"; }
check_fails "sway 1.12 -C, outside a session, fails: it needs a backend (the tip)" \
  env XDG_RUNTIME_DIR="$(mktemp -d)" timeout 60 "$swaybin/bin/sway" -C -c "$cfg"
check "the generated config passes sway -C on the headless backend (the tip)" headless "$swaybin/bin/sway" -C -c "$cfg"
echo 'nonsense_command x' >bad.conf
check_fails "  and that check does catch a bad line" headless "$swaybin/bin/sway" -C -c bad.conf
conf=$(cat "$cfg" 2>/dev/null || true)
assert_no_match "the config does not include /etc/sway/config.d/* (the correction)" 'include /etc/sway/config\.d' "$conf"
assert_match "  systemd.enable exports the environment itself instead" 'dbus-update-activation-environment --systemd .*XDG_CURRENT_DESKTOP' "$conf"
assert_match "\$mod+Shift+e is the system mode" 'bindsym Mod4\+Shift\+e mode "system"' "$conf"
assert_match "the default bindings are kept (mkOptionDefault)" 'bindsym Mod4\+Return exec foot' "$conf"
assert_match "the resize mode is kept" 'mode "resize"' "$conf"
assert_match "the keyboard input block" 'xkb_layout fr' "$conf"
assert_match "the --locked brightness keys" 'bindsym --locked XF86MonBrightnessUp +exec brightnessctl set 5%\+' "$conf"
assert_no_match "bars = [ ] leaves no bar block" '^bar \{' "$conf"

section "Azerty workspace keys"
{ echo '{ lib, ... }:'; note_block "$NOTE" 'User side with home-manager' 2; } >user/azerty.nix
sed -i 's|# \.\.\. the other keys from above||' user/azerty.nix
HMA="$SYSM $HMBASE $(hmuser "$W/user/main.nix" "$W/user/azerty.nix")"
conf=$(cat "$(hmconf "$HMA")" 2>/dev/null || true)
assert_match "\$mod+ampersand goes to workspace 1" 'bindsym Mod4\+ampersand workspace number 1' "$conf"
assert_match "\$mod+Shift+agrave moves to workspace 10" 'bindsym Mod4\+Shift\+agrave move container to workspace number 10' "$conf"
assert_match "\$mod+minus is workspace 6, not the scratchpad: a plain value overrides a default (the correction)" 'bindsym Mod4\+minus workspace number 6' "$conf"
assert_no_match "  and the default scratchpad binding is gone" 'bindsym Mod4\+minus scratchpad show' "$conf"

section "Helpers as home-manager services"
user 'Helpers as home-manager services' 1 helpers.nix
sed -i '1s/^{/{ pkgs, ... }: {/' user/helpers.nix
HMH="$SYSM $HMBASE $(hmuser "$W/user/helpers.nix")"
out=$(evm "$HMH" home-manager.users.alice.home.activationPackage.drvPath 2>&1) && ok=yes || ok=no
assert_eq "the helpers block evaluates" yes "$ok"
assert_no_match "with no evaluation warning" 'evaluation warning' "$out"
check_output "Waybar runs as a user service" 'graphical-session\.target|sway-session\.target' \
  evm "$HMH" 'home-manager.users.alice.systemd.user.services.waybar.Install.WantedBy'
check_output "mako settings reach its config" 'default-timeout=5000' \
  evm "$HMH" 'home-manager.users.alice.xdg.configFile."mako/config".text'
check_output "swayidle has a before-sleep event" 'before-sleep' \
  evm "$HMH" 'home-manager.users.alice.systemd.user.services.swayidle.Service.ExecStart'
check_output "kanshi gets both profiles" 'profile docked' \
  evm "$HMH" 'home-manager.users.alice.xdg.configFile."kanshi/config".text'
check "cliphist is a home-manager service" evm "$HMH $(hmuser '{ services.cliphist.enable = true; }')" 'home-manager.users.alice.systemd.user.services.cliphist.Service.ExecStart'

section "Option shapes that changed recently"
# The warnings are printed when the whole system is evaluated, not the user's package.
old() { evm "$SYSM $HMBASE $(hmuser "$1")" $TOP 2>&1; }
out=$(old '{ services.mako = { enable = true; defaultTimeout = 5000; }; }') || true
assert_match "the old mako options fail or warn" 'defaultTimeout|renamed|removed|settings' "$out"
out=$(old '{ pkgs, ... }: { services.swayidle = { enable = true; events = [ { event = "before-sleep"; command = "true"; } ]; }; }') || true
assert_match "the old swayidle events list warns" 'warning|deprecated|events' "$out"
out=$(old '{ services.kanshi = { enable = true; profiles.laptop.outputs = [ { criteria = "eDP-1"; } ]; }; }') || true
assert_match "services.kanshi.profiles is deprecated" 'warning|deprecated|profiles' "$out"
out=$(old '{ programs.waybar = { enable = true; systemd.enable = true; systemd.target = "sway-session.target"; }; }') || true
assert_match "waybar systemd.target is replaced by systemd.targets" 'targets|renamed|removed' "$out"

section "Trying changes safely"
# Not --help: nixos-rebuild-ng opens the man page for it, and there is no man here.
check "nixos-rebuild build-vm exists" bash -c 'nixos-rebuild no-such-action 2>&1 | grep -qw build-vm'
check "system.build.vm evaluates for the Sway system" evm "$SYSM" system.build.vm.drvPath
skip "running the VM" "it needs QEMU with a display; the container has neither"
