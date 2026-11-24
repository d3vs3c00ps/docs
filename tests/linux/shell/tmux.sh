#!/usr/bin/env bash
# note: linux/shell/tmux.md
# env: leap
source "$NOTES_ROOT/tests/lib/assert.sh"

NOTE=linux/shell/tmux
zypper -n -q install --no-recommends tmux >/dev/null
export TERM=xterm TMUX_TMPDIR
TMUX_TMPDIR=$(mktemp -d)
cd "$(mktemp -d)"
# on_tty CMD: run CMD with a pseudo-terminal, as attach needs one.
on_tty() { script -qec "$1" /dev/null >/dev/null; }

section "From a normal shell"
blk=$(note_block "$NOTE" "From a normal shell" 1)
# Plain `tmux` attaches and waits for input: start it in the background, then detach it.
script -qec "$(sed -n 1p <<<"$blk" | sed 's/ *#.*//')" /dev/null >/dev/null &
check "tmux creates a session (from the note)" retry 10 tmux has-session -t 0
tmux detach-client -s 0 || true
wait || true
check_output "tmux ls (from the note)" '^0: ' bash -ec "$(sed -n 2p <<<"$blk")"
check "tmux attach reattaches the most recent session" on_tty 'tmux attach \; detach-client'
check "tmux attach -t 0 (from the note)" on_tty "$(sed -n 4p <<<"$blk" | sed 's/ *#.*//') \; detach-client"
check "tmux new -s build creates a named session" on_tty "$(sed -n 5p <<<"$blk" | sed 's/ *#.*//') \; detach-client"
check_output "the session is called build" '^build: ' tmux ls

section "Window and pane bindings"
# key -> the command tmux runs for Ctrl+b key, as in the two tables.
while IFS='|' read -r key cmd; do
  check_output "Ctrl+b $key runs $cmd" "$cmd" tmux list-keys -T prefix "$key"
done <<'KEYS'
c|new-window
n|next-window
p|previous-window
1|select-window -t :=1
w|choose-tree -Zw
,|rename-window
d|detach-client
t|clock-mode
%|split-window -h
"|split-window$
o|select-pane -t :\.\+
Up|select-pane -U
Space|next-layout
M-Up|resize-pane -U
!|break-pane
q|display-panes
z|resize-pane -Z
x|kill-pane
KEYS

section "Joining a window back into a pane"
tmux kill-server
tmux new -d -s j
for i in 1 2 3; do tmux new-window -d -t "j:$i"; done
join=$(note_block "$NOTE" "Joining" 1 | sed 's/^://')
check "joinp -h -s 3.0 -l 25% (from the note)" bash -ec "tmux $join"
check_output "window 0 now has two panes side by side" '^0: .*\(2 panes\).*\{' tmux list-windows -t j
check_output "the joined pane has about 25% of the width" '^20$' tmux list-panes -t j:0 -F '#{pane_width}' -f '#{==:#{pane_index},1}'
tmux new-window -d -t j:3
check_output "the old -p 25 fails with tmux 3.5 (the correction)" 'size missing' bash -c 'tmux joinp -h -s 3.0 -p 25 2>&1; true'

section "The command prompt"
tmux kill-server
script=$(note_block "$NOTE" "The command prompt" 1)
check "the layout script, without the final attach (from the note)" bash -ec "$(grep -v 'attach' <<<"$script")"
check_output "two panes in work:editor" '^0 1 $' bash -c "tmux list-panes -t work:editor -F '#{pane_index}' | tr '\n' ' '"
check "the last line attaches" on_tty "$(tail -1 <<<"$script") \; detach-client"
retry 10 bash -c "tmux capture-pane -p -t work:editor.1 | grep -q 'journalctl -f'"
check_output "the second pane runs journalctl -f" 'journalctl -f' tmux capture-pane -p -t work:editor.1
for c in list-keys list-commands list-sessions list-windows list-panes rename-window move-window swap-pane capture-pane pipe-pane source-file; do
  check_output "$c is a tmux command" "^$c" tmux list-commands "$c"
done
check "setw synchronize-panes on" tmux setw -t work:editor synchronize-panes on
check_output "the option is set" 'synchronize-panes on' tmux show-window-options -t work:editor synchronize-panes
tmux setw -t work:editor synchronize-panes off
note_block "$NOTE" "The command prompt" 2 >bind.conf
check "the bind line from the tip loads with source-file" tmux source-file bind.conf
check_output "and binds Ctrl+b S" 'synchronize-panes.*pane_synchronized,ON,OFF' tmux list-keys -T prefix S
seq 1 4000 >numbers && tmux send-keys -t work:editor.0 'cat numbers' Enter
retry 10 bash -c "tmux capture-pane -p -t work:editor.0 | grep -q '^4000'"
check "capture-pane -S -3000 (from the note)" bash -ec "cd $PWD && tmux select-pane -t work:editor.0 && $(note_block "$NOTE" "The command prompt" 3)"
check_output "it recovers lines that scrolled out of view" '^2500$' grep -x 2500 output.txt
check_fails "but not more than history-limit (2000) lines back" grep -x 100 output.txt
check_output "history-limit is 2000 by default" '^history-limit 2000$' tmux show-options -g history-limit
tmux kill-server
