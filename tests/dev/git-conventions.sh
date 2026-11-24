#!/usr/bin/env bash
# note: dev/git-conventions.md
# env: compose
# The gitmoji tables are checked against the gitmojis npm package (its data is read as
# text, not run). The GitLab settings and the review workflow are not tested.
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/compose.sh"
source "$NOTES_ROOT/tests/versions.env"

NOTE=dev/git-conventions
pull "$MERMAID_CLI_IMAGE"
W=$PWD
export GIT_CONFIG_GLOBAL=$W/gitconfig GIT_CONFIG_NOSYSTEM=1
git config --global user.name 'Test User' && git config --global user.email test@example.com

section "gitmoji"
mkdir gm && curl -fsSL "https://registry.npmjs.org/gitmojis/-/gitmojis-${GITMOJIS_VERSION}.tgz" | tar xz -C gm
out=$(python3 -I - gm/package/dist/index.mjs "$NOTES_ROOT/content/$NOTE.md" <<'EOF'
import re, sys
src = open(sys.argv[1], encoding="utf-8").read()
official = {c: e for e, c in re.findall(r'emoji:\s*"([^"]+)"[^}]*?code:\s*"(:[a-z0-9_]+:)"', src)}
strip = lambda s: s.replace("\ufe0f", "")
rows = bad = 0
for line in open(sys.argv[2], encoding="utf-8"):
    m = re.match(r"\| (\S+) \| `(:[a-z0-9_]+:)` \|", line)
    if not m:
        continue
    rows += 1
    emoji, code = m.groups()
    if code not in official:
        print("not a gitmoji:", code); bad += 1
    elif strip(official[code]) != strip(emoji):
        print("wrong emoji for", code); bad += 1
print(f"{len(official)} official, {rows} rows, {bad} bad")
EOF
)
assert_match "every code in the tables is a gitmoji, with its emoji" '^[0-9]+ official, [0-9]+ rows, 0 bad$' "$(tail -1 <<<"$out")"
assert_match "the list was read (more than 60 gitmojis)" '^[6-9][0-9] official' "$(tail -1 <<<"$out")"

section "Branches"
git init -q plain
check_output "plain git init names the first branch master" '^refs/heads/master$' git -C plain symbolic-ref HEAD
check_output "git init -b main names it main" '^refs/heads/main$' bash -c 'git init -q -b main b && git -C b symbolic-ref HEAD'
git config --global init.defaultBranch main
check_output "and so does init.defaultBranch main" '^refs/heads/main$' bash -c 'git init -q c && git -C c symbolic-ref HEAD'
note_block "$NOTE" 'A simplified gitflow' 1 >flow.mmd
check "the gitGraph renders" docker run --rm -u "$(id -u):$(id -g)" -v "$W:/data" "$MERMAID_CLI_IMAGE" -i flow.mmd -o flow.svg

section "Tags"
cd c && git commit -q --allow-empty -m ":tada: init" && git tag -a v1.0.0 -m "1.0.0" && git tag v1.0.1
check_output "an annotated tag is a tag object, with a message and a tagger" '^tag Test User 1\.0\.0$' \
  bash -c 'echo "$(git cat-file -t v1.0.0) $(git for-each-ref --format="%(taggername) %(contents:subject)" refs/tags/v1.0.0)"'
check_output "a lightweight tag is only a name for the commit" '^commit$' git cat-file -t v1.0.1
check_output "git log shows a gitmoji code as typed" '^:tada: init$' git log -1 --format=%s
