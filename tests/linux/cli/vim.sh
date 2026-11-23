#!/usr/bin/env bash
# note: linux/cli/vim.md
# env: leap
source "$NOTES_ROOT/tests/lib/assert.sh"

NOTE=linux/cli/vim
zypper -n -q install --no-recommends vim >/dev/null
export LANG=C.UTF-8
cd "$(mktemp -d)"

# ex BLOCK [CMD...]: a note block as a vimrc (leading ':' removed), then the extra
# commands. vim -es exits non-zero when any line raises an error.
ex() {
  # shellcheck disable=SC2001 # a regex escape needs sed
  sed 's/^://' <<<"$1" >rc.vim
  shift
  local args=() c
  for c in "$@"; do args+=(-c "$c"); done
  vim -N -es -u rc.vim -i NONE "${args[@]}" -c 'qa!' </dev/null
}
# out EXPR: print a Vim expression to stdout.
out() { echo "call writefile([$1], '/dev/stdout')"; }

section "Line numbers"
check_output "set number / nu (from the note)" '^1$' ex "$(note_block "$NOTE" "Line numbers" 1)" "$(out '&number')"
check_output "nu rnu sets both (from the note)" '^1 1$' ex "$(note_block "$NOTE" "Line numbers" 2)" "$(out '&nu . " " . &rnu')"

section "Showing whitespace"
check_output "listchars+=space adds the space item (from the note)" 'space:␣' \
  ex "$(note_block "$NOTE" "Showing whitespace" 2)" "$(out '&lcs')"
check_output "the full listchars line and set list (from the note)" '^1 eol:¬,tab:>·,trail:~,extends:>,precedes:<,space:␣$' \
  ex "$(note_block "$NOTE" "Showing whitespace" 3)" "$(out '&list . " " . &lcs')"
check_output "listchars alone leaves list off" '^0$' ex 'set listchars=tab:>·,trail:~' "$(out '&list')"
check_output ":set nolist turns it off again" '^0$' ex 'set list' 'set nolist' "$(out '&list')"
check_output "the ~/.vimrc lines load without error (from the note)" '^1 1 tab:>·,trail:~,extends:>,precedes:<$' \
  ex "$(note_block "$NOTE" "Showing whitespace" 4)" "$(out '&nu . " " . &list . " " . &lcs')"

section "Highlighting trailing whitespace instead"
check_output ":match ErrorMsg (from the note)" "'group': 'ErrorMsg'" \
  ex "$(note_block "$NOTE" "Highlighting" 1)" "$(out 'string(getmatches())')"
printf 'a  \nb\t\nc\n' >ws.txt
check "the substitution (from the note)" vim -N -es -u NONE -i NONE \
  -c "$(note_block "$NOTE" "Highlighting" 2 | sed 's/^://')" -c 'wq' ws.txt
assert_eq "removes trailing spaces and tabs" "$(printf 'a\nb\nc')" "$(cat ws.txt)"
check "with the e flag, a clean file gives no error" vim -N -es -u NONE -i NONE -c '%s/\s\+$//e' -c 'wq' ws.txt
check_fails "without it, vim reports E486" vim -N -es -u NONE -i NONE -c '%s/\s\+$//' -c 'wq' ws.txt
