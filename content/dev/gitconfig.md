---
title: Git configuration
description: Where git reads its configuration, which level wins, the environment variables that override all of it, conditional includes for work and personal identities, and a commented ~/.gitconfig
tags: [dev, git, configuration]
type: reference
status: complete
---

# Git configuration

Git reads settings from several files and merges them. Most surprises come from not
knowing which file a value came from, or from an environment variable that silently
overrides all of them. For the commands themselves, see [[dev/git]] and
[[dev/git-cheatsheet]].

## Levels

| Level | File | Written by |
| --- | --- | --- |
| system | `/etc/gitconfig` | `git config --system` |
| global | `~/.gitconfig` or `~/.config/git/config` | `git config --global` |
| local | `.git/config` in the repository | `git config` or `git config --local` |
| worktree | `.git/config.worktree` | `git config --worktree`, once `extensions.worktreeConfig` is on; before that, it writes `.git/config` like `--local` |
| command | — | `git -c key=value <command>`, for one command |

Git reads them in that order, and **a later level wins**: a value in `.git/config`
replaces the same key in `~/.gitconfig`. Keys that can hold several values, such as
`includeIf` paths, add up instead.

## Reading the configuration

The question is almost always "where does this value come from":

```bash
git config --show-origin --show-scope --get-all user.email
```

```text
global  file:/home/alice/.gitconfig        alice@work.example.com
local   file:.git/config                   alice@example.com
```

The last line is the value git uses. The whole merged configuration, with origins:

```bash
git config --list --show-origin --show-scope
```

Change and remove values:

```bash
git config --global init.defaultBranch main
git config --local core.autocrlf false
git config --unset --local core.autocrlf
git config --global --edit          # open ~/.gitconfig in the editor
```

## Environment variables beat every file

These variables override the configuration, **including the repository's own
`.git/config`**:

| Variable | Overrides |
| --- | --- |
| `GIT_AUTHOR_NAME`, `GIT_AUTHOR_EMAIL` | `user.name`, `user.email` for the author |
| `GIT_COMMITTER_NAME`, `GIT_COMMITTER_EMAIL` | the same for the committer |
| `GIT_CONFIG_GLOBAL=<file>` | replaces `~/.gitconfig` with another file |
| `GIT_CONFIG_NOSYSTEM=1` | ignores `/etc/gitconfig` |
| `GIT_CONFIG_COUNT`, `GIT_CONFIG_KEY_<n>`, `GIT_CONFIG_VALUE_<n>` | adds settings, like `-c` |

`git var` prints the identity git will actually use, after variables and files:

```bash
git var GIT_AUTHOR_IDENT
git var GIT_COMMITTER_IDENT
```

> [!warning] A correct `.git/config` can still commit with the wrong address
> If a shell startup file exports `GIT_AUTHOR_EMAIL`, every commit uses it, whatever
> the repository's configuration says. `git config user.email` shows the configured
> value, not the one used — only `git var GIT_AUTHOR_IDENT` tells the truth.
> `~/.zshenv` is a common place for such exports: zsh reads it for every shell,
> including the ones editors start. Remove the exports and let the configuration
> decide.

## Conditional includes

`includeIf` loads another file only when a condition holds. It is the clean way to
have a work identity and a personal identity on one machine, chosen by where the
repository lives:

```ini
# ~/.gitconfig
[user]
	name = Alice Example
	email = alice@work.example.com

[includeIf "gitdir:~/personal/"]
	path = ~/.gitconfig-personal
```

```ini
# ~/.gitconfig-personal
[user]
	email = alice@example.com
```

Every repository under `~/personal/` now commits as `alice@example.com`, with no
per-repository setup. Put the `includeIf` **after** `[user]`: the included values
must come later to win.

| Condition | Matches |
| --- | --- |
| `gitdir:~/personal/` | repositories under that directory. The trailing `/` means "and everything below" |
| `gitdir/i:~/Personal/` | the same, case-insensitive (macOS, Windows) |
| `onbranch:main` | while `main` is checked out |
| `hasconfig:remote.*.url:https://github.com/acme/**` | repositories with a remote matching the pattern |

A relative `path` is relative to the file that contains the `includeIf`.

> [!tip] Check from inside a repository
> `git config --show-origin --get user.email` in a personal repository should name
> `~/.gitconfig-personal`. If it names `~/.gitconfig`, the path in the condition does
> not match the repository's location.

## A commented `~/.gitconfig`

```ini
[init]
	defaultBranch = main
[pull]
	ff = only              # refuse to create a merge commit on pull: decide explicitly
[push]
	autoSetupRemote = true # the first push of a new branch sets its upstream
[fetch]
	prune = true           # drop remote-tracking branches deleted on the remote
[rebase]
	autoStash = true       # stash local changes before a rebase, restore them after
	autoSquash = true      # place fixup! commits automatically in rebase -i
	updateRefs = true      # move stacked branches along with the one being rebased
[rerere]
	enabled = true         # remember how a conflict was resolved, reuse it next time
[merge]
	conflictStyle = zdiff3 # show the common ancestor inside conflict markers
[diff]
	algorithm = histogram  # often more readable diffs than the default
	colorMoved = default   # moved lines in another colour than added and removed ones
[commit]
	verbose = true         # show the diff below the message in the editor
[branch]
	sort = -committerdate  # git branch lists recent branches first
[tag]
	sort = version:refname # v1.10 after v1.9, not after v1.1
[column]
	ui = auto              # branches and tags in columns, in a terminal
[help]
	autocorrect = prompt   # ask before running the command a typo most likely meant
```

What `merge.conflictStyle = zdiff3` changes, on a conflicted file:

```text
<<<<<<< HEAD
timeout = 30
||||||| ce69715
timeout = 10
=======
timeout = 60
>>>>>>> feature
```

The middle part, after `|||||||` and the hash of the common ancestor, is the version
both sides started from. Without it, you see two changes but not what each side
changed **from**. In a rebase the label reads `parent of <hash> (<subject>)`.

## Aliases

```ini
[alias]
	st = status --short --branch
	lg = log --graph --oneline --decorate --all
	last = log -1 --stat
	amend = commit --amend --no-edit
	fixup = commit --fixup
	undo = reset --soft HEAD~1
	wip = !git add --all && git commit --message wip
```

`git lg` then shows every branch as a graph. An alias that starts with `!` runs a
shell command, from the top of the repository.

## A commit message template

```ini
[commit]
	template = ~/.gitmessage
```

The template's text appears in the editor for each new commit. If you save it
unchanged, git aborts the commit — the template counts as an empty message.

## Signing commits with an SSH key

An SSH key works for signing, with no GPG setup:

```ini
[gpg]
	format = ssh
[user]
	signingkey = ~/.ssh/id_ed25519.pub
[commit]
	gpgSign = true
[gpg "ssh"]
	allowedSignersFile = ~/.config/git/allowed_signers
```

```bash
echo "alice@example.com $(cat ~/.ssh/id_ed25519.pub)" > ~/.config/git/allowed_signers
git log --show-signature -1
```

`allowedSignersFile` maps addresses to keys, so `git log --show-signature` can say
whose signature it is. Forges such as GitHub and Gitea verify it against the keys in
your account.

> [!note] Not tested here
> The test container has no `ssh-keygen`, which git calls to sign. The configuration
> above follows the git documentation for `gpg.format = ssh`.

## Where to go next

- [[dev/git]] — the commands, from the first commit to worktrees
- [[dev/git-cheatsheet]] — advanced commits, rebase, history rewriting, finding commits
- [[dev/git-conventions]] — branching model and commit messages

<!-- uplink -->
Part of [[dev/index|Development]].
