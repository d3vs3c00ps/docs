#!/usr/bin/env bash
# note: dev/git-cheatsheet.md
# env: leap
# The image has no make: "Test every commit" uses a stub make that runs a real check.
source "$NOTES_ROOT/tests/lib/assert.sh"

NOTE=dev/git-cheatsheet
HOME=$(mktemp -d)
export HOME GIT_CONFIG_NOSYSTEM=1
unset GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL
git config --global user.name "Alice Example"
git config --global user.email alice@example.com
git config --global init.defaultBranch main
export GIT_EDITOR=true
blk() { note_block "$NOTE" "$1" "${2:-1}"; }               # a block of the note
line() { blk "$1" "$2" | sed -n "${3}p"; }                 # one line of a block
commit() { echo "$1" >>"${2:-f.txt}" && git add -A && git commit -qm "$1"; }
fresh() { cd "$HOME" && rm -rf "$1" && git init -q "$1" && cd "$1"; }
count() { git rev-list --count "${1:-HEAD}"; }

section "Reading the state"
fresh state && commit one && commit two
check "status, log graph, show (from the note)" bash -ec "$(blk "Reading the state")"

section "Multi-line messages"
fresh msg && commit base && echo x >>f.txt && git add f.txt
check "two -m (from the note)" bash -ec "$(blk "Multi-line messages" 1)"
assert_eq "each -m is a paragraph, a blank line between" \
  "$(printf 'Add the CSV parser\n\nThe old regex missed quoted fields. The parser handles them and reports the line number of an error.')" \
  "$(git log -1 --format=%B | sed '/^$/{N;/^\n$/D}' | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}')"
echo y >>f.txt && git add f.txt
check "-F - with a heredoc (from the note)" bash -ec "$(blk "Multi-line messages" 2)"
check_output "subject is the first line" '^Add the CSV parser$' git log -1 --format=%s
check_output "the body keeps its line breaks" '^handles them and reports' git log -1 --format=%b

section "Amend the last commit"
fresh amend && commit one && commit two
before=$(count)
check "--amend, with the editor (from the note)" bash -ec "$(line "Amend the last commit" 1 1)"
echo more >>f.txt && git add f.txt
check "--amend --no-edit (from the note)" bash -ec "$(line "Amend the last commit" 1 2)"
assert_eq "amend replaces the commit, no new one" "$before" "$(count)"
check_output "and the staged change is in it" 'more' git show HEAD:f.txt
check_output "the message is kept" '^two$' git log -1 --format=%s
git commit -q --amend --no-edit --author="Bob <bob@example.com>"
check "--amend --no-edit --reset-author (from the note)" bash -ec "$(line "Amend the last commit" 1 3)"
check_output "the author is the current identity again" '^alice@example\.com$' git log -1 --format=%ae

section "Part of a file"
fresh partial && seq 1 30 >n.txt && git add n.txt && git commit -qm base
sed -i -e '1s/.*/first/' -e '30s/.*/last/' n.txt
check "git add -p, answering y then n" bash -c "printf 'y\nn\n' | $(blk "Part of a file") >/dev/null"
check_output "the first hunk is staged" '^\+first$' git diff --cached
check_output "the second is not" '^\+last$' git diff
assert_no_match "and is not in the index" '\+last' "$(git diff --cached)"

section "Fixup commits"
fresh fixup && commit c1 && commit c2 c2.txt && commit c3 && commit c4
echo fixed >>c2.txt && git add c2.txt
check "--fixup HEAD~2 (from the note)" bash -ec "$(line "Fixup commits" 1 1)"
check_output "makes a commit named fixup! <subject>" '^fixup! c2$' git log -1 --format=%s
check "rebase -i --autosquash (from the note)" bash -ec "$(line "Fixup commits" 1 2)"
assert_eq "the fixup is merged: 4 commits again" "4" "$(count)"
assert_no_match "no fixup! commit left" 'fixup!' "$(git log --format=%s)"
check_output "the fix is in c2 itself" 'fixed' git show "$(git log --format='%H %s' | awk '$2=="c2"{print $1}'):c2.txt"
tree=$(git rev-parse 'HEAD^{tree}')
check "--fixup=reword:HEAD~2, with a new message" env GIT_EDITOR="sed -i '3s/.*/c2 renamed/'" git commit -q --fixup=reword:HEAD~2
GIT_SEQUENCE_EDITOR=: git rebase -qi --autosquash HEAD~4
check_output "after the rebase, only the message changed" '^c2 renamed$' git log --format=%s
assert_eq "and the content did not" "$tree" "$(git rev-parse 'HEAD^{tree}')"
git config --global rebase.autoSquash true
commit c5 && echo again >>c5.txt && git add c5.txt && git commit -q --fixup HEAD
check "with rebase.autoSquash = true, plain rebase -i squashes too" env GIT_SEQUENCE_EDITOR=: git rebase -qi HEAD~3
assert_no_match "no fixup! left" 'fixup!' "$(git log --format=%s)"
git config --global --unset rebase.autoSquash

section "Other commit options"
fresh opts && commit base
check "--allow-empty" git commit -q --allow-empty -m "start CI"
assert_eq "makes a commit with no change" "" "$(git diff --stat HEAD~1 HEAD)"
echo a >>f.txt && git add f.txt && git commit -q --author="Bob <bob@example.com>" -m bob
check_output "--author: Bob is the author" '^bob@example\.com alice@example\.com$' git log -1 --format='%ae %ce'
echo b >>f.txt && git add f.txt && git commit -q --date="2026-01-31 10:00" -m dated
check_output "--date sets the author date" '^2026-01-31 10:00' git log -1 --format=%ai
echo c >>f.txt && git add f.txt && git commit -q --trailer "Reviewed-by: Bob <bob@example.com>" -m reviewed
check_output "--trailer adds a trailer at the end" '^Reviewed-by: Bob <bob@example.com>$' bash -c 'git log -1 --format=%B | sed "/^$/d" | tail -1'
printf '#!/bin/sh\nexit 1\n' >.git/hooks/pre-commit && chmod +x .git/hooks/pre-commit
echo d >>f.txt && git add f.txt
check_fails "a failing pre-commit hook blocks the commit" git commit -qm hooked
check "--no-verify skips it" git commit -q --no-verify -m hooked
rm .git/hooks/pre-commit
echo e >>f.txt && echo g >>g.txt && git add f.txt g.txt
check "git commit <path> commits only that file" git commit -q f.txt -m "only f"
check_output "the other one stays staged" '^A  g\.txt$' git status --short

section "Interactive"
fresh inter && for n in 1 2 3 4 5; do commit r$n r$n.txt; done
check "rebase -i HEAD~4 shows the oldest first (from the note)" \
  env GIT_SEQUENCE_EDITOR="cp \"\$1\" $HOME/todo.txt; true #" bash -ec "$(blk "Interactive" 1)"
check_output "the list starts with HEAD~3" '^pick [0-9a-f]+ (# )?r2$' head -1 "$HOME/todo.txt"
GIT_SEQUENCE_EDITOR="sed -i '2s/^pick/drop/'" git rebase -qi HEAD~4
assert_eq "drop removes a commit" "r5 r4 r2 r1" "$(git log --format=%s | tr '\n' ' ' | sed 's/ $//')"
GIT_SEQUENCE_EDITOR="sed -i '2s/^pick/fixup/'" git rebase -qi HEAD~3
assert_eq "fixup merges into the commit above, keeps its message" "r5 r2 r1" "$(git log --format=%s | tr '\n' ' ' | sed 's/ $//')"
GIT_SEQUENCE_EDITOR="sed -i '2s/^pick/squash/'" git rebase -qi HEAD~2
check_output "squash keeps both messages for editing" '^r5$' git log -1 --format=%b
GIT_SEQUENCE_EDITOR="sed -i '1i exec false'" git rebase -qi HEAD~1 2>/dev/null || true
check_output "exec stops the rebase when it fails" 'rebase-merge' bash -c 'ls -d .git/rebase-merge'
check "--abort goes back (from the note)" bash -ec "$(line "Interactive" 2 3)"
check_fails "no rebase in progress" test -d .git/rebase-merge
fresh conflict && commit base && git switch -q -c side && echo side >f.txt && git commit -qam side && echo side2 >g.txt && git add g.txt && git commit -qm side2
git switch -q main && echo main >f.txt && git commit -qam main && git switch -q side
git rebase -q main 2>/dev/null || true
check_output "a conflicting rebase stops" 'rebase' bash -c 'git status | head -1'
check "--skip drops the conflicting commit (from the note)" bash -ec "$(line "Interactive" 2 2) >/dev/null 2>&1 || true; ! test -d .git/rebase-merge"
assert_eq "side is now main + side2 only" "side2 main base" "$(git log --format=%s | tr '\n' ' ' | sed 's/ $//')"
git reset -q --hard ORIG_HEAD 2>/dev/null || true

section "Move a branch to another base"
fresh onto && commit base
git switch -q -c feature-a && commit a1 && commit a2
git switch -q -c feature-b && commit b1 b.txt && commit b2 b.txt
git switch -q main && git merge -q --squash feature-a && git commit -qm "squashed feature-a"
check "rebase --onto main feature-a feature-b (from the note)" bash -ec "$(blk "Move a branch to another base")"
assert_eq "feature-b is now b1, b2 on top of main" "b2 b1 squashed feature-a base" "$(git log --format=%s feature-b | tr '\n' ' ' | sed 's/ $//')"

section "Test every commit"
fresh exectest && commit base && git switch -q -c work && commit w1 && commit w2 && touch ok.txt && git add ok.txt && git commit -qm w3 && git switch -q main && commit m1 m.txt && git switch -q work
mkdir -p "$HOME/bin" && printf '#!/bin/sh\n# stub: make test checks that ok.txt exists\n[ "$1" = test ] && test -f ok.txt\n' >"$HOME/bin/make" && chmod +x "$HOME/bin/make"
check_fails "rebase --exec stops at the first failing commit (from the note)" env PATH="$HOME/bin:$PATH" bash -ec "$(blk "Test every commit")"
check_output "it stopped after w1" '^w1$' git log -1 --format=%s
git rebase --abort

section "Stacked branches"
fresh stack && commit base && git switch -q -c part1 && commit p1 && git switch -q -c part2 && commit p2 && git switch -q main && commit m1 m.txt && git switch -q part2
check "rebase --update-refs main (from the note)" bash -ec "$(blk "Stacked branches")"
check_output "part1 moved with it: it sits on main now" '^m1$' git log -1 --format=%s part1~1
check "and part1 is still part2's ancestor" git merge-base --is-ancestor part1 part2
git switch -q main && git reset -q --hard HEAD && fresh stack2 && commit base && git switch -q -c part1 && commit p1 && git switch -q -c part2 && commit p2 && git switch -q main && commit m1 m.txt && git switch -q part2
git rebase -q main
check_output "without it, part1 stays on the old base" '^base$' git log -1 --format=%s part1~1

section "Undo a finished rebase"
fresh undo && commit base && git switch -q -c t && commit t1 && git switch -q main && commit m1 m.txt && git switch -q t
pre=$(git rev-parse HEAD) && git rebase -q main
check "reset --hard ORIG_HEAD (from the note)" bash -ec "$(blk "Undo a finished rebase")"
assert_eq "ORIG_HEAD is the tip before the rebase" "$pre" "$(git rev-parse HEAD)"

section "First, a backup"
fresh bk && commit one && git switch -q -c other && commit two && git switch -q main && git tag v1
check "bundle create and verify (from the note)" bash -ec "$(blk "First, a backup")"
check "restore: clone the bundle" git clone -q ../before-rewrite.bundle "$HOME/restored"
check_output "with every branch and tag" 'other' git -C "$HOME/restored" branch -a
check_output "and the tag" '^v1$' git -C "$HOME/restored" tag

section "With git filter-repo"
skip "git filter-repo" "the test container does not have git-filter-repo"

section "With git filter-branch"
fresh rw && git config user.email alice@work.example.com
echo "contact: alice@work.example.com" >notes.txt && git add notes.txt && git commit -qm "WIP: first"
commit "second"
git switch -q -c other && GIT_COMMITTER_EMAIL=bob@work.example.com git commit -q --allow-empty -m "WIP: on other" && git switch -q main
git config user.email alice@example.com
check_output "before: work addresses in history" 'work\.example\.com' git log --all --format='%ae %ce'
git log --all --format='%H %T' | sort >"$HOME/rw-before.txt"
check "filter-branch with env, msg and tree filters (from the note)" bash -ec "$(blk "With git filter-branch")"
assert_no_match "no work address left on the branches" 'work\.example\.com' "$(git log --branches --format='%ae %ce')"
check_output "but git log --all still sees the old commits, through refs/original" 'work\.example\.com' git log --all --format='%ae %ce'
check_output "bob's address was rewritten too" 'alice@example\.com' git log -1 --format=%ce other
assert_no_match "WIP: prefixes are gone, on every branch" '^WIP: ' "$(git log --branches --format=%s)"
check_output "the file content is rewritten in every commit" '^contact: alice@example\.com$' git show "$(git rev-list --max-parents=0 main)":notes.txt

section "Remove the old commits for real"
check_output "before the purge, old objects still hold the address" '^[1-9]' bash -c 'git cat-file --batch-all-objects --batch | grep -c "work.example.com"'
check_output "refs/original keeps the old branches" 'refs/original' git for-each-ref refs/original
check "purge (from the note)" bash -ec "$(blk "Remove the old commits for real")"
assert_eq "refs/original is gone" "" "$(git for-each-ref refs/original)"

section "Prove it is clean"
check_output "identities left (from the note)" 'alice@example\.com alice@example\.com' bash -ec "$(line "Prove it is clean" 1 1)"
check_output "grep over every object counts 0 (from the note)" '^0$' bash -c "$(line "Prove it is clean" 1 2); true"
fresh msgonly && commit one && commit "WIP: two" && git log --all --format=%T | sort -u >trees-before.txt
FILTER_BRANCH_SQUELCH_WARNING=1 git filter-branch -f --msg-filter 'sed "s/^WIP: //"' -- --all >/dev/null 2>&1
check_output "a messages-only rewrite keeps every tree (from the note)" 'same content' bash -ec "$(blk "Prove it is clean" 2)"
check_output "while the commit hashes changed" '^two$' git log -1 --format=%s

section "Publish"
fresh pub && commit one && git switch -q -c other && commit two && git switch -q main
git init -q --bare "$HOME/pub.git" && git remote add origin "$HOME/pub.git" && git push -q --all origin && git fetch -q origin
git commit -q --amend -m "one, rewritten"
check "force-with-lease pushes the rewritten branches (from the note)" bash -ec "$(blk "Publish")"
check_output "the remote has the new commit" 'one, rewritten' git --git-dir="$HOME/pub.git" log -1 --format=%s main
git clone -q "$HOME/pub.git" "$HOME/other-clone" && (cd "$HOME/other-clone" && commit theirs && git push -q origin main)
git commit -q --amend -m "one, again"
check_fails "it refuses when the remote moved since the last fetch" git push -q --force-with-lease --all origin

section "Stash"
fresh st && commit base && echo tracked >f.txt && echo new >u.txt
check "push -m (from the note)" bash -ec "$(line "Stash" 1 1)"
check_output "the new file is still there: not stashed without -u" '^\?\? u\.txt$' git status --short
git stash pop -q
check "push -u -m (from the note)" bash -ec "$(line "Stash" 1 2)"
assert_eq "-u stashes the untracked file too" "" "$(git status --short)"
git stash pop -q && rm u.txt
echo staged >s.txt && git add s.txt && echo unstaged >>f.txt
check "push --staged (from the note)" bash -ec "$(line "Stash" 1 3)"
check_output "only the staged file was stashed" '^ M f\.txt$' git status --short
assert_no_match "s.txt went into the stash" 's\.txt' "$(git status --short)"
git stash pop -q && git restore --staged s.txt 2>/dev/null; git checkout -q -- f.txt 2>/dev/null; rm -f s.txt
mkdir -p src && echo p >src/parser.py && git add src && git commit -qm parser
echo change >>src/parser.py && echo other >>f.txt
check "push -- src/parser.py (from the note)" bash -ec "$(line "Stash" 1 4)"
check_output "only that path is stashed" '^ M f\.txt$' git status --short
git checkout -q -- f.txt && git stash clear
echo one >>f.txt && git stash push -q -m first && echo two >>f.txt && git add f.txt && git stash push -q -m second
check_output "stash list (from the note)" 'stash@\{1\}: On main: first' bash -ec "$(line "Stash" 2 1)"
check_output "show -p 'stash@{1}' prints its diff (from the note)" '^\+one$' bash -ec "$(line "Stash" 2 2)"
git stash apply -q 'stash@{0}'
check_output "without --index, apply restores staged changes as unstaged" '^ M f\.txt$' git status --short
git checkout -q -- f.txt
echo n >newfile.txt && git add newfile.txt && git stash push -q -m newfile && git stash apply -q
check_output "but a new file that was staged stays staged" '^A  newfile\.txt$' git status --short
git reset -q --hard && rm -f newfile.txt && git stash drop -q
git checkout -q -- f.txt
check "apply --index (from the note, on the staged stash)" bash -ec "$(line "Stash" 2 3 | sed 's/stash@{1}/stash@{0}/')"
check_output "with --index, it is staged again" '^M  f\.txt$' git status --short
git reset -q --hard
check "pop (from the note)" bash -ec "$(line "Stash" 2 4)"
check_output "pop removed the newest stash" '^1$' bash -c 'git stash list | wc -l'
git reset -q --hard && echo br >>f.txt && git stash push -q -m forbranch && commit moved
check "stash branch (from the note)" bash -ec "$(line "Stash" 2 5)"
check_output "the branch starts where the stash was made" '^base|^parser' git log -1 --format=%s
check_output "with the stash applied" 'br' cat f.txt
git switch -q -f main && git stash clear && echo lost >>f.txt && git stash push -q -m tolose && echo x >>f.txt && git stash push -q -m keep
dropped=$(git stash drop 'stash@{1}' | sed -n 's/.*(\([0-9a-f]*\)).*/\1/p')
assert_match "drop prints the hash of the dropped stash" '^[0-9a-f]{7,}$' "$dropped"
check_output "fsck lists it among unreachable commits (from the note)" "$dropped" bash -c "$(blk "Stash" 3)"
git checkout -q -- f.txt
check "stash apply <hash> brings it back" git stash apply -q "$dropped"
check_output "with its change" 'lost' cat f.txt
git checkout -q -- f.txt
check "stash clear (from the note)" bash -ec "$(line "Stash" 2 7)"
assert_eq "no stash left" "" "$(git stash list)"
git stash list >/dev/null

section "Reset"
fresh rs && commit c1 && commit c2 && commit c3 && commit c4
tree=$(git rev-parse 'HEAD^{tree}')
check "reset --soft HEAD~3, then commit (from the note)" bash -ec "$(blk "Reset" 1)"
assert_eq "one commit replaces the last three" "2" "$(count)"
assert_eq "with the same content" "$tree" "$(git rev-parse 'HEAD^{tree}')"
commit c5
check "reset HEAD~1 (from the note)" bash -ec "$(line "Reset" 2 1)"
check_output "undoes the commit, keeps its changes unstaged" '^ M f\.txt$' git status --short
git commit -qam c5 && echo wip >w.txt
check "reset --keep HEAD~1 (from the note)" bash -ec "$(line "Reset" 2 2)"
check_output "drops the commit, keeps the uncommitted file" 'w\.txt' git status --short
commit c6 && echo local >>f.txt
check_fails "--keep refuses when a locally changed file would change" git reset -q --keep HEAD~1
git checkout -q -- f.txt && echo n >notes.txt && git add notes.txt
check "reset -- notes.txt (from the note)" bash -ec "$(line "Reset" 2 3)"
check_output "unstages it, keeps the file" '^\?\? notes\.txt$' bash -c 'git status --short | grep notes'
rm notes.txt w.txt && echo gone >>f.txt
before=$(git rev-parse HEAD) && git reset -q --hard HEAD~1
assert_no_match "--hard: the uncommitted change is lost" 'gone' "$(cat f.txt)"
check "reset --hard ORIG_HEAD (from the note)" bash -ec "$(line "Reset" 3 1)"
assert_eq "ORIG_HEAD undid the reset" "$before" "$(git rev-parse HEAD)"
check_output "reflog lists the positions (from the note)" 'reset: moving to' bash -ec "$(line "Reset" 3 2)"
git reset -q --hard HEAD~2
check "reset --hard HEAD@{1} (from the note)" bash -ec "$(line "Reset" 3 3)"
assert_eq "back to the previous position" "$before" "$(git rev-parse HEAD)"

section "Where is this commit"
fresh where && commit base
git switch -q -c feature && commit f1 && commit f2 f2.txt && echo "timeout = 60" >app.conf && git add app.conf && git commit -qm f3
git switch -q main && commit m1 m.txt && git cherry-pick feature~1 >/dev/null
git branch finished main~2 && git tag v1 feature
git init -q --bare "$HOME/where.git" && git remote add origin "$HOME/where.git" && git push -q origin feature && git fetch -q origin
out=$(bash -ec "$(line "Where is this commit" 2 1)")
assert_match "branch --contains: feature has feature~1" 'feature' "$out"
assert_no_match "main does not: the cherry-picked copy has another hash" 'main' "$out"
check_output "branch -a --contains lists the remote-tracking branch (from the note)" 'remotes/origin/feature' bash -ec "$(line "Where is this commit" 2 2)"
check_output "tag --contains (from the note)" '^v1$' bash -ec "$(line "Where is this commit" 2 3)"
merged=$(bash -ec "$(line "Where is this commit" 3 1)")
assert_match "--merged main lists a branch main contains" 'finished' "$merged"
assert_no_match "and not feature" 'feature' "$merged"
check_output "--no-merged main lists feature (from the note)" 'feature' bash -ec "$(line "Where is this commit" 3 2)"
check_output "merge-base is where they split (from the note)" "^$(git rev-parse main~2)$" bash -ec "$(line "Where is this commit" 4 1)"
check_output "is-ancestor (from the note)" 'feature~3 is in main' bash -ec "$(line "Where is this commit" 4 2)"
assert_eq "main..feature: the three feature commits" "f3 f2 f1" "$(bash -ec "$(line "Where is this commit" 4 3)" | cut -d' ' -f2- | tr '\n' ' ' | sed 's/ $//')"
lr=$(bash -ec "$(line "Where is this commit" 4 4)")
assert_match "--left-right: < marks main's side" '^< [0-9a-f]+ m1$' "$lr"
assert_match "> marks feature's side" '^> [0-9a-f]+ f3$' "$lr"
cm=$(bash -ec "$(line "Where is this commit" 4 5)")
assert_match "--cherry-mark: = for the change on both sides" '^= [0-9a-f]+ f2$' "$cm"
ch=$(bash -ec "$(line "Where is this commit" 4 6)")
assert_match "git cherry: - for f2, an equivalent is in main" '^- [0-9a-f]+ f2$' "$ch"
assert_match "+ for f1, not in main" '^\+ [0-9a-f]+ f1$' "$ch"
check_output "name-rev prefers a tag when one contains it (from the note)" 'tags/v1~1$' bash -ec "$(line "Where is this commit" 5 1)"
check_output "--refs='refs/heads/*' names it by branch (from the note)" ' feature~1$' bash -ec "$(line "Where is this commit" 5 2)"
check_output "log -S --source names the branch (from the note)" 'feature.*f3' bash -ec "$(line "Where is this commit" 5 3)"
dec=$(bash -ec "$(line "Where is this commit" 5 4)")
assert_no_match "--simplify-by-decoration hides undecorated commits" 'f1$' "$dec"
