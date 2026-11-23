#!/usr/bin/env bash
# note: security/cvss.md
# env: leap
source "$NOTES_ROOT/tests/lib/assert.sh"

NOTE=security/cvss
cd "$(mktemp -d)"
# Leap's Python is externally managed (PEP 668): pip runs in a virtual environment.
python3 -m venv venv
# shellcheck source=/dev/null
source venv/bin/activate

section "Python cvss library"
# The blocks sit in a list item: drop the two-space indent.
block() { note_block "$NOTE" 'Tools and references' "$1" | sed 's/^  //'; }
check "pip install cvss (from the note)" bash -ec "$(block 1)"
block 2 >example.py
check_output "the example prints 9.3 and Critical (from the note)" '^9\.3 Critical$' \
  bash -c 'python3 example.py | paste -sd " "'

# score VECTOR: prints "<score> <severity>" with the library the note recommends.
score() { python3 -c 'import sys; from cvss import CVSS4; c = CVSS4(sys.argv[1]); print(c.base_score, c.severity)' "$1"; }
# vec HEADING: the first vector string under a worked example heading.
vec() { note_block "$NOTE" "$1" 1 | grep '^CVSS:4\.0/'; }

section "Worked examples"
check_output "remote code execution: 9.3 Critical" '^9\.3 Critical$' score "$(vec 'Remote code execution')"
check_output "container escape: 8.5 High" '^8\.5 High$' score "$(vec 'Container escape')"
check_output "stored XSS: 5.1 Medium" '^5\.1 Medium$' score "$(vec 'Stored XSS')"
check_output "denial of service: 8.7 High" '^8\.7 High$' score "$(vec 'Denial of service')"
check_output "physical access: 5.1 Medium, not Low (the correction)" '^5\.1 Medium$' score "$(vec 'physical access')"
for h in 'Remote code execution' 'Container escape' 'Stored XSS' 'Denial of service' 'physical access'; do
  n=$(vec "$h" | tr '/' '\n' | grep -c ':')
  assert_eq "$h: the vector has the prefix and all eleven Base metrics" 12 "$n"
done

section "Building a vector string"
check_output "a vector without SC/SI/SA is refused: no defaulting" 'Missing mandatory metrics "SC, SI, SA"' \
  bash -c 'python3 -c "from cvss import CVSS4; CVSS4(\"CVSS:4.0/AV:N/AC:L/AT:N/PR:N/UI:N/VC:H/VI:H/VA:H\")" 2>&1; true'
check_output "the template line lists the eleven Base metrics in order" \
  '^CVSS:4\.0/AV:<val>/AC:<val>/AT:<val>/PR:<val>/UI:<val>/VC:<val>/VI:<val>/VA:<val>/SC:<val>/SI:<val>/SA:<val>$' \
  note_block "$NOTE" 'Building a vector string' 1

section "Threat metrics"
base=$(vec 'Remote code execution')
check_output "E:A gives the same score as no E (from the note)" '^9\.3 Critical$' score "$(note_block "$NOTE" 'Threat metrics' 1)"
check_output "E:P lowers it" '^8\.9 High$' score "$base/E:P"
check_output "E:U lowers it to 8.1" '^8\.1 High$' score "$base/E:U"
check_output "E:X (Not Defined) counts as Attacked" '^9\.3 Critical$' score "$base/E:X"

section "Severity scale"
check_output "a score of 0 is None" '^0(\.0)? None$' score CVSS:4.0/AV:N/AC:L/AT:N/PR:N/UI:N/VC:N/VI:N/VA:N/SC:N/SI:N/SA:N
