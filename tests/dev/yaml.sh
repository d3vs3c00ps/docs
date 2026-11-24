#!/usr/bin/env bash
# note: dev/yaml.md
# env: ansible-systemd
# PyYAML (the parser Ansible uses) and yamllint come from the Ansible venv.
source "$NOTES_ROOT/tests/lib/assert.sh"

NOTE=dev/yaml
PY=/opt/ansible/bin/python
cd "$(mktemp -d)"
# load: parse YAML on stdin with PyYAML, print each top-level value as repr, one per line.
load() { "$PY" -c 'import sys, yaml
d = yaml.safe_load(sys.stdin)
for k, v in (d.items() if isinstance(d, dict) else [(None, d)]): print(f"{k}={v!r}")'; }
# blk HEADING N: block N under HEADING, parsed.
blk() { note_block "$NOTE" "$1" "$2" | load; }
# j CMD...: CMD output on one line.
j() { "$@" | tr "\n" " " | sed "s/ $//"; }

section "Block scalars"
assert_eq "literal keeps newlines, as the 'Becomes' block shows" \
  "description='$(note_block "$NOTE" 'Literal' 2 | sed 's/$/\\n/' | tr -d '\n')'" "$(blk 'Literal' 1)"
assert_eq "folded joins lines and keeps one newline per blank line" \
  "description='$(note_block "$NOTE" 'Folded' 2 | sed 's/$/\\n/' | tr -d '\n')'" "$(blk 'Folded' 1)"
check_output "a more-indented line is not folded" "^d='a b\\\\n  kept\\\\nc\\\\n'$" load <<<$'d: >\n  a\n  b\n    kept\n  c'

section "Chomping"
assert_eq "the six combinations: clip one newline, strip none, keep all" "literal_clip='text\n'
literal_strip='text'
literal_keep='text\n\n'
folded_clip='text\n'
folded_strip='text'
folded_keep='text\n'" "$(blk 'Chomping indicators' 1)"
check_output ">- gives one line with no trailing newline" \
  "'/opt/app/bin/tool --config /etc/app/config.yml --log-level debug --timeout 30'\\}\]$" \
  "$PY" -c 'import sys, yaml; print(yaml.safe_load(sys.stdin))' <<<"$(note_block "$NOTE" 'Chomping indicators' 2)"

section "Flow styles"
flow=$(note_block "$NOTE" 'Flow styles' 1)
check_fails "the block as a whole is invalid (the 'broken' line)" load <<<"$flow"
assert_eq "double quotes honour \\n, single quotes do not, a quoted colon is fine" "double='line one\nline two'
single='line one\\\\nline two'
plain='line one'
fixed='value: with colon'" "$(grep -v '^broken' <<<"$flow" | load)"
check_output "'' is a literal quote in single quotes" "^s=\"it's\"$" load <<<"s: 'it''s'"
check_output "plain cannot contain ' #': the rest is a comment" "^p='a'$" load <<<"p: a #b"

section "Summary table"
# Each row of the table, checked against PyYAML. In: YAML text; out: the repr of the value.
row() { check_output "$1" "^v=$3$" load <<<"$2"; }
row "trailing space: a literal block keeps it" $'v: |\n  a  \n' "'a  \\\\n'"
row "trailing space: a folded block keeps it" $'v: >\n  a  \n' "'a  \\\\n'"
row "trailing space: double quotes drop it at a fold" $'v: "a  \n  b"' "'a b'"
row "trailing space: single quotes drop it at a fold" $'v: \'a  \n  b\'' "'a b'"
row "trailing space: a multi-line plain scalar drops it" $'v: a  \n  b' "'a b'"
row "single newline: | keeps it, > folds it" $'v: |\n  a\n  b' "'a\\\\nb\\\\n'"
row "single newline in double quotes is a space" $'v: "a\n  b"' "'a b'"
row "double newline in > is one newline" $'v: >\n  a\n\n  b' "'a\\\\nb\\\\n'"
row "double newline in plain is one newline" $'v: a\n\n  b' "'a\\\\nb'"
row "double newline in | stays two" $'v: |\n  a\n\n  b' "'a\\\\n\\\\nb\\\\n'"
check_output "final double newline: |+ keeps both" "^v='a\\\\n\\\\n'$" load < <(printf 'v: |+\n  a\n\n')
row "final double newline: > clips to one" $'v: >\n  a\n\n' "'a\\\\n'"
row "line continuation with \\ in double quotes" $'v: "a\\\n  b"' "'ab'"
row "leading space in a folded block keeps the newline around it" $'v: >\n  a\n   b\n  c' "'a\\\\n b\\\\nc\\\\n'"
row "leading space in a plain scalar: folded away" $'v: a\n     b' "'a b'"
row "leading space in double quotes: folded away" $'v: "a\n     b"' "'a b'"
row "leading space in single quotes: folded away" $'v: \'a\n   b\'' "'a b'"

section "Indentation"
check_fails "a tab in indentation is a parse error" load <<<$'a:\n\tb: 1'
check_output "the extra indent inside a block is content" "\\\\n    echo" blk Indentation 1
check_output "|2 keeps the two extra leading spaces" "^script='  this line keeps two leading spaces\\\\n'$" blk Indentation 2

section "Data types"
assert_eq "types as the comments say" "string='hello'
integer=42
float=3.14
boolean=True
null_1=None
null_2=None
null_3=None
list=['a', 'b', 'c']
dict={'k': 'v'}
date=datetime.date(2026, 8, 10)" "$(blk 'Data types' 1)"
assert_eq "the quoted values in the Norway warning stay strings" "countries=['NO', 'SE', 'DK']
version='1.10'
port='8080'" "$(blk 'Data types' 2)"
check_output "unquoted, NO is false and 1.10 is 1.1" "^c=\[False\] v=1.1$" j load <<<$'c: [NO]\nv: 1.10'
check_output "PyYAML reads yes, On and OFF as booleans" "^v=\[True, True, False\]$" load <<<'v: [yes, On, OFF]'
check_output "and True, TRUE, Off" "^v=\[True, True, False\]$" load <<<'v: [True, TRUE, Off]'
check_output "but not y, n, or a mixed case like yEs" "^v=\['y', 'n', 'yEs'\]$" load <<<'v: [y, n, yEs]'
cat >play.yml <<EOF
- hosts: localhost
  gather_facts: false
  vars:
    myvar: "1.10"
  tasks:
$(note_block "$NOTE" 'Data types' 3 | sed 's/^/    /')
EOF
check_output "type_debug shows what a value became in Ansible" '"msg": "str"' ansible-playbook -i localhost, -c local play.yml

section "Documents, anchors"
check_output "two documents" "^\[\{'kind': 'first'\}, \{'kind': 'second'\}\]$" \
  "$PY" -c 'import sys, yaml; print(list(yaml.safe_load_all(sys.stdin)))' <<<"$(note_block "$NOTE" Documents 1)"
check_output "<<: merges the anchored mapping" "^test=\{'adapter': 'postgres', 'host': 'localhost', 'database': 'test_db'\}$" blk 'Anchors and aliases' 1

section "Linting"
printf 'a: 1\na: 2\nb: 3   \n' >dup.yml
check_output "PyYAML keeps the last value of a duplicate key, silently" "^a=2$" load <dup.yml
out=$(/opt/ansible/bin/yamllint dup.yml 2>&1) || true
assert_match "yamllint reports the duplicate key" 'duplication of key "a"' "$out"
assert_match "and the trailing spaces" 'trailing spaces' "$out"
printf 'a:\n\tb: 1\n' >tab.yml
check_output "and a tab" 'syntax error' bash -c '/opt/ansible/bin/yamllint tab.yml; true'
