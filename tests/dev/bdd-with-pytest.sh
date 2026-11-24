#!/usr/bin/env bash
# note: dev/bdd-with-pytest.md
# env: leap
# timeout: 600
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/versions.env"

NOTE=dev/bdd-with-pytest
python3 -m venv /opt/bdd >/dev/null
/opt/bdd/bin/pip install -q "pytest==${PYTEST_VERSION}" "pytest-order==${PYTEST_ORDER_VERSION}" \
  "pytest-bdd==${PYTEST_BDD_VERSION}" "gherkin-official==${GHERKIN_VERSION}"
export PATH=/opt/bdd/bin:$PATH
cd "$(mktemp -d)" && mkdir -p features tests
nb() { note_block "$NOTE" "$@"; }

section "The feature file"
# Steps 1 to 3 and the bug report are one file: the later blocks are scenarios to append.
{ nb 'Step 1' 1; echo; nb 'Step 2' 1; echo; nb 'Step 3' 1; echo; nb 'From bug report' 1; } >features/enrichment.feature
check_output "the four scenarios parse as one feature" '^4$' python -c '
from gherkin.parser import Parser
d = Parser().parse(open("features/enrichment.feature").read())
print(len(d["feature"]["children"]))'

section "Two layers, plain pytest"
nb 'Mapping to pytest' 1 >connector.py
nb 'Mapping to pytest' 2 >tests/test_enrichment_feature.py
check_output "the scenario outline runs as three parametrized tests" '3 passed' \
  python -m pytest -q -p no:cacheprovider --rootdir=. --import-mode=importlib -o pythonpath=. tests/test_enrichment_feature.py
sed -i 's/record\["tags"\].append("enriched")/pass/' connector.py
check_output "and fails when the chunk stops tagging" '3 failed' \
  bash -c 'python -m pytest -q -p no:cacheprovider -o pythonpath=. tests/test_enrichment_feature.py; true'
nb 'Mapping to pytest' 1 >connector.py

section "pytest-order"
mkdir order && nb 'Ordering tests' 1 | awk '/^# tests\//{f="order/" substr($2, 7)} {print > f}'
# Rename so that file order and alphabetical order disagree with the markers.
mv order/test_fetch_package.py order/test_z_fetch.py && mv order/test_process_package.py order/test_a_process.py
check_output "order(10) runs before order(20), whatever the file names" \
  'test_z_fetch.py::test_fetch_package_from_registry PASSED.*test_a_process.py::test_process_package PASSED' \
  bash -c 'python -m pytest -v -p no:cacheprovider order | tr "\n" " "'

section "pytest-bdd: the feature file drives the tests"
cat >tests/test_bdd.py <<'EOF'
from pytest_bdd import given, parsers, scenario, then, when

from connector import enrich


@scenario("../features/enrichment.feature", "Successfully enrich a known package")
def test_known_package():
    pass


@given(parsers.parse('a package record for "{name}" exists in the catalogue'), target_fixture="ctx")
def record(name):
    return {"catalogue": {name: {"downloads": None, "tags": []}}, "names": [name]}


@given(parsers.parse('the registry has a report for "{name}" with {n:d} downloads'))
def report(ctx, name, n):
    ctx["registry"] = {name: {"downloads": n}}


@when("the connector runs for enrichment")
def run(ctx):
    enrich(ctx["catalogue"], ctx["registry"], ctx["names"])


@then(parsers.parse('the package "{name}" should be updated with {n:d} downloads'))
def downloads(ctx, name, n):
    assert ctx["catalogue"][name]["downloads"] == n


@then(parsers.parse('the package "{name}" should be tagged with "{tag}"'))
def tagged(ctx, name, tag):
    assert tag in ctx["catalogue"][name]["tags"]
EOF
check_output "the scenario runs from the .feature file" '1 passed' \
  python -m pytest -q -p no:cacheprovider -o pythonpath=. tests/test_bdd.py
sed -i 's/with 5000 downloads$/with 5000 weekly downloads/' features/enrichment.feature
check_output "when the feature text stops matching a step, the test fails" 'StepDefinitionNotFoundError' \
  bash -c 'python -m pytest -q -p no:cacheprovider -o pythonpath=. tests/test_bdd.py; true'
assert_eq "the bug-report Given is the same step as in the other scenarios" 2 \
  "$({ nb 'Step 1' 1; nb 'From bug report' 1; } | grep -c 'Given a package record for "[a-z-]*" exists in the catalogue$')"
