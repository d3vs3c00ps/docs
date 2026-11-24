---
title: Shell tips
description: Bash history expansion, redirection, job control, brace expansion and parameter substitution
tags: [linux, shell, bash, cli, cheatsheet]
type: reference
status: complete
---

# Shell tips

Ways to get more out of `bash` and waste less time typing. For the interactive
shell itself see [[linux/shell/zsh]].

## History expansion

`!$` recalls the last argument of the previous command line:

```console
$ cd /tmp
$ ls !$
ls /tmp
sample.test
```

`!!` recalls the entire previous command line — the classic use being a forgotten
`sudo`:

```console
$ systemctl restart nginx
Failed to restart nginx.service: Access denied
$ sudo !!
sudo systemctl restart nginx
```

`!-n` recalls the *n*-th previous command. `!-2` is the one before last:

```console
$ ls
sample.test
$ echo hello
hello
$ !-2
ls
sample.test
```

Substitute within the most recent command — first occurrence, then all
occurrences:

```bash
!!:s/foo/bar/
!!:gs/foo/bar/
```

> [!tip] Check before you run
> Set `shopt -s histverify` so history expansions are loaded into the prompt for
> you to confirm rather than executed immediately. Very much worth it before
> `sudo !!` ever bites you.

## Redirection

```bash
sh test.sh > output.txt    # stdout to a file, truncating it
sh test.sh >> output.txt   # stdout to a file, appending
sh test.sh 2> error.log    # stderr to a file
sh test.sh 2>&1            # stderr to wherever stdout currently goes
sh test.sh 2>/dev/null     # discard stderr
sh test.sh &>/dev/null     # discard both stdout and stderr
```

> [!warning] Order matters for `2>&1`
> `2>&1` duplicates whatever stdout points at *right now*. So
> `cmd > file 2>&1` sends both to the file, while `cmd 2>&1 > file` sends stderr
> to the terminal and only stdout to the file.

## Conditional operators

`&&` and `||` are conditional command separators.

`&&` runs the second command only if the first succeeded:

```console
$ true && echo it works!
it works!
$ false && echo it works!
```

`||` runs the second command only if the first failed:

```console
$ true || echo it works!
$ false || echo it works!
it works!
```

## Exit codes

The special variable `$?` holds the exit status of the previous command. Zero
means success; **any** non-zero value means failure, and the specific value is
often meaningful (`1` generic error, `2` misuse, `126` not executable, `127` not
found, `130` interrupted with `Ctrl+C`).

```console
$ true ; echo $?
0
$ false ; echo $?
1
```

## Removing a stale SSH host key

When a host's key changes you get:

```text
@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
@    WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!      @
@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
IT IS POSSIBLE THAT SOMEONE IS DOING SOMETHING NASTY!
Someone could be eavesdropping on you right now (man-in-the-middle attack)!
It is also possible that a host key has just been changed.
Add correct host key in ~/.ssh/known_hosts to get rid of this message.
Offending ECDSA key in ~/.ssh/known_hosts:13
ECDSA host key for 192.168.0.22 has changed and you have requested strict checking.
Host key verification failed.
```

Rather than editing `known_hosts` by hand, remove just that entry:

```bash
ssh-keygen -R 192.168.0.22
```

> [!warning] Confirm before you clear it
> This message is exactly what a man-in-the-middle attack looks like. If you did
> not rebuild or re-key that host, verify the new fingerprint out of band first.

## Job control

`Ctrl+Z` **suspends** the foreground process and returns you to the prompt. The
job is stopped, not running — `bg` resumes it in the background, `fg` brings it
back to the foreground. You can suspend several jobs and return to any of them.

```console
$ tail -f app.log
^Z
[1]+  Stopped                 tail -f app.log
$ tail -f error.log
^Z
[2]+  Stopped                 tail -f error.log
$ jobs
[1]-  Stopped                 tail -f app.log
[2]+  Stopped                 tail -f error.log
$ fg 2
tail -f error.log
```

`bg` resumes the most recently stopped job in the background — the equivalent of
having launched it with `&`:

```console
$ bg
[2]+ tail -f error.log &
```

## Checking a script's syntax

Parse a script without executing it:

```bash
bash -n script.sh
```

For real linting, `shellcheck script.sh` catches far more.

## Finding and deleting files

Delete every file of a given type:

```bash
find / -type f -name "*.m4a" -exec rm {} \;
```

`-exec ... +` batches arguments instead of forking once per file, which is much
faster:

```bash
find / -type f -name "*.m4a" -exec rm {} +
```

When `-exec` is unavailable (busybox, for instance):

```bash
find / -type f -name "*.m4a" -print0 | xargs -0 rm
```

Remove empty directories:

```bash
find ./ -depth -type d -empty -exec rmdir {} \;
```

GNU find can do the same with `-delete`, which implies `-depth`:

```bash
find ./ -type d -empty -delete
```

> [!tip] Spaces in file names
> Prefer `-print0 | xargs -0` over a bare pipe, so file names that contain spaces or
> newlines are handled correctly.

## Quoting

Single quotes suppress expansion; double quotes allow it:

```bash
NAME="John"
echo "Hi $NAME"  #=> Hi John
echo 'Hi $NAME'  #=> Hi $NAME
```

## Command substitution

Both forms are equivalent, but `$( )` nests and is preferred:

```bash
echo "I'm in $(pwd)"
echo "I'm in `pwd`"
```

## Brace expansion

```text
{A,B}.js    ->  A.js B.js
{1..5}      ->  1 2 3 4 5
{01..05}    ->  01 02 03 04 05
{a..e}      ->  a b c d e
```

Practical uses:

```bash
mkdir -p ~/{work,image,private}
mv test.{txt,md}     # rename the txt extension to md
mv test.txt{,.bak}   # append a .bak extension
cp config.yml{,.orig}
```

Running the same command across a range of hosts:

```bash
for server in apache-{1..4}; do
    ssh -t "your.name@${server}" sudo -- sh -c 'uptime'
done
```

## Parameter substitution and slicing

```bash
name="John"
echo "${name}"
echo "${name/J/j}"    #=> john   (substitute first match)
echo "${name//o/0}"   #=> J0hn   (substitute all matches)
echo "${name:0:2}"    #=> Jo     (slice: offset 0, length 2)
echo "${name:(-1)}"   #=> n      (slice from the right)
echo "${name:(-2):1}" #=> h
echo "${name:-anon}"  #=> John   (default if unset or empty)
echo "${#name}"       #=> 4      (length)
```

## Reading a file line by line

```bash
while read -r line; do
    echo "$line"
done < file.txt
```

> [!warning] The redirect belongs on `done`
> `< file.txt | while read line; do ... done` runs, but the redirection alone is an
> empty command: nothing goes into the pipe, so the loop reads nothing and prints
> nothing, with no error. Use `read -r` so backslashes are not swallowed, and quote
> `"$line"` so whitespace is preserved.

## Monitoring one-liners

```bash
free -m -l -t                      # memory, with low/high and totals

ps auxf | sort -nr -k 4 | head -10 # top memory consumers
ps auxf | sort -nr -k 3 | head -10 # top CPU consumers
```

## Several commands on one line

`;` runs each in turn regardless of the previous exit status:

```console
$ ls test/ ; ls test2/
test1.md
test2.md
```

<!-- uplink -->
Part of [[linux/shell/index|Shells]].
