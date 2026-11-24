---
title: BDD with pytest
description: Turning Gherkin scenarios into pytest tests — the two-layer strategy, scenario outlines as parametrize, and going from bug report to permanent guardrail
tags: [dev, testing, bdd, gherkin, python, pytest]
type: howto
status: complete
---

# BDD with pytest

Behaviour Driven Development is a collaborative approach to building a shared
understanding of how software should behave, from the user's point of view. This note
is about the **implementation half**: turning agreed Gherkin scenarios into real
`pytest` tests without adopting a new framework first.

For the Gherkin language itself and a worked Ansible/Molecule example, see
[[dev/gherkin]]. The two are complementary — that one covers infrastructure testing,
this one application code in Python.

## The problems it addresses

Familiar situations, all symptoms of a gap between business intent and technical
implementation rather than individual failings:

- **"It's not what I asked for."** A feature is specified, built, and does not match
  the need.
- **The estimation black hole.** Vague requirements hide complexity until mid-sprint.
- **Fear of refactoring.** A brittle codebase where a small change breaks something
  unrelated.
- **Documentation that lies.** Docs disconnected from the code, and therefore
  perpetually out of date.

> [!note] The core idea
> Use one common language to bridge the gap, so that feature requirements *are* the
> blueprint for the tests.

## What BDD is, and is not

**It is a conversation.** It brings together the "three amigos" — product,
development and testing — to agree the desired behaviour of a feature *before*
implementation starts.

**It is not a tool.** Tools help, but the goal is shared understanding. You can start
today with what you already have.

**It is not dogma.** It is a pragmatic way to reduce ambiguity. Adapt it.

## From conversation to blueprint

### Step 1 — the happy path

Start with the core value. Write one simple, successful scenario in a `.feature`
file. This is really just writing acceptance criteria for the MVP: once they pass,
you can ship.

```gherkin
# features/enrichment.feature

Feature: Registry connector — package enrichment
  As a maintainer,
  I want to enrich a package record with its download count
  So that I can see which dependencies are widely used.

  Scenario: Successfully enrich a known package
    Given a package record for "requests" exists in the catalogue
      And the registry has a report for "requests" with 5000 downloads
    When the connector runs for enrichment
    Then the package "requests" should be updated with 5000 downloads
      And the package "requests" should be tagged with "enriched"
```

### Step 2 — the unhappy paths

Ask "what if…?" to surface hidden requirements. Each answer becomes another
scenario.

```gherkin
  Scenario: Attempt to enrich an unknown package
    Given a package record for "not-a-real-package" exists in the catalogue
    When the connector runs for enrichment
    Then the connector should log an error for "not-a-real-package"
      And no enrichment call to the registry should be made
```

This step is where BDD earns its keep. The unhappy paths are the requirements nobody
wrote down, and discovering them in a conversation is far cheaper than discovering
them in production.

### Step 3 — scale with scenario outlines

For many inputs against the same behaviour, use a template plus a table:

```gherkin
  Scenario Outline: Enrich different package types
    Given a package record for "<name>" exists in the catalogue
      And the registry has a report for "<name>" with <downloads> downloads
    When the connector runs for enrichment
    Then the package "<name>" should be updated with <downloads> downloads
      And the package "<name>" should be tagged with "enriched"

    Examples:
      | name         | downloads |
      | requests     | 5000      |
      | urllib3      | 9200      |
      | tiny-helper  | 45        |
```

You now have a human-readable blueprint covering the happy path, the edge cases and
multiple data points.

## Two layers of test

The Gherkin gives you the *what*. For the *how*, think in two layers.

**Layer 1 — the scenario.** A Gherkin `Scenario` describes end-to-end observable
behaviour, so a test implementing a full scenario is a high-level **integration
test**. Its job is proving the pieces are wired together correctly.

**Layer 2 — the chunk.** An end-to-end scenario is usually too large to implement in
one go, so break it into logical **chunks** — a function, a method. Build each with
the ordinary cycle:

1. **Red** — write a small, focused unit test for one piece and watch it fail.
2. **Green** — write the minimum code to pass it.
3. **Refactor** — clean up, protected by the passing test.

Build the components in isolation, then write the scenario test that wires them
together.

## Mapping to pytest

| Gherkin | pytest |
| --- | --- |
| `Scenario` | A high-level `test_...()` function |
| A chunk of logic | A low-level `test_...()` function |
| `Given` / `When` / `Then` | Helper functions `_given_…`, `_when_…`, `_then_…` |
| `Scenario Outline` | `@pytest.mark.parametrize` |

The chunk the scenario relies on is a plain function, built first with its own unit
tests:

```python
# connector.py
def enrich(catalogue, registry, names):
    """Copy each package's download count from the registry, and tag it."""
    for name in names:
        record = catalogue[name]
        record["downloads"] = registry[name]["downloads"]
        record["tags"].append("enriched")
```

A scenario outline becomes:

```python
# tests/test_enrichment_feature.py
import pytest

from connector import enrich


@pytest.mark.parametrize(
    "package_name, downloads",
    [
        ("requests", 5000),
        ("urllib3", 9200),
        ("tiny-helper", 45),
    ],
)
def test_enrich_different_package_types(package_name, downloads):
    # GIVEN a package record exists
    context = _given_a_package_record_exists(package_name)
    # AND the registry has a report
    context = _given_a_registry_report_exists(
        context, for_package=package_name, with_downloads=downloads
    )

    # WHEN the connector runs for enrichment
    # This calls the main entry point, which uses the smaller chunk
    # functions built underneath.
    context = _when_the_connector_runs_for_enrichment(context)

    # THEN the package should be updated
    _then_the_package_downloads_are(
        context, package=package_name, expected=downloads
    )
    # AND tagged
    _then_the_package_is_tagged(
        context, package=package_name, expected_tag="enriched"
    )


# --- Helpers implementing the Gherkin steps ---


def _given_a_package_record_exists(package_name):
    """Set up state, mocks, or test database entries."""
    return {
        "catalogue": {package_name: {"downloads": None, "tags": []}},
        "packages_to_process": [package_name],
    }


def _given_a_registry_report_exists(context, for_package, with_downloads):
    context["registry"] = {for_package: {"downloads": with_downloads}}
    return context


def _when_the_connector_runs_for_enrichment(context):
    enrich(context["catalogue"], context["registry"], context["packages_to_process"])
    return context


def _then_the_package_downloads_are(context, package, expected):
    assert context["catalogue"][package]["downloads"] == expected


def _then_the_package_is_tagged(context, package, expected_tag):
    assert expected_tag in context["catalogue"][package]["tags"]
```

Keeping the steps as named helpers is what makes the test read like the scenario. The
moment you inline the setup, the correspondence between the `.feature` file and the
test is lost — which is the whole point.

### Ordering tests to mirror the pipeline

For complex features, [`pytest-order`](https://pypi.org/project/pytest-order/)
creates a predictable execution order that follows the application's stages, making
failures much easier to localise.

Assign numeric orders by scope:

- `order(0)` — setup and configuration
- `order(10)` — fetchers and API calls
- `order(20)` — data mapping and processing
- `order(30)` — serialisation

```python
# tests/test_fetch_package.py
import pytest


@pytest.mark.order(10)
def test_fetch_package_from_registry():
    ...


# tests/test_process_package.py
import pytest


@pytest.mark.order(20)
def test_process_package():
    ...
```

If an `order(10)` test fails you know where the problem is before the full scenario
even runs.

> [!warning] Order-dependent tests are a trade-off
> Ordering makes output readable, but it is a short step from *ordering* tests to
> tests that *depend* on each other's state — at which point they cannot run in
> isolation, cannot be parallelised with `pytest-xdist`, and a single early failure
> cascades. Use ordering for legibility, and keep every test independently runnable.

## From bug report to guardrail

The same workflow fixes bugs. A vague ticket — "the connector crashes on some API
responses" — becomes a precise, failing scenario:

```gherkin
  Scenario: Handle a malformed API response with no download count
    Given a package record for "tiny-helper" exists in the catalogue
      And the registry returns a malformed report missing the 'downloads' field
    When the connector runs for enrichment
    Then the connector should log a warning about the malformed report
      And the package should not be updated
```

That scenario is a failing test replicating the bug exactly. The job is to make it
pass. Afterwards it stays as a permanent guardrail against regression.

This is the cheapest possible upgrade to a bug-fixing process: the reproduction you
had to write anyway becomes a test you keep.

## Why it is worth the effort

**For product owners** — the `.feature` file is a concrete, plain-English agreement
on what will be built and tested. Discussing scenarios surfaces complexity early, so
estimates improve. Bug reports become clear scenarios.

**For developers** — chunks give a clear implementation to-do list; two layers of
test give confidence from the ground up; a failing scenario is an unambiguous bug
report; and a comprehensive suite makes refactoring safe.

**For the team** — a shared language reduces friction between roles, and
conversations stay anchored to behaviour and outcomes.

## Levelling up with pytest-bdd

Once the flow is comfortable,
[`pytest-bdd`](https://pytest-bdd.readthedocs.io/) parses the `.feature` file
directly to drive the tests.

The real benefit is **living documentation**: the `.feature` file cannot go stale,
because if its text stops matching a step definition in the code, the tests fail.
That is the strongest available guarantee that specification and implementation
agree.

## How to start

You do not need a new library tomorrow — start with the process.

1. **Start small.** Pick one feature, or one bug.
2. **Get the three amigos together** to write the scenarios in a `.feature` file.
3. **Break it down** into logical chunks.
4. **Implement in two layers** — chunk tests to build the logic, then a scenario test
   for the end-to-end behaviour.
5. **Review and iterate.** Once the flow feels natural, have the conversation about
   adopting `pytest-bdd`.

The goal is incremental improvement, not a methodology rollout.

## Where to go next

- [[dev/gherkin]] — the Gherkin language, and BDD applied to Ansible roles
- [[dev/python]] — the language these tests are written in

<!-- uplink -->
Part of [[dev/index|Development]].
