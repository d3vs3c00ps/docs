#!/usr/bin/env bash
# note: linux/cli/scalpel.md
# env: go
# scalpel is not packaged for openSUSE Leap 16 or EPEL. The go env is Debian (trixie),
# which ships it (1.60), so the test installs it with apt.
source "$NOTES_ROOT/tests/lib/assert.sh"

NOTE=linux/cli/scalpel
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null
apt-get install -y -qq --no-install-recommends scalpel bsdextrautils >/dev/null
cd "$(mktemp -d)"

section "1. Find the file signature"
# The first 32 bytes of the PDF in the note's example.
printf '%%PDF-1.5\n%%\xe4\xf0\xed\xf8\n4 0 obj\n<</Filter' >document.pdf
expected=$(note_block "$NOTE" 'Find the file signature' 1 | sed -n '2,3p')
cmd=$(note_block "$NOTE" 'Find the file signature' 1 | sed -n '1s/^\$ //p')
assert_eq "hexdump -C -n 32 prints the note's output" "$expected" "$($cmd | sed -n '1,2p')"
assert_match "the first six bytes are the note's signature" '^00000000  25 50 44 46 2d 31 ' "$expected"

section "2. Declare the type in the configuration"
note_block "$NOTE" 'Declare the type' 1 >scalpel.conf
# A disk image with two PDFs that end with %%EOF: 2 MB at 1 MiB, 100 kB at 8 MiB.
pdf() { printf '%%PDF-1.7\n'; head -c "$1" /dev/zero | tr '\0' "$2"; printf '\n%%%%EOF\n'; }
pdf 2000000 a >a.pdf
pdf 100000 b >b.pdf
truncate -s 16M image_dd.img
dd if=a.pdf of=image_dd.img bs=1M seek=1 conv=notrunc status=none
dd if=b.pdf of=image_dd.img bs=1M seek=8 conv=notrunc status=none

section "3. Run the search"
run=$(note_block "$NOTE" 'Run the search' 1 | grep image_dd.img)
check "scalpel carves the image (from the note)" bash -ec "$run"
check_output "audit.txt lists the files with their offset" '00000000\.pdf +1048576' cat output_folder/audit.txt
check "with the footer, the first file is carved exactly" cmp a.pdf output_folder/pdf-0-0/00000000.pdf
check "and so is the second" cmp b.pdf output_folder/pdf-0-0/00000001.pdf
check_output "a second run into the same, populated folder stops" 'non-empty output directory' \
  bash -c "$run 2>&1; true"
mkdir empty
check "an existing, empty folder is accepted" scalpel -c scalpel.conf -o empty image_dd.img
skip "carving /dev/sda (the note's first line)" "the test never reads the host's disks"

section "Correction: min:max sizes"
printf '%s\n' 'pdf     y    1000000:30000000    \x25\x50\x44\x46\x2d\x31' >range.conf
check "the packaged scalpel is 1.60" bash -c 'scalpel -V | grep -q "version 1.60"'
check "it accepts the old min:max line with no error" scalpel -c range.conf -o range image_dd.img
assert_eq "and carves both files, including the one under the 'minimum'" 2 "$(find range -name '*.pdf' | wc -l)"
assert_eq "each cut at 1 MB, read as the maximum" "1000000 1000000" \
  "$(find range -name '*.pdf' -exec stat -c %s {} + | sort | xargs)"
skip "a minimum size works from scalpel 1.90" "needs scalpel 2.0 built from source; only the 1.60 package is tested"

section "REVERSE"
sed 's/$/    REVERSE/' scalpel.conf >reverse.conf
scalpel -c reverse.conf -o reverse image_dd.img >/dev/null 2>&1
size=$(stat -c %s reverse/pdf-0-0/00000000.pdf)
assert_eq "REVERSE keeps the last footer, so the first file runs into the second" \
  $((8 * 1048576 + $(stat -c %s b.pdf) - 1048576)) "$size"
