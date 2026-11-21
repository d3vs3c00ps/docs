# shellcheck shell=bash
# Helpers for the containerd/* note tests. Their notes are cheat sheets: one command
# per line, with sudo, comments and placeholders, so tests run them line by line on
# a kind node. Requires tests/lib/assert.sh, tests/lib/k8s.sh and NOTE.

CP=$CLUSTER-control-plane
on() { docker exec "$CP" "$@"; }
# on_sh CMD: run one note line on the control plane node, as root (no sudo there).
on_sh() { docker exec "$CP" bash -ec "$1"; }

# nline BLOCK LINE: the LINE-th command of code block BLOCK (an index in the note),
# without `sudo `, comments or blank lines. A missing line fails the test (see note.sh).
nline() {
  local l
  l=$(note_block "$NOTE" "$1" | sed -E 's/(^|[[:space:]|;&])sudo /\1/g; s/[[:space:]]+#.*$//' \
    | grep -vE '^[[:space:]]*(#|$)' | sed -n "${2}p")
  if [[ -z $l ]]; then
    echo "nline: no line $2 in block $1 of $NOTE" >&2
    [[ -n ${_T_NB_MISSING:-} ]] && echo "line $2 of block $1 in $NOTE" >>"$_T_NB_MISSING"
    return 1
  fi
  printf '%s\n' "$l"
}
