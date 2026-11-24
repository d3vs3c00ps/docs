#!/usr/bin/env bash
# note: ai/prompt-optimization.md
# env: go
# timeout: 600
# Only the install command runs. The prompting advice is about model behaviour and is
# not tested.
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/versions.env"

NOTE=ai/prompt-optimization
DEBIAN_FRONTEND=noninteractive apt-get -qq update >/dev/null && apt-get -qq install -y xz-utils >/dev/null
arch=$(uname -m); arch=${arch/x86_64/x64}; arch=${arch/aarch64/arm64}
curl -sfL "https://nodejs.org/dist/$NODEJS_VERSION/node-$NODEJS_VERSION-linux-$arch.tar.xz" | tar xJ -C /opt
export PATH=/opt/node-$NODEJS_VERSION-linux-$arch/bin:$PATH
mkdir -p /work/po && cd /work/po && git init -q
cmd=$(note_block "$NOTE" 'prompt-master' 1 | sed "s/npx skills /npx -y skills@$SKILLS_CLI_VERSION /")

section "prompt-master"
check_output "without a terminal it asks which agent, and installs nothing (the tip)" 'SKILLS_PROMPT_REQUIRES_TTY|Nothing was installed' \
  bash -c "timeout 180 $cmd </dev/null 2>&1; true"
check "with --agent and -y it installs (from the note)" bash -c "timeout 180 $cmd --agent claude-code -y </dev/null >/tmp/skills.log 2>&1"
check_output "  the skill's SKILL.md is in the project" 'SKILL\.md$' bash -c 'find /work/po -name SKILL.md -path "*prompt-master*"'

skip "the prompt patterns and the skill's output" "model behaviour, not a command"
