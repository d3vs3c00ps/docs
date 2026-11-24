#!/usr/bin/env bash
# note: linux/shell/zsh.md
# env: leap
source "$NOTES_ROOT/tests/lib/assert.sh"

NOTE=linux/shell/zsh
zypper -n -q install --no-recommends zsh >/dev/null
cd "$(mktemp -d)"
# z CODE: run CODE in a zsh with no startup files.
z() { zsh -f -c "$1"; }
# zv DESC EXPECTED CODE: CODE prints exactly EXPECTED.
zv() { assert_eq "$1" "$2" "$(z "$3" 2>&1)"; }

section "Strings"
S='V="hello world";'
zv 'length ${#V}' 11 "$S"' echo ${#V}'
zv 'one character, from 1: ${V[1]}' h "$S"' echo ${V[1]}'
zv 'from an index: ${V[7,-1]}' world "$S"' echo ${V[7,-1]}'
zv 'substring ${V[1,4]}' hell "$S"' echo ${V[1,4]}'
zv 'replace the first ${V/o/0}' 'hell0 world' "$S"' echo ${V/o/0}'
zv 'replace all ${V//o/0}' 'hell0 w0rld' "$S"' echo ${V//o/0}'
zv '${V%%o*} removes the first match and the rest' hell "$S"' echo ${V%%o*}'
zv 'starts with' yes "$S"' if [[ $V = "hel"* ]]; then echo yes; fi'
zv 'contains' yes "$S"' if [[ $V = *"o w"* ]]; then echo yes; fi'
zv 'ends with' yes "$S"' if [[ $V = *"rld" ]]; then echo yes; fi'
assert_eq "bash: \${V[1]} is not the second character of a string" '' "$(bash -c 'V=hello; echo "${V[1]}"')"
assert_eq "bash: \${V[1]} is the second element of an array" 'b' "$(bash -c 'V=(a b); echo "${V[1]}"')"

section "Arrays"
A='A=(x y z);'
zv 'create, push' 'x y z w' "$A"' A+=(w); echo $A'
zv 'access ${A[2]}' y "$A"' echo ${A[2]}'
zv 'shift A' 'y z' "$A"' shift A; echo $A'
zv 'shift -p A' 'x y' "$A"' shift -p A; echo $A'
zv 'length ${#A}' 3 "$A"' echo ${#A}'
zv 'for value in $A' 'xyz' "$A"' for v in $A; do printf %s $v; done'
zv '(Ie): index of a value' 2 "$A"' echo ${A[(Ie)y]}'
zv '(Ie): 0 if not found (the correction)' 0 "$A"' echo ${A[(Ie)q]}'
zv '(ie): length + 1 if not found (the old claim was 0)' 4 "$A"' echo ${A[(ie)q]}'
zv '(( $A[(Ie)value] )) tests membership' 'in out' "$A"' (( $A[(Ie)y] )) && printf "in "; (( $A[(Ie)q] )) || echo out'
zv 'the old (ie) test is true even for a missing value' 'true' "$A"' (( $A[(ie)q] )) && echo true'
zv '${A:1} counts from 0' 'y z' "$A"' echo ${A:1}'
zv '${A:1:1}' 'y' "$A"' echo ${A:1:1}'
zv '[[ -z $E ]] on an empty array' empty 'E=(); if [[ -z $E ]]; then echo empty; fi'
zv '[[ ! -z $A ]] on a non-empty array' full "$A"' if [[ ! -z $A ]]; then echo full; fi'
zv 'A[2]=() removes an element' 'x z' "$A"' A[2]=(); echo $A'

section "Associative arrays"
M='typeset -A M=( [key1]=value1 [key2]=value2 );'
zv 'typeset -A M=() creates an empty one' 0 'typeset -A M=(); echo ${#M}'
zv 'create with values, $M[key]' value1 "$M"' echo $M[key1]'
zv 'add a key' value3 "$M"' M[key3]=value3; echo $M[key3]'
zv "unset 'M[key]'" 1 "$M"" unset 'M[key1]'; echo \${#M}"
zv 'number of elements' 2 "$M"' echo ${#M}'
zv 'iterate the values' 'value1 value2' "$M"' for v in $M; do echo $v; done | sort | xargs'
zv 'iterate the keys' 'key1 key2' "$M"' for k in ${(k)M}; do echo $k; done | sort | xargs'
zv 'iterate key-value pairs' 'key1=value1 key2=value2' "$M"' for k v in ${(kv)M}; do echo $k=$v; done | sort | xargs'

section "Arithmetic and variables"
zv 'no $ needed in $(( ))' 5 'a=2; b=3; echo $((a + b))'
zv '${(P)NAMEVAR}' hello 'V=hello; N=V; echo ${(P)N}'
zv '${(k)parameters} lists variables' yes 'MYVAR=1; (( ${${(k)parameters}[(Ie)MYVAR]} )) && echo yes'
zv 'unset' '' 'V=1; unset V; echo $V'

section "Functions"
zv 'local is not visible outside' ':' 'f() { local v=1; }; f; echo ":$v"'
zv '$0 in a function is the function name (the correction)' myfunc 'myfunc() { echo $0; }; myfunc'
printf 'f() { echo $ZSH_ARGZERO; }; f\n' >script.zsh
zv '$ZSH_ARGZERO is the script name' script.zsh 'zsh -f script.zsh'
zv '$1, $2, $#' 'a b 2' 'f() { echo $1 $2 $#; }; f a b'
zv '$@ is an array' 2 'f() { local a=($@); echo ${#a}; }; f "x y" z'
zv 'shift and shift -p in a function' 'b' 'f() { shift; shift -p; echo $@; }; f a b c'
zv 'return sets the status' 1 'f() { return 1; }; f; echo $?'
zv '${(k)functions}, unset -f' 'yes no' 'myf() { :; }; (( ${${(k)functions}[(Ie)myf]} )) && printf "yes "; unset -f myf; (( ${${(k)functions}[(Ie)myf]} )) || echo no'
zv '${@:q} escapes spaces' 'a\ b c' 'f() { echo ${@:q}; }; f "a b" c'

section "Aliases"
zv 'alias defines, ${(k)aliases} lists, unalias removes' 'll=ll yes no' 'alias ll="ls -l"; printf "%s" "$(alias | grep -o "^ll=")"; printf "ll "; (( ${${(k)aliases}[(Ie)ll]} )) && printf "yes "; unalias ll; (( ${${(k)aliases}[(Ie)ll]} )) || echo no'

section "Conditionals"
check "the if forms parse (from the note)" zsh -n -c "$(note_block "$NOTE" Conditionals 1 | sed 's/\.\.\./:/g')"
zv '-z / -n' 'z n' 'E=; V=1; [[ -z $E ]] && printf "z "; [[ -n $V ]] && echo n'
mkdir d && touch f && ln -s f l
zv '-f, -d, -L' 'f d L' '[[ -f f ]] && printf "f "; [[ -d d ]] && printf "d "; [[ -L l ]] && echo L'
zv '-o OPTION' set 'setopt extendedglob; [[ -o extendedglob ]] && echo set'
zv '= and !=' 'eq ne' 'a=x b=x c=y; [[ $a = $b ]] && printf "eq "; [[ $a != $c ]] && echo ne'
zv '(( )) with and without $' 'gt lt' 'a=3 b=2; (( $a > $b )) && printf "gt "; (( b < a )) && echo lt'
zv 'if command / if ! command' 'ok ko' 'if true; then printf "ok "; fi; if ! false; then echo ko; fi'

section "Loops"
check "the for forms parse (from the note)" zsh -n -c "$(note_block "$NOTE" Loops 1 | sed 's/\.\.\./:/g')"
zv '{1..3} is inclusive' '123' 'for i in {1..3}; do printf $i; done'
zv 'a glob with no match is an error' 'no matches found' 'for i in /nonexistent*; do :; done 2>&1 | grep -o "no matches found"'
zv '(N) makes it silent' 'none' 'for i in /nonexistent*(N); do echo $i; done; echo none'

section "Worked example"
assert_eq "add and add_twice print 5 and 10 (from the note)" "$(printf '5\n10')" "$(z "$(note_block "$NOTE" "Worked example" 1)")"

section "A word on conditionals"
assert_eq "&& prints only when the condition holds (from the note)" "VARNAME is not defined or empty!" \
  "$(z "FILEPATH=/nonexistent; $(note_block "$NOTE" "A word on conditionals" 1)")"
assert_eq "|| prints only when it is false (from the note)" "File does not exist!" \
  "$(z "FILEPATH=/nonexistent; $(note_block "$NOTE" "A word on conditionals" 2)")"
zv '[[ ]] sets 0 or 1' '0 1' '[[ a = a ]]; printf "$? "; [[ a = b ]]; echo $?'

section "Configuration frameworks"
tip=$(note_block "$NOTE" "Configuration frameworks" 1)
# `zsh -i -c exit` keeps the status of the last line of /etc/zshrc, so only the output counts.
check_output "the startup loop prints ten timings (from the note)" '^10$' \
  bash -c "zsh -f -c '$(grep '^for' <<<"$tip")' 2>&1 | grep -c 'zsh -i -c exit.* total'"
mkdir zdot
printf '%s\nmyslow() { sleep 0.2; }\nmyslow\n%s\n' "$(grep zmodload <<<"$tip")" "$(grep '^zprof' <<<"$tip")" >zdot/.zshrc
check_output "zprof names the slow function" 'myslow' env ZDOTDIR="$PWD/zdot" zsh -i -c exit
