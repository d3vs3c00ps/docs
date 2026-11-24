---
title: AI-assisted scanning
description: Agentic vulnerability scanners — Vigolium and Lyrie, running them against a local model, and an honest account of what changes and what does not
tags: [security, offensive, ai, scanning, llm]
type: concept
status: complete
---

# AI-assisted scanning

A newer category: scanners that use an LLM to drive the scan rather than executing a
fixed set of checks. The claim is that an agent can discover endpoints, choose which
tests apply, generate a payload for an unusual case, and triage its own findings —
work that otherwise needs a person.

> [!warning] Only against systems you are authorised to test
> Everything in this section is active testing, and these tools generate exploitation
> attempts autonomously. An agentic scanner is *less* predictable than
> [[security/offensive/nuclei|a template-driven one]], not more — scope it tightly,
> and never point it somewhere on the assumption it will be gentle.

## Vigolium

[Vigolium](https://github.com/vigolium/vigolium) is a web vulnerability scanner with
two modes, which is the design worth noting:

| Mode | Command | Behaviour |
| --- | --- | --- |
| **Native** | `vigolium scan` | Deterministic, multi-phase. About 335 modules by the project's own count — 216 active (fuzzing), 119 passive (pattern matching) |
| **Agentic** | `vigolium agent` | An LLM discovers endpoints, selects modules, generates custom extensions, and triages findings |

MIT licence.

```bash
docker run --rm j3ssie/vigolium:v0.5.6 scan -t https://staging.example.com
```

> [!warning] Correction
> An earlier version gave the licence as AGPL-3.0, the image as `vigolium/vigolium`,
> the target as a bare argument, and about 323 modules. Checked against v0.5.6: MIT,
> `j3ssie/vigolium`, `-t URL`, and 216 + 119 modules.

> [!warning] Out-of-band checks use a public server by default
> Like [[security/offensive/nuclei|nuclei]], Vigolium registers with the public
> interactsh server `oast.pro` for its out-of-band modules (`oast.enabled = true`,
> `oast.server_url = oast.pro`). Point it at your own server, or turn it off:
>
> ```bash
> vigolium config set oast.enabled false
> ```

### Pointing it at a local model

The reason it belongs alongside these notes: the model provider is pluggable, and one
of the providers is `openai-compatible` — which is exactly what
[[ai/llama-cpp|llama-server]], [[ai/llama-swap]] and [[ai/ollama]] expose. The
endpoint lives in the `agent.olium.custom_provider` settings, which point at Ollama's
`http://localhost:11434/v1` by default:

```bash
vigolium config set agent.olium.provider openai-compatible
vigolium config set agent.olium.custom_provider.base_url http://localhost:8080/v1
vigolium config set agent.olium.custom_provider.model_id qwen-27b
```

> [!warning] Correction
> The note used `OPENAI_BASE_URL`, `OPENAI_API_KEY` and `OPENAI_MODEL` environment
> variables. Vigolium's documentation does not list them; the settings above are the
> ones `vigolium config ls` shows.

> [!important] For this use case, local inference is not a preference — it is the point
> An agentic scanner sends the target's responses to the model: URLs, parameter names,
> error messages, stack traces, sometimes response bodies. Against a hosted API, all
> of that leaves your environment and lands with a third party.
>
> For a scan of your own staging environment that may be tolerable. For anything under
> a confidentiality obligation, or a client engagement, it is not — and running the
> model on the same machine as the scanner removes the question entirely. See
> [[ai/hardware-requirements]] for what that costs.

The practical constraint is the same one in [[ai/models]]: agentic work is tool
calling, and models below roughly 27B do it unreliably. A scanner whose agent emits
malformed tool calls produces a scan that quietly does less than you think.

## Lyrie

[Lyrie](https://www.helpnetsecurity.com/2026/05/18/lyrie-ai-autonomous-pentesting-agent/)
is an open-source autonomous pentesting agent from OTT Cybersecurity, structured as a
multi-phase pipeline. The announcement says seven phases but names six:
reconnaissance, fingerprinting, scanning, exploitation, proof-of-concept generation
and reporting.

Two aspects are genuinely interesting regardless of the agent framing:

- **SARIF output**, so findings flow into GitHub Code Scanning and any other tool that
  speaks the format — which makes it pipeline-compatible in a way most pentest tooling
  is not. See [[security/devsecops-chain]].
- **Red-teaming modules aimed at LLM endpoints** — testing the models you deploy
  rather than using models to test something else. That is a real and under-served
  need if you are exposing an inference endpoint.

Its heaviest capability, gradient-based suffix attacks, is documented as requiring
H200-class GPUs, so treat the full feature set as aspirational on your own hardware.

## What actually changes

Being clear about this, because the category is heavily marketed.

**Genuinely better:**

- **Triage.** Deciding whether a finding is real is judgement work, and the thing
  humans spend most of their time on. A model that removes obvious false positives
  earns its place immediately.
- **Unusual targets.** A bespoke API with non-standard authentication defeats template
  scanners, which only know the patterns they were given. An agent can work out the
  shape.
- **Report drafting.** Turning findings into prose is real effort and a legitimate use.

**Not better, and sometimes worse:**

- **Coverage of known issues.** For a known vulnerability class, a deterministic check
  is faster, cheaper and *complete*. [[security/offensive/nuclei|nuclei]] with a
  reviewed template set beats an agent, every time, for what templates cover.
- **Reproducibility.** Two runs take different paths, so you cannot say "we tested for
  X" with confidence, and you cannot diff this week's scan against last week's. That
  is disqualifying for a compliance gate.
- **Cost and time.** Orders of magnitude more expensive per target than a pattern
  scanner.

> [!warning] "Autonomous pentesting" oversells what these do
> They automate the *scanning* phase — the part that was already automatable. The
> parts that make a penetration test valuable are chaining several minor findings into
> a real attack path, understanding business logic well enough to see that a
> permission check is missing, and knowing what matters to this organisation.
>
> Judge the output the way you would judge a scanner's: as a list of leads requiring
> verification, not as an assessment. The
> [[security/devsecops-chain#what-each-stage-genuinely-cannot-do|what each stage cannot do]]
> framing applies unchanged.

> [!danger] An agent that exploits is an agent that can break something
> Deterministic scanners are bounded by their templates, so you can read them and know
> what will be sent — which is why [[security/offensive/nuclei]] recommends reviewing
> a template set before production. An agent generating payloads has no such bound: it
> can submit forms, trigger state changes, exhaust resources, or fill a database with
> test data.
>
> Run these against staging, from a scoped network, with the blast radius understood
> in advance.

## Where this sits

A reasonable position today: deterministic tooling as the **gate**, agentic tooling as
an **exploratory supplement** on targets that defeat templates. Same placement logic
as everything else in [[security/devsecops-chain]] — the thing that blocks a pipeline
has to be predictable.

## Where to go next

- [[security/offensive/nuclei]] — the deterministic counterpart, and a CI gate
- [[ai/llama-cpp]] · [[ai/llama-swap]] — the local endpoint to point these at
- [[ai/models]] — which models handle tool calling adequately
- [[security/devsecops-chain]] — where a scan belongs in a pipeline

## Sources

- [Vigolium](https://github.com/vigolium/vigolium) — MIT
- [Help Net Security — Lyrie, an open-source autonomous pentesting agent](https://www.helpnetsecurity.com/2026/05/18/lyrie-ai-autonomous-pentesting-agent/)

<!-- uplink -->
Part of [[security/offensive/index|Offensive tooling]].
