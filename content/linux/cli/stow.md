---
title: GNU Stow
description: Managing dotfiles with GNU Stow — one git repository, one package per tool, symlinks into your home directory, and the traps of tree folding and --adopt
tags: [linux, cli, dotfiles, stow, git]
type: howto
status: complete
---

# GNU Stow

[GNU Stow](https://www.gnu.org/software/stow/) is a symlink manager. You keep files in
one directory, and Stow creates symbolic links to them somewhere else.

The most common use is **dotfiles**. You keep your configuration files (`.bashrc`,
`.gitconfig`, `~/.config/nvim/`) in one git repository. Stow links them into your home
directory. To set up a new machine, you clone the repository and run one command.

Stow has no templates, no secrets handling and no state file. It only creates and
removes links. That makes it simple to reason about.

## Terms

| Term | Meaning |
| --- | --- |
| stow directory | The directory that holds the packages. For dotfiles, your repository, for example `~/dotfiles`. |
| package | A subdirectory of the stow directory. One package per tool: `bash`, `git`, `nvim`. |
| target directory | Where the links go. **By default, the parent of the stow directory.** |

Because the default target is the parent directory, a repository at `~/dotfiles` links
into `~` with no extra option. If the repository lives somewhere else, pass
`--target ~` (or `-t ~`), or put it in a `.stowrc` file (see below).

Inside a package, files sit at the path they must have **relative to the target**.
`bash/.bashrc` becomes `~/.bashrc`. `nvim/.config/nvim/init.lua` becomes
`~/.config/nvim/init.lua`.

## Install

On openSUSE Leap 16:

```bash
sudo zypper install stow
stow --version
```

Most distributions and Homebrew package it as `stow`. Check the version: this note
assumes **2.4.0 or later**, because `--dotfiles` did not work with directories before
that (see [the `--dotfiles` section](#store-files-without-the-leading-dot)).

## Repository layout

```text
~/dotfiles/
├── bash/
│   └── .bashrc
├── git/
│   └── .gitconfig
├── nvim/
│   └── .config/
│       └── nvim/
│           └── init.lua
└── README.md
```

`README.md` is not linked. Stow ignores it by default (see [ignore lists](#ignore-lists)).

## First run

Always simulate first. `-n` changes nothing and `-v` prints what would happen:

```bash
cd ~/dotfiles
stow -nv bash
```

```text
LINK: .bashrc => dotfiles/bash/.bashrc
WARNING: in simulation mode so not modifying filesystem.
```

Then do it for real, with several packages at once:

```bash
stow -v bash git nvim
ls -l ~/.bashrc
```

```text
lrwxrwxrwx 1 you you 21 … /home/you/.bashrc -> dotfiles/bash/.bashrc
```

The links are **relative**. If you move the repository, the links break, and
`stow -R` from the new location does not fix them: Stow refuses to touch links that
point outside its own directory ("existing target is not owned by stow"). Unstow
before you move the repository, and stow again after:

```bash
cd ~/dotfiles && stow -D bash git nvim
mv ~/dotfiles ~/src/dotfiles
cd ~/src/dotfiles && stow -t ~ bash git nvim
```

If you already moved it, delete the broken links first, then stow:

```bash
find ~ -xtype l -lname '*dotfiles/*' -print -delete
```

## Tree folding: the `~/.config` trap

If a target directory does not exist, Stow does not create it. It creates **one link to
the whole directory** instead. This is called tree folding.

On a fresh machine with no `~/.config`, `stow nvim` gives:

```text
LINK: .config => dotfiles/nvim/.config
```

Now `~/.config` itself is a link into your repository. Every program that writes to
`~/.config` writes into your git repository.

Stow fixes this by itself when a second package needs the same directory: it
"unfolds" the link into a real directory with one link per entry. But until then, the
problem is real. Two ways to avoid it:

- create the directory first: `mkdir -p ~/.config`
- or pass `--no-folding`, so Stow always creates real directories and links only files

```bash
stow -v --no-folding nvim
```

```text
MKDIR: .config
MKDIR: .config/nvim
LINK: .config/nvim/init.lua => ../../dotfiles/nvim/.config/nvim/init.lua
```

`--no-folding` is a good default for dotfiles. Put it in `.stowrc`.

## Remove and restow

```bash
stow -D nvim     # remove the package's links
stow -R nvim     # restow: remove, then stow again
```

Restow after you **add or delete files** in a package. A plain `stow` adds links for new
files, but it does not remove links to files you deleted. Those stay behind as broken
links. `-R` removes them.

## Store files without the leading dot

Hidden files are easy to miss in a repository. With `--dotfiles`, a name that starts
with `dot-` is linked as a name that starts with `.`:

```text
~/dotfiles/zsh/dot-zshrc              ->  ~/.zshrc
~/dotfiles/tmux/dot-config/tmux/...   ->  ~/.config/tmux/...
```

```bash
stow -v --dotfiles zsh tmux
```

> [!warning] Needs Stow 2.4.0 or later for directories
> Before 2.4.0, `--dotfiles` only worked for files. With a directory such as
> `dot-config`, stow 2.3.1 stops with
> `ERROR: stow_contents() called with non-directory path`. Debian 12 still ships 2.3.1. Since 2.4.1, a file such as
> `dot-gitignore` is no longer hidden by the default ignore list.

You must pass `--dotfiles` for **every** command on those packages, including `-D`
and `-R`. Otherwise Stow looks for `dot-zshrc` in your home directory and finds
nothing. Putting the option in `.stowrc` avoids the mistake.

## Conflicts

Stow never overwrites a real file. If `~/.gitconfig` already exists and is not a
link, it stops and changes nothing:

```text
WARNING! stowing git would cause conflicts:
  * cannot stow dotfiles/git/.gitconfig over existing target .gitconfig since neither a link nor a directory and --adopt not specified
All operations aborted.
```

The exact wording depends on the version. The exit code is non-zero. Move or delete
the existing file, then stow again.

### `--adopt`, and why it is dangerous

`--adopt` resolves conflicts the other way. It **moves the existing file into the
package**, then links it:

```bash
stow --adopt -v git
```

```text
MV: .gitconfig -> dotfiles/git/.gitconfig
LINK: .gitconfig => dotfiles/git/.gitconfig
```

The file from your home directory **replaces the file in the repository**. Your
committed version is overwritten on disk. This is useful to import a machine's existing
config. It is a trap when you expected the repository version to win.

Because the repository is in git, you can always see and undo it:

```bash
git -C ~/dotfiles diff          # what the machine's files changed
git -C ~/dotfiles checkout .    # keep the repository versions instead
```

## Ignore lists

By default, Stow ignores version control files and common documentation at the top of
a package: `.git`, `.gitignore`, `README*`, `LICENSE*`, `COPYING`, and a few more.

To ignore other files in one package, create `.stow-local-ignore` in that package. It
holds one Perl regular expression per line.

> [!warning] A local ignore list replaces the default list
> Once `.stow-local-ignore` exists, the built-in defaults no longer apply to that
> package. If the package has a `README.md`, list it again, or it gets linked.

```text
# ~/dotfiles/scripts/.stow-local-ignore
\.stow-local-ignore
README.*
NOTES\.md
```

For a one-off, use `--ignore=REGEX` on the command line.

## Defaults in `.stowrc`

Stow reads options from `.stowrc` in the current directory, then from `~/.stowrc`.
Put your usual options there, one per line:

```text
--target=~
--dotfiles
--no-folding
```

`~` and environment variables are expanded in `--target` and `--dir`. Now plain
`stow zsh` does the right thing, and so does `stow -D zsh`.

## Several machines

Split packages by what they are for, then choose per machine:

```text
~/dotfiles/
├── common/     every machine: shell, git, editor
├── work/       work laptop only
└── server/     minimal set for servers
```

A small bootstrap script keeps it repeatable:

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p ~/.config ~/.local/bin
packages=(bash git nvim tmux)
[[ $(hostname) == work-* ]] && packages+=(work)
stow -v --no-folding "${packages[@]}"
```

## Keep secrets out of the repository

Dotfiles repositories are often public. Never commit tokens, keys or a work email
address. Keep them in a file that is not in the repository, and include it:

```ini
# ~/dotfiles/git/.gitconfig — committed
[user]
    name = Your Name
[include]
    path = ~/.config/git/local
```

```ini
# ~/.config/git/local — not committed
[user]
    email = your.name@example.com
```

The same pattern works for shells: end `.bashrc` with
`[ -f ~/.bashrc.local ] && . ~/.bashrc.local`.

## Programs that replace your links

Some tools save a file by writing a new file and renaming it over the old one. That
replaces the link with a regular file, and your change never reaches the repository.
`sed -i` does this by default:

```bash
sed -i 's/old/new/' ~/.bashrc          # ~/.bashrc is now a regular file
sed -i --follow-symlinks 's/old/new/' ~/.bashrc   # edits the repository file
```

Check for drift now and then. The first command lists the links under `~` that point
into the repository. The second simulates a restow: a file that should be a link but
is not shows up as a conflict.

```bash
find ~ -maxdepth 3 -lname '*dotfiles/*' 2>/dev/null
stow -nv --no-folding -R bash git nvim
```

## When to use something else

| Tool | Choose it when |
| --- | --- |
| Stow | You want plain files and links, and nothing else. |
| [chezmoi](https://www.chezmoi.io) | You need templates per machine, or secrets from a password manager. |
| [yadm](https://yadm.io) | You want git directly on `$HOME`, with alternate files per host. |
| home-manager | You use Nix. It builds the files from a declarative config. See [[linux/distributions/nixos/workstation]]. |

## See also

- git — the repository that holds the packages
- [[linux/shell/zsh]] and [[linux/shell/tmux]] — typical packages

<!-- uplink -->
Part of [[linux/cli/index|Command line tools]].
