#!/usr/bin/env bash
# note: dev/gherkin.md
# env: ansible-systemd
# timeout: 900
# Feature files go through the official Gherkin parser (the one Cucumber uses). The
# role's tasks and asserts run with ansible-playbook on a temporary directory:
# Molecule itself needs a container driver, which this env does not have.
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/versions.env"

NOTE=dev/gherkin
python3 -m venv /opt/gherkin >/dev/null
/opt/gherkin/bin/pip install -q "gherkin-official==${GHERKIN_VERSION}"
cd "$(mktemp -d)" && W=$PWD
export ANSIBLE_ROLES_PATH=$W ANSIBLE_LOCALHOST_WARNING=false ANSIBLE_INVENTORY_UNPARSED_WARNING=false
# parse: give stdin to the Gherkin parser; print OK, or ERROR and the first error line.
parse() { /opt/gherkin/bin/python -c '
import sys
from gherkin.parser import Parser
try:
    Parser().parse(sys.stdin.read()); print("OK")
except Exception as e:
    print("ERROR", str(e).splitlines()[0])'; }
# pickles: the scenarios a feature compiles to, with their steps, one per line.
pickles() { /opt/gherkin/bin/python -c '
import sys
from gherkin.parser import Parser
from gherkin.pickles.compiler import Compiler
doc = Parser().parse(sys.stdin.read()); doc["uri"] = "f"
for p in Compiler().compile(doc): print(p["name"], "|", " / ".join(s["text"] for s in p["steps"]))'; }
nb() { note_block "$NOTE" "$@"; }

section "Feature files"
check_output "the anatomy block parses" '^OK$' parse < <(nb 'Anatomy of a feature' 1)
check_output "the install_apache example parses" '^OK$' parse < <(nb 'Anatomy of a feature' 3)
check_output "the step line in the warning parses inside a scenario" '^OK$' \
  parse < <(printf 'Feature: f\n  Scenario: s\n    %s\n' "$(nb 'Anatomy of a feature' 2)")
check_output "Given: as the first line is not a step: the scenario has none" '^s \| $' \
  pickles <<<$'Feature: f\n  Scenario: s\n    Given: I am on a Linux machine with YUM'
check_output "Then: after a real step is rejected" '^ERROR' parse <<<$'Feature: f\n  Scenario: s\n    Given a\n    Then: b'
check_output "clean_repos.feature parses" '^OK$' parse < <(nb 'Feature: clean_repos' 1)
check_output "add_repos.feature parses" '^OK$' parse < <(nb 'Feature: add_repos' 1)
check_output "create_database_user.feature parses" '^OK$' parse < <(nb Constraints 1)

section "Scenarios, Background, placeholders"
check_output "a Background step runs before each scenario" '^a \| shared / own a$' \
  pickles <<<$'Feature: f\n  Background:\n    Given shared\n  Scenario: a\n    Given own a\n  Scenario: b\n    Given own b'
check_output "in a plain Scenario, <user> stays plain text" '\| I have a database server / I create <user> with <password>' \
  pickles < <(nb Constraints 1)
check_output "a Scenario Outline fills it from Examples" '\| I have a database server / I create alice with s3cret' \
  pickles < <(nb Constraints 1 | sed 's/Scenario:/Scenario Outline:/'; printf '    Examples:\n      | user  | password |\n      | alice | s3cret   |\n')

section "Constraints"
for h in Constraints 'Constraint on clean_repos'; do
  n=$([[ $h == Constraints ]] && echo 2 || echo 1)
  c=$(nb "$h" "$n")
  check_output "Constraint: is not a Gherkin keyword: a parser rejects the file ($h)" '^ERROR' parse <<<"$c"
  check_output "the same text as a Feature: parses ($h)" '^OK$' parse <<<"${c/Constraint:/Feature:}"
done

section "The role, test first"
mkdir -p yum/tasks yum/molecule/default/tests repos.d
mkrepos() { rm -rf repos.d/* repos.d/.[!.]* && touch repos.d/{base,epel,extra}.repo repos.d/.hidden; }
# verify TESTFILE [YUM_REPOS_JSON]: run a Molecule-style test file against repos.d.
verify() {
  printf -- '- hosts: localhost\n  gather_facts: false\n  vars:\n    yum_reposdir: %s\n    yum_repos: %s\n  tasks:\n    - ansible.builtin.include_tasks: %s\n' \
    "$W/repos.d" "${2:-[]}" "$1" >verify.yml
  ansible-playbook -i localhost, -c local verify.yml
}
converge() {
  printf -- '- hosts: localhost\n  gather_facts: false\n  vars:\n    yum_reposdir: %s\n    yum_repos: %s\n  roles: [yum]\n' \
    "$W/repos.d" "${1:-[]}" >converge.yml
  ansible-playbook -i localhost, -c local converge.yml "${@:2}"
}
nb "Implementing the feature's test" 1 >yum/molecule/default/tests/test_clean_repos.yml
mkrepos
check_fails "the test fails before anything is implemented" verify yum/molecule/default/tests/test_clean_repos.yml
nb 'Automating it' 1 >yum/tasks/clean_repos.yml
nb 'Automating it' 2 >yum/tasks/main.yml
check "converge runs the role" converge
check "then the test passes: hidden files went too" verify yum/molecule/default/tests/test_clean_repos.yml
mkrepos
check_output "the feature's @tag selects the tasks" 'Remove the yum repository files' converge '[]' --tags clean_repos

section "The constraint"
keep='[{name: epel}]'
nb "Implementing the constraint's test" 1 >yum/molecule/default/tests/test_clean_repos.yml
mkrepos; converge "$keep" >/dev/null
check_fails "the constraint's test catches the role that deletes everything" verify yum/molecule/default/tests/test_clean_repos.yml "$keep"
nb 'Automating the constraint' 1 >yum/tasks/clean_repos.yml
mkrepos
check "the constrained role converges" converge "$keep"
check_output "only the kept repository is left" '^epel\.repo$' ls -A repos.d
check "and the constraint's test passes" verify yum/molecule/default/tests/test_clean_repos.yml "$keep"
mkrepos; converge >/dev/null
check "with an empty yum_repos the first assert applies, and passes" verify yum/molecule/default/tests/test_clean_repos.yml
cat >wrong.yml <<EOF
- hosts: localhost
  gather_facts: false
  vars: {yum_reposdir: /etc/yum.repos.d, item: {name: epel}, __files_path: []}
  tasks:
    - ansible.builtin.set_fact:
$(nb 'Automating the constraint' 2 | sed 's/^/        /')
    - ansible.builtin.debug: {msg: "{{ __files_path | type_debug }} {{ __files_path }}"}
EOF
check_output "the quoted form gives a string, with no path separator" '"msg": "str ..\[\] \+ \[.*/etc/yum\.repos\.depel\.repo' \
  ansible-playbook -i localhost, -c local wrong.yml

section "The git workflow"
git config --global user.name 'Test User' && git config --global user.email test@example.com
git init -q --bare origin.git
mkdir -p flow && cd flow
mkdir -p documentations/{features,constraints}/{todo,wip,done} tasks
touch documentations/{features,constraints}/{todo,wip,done}/.gitkeep
check "init, first commit, develop (from the note)" bash -ec "$(nb 'Creating the role structure' 2)"
check_output "the first branch is main" '^main$' git branch --format='%(refname:short)' --list main
git remote add origin "$W/origin.git"
nb 'Feature: clean_repos' 1 >documentations/features/todo/clean_repos.feature
nb 'Feature: add_repos' 1 >documentations/features/todo/add_repos.feature
check "commit the features (from the note)" bash -ec "$(nb 'Creating the features' 1)"
check "claim clean_repos into wip (from the note)" bash -ec "$(nb 'Feature: clean_repos' 2)"
check "branch feature/clean_repos (from the note)" bash -ec "$(nb 'Feature: clean_repos' 3)"
cp "$W"/yum/tasks/main.yml tasks/ && nb 'Automating it' 1 >tasks/clean_repos.yml
check "move to done and commit (from the note)" bash -ec "$(nb 'Automating it' 3)"
check "merge, tag 0.1.0, delete the branch (from the note)" bash -ec "$(nb 'Automating it' 4)"
check_output "the feature is done on develop" 'documentations/features/done/clean_repos.feature' git ls-files
nb 'Constraint on clean_repos' 1 >documentations/constraints/todo/clean_repos.constraint
git add -A documentations/constraints && git commit -qm "constraint clean_repos"
check "claim the constraint and branch (from the note)" bash -ec "$(nb 'Constraint on clean_repos' 2)"
nb 'Automating the constraint' 1 >tasks/clean_repos.yml
check "done, merge, tag 0.2.1 (from the note)" bash -ec "$(nb 'Automating the constraint' 3)"
check "merge into main and push (from the note)" bash -ec "$(nb 'Automating the constraint' 4)"
check_output "origin has main with both tags reachable" '0\.1\.0.*0\.2\.1|0\.2\.1.*0\.1\.0' bash -c "git tag --merged origin/main | tr '\n' ' '"
