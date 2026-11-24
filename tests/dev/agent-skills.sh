#!/usr/bin/env bash
# note: dev/agent-skills.md
# env: go
# timeout: 900
# The install commands run with the skills CLI, and every SKILL.md example is checked
# against the rules of the Agent Skills specification. Whether an agent then follows a
# skill is model behaviour, and is not tested.
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/versions.env"

NOTE=dev/agent-skills
DEBIAN_FRONTEND=noninteractive apt-get -qq update >/dev/null && apt-get -qq install -y xz-utils python3-yaml >/dev/null
arch=$(uname -m); arch=${arch/x86_64/x64}; arch=${arch/aarch64/arm64}
curl -sfL "https://nodejs.org/dist/$NODEJS_VERSION/node-$NODEJS_VERSION-linux-$arch.tar.xz" | tar xJ -C /opt
export PATH=/opt/node-$NODEJS_VERSION-linux-$arch/bin:$PATH
skills() { timeout 180 npx -y "skills@$SKILLS_CLI_VERSION" "$@" </dev/null; }
# names REPO: the skill names a repository holds, one per line.
names() { skills add "$1" --list 2>&1 | sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g' | grep -E '^│    [a-z0-9-]+$' | tr -d '│ ' || true; }

section "Installing"
mkdir -p /work/codex && cd /work/codex && git init -q
while read -r cmd; do
  check "${cmd#npx skills add } installs (from the note, with --agent codex -y)" \
    bash -c "$(declare -f skills); NODEJS_VERSION=$NODEJS_VERSION SKILLS_CLI_VERSION=$SKILLS_CLI_VERSION PATH=$PATH; skills ${cmd#npx skills } --agent codex -y >/dev/null 2>&1"
done < <(note_block "$NOTE" Installing 1)
check_output "for Codex, they land in .agents/skills/" '^frontend-design prompt-master tdd $' \
  bash -c 'ls .agents/skills | sort | tr "\n" " "'
mkdir -p /work/claude && cd /work/claude && git init -q
check "the same for Claude Code" skills add mattpocock/skills --skill tdd --agent claude-code -y
check "lands in .claude/skills/" test -f .claude/skills/tdd/SKILL.md
check_fails "the owner/repo/skill form finds no skill" skills add mattpocock/skills/tdd --agent codex -y

section "The skills the note names"
mp=$(names mattpocock/skills)
for s in tdd diagnosing-bugs improve-codebase-architecture; do assert_match "mattpocock/skills has $s" "^$s\$" "$mp"; done
assert_match "anthropics/skills has frontend-design" '^frontend-design$' "$(names anthropics/skills)"
assert_match "obra/superpowers is a collection" '^brainstorming$' "$(names obra/superpowers)"
check_output "every row of the table installs with its own command" '^ok$' bash -c '
  grep -o "npx skills add [^\`]*" "$NOTES_ROOT/content/dev/agent-skills.md" | sort -u | while read -r c; do
    [[ $c == *--skill* || $c == *prompt-master* ]] || { echo "no --skill: $c"; exit 1; }
  done; echo ok'

section "SKILL.md examples against the specification"
# spec: name 1-64 chars, [a-z0-9-], no leading, trailing or double hyphen, equal to the
# directory; description 1-1024 chars; only the spec fields.
validate() { python3 -c '
import re, sys, yaml
dirname, text = sys.argv[1], sys.stdin.read()
fm = yaml.safe_load(text.split("---")[1])
allowed = {"name", "description", "license", "compatibility", "metadata", "allowed-tools"}
n, d = fm.get("name", ""), fm.get("description", "")
errs = [k for k in fm if k not in allowed]
if not re.fullmatch(r"[a-z0-9]+(-[a-z0-9]+)*", n) or len(n) > 64: errs.append("name")
if n != dirname: errs.append("name is not the directory")
if not 0 < len(d) <= 1024: errs.append("description")
print("valid" if not errs else "invalid: " + " ".join(errs))' "$1"; }
check_output "the minimal go-service skill is valid" '^valid$' validate go-service < <(note_block "$NOTE" Structure 2)
check_output "platform-go is valid" '^valid$' validate platform-go < <(note_block "$NOTE" 'Go conventions' 1)
check_output "platform-python is valid" '^valid$' validate platform-python < <(note_block "$NOTE" 'Python conventions' 1)
check_output "a paths field is not in the specification" '^invalid: paths$' validate x <<<$'---\nname: x\ndescription: d\npaths: ["*.py"]\n---'
