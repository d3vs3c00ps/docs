---
title: Zsh cheat sheet
description: Zsh syntax reference — strings, arrays, associative arrays, functions, conditionals and loops
tags: [linux, shell, zsh, cheatsheet]
type: reference
status: complete
source: https://gist.github.com/ClementNerma/1dd94cb0f1884b9c20d1ba0037bdcde2
license: unspecified — the source gist states no licence
---

# Zsh cheat sheet

A reference for performing various actions in Zsh. Its syntax is not always
intuitive and is generally not well documented, which makes this hard to find
online.

> [!info] Adapted from a third-party cheat sheet
> Originally by **Clément Nerma**, published as
> [this gist](https://gist.github.com/ClementNerma/1dd94cb0f1884b9c20d1ba0037bdcde2).
> Reproduced here with formatting changes and corrections.

For POSIX/bash equivalents see [[linux/shell/shell-tips]].

## Strings

| Description | Syntax |
| --- | --- |
| Get the length of a string | `${#VARNAME}` |
| Get a single character | `${VARNAME[index]}` |
| Get the string from a specific index | `${VARNAME[index,-1]}` |
| Get a substring | `${VARNAME[from,to]}` |
| Replace the first occurrence in a string | `${VARNAME/toreplace/replacement}` |
| Replace all occurrences in a string | `${VARNAME//toreplace/replacement}` |
| Remove the first match of a pattern and everything after it | `${VARNAME%%pattern*}` |
| Check if a string starts with a substring | `if [[ $VARNAME = "startstr"* ]]` |
| Check if a string contains a substring | `if [[ $VARNAME = *"substring"* ]]` |
| Check if a string ends with a substring | `if [[ $VARNAME = *"substring" ]]` |

> [!note] Zsh indexes strings and arrays from 1
> In zsh, `${VARNAME[1]}` is the *first* character or element. In bash, `${VARNAME[1]}`
> is the *second* element of an array, and a string has no `[n]` index at all. This is
> one of the most common sources of confusion when porting bash scripts.
> The `${VARNAME:offset}` form is the exception: it counts from 0, as in bash.

## Arrays

| Description | Syntax |
| --- | --- |
| Create an array | `VARNAME=()` |
| Create an array with initial values | `VARNAME=(value1 value2 value3)` |
| Push to an array | `VARNAME+=(value)` |
| Access an array's element | `${VARNAME[index]}` |
| Remove first element from an array (shift) | `shift VARNAME` |
| Remove last element from an array (pop) | `shift -p VARNAME` |
| Get an array's length | `${#VARNAME}` |
| Iterate over an array's values | `for value in $VARNAME;` |
| Get index of a value in an array (`0` if not found) | `${VARNAME[(Ie)value]}` |
| Get index of a value in an array (length + 1 if not found) | `${VARNAME[(ie)value]}` |
| Get an array slice from an offset (counted from 0) | `${VARNAME:offset}` |
| Get an array slice of a given length from an offset | `${VARNAME:offset:length}` |
| Check if a value is contained in an array | `if (( $VARNAME[(Ie)value] ));` |
| Check if an array is empty | `if [[ -z $VARNAME ]]` |
| Check if an array is not empty | `if [[ ! -z $VARNAME ]]` |
| Remove an element from an array | `VARNAME[index]=()` |

> [!warning] Correction
> This table used `(ie)` for "`0` if not found" and for the "is contained" test.
> `(ie)` searches from the start and returns the array length + 1 when there is no
> match, so `(( $VARNAME[(ie)value] ))` is always true. `(Ie)` searches from the end
> and returns `0` when there is no match.

## Associative arrays (maps / dictionaries)

Associative arrays are the equivalent of hash maps or dictionaries in many other
languages: unlike arrays they can use string keys, and those keys have no
guaranteed order.

| Description | Syntax |
| --- | --- |
| Create an associative array | `typeset -A VARNAME=()` |
| Create one with initial values | `typeset -A VARNAME=( [key1]=value1 [key2]=value2 )` |
| Add a new key | `VARNAME[key]=value` |
| Access an element | `$VARNAME[key]` |
| Remove a key | `unset 'VARNAME[key]'` |
| Get the number of elements | `${#VARNAME}` |
| Iterate over the values | `for value in $VARNAME;` |
| Iterate over the keys | `for key in ${(k)VARNAME};` |
| Iterate over key-value pairs | `for key value in ${(kv)VARNAME};` |

## Arithmetic

| Description | Syntax |
| --- | --- |
| Compute an expression (variables need no `$` prefix inside) | `$((expression))` |

## Variables

| Description | Syntax |
| --- | --- |
| Get the value of a variable whose name is in another variable | `${(P)NAMEVAR}` |
| Get the list of all defined variables, as an array | `${(k)parameters}` |
| Delete a variable | `unset VARNAME` |

## Functions

| Description | Syntax |
| --- | --- |
| Declare a local variable (not visible outside the function) | `local varname=...` |
| Get the function name (inside a function) | `$0` |
| Get the script or shell name | `$ZSH_ARGZERO` |
| Get a parameter | `$1` (second is `$2`, etc.) |
| Expand all parameters | `$*` |
| Expand all parameters, keeping quoting | `$@` (it's an array) |
| Get the number of parameters (not counting `$0`) | `$#` |
| Remove the first parameter from `$@` | `shift` |
| Remove the last parameter from `$@` | `shift -p` |
| Exit the function with a status code | `return 1` (or any other code) |
| Get the list of all functions, as an array | `${(k)functions}` |
| Delete a function | `unset -f func_name` |
| Get the arguments, with escaped spaces | `${@:q}` |

> [!warning] Correction
> This table said `$0` is "the original executable name". In zsh, inside a function,
> `$0` is the function name (option `FUNCTION_ARGZERO`, on by default). Use
> `$ZSH_ARGZERO` for the script name.

## Aliases

| Description | Syntax |
| --- | --- |
| Display all defined aliases | `alias` |
| Get all defined aliases, as an array | `${(k)aliases}` |
| Define an alias | `alias name="command arg1 arg2 ..."` |
| Remove an alias | `unalias name` |

## Conditionals

See [[#A word on conditionals]] for how these actually work.

```zsh
# 1)
if expression
then
    # instructions
fi

# 2)
if expression; then
    # instructions
fi

# 3)
if expression; then ...; fi

# 4)
if expression; then
    # instructions
else
    # instructions
fi

# 5)
if expression; then
    # instructions
elif expression; then
    # instructions
else
    # instructions
fi
```

| Description | Syntax |
| --- | --- |
| Check if a string is empty or undefined | `if [[ -z $VARNAME ]];` |
| Check if a string is defined and not empty | `if [[ -n $VARNAME ]];` |
| Check if a file exists | `if [[ -f "filepath" ]];` |
| Check if a directory exists | `if [[ -d "dirpath" ]];` |
| Check if a symbolic link exists | `if [[ -L "symlinkpath" ]];` |
| Check if a shell option is set | `if [[ -o OPTION_NAME ]];` |
| Check if two values are equal | `if [[ $VAR1 = $VAR2 ]];` |
| Check if two values differ | `if [[ $VAR1 != $VAR2 ]];` |
| Check if a number is greater than another | `if (( $VAR1 > $VAR2 ));` |
| Check if a number is smaller than another | `if (( $VAR1 < $VAR2 ));` |
| Check if a command exits successfully (code `0`) | `if command arg1 arg2 ...` |
| Check if a command does not exit successfully | `if ! command arg1 arg2 ...` |

The `$` before variable names inside an arithmetic expression `(( ... ))` is
optional, so `if (( VAR1 < VAR2 ));` is equally valid.

Every `-` test operator is listed in
[Zsh's conditional expressions manual](https://zsh.sourceforge.io/Doc/Release/Conditional-Expressions.html).

## Loops

```zsh
# 1)
for itervarname in iterable
do
    # instructions
done

# 2)
for itervarname in iterable; do
    # instructions
done

# 3)
for itervarname in iterable; do ...; done
```

| Description | Syntax |
| --- | --- |
| Iterate over a range (inclusive) | `for i in {from..to};` |
| Iterate over filesystem items | `for i in globpattern;` |
| Iterate over filesystem items, silent if no match | `for i in globpattern(N);` |

## Worked example

Returning a value from a function — Zsh functions return a status code, so a
"return value" is really stdout captured by the caller:

```zsh
function add() {
    local sum=$(($1 + $2))
    echo $sum
}

function add_twice() {
    local sum=$(add $1 $2)   # capture the callee's stdout
    local sum_twice=$(add $sum $sum)
    echo $sum_twice
}

echo $(add 2 3)         # 5
echo $(add_twice 2 3)   # 10
```

## A word on conditionals

Conditionals take expressions: in `if [[ -z $VARNAME ]];` the expression is
`[[ -z $VARNAME ]]`. The same expressions work in `while` loops, and standalone
outside any block:

```zsh
[[ -z $VARNAME ]] && echo "VARNAME is not defined or empty!"
[[ -f $FILEPATH ]] && echo "File exists!"
```

This works because conditional expressions (`[[ ... ]]` and `(( ... ))`) do not
return a value — they behave like commands, setting the status code to `0` when
the condition holds and `1` otherwise.

To display a message only when the condition is *false*:

```zsh
[[ -z $VARNAME ]] || echo "VARNAME is not empty!"
[[ -f $FILEPATH ]] || echo "File does not exist!"
```

## Configuration frameworks

Zsh's own configuration is verbose, and a framework bundles completions, prompt
themes and a plugin mechanism so you are not assembling them yourself.

| Framework | Character |
| --- | --- |
| **Oh My Zsh** | The default answer. Enormous plugin and theme library, very well documented, and noticeably slow to start once you enable much of it |
| **Prezto** | A leaner rewrite of the same idea. Faster, smaller, fewer plugins |
| **zinit** | Aggressive lazy loading — plugins load on first use, which keeps startup fast even with many of them |
| **antidote** | A plugin manager rather than a framework; static loading, very fast |
| **zim** | Modular, with a focus on startup speed |
| **Starship** | Prompt only, not a framework. Written in Rust, works identically in zsh, bash and fish |

> [!tip] Measure startup before and after
> A framework with a dozen plugins can add several hundred milliseconds to every new
> shell, which is felt on every terminal you open.
>
> ```zsh
> # Startup time, ten runs
> for i in {1..10}; do time zsh -i -c exit; done
>
> # Which plugin is responsible
> zmodload zsh/zprof     # at the top of .zshrc
> zprof                  # at the bottom
> ```
>
> `zprof` output names the slow function directly. It is usually a completion
> initialisation or a version-manager plugin (`nvm`, `rbenv`) that shells out at
> startup.

> [!note] A framework is optional, and increasingly so
> Most of what Oh My Zsh was needed for is now available as three or four lines in
> `.zshrc` plus a standalone prompt: `compinit` for completions,
> `zsh-autosuggestions` and `zsh-syntax-highlighting` as plain plugins, and Starship
> for the prompt. That is faster and easier to reason about than a framework you have
> not read.
>
> Reach for a framework if you want the plugin ecosystem; skip it if you want a fast
> shell.

Under NixOS, home-manager configures all of this declaratively — see
[[linux/distributions/nixos/workstation]].

Overview of the options:
[7 best free and open source Zsh configuration frameworks](https://www.linuxtoday.com/blog/7-best-free-and-open-source-zsh-configuration-frameworks/).

<!-- uplink -->
Part of [[linux/shell/index|Shells]].
