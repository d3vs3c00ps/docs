#!/usr/bin/env bash
# note: dev/markdown.md
# env: compose
# timeout: 600
# The note's blocks go through this repository's own Quartz build, on a small sample
# site. Mermaid is checked with mermaid-cli and linting with markdownlint-cli. How
# Obsidian itself renders is not tested.
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/compose.sh"
source "$NOTES_ROOT/tests/versions.env"

NOTE=dev/markdown
nb() { note_block "$NOTE" "$@"; }
pull "$MERMAID_CLI_IMAGE" node:24-alpine
W=$PWD
# Quartz skips git-ignored paths, and this TMPDIR is git-ignored: give the sample site
# its own git root, so the repository's .gitignore does not apply.
C=$W/content && mkdir -p "$C/linux/logging" && git -C "$C" init -q
printf -- '---\ntitle: Home\n---\nHome.\n' >"$C/index.md"
printf -- '---\ntitle: The rsyslog note title\naliases: [syslog-daemon]\n---\n## Queues\n\nQueue text. ^blk1\n' >"$C/linux/logging/rsyslog.md"
printf -- '---\ntitle: Draft\ndraft: true\n---\nSecret draft.\n' >"$C/draft.md"
printf '\n---\ntitle: Blank line first\n---\nBody.\n' >"$C/broken.md"
fence() { printf '```%s\n%s\n```\n\n' "$1" "$2"; }
{
  printf -- '---\ntitle: Sample\n---\n\n'
  for h in Basics Tables Callouts 'Links between notes' Footnotes 'Highlighting and comments' 'Task lists'; do nb "$h" 1; echo; done
  printf '> [!important] An important one\n> x\n\n> [!caution] A caution\n> y\n\n'
  printf '[[linux/logging/rsyslog#^blk1]]\n\n![[linux/logging/rsyslog#Queues]]\n\n'
  printf '%%%%a comment\nover two lines%%%%\n\nText directly above a rule\n---\n\n'
  fence mermaid "$(nb 'Mermaid diagrams' 2)"
} >"$C/sample.md"
rel=${W#"$NOTES_ROOT"/}
check "Quartz builds the sample site" bash -c "cd '$NOTES_ROOT' && npx quartz build -d '$rel/content' -o '$rel/public' >build.log 2>&1 || { cat build.log; false; }"
P=public/sample.html
art() { sed -n '/<article/,/<\/article>/p' "$P"; }

section "Basics and tables"
check_output "strikethrough and inline code render" '<del>strikethrough</del>.*<code>inline code</code>' art
check_output "the table keeps its alignment" 'text-align:center|align="center"' art
check_output "--- directly under text makes it an H2" '<h2 id="text-directly-above-a-rule">' art

section "Callouts"
for t in note warning example; do check_output "> [!$t] renders as a callout" "data-callout=\"$t\"" art; done
check_output "the - suffix starts collapsed" 'class="callout tip is-collapsible is-collapsed"' art
check_output "the + suffix is collapsible, not collapsed" 'class="callout example is-collapsible"' art
# callout_of TEXT: the data-callout of the callout that holds TEXT.
callout_of() { python3 -c 'import re, sys
h = open(sys.argv[1]).read(); i = h.index(sys.argv[2])
print(re.findall(r"data-callout=\"([a-z]+)\"", h[:i])[-1])' "$P" "$1"; }
check_output "important is drawn as tip" '^tip$' callout_of 'An important one'
check_output "caution is drawn as warning, not danger" '^warning$' callout_of 'A caution'

section "Links, embeds, footnotes"
check_output "[[path/note]] shows the file name, not the title" 'data-slug="linux/logging/rsyslog">rsyslog</a>' art
check_fails "the title is not used as the link text" grep -q '>The rsyslog note title</a>' "$P"
check_output "an alias shows your text" '>the rsyslog note</a>' art
check_output "#Heading links to the section" 'href="\./linux/logging/rsyslog#queues"' art
check_output "#^block-id links to the block" 'href="\./linux/logging/rsyslog#blk1"' art
check_output "![[note#Section]] embeds the section" 'transclude.*Queue text|Queue text.*transclude' bash -c "$(declare -f art); P=$P; art | tr -d '\n'"
check_output "footnotes are collected" 'user-content-fn' art
check_output "aliases resolve: a redirect page exists" 'rel="canonical" href="\./linux/logging/rsyslog"' cat public/syslog-daemon.html

section "Highlights, comments, tasks, drafts, frontmatter"
check_output "==text== is highlighted" 'class="text-highlight">highlighted text<' art
check_output "%%comments%% never render, even over two lines" '^0$' bash -c "grep -c 'never renders\|over two lines' $P || true"
check_output "task lists render checkboxes, one checked" 'type="checkbox" checked' art
check_fails "draft: true keeps a note off the site" test -e public/draft.html
# Obsidian needs --- on line 1; that is not tested here. Quartz is lenient:
check_output "Quartz still reads frontmatter after a blank line" '<title>Blank line first</title>' cat public/broken.html
check_fails "and shows no keys as text" grep -q 'title: Blank line first' public/broken.html

section "Mermaid"
mmd() { printf 'flowchart LR\n    A[%s] --> B\n' "$1" >in.mmd; docker run --rm -u "$(id -u):$(id -g)" -v "$W:/data" "$MERMAID_CLI_IMAGE" -i in.mmd -o out.svg 2>&1; }
nb 'Mermaid diagrams' 2 >note.mmd
check "the note's flowchart renders" docker run --rm -u "$(id -u):$(id -g)" -v "$W:/data" "$MERMAID_CLI_IMAGE" -i note.mmd -o note.svg
check_output "Quartz emits it as a Mermaid block" 'mermaid' art
check_output "A[foo (bar)] breaks the parser" 'Parse error' bash -c "$(declare -f mmd); W=$W; MERMAID_CLI_IMAGE=$MERMAID_CLI_IMAGE; mmd 'foo (bar)'; true"
check_fails 'A["foo (bar)"] does not' bash -c "$(declare -f mmd); W=$W; MERMAID_CLI_IMAGE=$MERMAID_CLI_IMAGE; mmd '\"foo (bar)\"' | grep -q 'Parse error'"
for l in 'foo-bar' 'foo: bar' 'foo #1'; do
  check_fails "A[$l] is fine without quotes" bash -c "$(declare -f mmd); W=$W; MERMAID_CLI_IMAGE=$MERMAID_CLI_IMAGE; mmd '$l' | grep -q 'Parse error'"
done

section "Linting"
mkdir lint && printf '# Title\n\nText under   \n---\n\n```\nno language\n```\n' >lint/x.md
out=$(docker run --rm -u "$(id -u):$(id -g)" -e npm_config_cache=/w/.npm -v "$W/lint:/w" -w /w node:24-alpine \
  npx -y "markdownlint-cli@$MARKDOWNLINT_CLI_VERSION" '**/*.md' 2>&1 || true)
assert_match "markdownlint flags trailing spaces" 'MD009' "$out"
assert_match "a fence with no language" 'MD040' "$out"
assert_match "and the setext heading made by --- under text, next to ATX ones" 'MD003' "$out"
