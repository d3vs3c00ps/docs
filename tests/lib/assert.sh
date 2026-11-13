# shellcheck shell=bash
# Sourced by every note test. Prints TAP, and exits non-zero if any check failed.
#
# A check runs a command and records pass or fail without stopping the script, so one
# run reports every broken claim. Setup commands run under `set -e`: if setup breaks,
# the test stops, because later checks would only report noise.

set -euo pipefail

NOTES_ROOT=${NOTES_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}
_t_n=0
_t_failed=0

# _t_finish [STATUS]: STATUS defaults to the status the script exited with.
_t_finish() {
  local rc=${1:-$?}
  echo "1..$_t_n"
  if ((rc != 0)); then
    echo "# aborted: a setup command failed with exit code $rc" >&2
    exit "$rc"
  fi
  if ((_t_failed > 0)); then
    echo "# $_t_failed of $_t_n checks failed"
    exit 1
  fi
}
trap _t_finish EXIT

_t_ok() {
  _t_n=$((_t_n + 1))
  echo "ok $_t_n - $1"
}

# _t_not_ok DESC [DETAIL...]: each detail line is printed as a TAP comment.
_t_not_ok() {
  _t_n=$((_t_n + 1))
  _t_failed=$((_t_failed + 1))
  echo "not ok $_t_n - $1"
  shift
  local line
  for line in "$@"; do
    [[ -n $line ]] || continue
    while IFS= read -r l; do echo "#   $l"; done <<<"$line"
  done
}

# section HEADING: names the note heading that the following checks cover.
section() { echo "# --- $*"; }

# skip DESC REASON: a claim that cannot run here. Say why, never skip silently.
skip() {
  _t_n=$((_t_n + 1))
  echo "ok $_t_n - $1 # SKIP $2"
}

# check DESC CMD...: passes when CMD exits 0.
check() {
  local desc=$1 out
  shift
  if out=$("$@" 2>&1); then _t_ok "$desc"; else _t_not_ok "$desc" "command: $*" "exit: $?" "$out"; fi
}

# check_fails DESC CMD...: passes when CMD exits non-zero, for errors a note warns about.
check_fails() {
  local desc=$1 out
  shift
  if out=$("$@" 2>&1); then _t_not_ok "$desc" "expected failure, got success: $*" "$out"; else _t_ok "$desc"; fi
}

# check_output DESC REGEX CMD...: passes when CMD exits 0 and its output matches REGEX.
check_output() {
  local desc=$1 re=$2 out
  shift 2
  if ! out=$("$@" 2>&1); then
    _t_not_ok "$desc" "command failed: $*" "$out"
  elif grep -Eq -- "$re" <<<"$out"; then
    _t_ok "$desc"
  else
    _t_not_ok "$desc" "output does not match /$re/: $*" "$out"
  fi
}

# assert_eq DESC EXPECTED ACTUAL
assert_eq() {
  if [[ $2 == "$3" ]]; then _t_ok "$1"; else _t_not_ok "$1" "expected: $2" "actual:   $3"; fi
}

# assert_match DESC REGEX STRING
assert_match() {
  if grep -Eq -- "$2" <<<"$3"; then _t_ok "$1"; else _t_not_ok "$1" "no match for /$2/ in:" "$3"; fi
}

# assert_no_match DESC REGEX STRING
assert_no_match() {
  if grep -Eq -- "$2" <<<"$3"; then _t_not_ok "$1" "unexpected match for /$2/ in:" "$3"; else _t_ok "$1"; fi
}

# assert_file DESC PATH / assert_no_file DESC PATH
assert_file() { if [[ -e $2 ]]; then _t_ok "$1"; else _t_not_ok "$1" "missing: $2"; fi; }
assert_no_file() { if [[ -e $2 || -L $2 ]]; then _t_not_ok "$1" "should not exist: $2"; else _t_ok "$1"; fi; }

# assert_link DESC PATH TARGET: PATH is a symlink whose target is exactly TARGET.
assert_link() {
  if [[ ! -L $2 ]]; then
    _t_not_ok "$1" "not a symlink: $2"
  elif [[ $(readlink "$2") == "$3" ]]; then
    _t_ok "$1"
  else
    _t_not_ok "$1" "$2 -> $(readlink "$2"), expected $3"
  fi
}

# retry N CMD...: run CMD up to N times, one second apart. For services that start slowly.
retry() {
  local n=$1 i
  shift
  for ((i = 1; i <= n; i++)); do
    "$@" >/dev/null 2>&1 && return 0
    sleep 1
  done
  return 1
}

# shellcheck source=note.sh
source "$NOTES_ROOT/tests/lib/note.sh"
