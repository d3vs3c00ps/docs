# shellcheck shell=bash
# Read code blocks straight from a note, so a test runs the note's own code instead of
# a copy that can drift. Blocks inside callouts (`> ` prefixes) are found too.
#
#   note_block NOTE N              the Nth code block in the note (1-based)
#   note_block NOTE HEADING [N]    the Nth code block after the first heading that
#                                  contains HEADING (default 1), within that section
#
# NOTE is relative to content/, with or without `.md`. Fails when the block is missing,
# so a test breaks loudly when the note changes under it.

note_block() {
  local note=${1%.md}.md sel=$2 n=${3:-1} file out
  file=$NOTES_ROOT/content/$note
  [[ -f $file ]] || { echo "note_block: no such note: $note" >&2; return 1; }

  out=$(awk -v sel="$sel" -v n="$n" '
    function strip(s) { sub(/^([ \t]*>[ \t]?)+/, "", s); return s }
    BEGIN { by_index = (sel ~ /^[0-9]+$/); want = by_index ? sel + 0 : n + 0 }
    {
      # Inside a block opened in a callout, strip the `> ` prefix; elsewhere keep `>` (a redirection).
      line = (fence && !fq) ? $0 : strip($0)
      if (!fence) {
        # Headings end the search section; the matching heading starts it.
        if (line ~ /^#+[ \t]/) {
          level = match(line, /[^#]/) - 1
          if (!by_index) {
            if (armed && level <= alevel) exit
            if (!armed && index(line, sel)) { armed = 1; alevel = level; next }
          }
        }
        if (match(line, /^[ \t]*(```+|~~~+)/)) {
          fq = ($0 ~ /^[ \t]*>/)
          f = substr(line, RSTART, RLENGTH); gsub(/[ \t]/, "", f)
          fence = f
          if (by_index || armed) count++
          next
        }
      } else {
        t = line; gsub(/[ \t]+$/, "", t); sub(/^[ \t]*/, "", t)
        if (t ~ /^(```+|~~~+)$/ && substr(t, 1, 1) == substr(fence, 1, 1) && length(t) >= length(fence)) {
          fence = ""
          if (count == want && (by_index || armed)) { found = 1; exit }
          next
        }
        if (count == want && (by_index || armed)) print line
      }
    }
    END { if (!found) exit 1 }
  ' "$file") || { echo "note_block: block '$sel' #$n not found in $note" >&2; return 1; }
  printf '%s\n' "$out"
}
