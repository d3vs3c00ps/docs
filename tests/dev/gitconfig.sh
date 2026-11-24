#!/usr/bin/env bash
# note: dev/gitconfig.md
# env: leap
source "$NOTES_ROOT/tests/lib/assert.sh"

NOTE=dev/gitconfig
HOME=$(mktemp -d)
export HOME GIT_CONFIG_NOSYSTEM=1
unset GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL
cd "$HOME"
git config --global user.name "Alice Example"
git config --global user.email global@example.com
git config --global init.defaultBranch main
git init -q repo && cd repo
git config --local user.email local@example.com
commit() { echo "$1" >>"${2:-f.txt}" && git add -A && git commit -qm "$1"; }

section "Levels"
check_output "a local value wins over the global one" '^local@example\.com$' git config --get user.email
check_output "git -c wins over both" '^cmd@example\.com$' git -c user.email=cmd@example.com config --get user.email
git config --worktree demo.where early
check_output "without extensions.worktreeConfig, --worktree writes .git/config" '^early$' git config --local --get demo.where
check_fails "and no config.worktree file" test -e .git/config.worktree
git config --unset --local demo.where
git config extensions.worktreeConfig true
git config --worktree user.email wt@example.com
check_output "with it, the worktree level wins over local" '^wt@example\.com$' git config --get user.email
check "and the value is in .git/config.worktree" grep -q wt@example.com .git/config.worktree
git config --unset --worktree user.email
git config --unset extensions.worktreeConfig
check_output "local is back" '^local@example\.com$' git config --get user.email
git config --global --add include.path one.inc
git config --local --add include.path two.inc
check_output "a multi-valued key adds up across levels" '^2$' bash -c 'git config --get-all include.path | wc -l'
git config --global --unset include.path; git config --local --unset include.path

section "Reading the configuration"
out=$(bash -ec "$(note_block "$NOTE" "Reading the configuration" 1)")
assert_match "--show-scope --show-origin: the global value" "^global	file:$HOME/\.gitconfig	global@example\.com" "$out"
assert_match "the local value comes last" '^local	file:\.git/config	local@example\.com$' "$(tail -1 <<<"$out")"
check_output "--list --show-origin --show-scope (from the note)" '^local	file:\.git/config	user\.email=local@example\.com$' \
  bash -ec "$(note_block "$NOTE" "Reading the configuration" 3)"
check "set, unset and --edit (from the note)" env GIT_EDITOR=true bash -ec "$(note_block "$NOTE" "Reading the configuration" 4)"
check_output "init.defaultBranch is set globally" '^main$' git config --global --get init.defaultBranch
check_fails "core.autocrlf is gone from .git/config" git config --local --get core.autocrlf

section "Environment variables beat every file"
commit one
check_output "git var shows the configured identity (from the note)" '<local@example\.com>' \
  bash -ec "$(note_block "$NOTE" "Environment variables beat every file" 1)"
export GIT_AUTHOR_EMAIL=env@example.com
check_output "with GIT_AUTHOR_EMAIL set, git var shows the variable" '<env@example\.com>' git var GIT_AUTHOR_IDENT
check_output "while git config still shows .git/config" '^local@example\.com$' git config --get user.email
commit two
check_output "and the commit uses the variable" '^env@example\.com$' git log -1 --format=%ae
unset GIT_AUTHOR_EMAIL
printf '[user]\n\temail = other@example.com\n' >"$HOME/other.gitconfig"
check_output "GIT_CONFIG_GLOBAL replaces ~/.gitconfig" '^other@example\.com$' \
  env GIT_CONFIG_GLOBAL="$HOME/other.gitconfig" git config --global --get user.email
check_output "GIT_CONFIG_COUNT/KEY/VALUE adds a setting" '^injected$' \
  env GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=demo.key GIT_CONFIG_VALUE_0=injected git config --get demo.key
if [[ -w /etc ]]; then
  printf '[demo]\n\tsystem = yes\n' >/etc/gitconfig
  check_output "/etc/gitconfig is read by default" '^yes$' env -u GIT_CONFIG_NOSYSTEM git config --get demo.system
  check_fails "GIT_CONFIG_NOSYSTEM=1 ignores it" git config --get demo.system
  rm /etc/gitconfig
else
  skip "GIT_CONFIG_NOSYSTEM" "/etc is not writable in this container"
fi

section "Conditional includes"
cd "$HOME" && rm -f .gitconfig
note_block "$NOTE" "Conditional includes" 1 >.gitconfig
note_block "$NOTE" "Conditional includes" 2 >.gitconfig-personal
git config --global init.defaultBranch main
mkdir -p personal other && git -C personal init -q a && git -C other init -q b
check_output "a repository under ~/personal/ uses the personal address" '^alice@example\.com$' git -C personal/a config --get user.email
check_output "one elsewhere keeps the work address" '^alice@work\.example\.com$' git -C other/b config --get user.email
check_output "--show-origin names the included file (the note's tip)" '\.gitconfig-personal' git -C personal/a config --show-origin --get user.email
check_output "the identity git uses follows" '<alice@example\.com>' git -C personal/a var GIT_AUTHOR_IDENT
mkdir -p personal/x/y && git -C personal/x/y init -q deep
check_output "the trailing / covers every level below" '^alice@example\.com$' git -C personal/x/y/deep config --get user.email
{ printf '[includeIf "gitdir:~/personal/"]\n\tpath = ~/.gitconfig-personal\n'; note_block "$NOTE" "Conditional includes" 1 | grep -v includeIf | grep -v 'path ='; } >.gitconfig-before
check_output "an includeIf placed before [user] loses: [user] comes later" '^alice@work\.example\.com$' \
  env GIT_CONFIG_GLOBAL="$HOME/.gitconfig-before" git -C personal/a config --get user.email
printf '[includeIf "gitdir/i:~/PERSONAL/"]\n\tpath = ~/.gitconfig-personal\n' >.gitconfig-ci
check_output "gitdir/i ignores case" '^alice@example\.com$' env GIT_CONFIG_GLOBAL="$HOME/.gitconfig-ci" git -C personal/a config --get user.email
printf '[includeIf "gitdir:~/PERSONAL/"]\n\tpath = ~/.gitconfig-personal\n' >.gitconfig-cs
check_fails "plain gitdir does not, on Linux" env GIT_CONFIG_GLOBAL="$HOME/.gitconfig-cs" git -C personal/a config --get user.email
printf '[demo]\n\tbranch = main\n' >.inc-main
printf '[includeIf "onbranch:main"]\n\tpath = ~/.inc-main\n' >.gitconfig-ob
(cd other/b && commit one)
check_output "onbranch:main applies on main" '^main$' env GIT_CONFIG_GLOBAL="$HOME/.gitconfig-ob" git -C other/b config --get demo.branch
git -C other/b switch -q -c topic
check_fails "and not on another branch" env GIT_CONFIG_GLOBAL="$HOME/.gitconfig-ob" git -C other/b config --get demo.branch
printf '[demo]\n\tacme = yes\n' >.inc-acme
printf '[includeIf "hasconfig:remote.*.url:https://github.com/acme/**"]\n\tpath = ~/.inc-acme\n' >.gitconfig-hc
git -C other/b remote add origin https://github.com/acme/tool.git
check_output "hasconfig:remote.*.url matches the remote" '^yes$' env GIT_CONFIG_GLOBAL="$HOME/.gitconfig-hc" git -C other/b config --get demo.acme
check_fails "and not a repository without that remote" env GIT_CONFIG_GLOBAL="$HOME/.gitconfig-hc" git -C personal/a config --get demo.acme
mkdir -p .config/sub && printf '[demo]\n\trel = yes\n' >.config/sub/rel.inc
printf '[include]\n\tpath = rel.inc\n' >.config/sub/main.gitconfig
check_output "a relative path is relative to the including file" '^yes$' \
  env GIT_CONFIG_GLOBAL="$HOME/.config/sub/main.gitconfig" git -C other/b config --get demo.rel

section "A commented ~/.gitconfig"
note_block "$NOTE" "A commented" 1 >"$HOME/commented.gitconfig"
printf '[user]\n\tname = Alice Example\n\temail = alice@example.com\n' >>"$HOME/commented.gitconfig"
check "the file parses" git config --file "$HOME/commented.gitconfig" --list
export GIT_CONFIG_GLOBAL="$HOME/commented.gitconfig"
check_output "every setting is read" '^16$' bash -c "git config --global --list | grep -vc '^user\.'"
cd "$HOME" && git init -q -b main s && cd s
commit base
git tag v1.1; git tag v1.9; git tag v1.10
assert_eq "tag order with tag.sort = version:refname" "v1.1 v1.9 v1.10" "$(git tag | tr '\n' ' ' | sed 's/ $//')"
git switch -q -c older && GIT_COMMITTER_DATE="2020-01-01T00:00:00" git commit -q --allow-empty -m old && git switch -q main
git switch -q -c newer && GIT_COMMITTER_DATE="2099-01-01T00:00:00" git commit -q --allow-empty -m new && git switch -q main
assert_eq "branch.sort: most recent first" "newer main older" "$(git branch --format='%(refname:short)' | tr '\n' ' ' | sed 's/ $//')"
git init -q --bare "$HOME/remote.git" && git remote add origin "$HOME/remote.git"
git switch -q -c pushme && commit pushme
check "push.autoSetupRemote: a plain git push works on a new branch" git push -q
check_output "and sets the upstream" '^origin/pushme$' git rev-parse --abbrev-ref '@{upstream}'
git clone -q "$HOME/remote.git" "$HOME/clone" && git -C "$HOME/clone" switch -q pushme
(cd "$HOME/clone" && commit theirs && git push -q)
commit ours
check_fails "pull.ff only refuses to merge diverged branches" git pull -q
check_output "and says why" 'fast-forward|Not possible' bash -c 'git pull 2>&1 || true'
git reset -q --hard origin/pushme 2>/dev/null || git reset -q --hard "@{u}"
git switch -q main && printf 'timeout = 10\n' >app.conf && git add app.conf && git commit -qm base-conf
git switch -q -c feature && printf 'timeout = 60\n' >app.conf && git commit -qam sixty
git switch -q main && printf 'timeout = 30\n' >app.conf && git commit -qam thirty
git merge -q feature >/dev/null 2>&1 || true
markers=$(cat app.conf)
assert_match "merge.conflictStyle = zdiff3 adds the base section" '^\|\|\|\|\|\|\| ' "$markers"
# Read the example raw: note_block strips a leading ">" (callouts), which eats ">>>>>>>".
example=$(awk '/conflictStyle = zdiff3` changes/ {on=1} on && /^```text/ {b=1; next} b && /^```/ {exit} b' "$NOTES_ROOT/content/$NOTE.md")
assert_eq "the conflict looks like the note's example, up to the hash" \
  "$(printf '%s\n' "$example" | sed 's/^||||||| [0-9a-f]*$/||||||| HASH/')" \
  "$(sed 's/^||||||| [0-9a-f]*$/||||||| HASH/' app.conf)"
check_output "the label after ||||||| is the common ancestor's hash" "^\\|{7} $(git rev-parse --short "$(git merge-base main feature)")$" cat app.conf
printf 'timeout = 45\n' >app.conf && git add app.conf && git commit -qm merged
check_output "rerere recorded the resolution in .git/rr-cache" '.' ls .git/rr-cache
git reset -q --hard HEAD~1
git merge -q feature >/dev/null 2>&1 || true
assert_eq "rerere: the same conflict is resolved from memory" "timeout = 45" "$(cat app.conf)"
git merge --abort 2>/dev/null || git reset -q --hard
cd "$HOME" && git init -q -b main as && cd as && commit base && git switch -q -c topic && commit topic t.txt
git switch -q main && commit main-moved m.txt && git switch -q topic && echo dirty >>f.txt
check "rebase.autoStash: rebase with uncommitted changes" git rebase -q main
check_output "the uncommitted change is back after the rebase" 'dirty' cat f.txt
check_fails "without autoStash, the same rebase refuses" bash -c 'git reset -q --hard HEAD~1 && echo dirty >>f.txt && git -c rebase.autoStash=false rebase -q main'
git -C "$HOME/clone" push -q origin --delete pushme 2>/dev/null || git --git-dir="$HOME/remote.git" branch -D pushme >/dev/null
check "fetch.prune: a plain fetch" git fetch -q
check_fails "drops the remote-tracking branch deleted on the remote" git rev-parse -q --verify refs/remotes/origin/pushme
cd "$HOME" && git init -q -b main ur && cd ur && commit base && git switch -q -c part1 && commit p1 p.txt && git switch -q -c part2 && commit p2 p.txt
git switch -q main && commit moved m.txt && git switch -q part2
check "rebase.updateRefs: a plain rebase" git rebase -q main
check_output "moves the stacked branch part1 too" '^moved$' git log -1 --format=%s part1~1
echo v >>f.txt && git add f.txt
check_output "commit.verbose: the editor shows the diff below the message" '^\+v$' \
  env GIT_EDITOR='sh -c "cp \"\$1\" $HOME/editmsg; echo verbose >\"\$1\"" --' bash -c "git commit -q && cat $HOME/editmsg"
check_output "help.autocorrect = prompt asks before running a typo" "Run 'status' instead" \
  bash -c "echo n | script -qec 'git stauts' /dev/null 2>&1; true"
unset GIT_CONFIG_GLOBAL

section "Aliases"
cd "$HOME" && git init -q -b main al && cd al
commit one && commit two
{ cat "$HOME/.gitconfig"; note_block "$NOTE" "Aliases" 1; } >"$HOME/aliases.gitconfig"
export GIT_CONFIG_GLOBAL="$HOME/aliases.gitconfig"
check_output "git st" '^## main' git st
check_output "git lg draws the graph" '^\* [0-9a-f]+ .*two' git lg
check_output "git last" 'f\.txt' git last
check "git undo" git undo
check_output "undo moved HEAD back one commit and kept the change staged" '^M  f\.txt$' git status --short
git commit -qm two-again
mkdir -p sub/deep && echo new >sub/deep/n.txt
check "git wip, run from a subdirectory" bash -c 'cd sub/deep && git wip -q'
check_output "committed as wip" '^wip$' git log -1 --format=%s
git config --global alias.where '!pwd'
check_output "a ! alias runs from the top of the repository" "^$HOME/al$" bash -c 'cd sub/deep && git where'
unset GIT_CONFIG_GLOBAL

section "A commit message template"
printf 'Subject line\n\n# Why the change:\n' >"$HOME/.gitmessage"
bash -ec "git config --global $(note_block "$NOTE" "A commit message template" 1 | awk '/template/ {print "commit.template", $3}')"
echo change >>f.txt && git add f.txt
check_output "an unchanged template aborts the commit" 'did not edit the message' bash -c 'GIT_EDITOR=true git commit 2>&1; true'
check "an edited one commits" env GIT_EDITOR="sed -i s/Subject\ line/Real\ subject/" git commit -q
check_output "with the edited text" '^Real subject$' git log -1 --format=%s

section "Signing commits with an SSH key"
skip "SSH signing" "the test container has no ssh-keygen, which git calls to sign"
