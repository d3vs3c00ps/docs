# shellcheck shell=bash
# Sourced by the Sway note tests. Sway runs in the container with no screen, GPU or
# input device: the headless wlroots backend gives virtual outputs (HEADLESS-1, ...)
# and pixman renders on the CPU. Not a .sh file, so it is not taken for a note test.

zypper -n -q install --no-recommends sway jq "$@" >/dev/null
export WLR_BACKENDS=headless WLR_RENDERER=pixman WLR_LIBINPUT_NO_DEVICES=1
export XDG_RUNTIME_DIR SWAYSOCK WAYLAND_DISPLAY SWAY_LOG
XDG_RUNTIME_DIR=$(mktemp -d)
SWAY_LOG=$XDG_RUNTIME_DIR/sway.log

# sway_check FILE: `sway -C` on FILE. Fails, and prints Sway's errors, on any error.
sway_check() {
  local out rc=0
  out=$(sway -C -c "$1" 2>&1) || rc=$?
  out=$(grep -v '\[wlr\]' <<<"$out" || true)
  [[ $rc == 0 ]] && ! grep -q 'ERROR' <<<"$out" && return 0
  printf '%s\n' "$out"
  return 1
}

# sway_start FILE: start a headless Sway on FILE, with a debug log in $SWAY_LOG, and
# wait until its IPC socket answers. Exports SWAYSOCK and WAYLAND_DISPLAY for clients.
sway_start() {
  local i
  # A Sway started with the variables of an earlier one does not open its socket.
  env -u SWAYSOCK -u WAYLAND_DISPLAY sway -d -c "$1" >"$SWAY_LOG" 2>&1 &
  SWAYSOCK=$XDG_RUNTIME_DIR/sway-ipc.$(id -u).$!.sock
  for ((i = 0; i < 50; i++)); do
    swaymsg -t get_version >/dev/null 2>&1 && break
    sleep 0.2
  done
  WAYLAND_DISPLAY=$(sed -n "s/.*Running compositor on wayland display '\([^']*\)'.*/\1/p" "$SWAY_LOG")
  swaymsg -t get_version >/dev/null
}

# sway_stop: exit Sway and wait for it.
sway_stop() {
  swaymsg exit >/dev/null 2>&1 || true
  wait 2>/dev/null || true
}

# sway_bound KEYS: the command Sway bound to KEYS (as printed in its debug log).
sway_bound() {
  sed -n "s/.*Bound $1 to command \`\(.*\)\` for device.*/\1/p" "$SWAY_LOG" | tail -1
}
