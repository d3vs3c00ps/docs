#!/usr/bin/env bash
# note: dev/git.md
# env: leap
# Placeholders in the note (c11a9316ff..., your.name@yourserver..., <file>, HEAD~N) are
# replaced by a real hash, a local bare repository, a file and a number.
source "$NOTES_ROOT/tests/lib/assert.sh"

NOTE=dev/git
HOME=$(mktemp -d)
export HOME GIT_CONFIG_NOSYSTEM=1 GIT_EDITOR=true
unset GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL
cd "$HOME"
blk() { note_block "$NOTE" "$1" "${2:-1}"; }
line() { blk "$1" "$2" | sed -n "${3}p"; }
commit() { echo "$1" >>"${2:-f.txt}" && git add -A && git commit -qm "$1"; }
fresh() { cd "$HOME" && rm -rf "$1" && git init -q -b main "$1" && cd "$1"; }
bare() { rm -rf "$HOME/$1.git" && git init -q --bare -b main "$HOME/$1.git"; }
sha_of() { git rev-parse "$1"; }
with_sha() { sed -E "s/c11a9316ff[0-9a-f]*/$1/g"; }

section "Configuring your identity"
check "global identity (from the note)" bash -ec "$(blk "Configuring your identity" 1)"
check_output "is written to ~/.gitconfig" '^user\.email=your\.name@example\.com$' git config --global --list
blk "Configuring your identity" 2 >"$HOME/shown.gitconfig"
check_output "the ini block is the same configuration" '^user\.email=your\.name@example\.com$' git config --file "$HOME/shown.gitconfig" --list
git config --global init.defaultBranch main
fresh perrepo && commit one
check "per-repository identity (from the note)" bash -ec "$(blk "Configuring your identity" 3)"
check_output "the repository value wins" '<your\.name@personal\.example\.com>' git var GIT_AUTHOR_IDENT
check_output "the environment variable wins over both" '<env@example\.com>' env GIT_AUTHOR_EMAIL=env@example.com git var GIT_AUTHOR_IDENT
cd "$HOME"
blk "Configuring your identity" 4 >>"$HOME/.gitconfig"
printf '[user]\n\temail = me@work.example.com\n' >"$HOME/.gitconfig-work"
printf '[user]\n\temail = me@personal.example.com\n' >"$HOME/.gitconfig-personal"
mkdir -p work personal && git -C work init -q w && git -C personal init -q p
check_output "includeIf gitdir:~/work/ (from the note)" '^me@work\.example\.com$' git -C work/w config --get user.email
check_output "includeIf gitdir:~/personal/" '^me@personal\.example\.com$' git -C personal/p config --get user.email

section "Initialising a project"
mkdir -p "$HOME/i1" "$HOME/i2"
check "git init (from the note)" bash -ec "cd $HOME/i1 && $(line "Initialising a project" 1 1)"
check "git init -b main (from the note)" bash -ec "cd $HOME/i2 && $(line "Initialising a project" 1 2)"
check_output "the first branch is main" '^refs/heads/main$' git -C "$HOME/i2" symbolic-ref HEAD

section "The remote repository"
fresh origin-src && commit one && bare myproject && git push -q "$HOME/myproject.git" main
cd "$HOME"
check "git clone (from the note, URL replaced by a local repository)" \
  bash -ec "$(blk "The remote repository" 1 | sed -E "s#ssh://[^ ]+#$HOME/myproject.git#")"
cd myproject
check_output "remote -v shows fetch and push URLs, as in the note" "^origin	$HOME/myproject\.git \(fetch\)$" git remote -v
check_output "and the push line" '\(push\)$' git remote -v
check_output "git status (from the note)" 'up to date with' bash -ec "$(blk "The remote repository" 3)"

section "Adding and committing"
fresh adding && echo a >a.txt && echo b >b.txt && git add -A && git commit -qm base
prep() { git reset -q --hard && git clean -qfd && echo more >>a.txt && rm b.txt && echo c >c.txt && mkdir -p sub && echo d >sub/d.txt; }
prep && (cd sub && git add .)
assert_eq "git add . stages only under the current directory" "A  sub/d.txt" "$(git status --short | grep -v '^ \|^??' | sed '/^$/d')"
prep && git add .
check_output "git add . from the top stages deletions too (Git >= 2.0)" '^D  b\.txt$' git status --short
check_output "and new files" '^A  c\.txt$' git status --short
prep && git add -u
check_output "git add -u stages modified files" '^M  a\.txt$' git status --short
check_output "and deletions" '^D  b\.txt$' git status --short
check_output "but not new files" '^\?\? c\.txt$' git status --short
prep && (cd sub && git add -A)
check_output "git add -A from a subdirectory covers the whole repository" '^A  c\.txt$' git status --short
prep && git add a.txt
assert_eq "git add <path> stages one file" "M  a.txt" "$(git status --short | grep -v '^ \|^??')"
check "git commit -m (from the note)" bash -ec "$(line "Adding and committing" 1 1)"
git reset -q --hard && git clean -qfd && echo x >>a.txt && echo new >new.txt
check "git commit -a -m (from the note)" bash -ec "$(line "Adding and committing" 1 2)"
check_output "-a committed the modified tracked file" 'a\.txt' git show --stat --format= HEAD
check_output "but not the new, untracked file (the trap)" '^\?\? new\.txt$' git status --short

section "Tags"
fresh tags && commit one && commit two && commit three
target=$(sha_of HEAD~1)
check "git tag v2 <commit> (from the note)" bash -ec "$(blk "Tags" 1 | with_sha "$target")"
assert_eq "v2 points to that commit" "$target" "$(git rev-parse 'v2^{commit}')"
git tag v1.0 HEAD~2 && git tag v1.1 HEAD~2
check_output "git tag -l 'v1.*' (from the note)" '^v1\.1$' bash -ec "$(blk "Tags" 2)"
check_fails "git tags is not a git command" git tags
git tag "$target" v2
check_output "the swapped order makes a tag named after the hash" "^$target$" git tag -l "$target"
git tag -d "$target" >/dev/null
check "git tag -d (from the note)" bash -ec "$(blk "Tags" 3)"
check_fails "v2 is gone" git rev-parse -q --verify refs/tags/v2
check "annotated tag (from the note)" bash -ec "$(blk "Tags" 4 | with_sha "$target")"
check_output "an annotated tag is a tag object" '^tag$' git cat-file -t v2
check_output "with a message, an author and a date" '^tagger Your Name|^tagger your\.name' git cat-file -p v2
check_output "the message" '^version 2$' bash -c 'git cat-file -p v2 | tail -1'
bare tagremote && git remote add origin "$HOME/tagremote.git" && git push -q origin main
assert_eq "git push alone sends no tag" "" "$(git ls-remote --tags origin)"
check "git push origin v2 / --tags (from the note)" bash -ec "$(blk "Tags" 5)"
check_output "the tags are on the remote" 'refs/tags/v1\.1' git ls-remote --tags origin

section ".gitignore"
fresh ign && commit base
blk ".gitignore" 1 >.gitignore
mkdir -p .vscode .venv __pycache__ roles/galaxy collections && touch .DS_Store Thumbs.db .vscode/s.json x.swp .venv/a __pycache__/m.pyc m.pyc roles/galaxy/r collections/c keep.txt
for p in .DS_Store Thumbs.db .vscode/s.json x.swp .venv/a __pycache__/m.pyc m.pyc roles/galaxy/r collections/c; do
  check "ignored (from the note's .gitignore): $p" git check-ignore -q "$p"
done
check_fails "an ordinary file is not ignored" git check-ignore -q keep.txt
echo log >app.log && git add app.log && git commit -qm log && echo '*.log' >>.gitignore && echo more >>app.log
check_output ".gitignore does not affect a tracked file" '^ M app\.log$' git status --short
git rm -q --cached app.log
check "after git rm --cached, it is ignored" git check-ignore -q app.log

section "Publishing to a remote"
fresh pub && commit one && bare my_project
url="your.name@yourserver.example.com:/path/to/my_project.git"
check "remote add + push (from the note, URL replaced)" bash -ec "$(blk "Publishing to a remote" 1 | sed "s#$url#$HOME/my_project.git#")"
check_fails "a plain push does not set an upstream" git rev-parse --abbrev-ref '@{upstream}'
check "push --set-upstream (from the note)" bash -ec "$(blk "Publishing to a remote" 2)"
check_output "now main tracks origin/main" '^origin/main$' git rev-parse --abbrev-ref '@{upstream}'
git switch -q -c dev && commit devwork && git switch -q main
check "push origin dev:main (from the note)" bash -ec "$(blk "Publishing to a remote" 3)"
assert_eq "the remote main is now local dev" "$(sha_of dev)" "$(git ls-remote origin refs/heads/main | cut -f1)"
git push -q origin dev
check "push origin :dev (from the note)" bash -ec "$(blk "Publishing to a remote" 4)"
assert_eq "deletes the remote dev" "" "$(git ls-remote origin refs/heads/dev)"
check "push origin main:feature-topic (from the note)" bash -ec "$(blk "Publishing to a remote" 5)"
check_output "creates the remote branch, no pull request" 'refs/heads/feature-topic' git ls-remote origin
skip "gh pr create / glab mr create" "needs a GitHub or GitLab account and network"
check "remote set-url (from the note, URL replaced)" bash -ec "$(blk "Publishing to a remote" 7 | sed "s#$url#$HOME/other.git#")"
check_output "the URL changed" "^$HOME/other\.git$" git remote get-url origin

section "History"
fresh hist && commit one && commit two
while read -r cmd; do
  [[ -z $cmd ]] && continue
  check "$(cut -c1-40 <<<"$cmd") (from the note)" bash -ec "${cmd//<file>/f.txt}"
done < <(blk "History" 1 | sed 's/#.*//')
check_output "--author filters by author" 'two' git log --author="your.name" --format=%s

section "Going back in history"
fresh back && commit one && commit two && commit three
check "switch --detach HEAD~1 (from the note)" bash -ec "$(line "Going back in history" 1 1)"
check_output "HEAD is detached on the parent" '^two$' git log -1 --format=%s
check_fails "no branch is checked out" git symbolic-ref -q HEAD
git switch -q main
check "switch --detach <hash> (from the note)" bash -ec "$(line "Going back in history" 1 2 | with_sha "$(sha_of HEAD~2)")"
commit orphan
orphan=$(sha_of HEAD)
git switch -q main 2>/dev/null
assert_eq "a commit made there belongs to no branch" "" "$(git branch --contains "$orphan")"
git switch -q --detach HEAD~1 && git switch -q -
check_output "git switch - returns to the branch" '^main$' git branch --show-current
git switch -q --detach HEAD~1 && commit keep && git switch -q -c fix-attempt
check_output "git switch -c keeps the work in a branch" '^fix-attempt$' git branch --contains HEAD --format='%(refname:short)'

section "Branches"
fresh br && commit one && bare brremote && git remote add origin "$HOME/brremote.git" && git push -q origin main && git fetch -q
check "switch -c dev (from the note)" bash -ec "$(line "Branches" 1 1)"
check_output "creates and switches" '^dev$' git branch --show-current
check "switch main (from the note)" bash -ec "$(line "Branches" 1 2)"
check "branch -m dev new_dev (from the note)" bash -ec "$(line "Branches" 1 3)"
check_output "renamed" 'new_dev' git branch
git branch dev
check "branch -d dev, a merged branch (from the note)" bash -ec "$(line "Branches" 1 4)"
git switch -q -c unmerged && commit extra && git switch -q main
check_fails "-d refuses a branch with unmerged commits" git branch -d unmerged
git branch -q -c unmerged dev
check "branch -D deletes regardless (from the note)" bash -ec "$(line "Branches" 1 5)"
check_output "branch -a lists remote-tracking branches (from the note)" 'remotes/origin/main' bash -ec "$(line "Branches" 1 6)"

section "Merging"
fresh mg && commit base && git switch -q -c dev && commit d1 d.txt && git switch -q main && commit m1 m.txt && git switch -q dev
check "switch main; merge dev (from the note)" bash -ec "$(blk "Merging" 1)"
check_output "records a merge commit with two parents" '^[0-9a-f]+ [0-9a-f]+ [0-9a-f]+$' git log -1 --format='%H %P'

section "Rebasing"
fresh rb && commit base && git switch -q -c dev && commit d1 d.txt && git switch -q main && commit m1 m.txt
check "rebase dev on main, then fast-forward (from the note)" bash -ec "$(blk "Rebasing" 1)"
assert_eq "main and dev are the same commit" "$(sha_of dev)" "$(sha_of main)"
assert_eq "linear: no merge commit" "" "$(git log --merges --format=%H)"
fresh rb2 && commit base && git switch -q -c dev && commit d1 d.txt && git switch -q main && commit m1 m.txt
check_fails "the original command fails" bash -c "git rebase dev -m \"Rebase branch 'dev'\" 2>/dev/null"
git rebase --abort 2>/dev/null || true
git rebase -q dev
check "from main, git rebase dev puts dev under main" git merge-base --is-ancestor dev main
check_output "main's commit was replayed on top" '^m1$' git log -1 --format=%s main

section "Resolving merge conflicts"
fresh rc && commit base && git switch -q -c dev && echo dev >f.txt && git commit -qam dev && git switch -q main && echo main >f.txt && git commit -qam main
check "merge.tool configuration (from the note)" bash -ec "$(blk "Resolving merge conflicts" 1)"
check_output "merge.tool is vimdiff" '^vimdiff$' git config --global --get merge.tool
skip "git mergetool" "interactive: opens vimdiff"
git merge dev >/dev/null 2>&1 || true
check_output "the merge stops on the conflict" '^UU f\.txt$' git status --short
check "merge --abort (from the note)" bash -ec "$(blk "Resolving merge conflicts" 5)"
check_output "abandons the merge" '^main$' cat f.txt
echo edit >>f.txt
while read -r cmd; do
  [[ -z $cmd ]] && continue
  check "$(cut -c1-40 <<<"$cmd") (from the note)" bash -ec "$cmd"
done < <(blk "Resolving merge conflicts" 3 | sed 's/#.*//')
check_output "git diff main..dev shows the change" '^\+dev$' git diff main..dev
git checkout -q -- f.txt && mkdir -p junkdir && touch junkdir/x junk.txt
check_fails "git clean alone refuses: no -f" git clean
check_output "git clean -nd lists what would go" 'Would remove junkdir/' git clean -nd
check "and deletes nothing" test -e junk.txt
git clean -qf
check "git clean -f leaves untracked directories" test -d junkdir
git merge dev >/dev/null 2>&1 || true
echo resolved >f.txt && git add f.txt
check "after resolving: commit, then clean -fd (from the note)" bash -ec "$(blk "Resolving merge conflicts" 4)"
check_output "the commit is the merge" '^Merge branch .dev.' git log -1 --format=%s
check_fails "clean -fd removed the directory" test -d junkdir

section "Undoing changes"
fresh undo && echo w >wrong_file && echo s >staged_file && git add -A && git commit -qm base
check "rm --cached (from the note)" bash -ec "$(blk "Undoing changes" 1)"
check "the file stays on disk" test -f wrong_file
check_output "and is no longer tracked" '^\?\? wrong_file$' git status --short
git commit -qm untrack && echo edit >>staged_file && git add staged_file
check "restore --staged (from the note)" bash -ec "$(blk "Undoing changes" 2)"
check_output "unstaged, edit kept" '^ M staged_file$' git status --short
check "restore (from the note)" bash -ec "$(blk "Undoing changes" 3)"
assert_eq "the edit is discarded" "s" "$(cat staged_file)"
echo edit >>staged_file && git add staged_file && git reset -q HEAD staged_file
check_output "reset HEAD <file> only unstages: the edit stays (the correction)" 'edit' cat staged_file
git checkout -q -- staged_file
for n in 1 2 3; do commit "c$n" n.txt; done
git reset -q --soft HEAD~2
check_output "reset --soft HEAD~2 (from the note): changes stay staged" '^M  n\.txt$' git status --short
git commit -qm redo
bash -ec "$(line "Undoing changes" 4 2 | sed 's/HEAD~N/HEAD~1/')"
check_output "reset --mixed HEAD~1: changes stay in the working tree" '^ M n\.txt$' git status --short
git commit -qam redo2 && lost=$(sha_of HEAD)
bash -ec "$(line "Undoing changes" 4 3 | sed 's/HEAD~N/HEAD~1/')"
assert_eq "reset --hard HEAD~1: the changes are gone" "" "$(git status --short)"
check "reflog then reset --hard <hash> recovers it (the tip)" bash -c "git reflog | grep -q ${lost:0:7} && git reset -q --hard $lost"
assert_eq "back at the lost commit" "$lost" "$(sha_of HEAD)"
before=$(git rev-list --count HEAD)
check "revert <hash> (from the note)" bash -ec "$(blk "Undoing changes" 5 | with_sha "$(sha_of HEAD)") --no-edit >/dev/null"
assert_eq "revert adds a new commit" "$((before + 1))" "$(git rev-list --count HEAD)"
check_output "that undoes the change" '^Revert ' git log -1 --format=%s

section "Pausing your work"
fresh pause && commit "reorder nav" && echo wip >>f.txt
check_output "git stash prints the note's message format" '^Saved working directory and index state WIP on main: [0-9a-f]+ reorder nav$' git stash
git stash pop -q && echo new >u.txt
check "stash push -m (from the note)" bash -ec "$(line "Pausing your work" 2 1)"
check_output "untracked files are not stashed by default" '^\?\? u\.txt$' git status --short
check "stash -u (from the note)" bash -ec "$(line "Pausing your work" 2 2)"
assert_eq "-u stashes them too" "" "$(git status --short)"
check_output "stash list shows the IDs in braces (from the note)" '^stash@\{1\}: On main: half-finished parser$' bash -ec "$(blk "Pausing your work" 3)"
check "stash apply stash@{0} (from the note)" bash -ec "$(line "Pausing your work" 4 1)"
check_output "apply keeps the stash in the list" '^2$' bash -c 'git stash list | wc -l'
git reset -q --hard && git clean -qfd
check "stash pop stash@{0} (from the note)" bash -ec "$(line "Pausing your work" 4 2)"
check_output "pop removes it" '^1$' bash -c 'git stash list | wc -l'
check "stash drop and clear (from the note)" bash -ec "$(blk "Pausing your work" 5)"
assert_eq "no stash left" "" "$(git stash list)"

section "Fetching remote changes"
fresh fsrc && commit one && bare fremote && git remote add origin "$HOME/fremote.git" && git push -q -u origin main
git clone -q "$HOME/fremote.git" "$HOME/fother" && (cd "$HOME/fother" && commit theirs t.txt && git push -q && git push -q origin HEAD:gone && git push -q origin --delete gone)
git push -q origin HEAD:stale 2>/dev/null || true
git fetch -q && (cd "$HOME/fother" && git push -q origin --delete stale)
before=$(sha_of main)
check "git fetch origin, --all --prune (from the note)" bash -ec "$(blk "Fetching remote changes" 1)"
assert_eq "fetch does not move the local branch" "$before" "$(sha_of main)"
check_fails "--prune dropped the remote-tracking branch deleted on the remote" git rev-parse -q --verify refs/remotes/origin/stale
commit ours o.txt
check_fails "a plain git pull on diverged branches stops, with no pull setting" git pull -q
check_output "and asks how to reconcile them" 'divergent branches' bash -c 'git pull 2>&1; true'
check "git pull --no-rebase merges" git pull -q --no-rebase
check_output "a merge commit" '^Merge' git log -1 --format=%s
git reset -q --hard HEAD~1
check "git pull --rebase gives linear history" git pull -q --rebase
assert_eq "no merge commit" "" "$(git log --merges --format=%H)"
echo localjunk >>f.txt && commit local-only
check "fetch + reset --hard origin/main (from the note)" bash -ec "$(blk "Fetching remote changes" 2)"
assert_eq "matches the remote, local work discarded" "$(git rev-parse origin/main)" "$(sha_of HEAD)"
check "pull.ff only (from the note)" bash -ec "$(blk "Fetching remote changes" 3)"
commit ours2 o2.txt && (cd "$HOME/fother" && git pull -q --rebase && commit theirs2 t2.txt && git push -q)
check_fails "pull.ff only refuses to merge diverged branches" git pull -q
check_output "it says so" 'fast-forward' bash -c 'git pull 2>&1; true'

section "Rewriting author information"
skip "git filter-repo" "the test container does not have git-filter-repo; see dev/git-cheatsheet for the tested filter-branch path"
fresh rewr && commit one && bare rwremote && git remote add origin "$HOME/rwremote.git" && git push -q origin main && git tag t1 && git push -q origin t1
git commit -q --amend -m rewritten && git tag -f t1 >/dev/null
check "push --force --tags 'refs/heads/*' (from the note)" bash -ec "$(blk "Rewriting author information" 2)"
check_output "the rewritten branch is on the remote" 'rewritten' git --git-dir="$HOME/rwremote.git" log -1 --format=%s main
assert_eq "and the moved tag" "$(sha_of t1)" "$(git ls-remote origin refs/tags/t1 | cut -f1)"

section "Converting a bare export into a working repository"
fresh exp-src && commit one && commit two
git clone -q --bare "$HOME/exp-src" "$HOME/export" && cd "$HOME/export"
check_fails "a current bare clone has no FETCH_HEAD, so the original list fails" test -e FETCH_HEAD
check "the note's commands, in a bare clone" bash -ec "$(blk "Converting a bare export" 1)"
check_output "the files are back" '^one$' head -1 f.txt
check_output "it is a normal repository" '^false$' git rev-parse --is-bare-repository

section "Worktrees"
fresh myapp && commit one && git branch hotfix/urgent
check "add, list, remove, prune (from the note)" bash -ec "$(blk "Worktrees" 1)"
check "feature/new-thing exists" git rev-parse -q --verify refs/heads/feature/new-thing
check_output "the hotfix worktree is still listed" 'myapp-hotfix' git worktree list
check_fails "the feature worktree was removed" test -d ../myapp-feature
git worktree remove --force ../myapp-hotfix
fresh myapp2 && commit one && echo wip >>f.txt
check "hotfix worktree from main (from the note)" bash -ec "$(blk "Worktrees" 2)"
check "the in-progress work is untouched" grep -q wip "$HOME/myapp2/f.txt"
check_fails "the same branch cannot be checked out twice" git worktree add -q ../dup main
(cd ../myapp-hotfix && commit fix h.txt)
check_output "a commit in one worktree is visible at once in the other" '^fix$' git log -1 --format=%s hotfix/urgent
check_fails "uncommitted edits stay in their worktree" grep -q wip ../myapp-hotfix/f.txt
rm -rf ../myapp-hotfix
check_output "a folder deleted by hand stays listed" 'myapp-hotfix' git worktree list
git worktree prune
assert_no_match "until git worktree prune" 'myapp-hotfix' "$(git worktree list)"

section "With parallel AI agents"
fresh tasks-app && commit one
check "three worktrees, three branches (from the note)" bash -ec "$(blk "With parallel AI agents" 1)"
check_output "each has its own branch" '^3$' bash -c 'git worktree list | grep -c "feature/"'
skip "the npm ci setup script" "the test container has no npm, and the line needs an existing ../myapp/.env"
