#!/usr/bin/env bash
# note: linux/cli/stow.md
# env: leap
source "$NOTES_ROOT/tests/lib/assert.sh"

NOTE=linux/cli/stow

# A throwaway home with a dotfiles repo in it, as in the note's layout.
new_home() {
  export HOME
  HOME=$(mktemp -d)
  mkdir -p "$HOME/dotfiles"/{bash,git,nvim/.config/nvim}
  echo 'alias ll="ls -l"' >"$HOME/dotfiles/bash/.bashrc"
  printf '[user]\n    name = Repo\n' >"$HOME/dotfiles/git/.gitconfig"
  echo 'vim.o.number = true' >"$HOME/dotfiles/nvim/.config/nvim/init.lua"
  echo readme >"$HOME/dotfiles/README.md"
  cd "$HOME/dotfiles"
}

section "Install"
zypper -n install stow >/dev/null
check_output "stow is at least 2.4.0" 'version 2\.([4-9]|[1-9][0-9])\.' stow --version

section "First run"
new_home
out=$(stow -nv bash 2>&1)
assert_match "dry run prints the LINK line" '^LINK: \.bashrc => dotfiles/bash/\.bashrc$' "$out"
assert_match "dry run warns about simulation mode" 'in simulation mode so not modifying filesystem' "$out"
assert_no_file "dry run changes nothing" "$HOME/.bashrc"
stow -v bash git nvim 2>/dev/null
assert_link "default target is the parent of the stow directory" "$HOME/.bashrc" dotfiles/bash/.bashrc
assert_no_file "README.md is not linked" "$HOME/README.md"

section "First run: moving the repository"
mv "$HOME/dotfiles" "$HOME/moved"
check_fails "link is broken after the move" test -e "$HOME/.bashrc"
cd "$HOME/moved"
check_output "stow -R refuses: not owned by stow" 'not owned by stow' bash -c "stow -R -t '$HOME' bash 2>&1; true"
check "find -xtype l deletes the broken links" find "$HOME" -xtype l -lname '*dotfiles/*' -print -delete
assert_no_file "broken link is gone" "$HOME/.bashrc"
check "stow works after the cleanup" stow -t "$HOME" bash
check "link works again" test -e "$HOME/.bashrc"

new_home
stow bash git nvim
mkdir -p "$HOME/src"
cd "$HOME"
# The note's unstow / move / stow sequence, verbatim.
check "unstow, move, stow sequence from the note" bash -ec "$(note_block "$NOTE" 'First run' 5)"
assert_link "links point to the new location" "$HOME/.bashrc" src/dotfiles/bash/.bashrc

section "Tree folding: the ~/.config trap"
new_home
out=$(stow -v nvim 2>&1)
assert_match "without ~/.config, nvim folds into one link" '^LINK: \.config => dotfiles/nvim/\.config$' "$out"
assert_link "\$HOME/.config itself is a link into the repo" "$HOME/.config" dotfiles/nvim/.config
mkdir -p tmux/.config/tmux && echo 'set -g mouse on' >tmux/.config/tmux/tmux.conf
stow -v tmux 2>/dev/null
check_fails "a second package unfolds ~/.config into a real directory" test -L "$HOME/.config"
check "nvim still reachable after unfolding" test -f "$HOME/.config/nvim/init.lua"
check "tmux reachable after unfolding" test -f "$HOME/.config/tmux/tmux.conf"

new_home
out=$(stow -v --no-folding nvim 2>&1)
assert_eq "--no-folding output matches the note" "$(note_block "$NOTE" 'Tree folding' 3)" "$out"
check "\$HOME/.config is a real directory" test -d "$HOME/.config" -a ! -L "$HOME/.config"
assert_link "only the file is linked" "$HOME/.config/nvim/init.lua" ../../dotfiles/nvim/.config/nvim/init.lua

section "Remove and restow"
new_home
stow nvim bash
stow -D nvim
assert_no_file "stow -D removes the package's links" "$HOME/.config"
echo 'export A=1' >bash/.bash_profile
stow bash
check "plain stow adds links for new files" test -L "$HOME/.bash_profile"
rm bash/.bash_profile
stow bash
check "plain stow leaves a broken link for a deleted file" test -L "$HOME/.bash_profile"
stow -R bash
assert_no_file "stow -R removes the broken link" "$HOME/.bash_profile"

section "Store files without the leading dot"
new_home
mkdir -p zsh tmux/dot-config/tmux
echo 'setopt autocd' >zsh/dot-zshrc
echo 'set -g mouse on' >tmux/dot-config/tmux/tmux.conf
mkdir -p "$HOME/.config"
check "stow --dotfiles with a dot-config directory" stow -v --dotfiles zsh tmux
assert_link "dot-zshrc becomes ~/.zshrc" "$HOME/.zshrc" dotfiles/zsh/dot-zshrc
check "dot-config/ is translated to .config/ (needs 2.4.0)" test -f "$HOME/.config/tmux/tmux.conf"
assert_no_file "no literal dot-config in the target" "$HOME/dot-config"
stow -D zsh 2>/dev/null || true
check "stow -D without --dotfiles leaves the link" test -L "$HOME/.zshrc"
stow -D --dotfiles zsh
assert_no_file "stow -D --dotfiles removes it" "$HOME/.zshrc"
mkdir -p gitpkg && echo '*.swp' >gitpkg/dot-gitignore
stow --dotfiles gitpkg
check "dot-gitignore is stowed, not ignored (2.4.1)" test -L "$HOME/.gitignore"

section "Conflicts"
new_home
echo 'real' >"$HOME/.gitconfig"
out=$(stow git 2>&1) && rc=0 || rc=$?
assert_match "exit code is non-zero" '^[1-9]' "$rc"
assert_match "the conflict is reported" 'would cause conflicts' "$out"
assert_match "conflict message wording matches the note" "$(note_block "$NOTE" 'Conflicts' 1 | sed -n 2p | sed 's/^ *\* //; s/[][\.*^$]/\\&/g')" "$out"
assert_eq "the real file is untouched" real "$(cat "$HOME/.gitconfig")"

section "--adopt"
# The adopted ~/.gitconfig is not valid git config, so keep git away from it.
export GIT_CONFIG_GLOBAL=/dev/null
git init -q . && git add -A && git -c user.name=t -c user.email=t@example.com commit -qm init
out=$(stow --adopt -v git 2>&1)
assert_match "MV line" '^MV: \.gitconfig -> dotfiles/git/\.gitconfig$' "$out"
assert_link "then linked" "$HOME/.gitconfig" dotfiles/git/.gitconfig
assert_eq "home file replaced the repository file" real "$(cat git/.gitconfig)"
check_output "git diff shows the change" '^\+real$' git -C "$HOME/dotfiles" diff
git -C "$HOME/dotfiles" checkout -q .
assert_match "checkout restores the repository version" 'name = Repo' "$(cat "$HOME/.gitconfig")"
unset GIT_CONFIG_GLOBAL

section "Ignore lists"
new_home
mkdir -p pkg/.git && touch pkg/LICENSE pkg/COPYING pkg/README.md pkg/.gitignore pkg/keep
stow pkg
for f in .git LICENSE COPYING README.md .gitignore; do
  assert_no_file "default ignore list skips $f" "$HOME/$f"
done
check "other files are linked" test -L "$HOME/keep"
mkdir -p scripts/bin && echo x >scripts/bin/hi && touch scripts/NOTES.md scripts/README.md
printf '%s\n' '\.stow-local-ignore' 'NOTES\.md' >scripts/.stow-local-ignore
stow scripts
assert_no_file "local ignore list applies" "$HOME/NOTES.md"
check "a local list replaces the defaults: README.md is linked" test -L "$HOME/README.md"
stow -D scripts
note_block "$NOTE" 'Ignore lists' 1 | grep -v '^#' >scripts/.stow-local-ignore
stow scripts
assert_no_file "the note's example list skips README.md" "$HOME/README.md"
assert_no_file "the note's example list skips NOTES.md" "$HOME/NOTES.md"

section "Defaults in .stowrc"
new_home
mkdir -p zsh && echo 'setopt autocd' >zsh/dot-zshrc
mv "$HOME/dotfiles" "$HOME/elsewhere" && mkdir -p "$HOME/src" && mv "$HOME/elsewhere" "$HOME/src/dotfiles"
cd "$HOME/src/dotfiles"
note_block "$NOTE" 'Defaults in' 1 >.stowrc
stow zsh nvim
assert_link "--target=~ is expanded to \$HOME" "$HOME/.zshrc" src/dotfiles/zsh/dot-zshrc
check "--no-folding from .stowrc applies" test -d "$HOME/.config" -a ! -L "$HOME/.config"
stow -D zsh
assert_no_file "-D picks up --dotfiles from .stowrc" "$HOME/.zshrc"

section "Several machines: bootstrap script"
new_home
note_block "$NOTE" 'Several machines' 2 >bootstrap.sh
mkdir -p tmux/.config/tmux && touch tmux/.config/tmux/tmux.conf
check "bootstrap script runs" bash bootstrap.sh
check "bootstrap linked nvim without folding" test -L "$HOME/.config/nvim/init.lua"
check "bootstrap linked bash" test -L "$HOME/.bashrc"

section "Keep secrets out of the repository"
new_home
note_block "$NOTE" 'Keep secrets' 1 >git/.gitconfig
mkdir -p "$HOME/.config/git"
note_block "$NOTE" 'Keep secrets' 2 >"$HOME/.config/git/local"
stow git
# Outside a repository, so only the global file (and what it includes) is read.
# `git config --global` alone would skip includes: --includes is off for named files.
cd "$HOME"
assert_eq "git reads the email from the included file" your.name@example.com "$(git config user.email)"
assert_eq "and the name from the committed file" "Your Name" "$(git config user.name)"
cd "$HOME/dotfiles"

section "Programs that replace your links"
new_home
stow bash
sed -i 's/ll/la/' "$HOME/.bashrc"
check_fails "sed -i replaces the link with a regular file" test -L "$HOME/.bashrc"
rm "$HOME/.bashrc"
stow bash
sed -i --follow-symlinks 's/ll/la/' "$HOME/.bashrc"
check "--follow-symlinks keeps the link" test -L "$HOME/.bashrc"
assert_match "and edits the repository file" 'alias la=' "$(cat bash/.bashrc)"
check_output "find lists links into the repository" '\.bashrc$' find ~ -maxdepth 3 -lname '*dotfiles/*'
sed -i 's/la/ll/' "$HOME/.bashrc"
out=$(stow -nv --no-folding -R bash 2>&1 || true)
assert_match "restow simulation reports a replaced link as a conflict" 'conflict' "$out"
