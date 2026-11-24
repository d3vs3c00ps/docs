---
title: Model landscape
description: Which models are worth running locally for coding work, how they compare, and how to pick the right file out of a quantizer repository
tags: [ai, models, llm]
type: reference
status: complete
---

# Model landscape

> [!note] Partly tested
> The repositories and the download command are checked. The 27B models are not
> downloaded or run, and the benchmark scores are the model authors' figures.

The models worth running locally for development work. All of them are available in
[[ai/quantization-glossary#gguf|GGUF]] format and run under [[ai/llama-cpp]] or
[[ai/ollama]].

For what the size labels mean, see [[ai/quantization-glossary]]. For whether your
machine can actually hold one, see [[ai/hardware-requirements]].

> [!warning] This note dates faster than anything else here
> Model releases move monthly. Treat the specific version numbers below as a
> snapshot, and check what is currently on HuggingFace before downloading. The
> *reasoning* — dense versus MoE, which quantization, how to size it — stays valid
> far longer than the model names do.

## Qwen 3.8 — announced, not yet downloadable

Alibaba launched **Qwen 3.8-Max** on 3 August 2026: a 2.4-trillion-parameter sparse
MoE with roughly 95B active per token, a ~983K token context window, and API access
only. A smaller open-weight **Qwen3.8-27B** was promised within about a week of
launch.

> [!important] Check before you plan around it
> As of mid-August 2026 the open-weight 27B has **not** appeared on HuggingFace, no
> licence has been named, and no new date has been given. Until it lands, the
> recommendations below remain the practical choice for local work. When it does
> land, expect it to displace Qwen 3.6-27B as the default coding model.

## Qwen 3.6 — the current local default

Optimised for agentic coding, and the strongest practical choice for local Go and
Python work today.

### Qwen 3.6-27B (dense)

The standout for local coding.

- **Architecture** — dense; all 27B parameters activate per token
- **Notable** — outperforms the much larger 397B MoE flagship on agentic coding
  benchmarks
- **Thinking preservation** — retains reasoning context across conversation turns
- **Hybrid attention** — GatedDeltaNet linear attention combined with traditional
  self-attention, for better long-context behaviour
- **Tool calling** — strong, and reliable with Zed's function-calling schema
- **Best for** — architecture decisions, complex refactoring, multi-file edits, review

### Qwen 3.6-35B-A3B (sparse MoE)

- **Architecture** — [[ai/quantization-glossary#mixture-of-experts-moe|MoE]]: 35B
  total, only 3B active per token
- **Speed** — very fast, because so little activates
- **Trade-off** — weaker than the dense 27B on complex reasoning
- **Best for** — quick completions, boilerplate, simple refactors

## Qwen 3.5

The previous generation, still excellent and available in more sizes.

| Variant | Notes |
| --- | --- |
| **3.5-397B-A17B** | Flagship MoE, 397B total / 17B active. Needs ~200 GB even at Q4 — not practical locally without a multi-GPU server. Listed for context; cloud APIs offer it. |
| **3.5-27B** (dense) | 201 languages, Gated Delta Networks. Slightly weaker than 3.6-27B on coding, still very capable. Good general-purpose and multilingual choice. |
| **3.5-9B** (dense) | The sweet spot for limited VRAM — fits an 8 GB GPU at Q4_K_M. Noticeably weaker on complex reasoning. Good for unit tests, docstrings, simple completions. |
| **3.5-4B** (dense) | ~3 GB at Q4_K_M, runs acceptably on CPU. Limited reasoning; fine for formatting, boilerplate and documentation drafts. |
| **3.5-2B / 0.8B** | Too small for meaningful code generation. Autocomplete-style suggestions or experimentation on minimal hardware. |

## Qwopus — Claude-like reasoning locally

[Qwopus](https://huggingface.co/Jackrong) is a community fine-tune distilling Claude
Opus 4.6 reasoning into Qwen models.

It uses **knowledge distillation**: the smaller model studies the reasoning outputs of
the larger one and learns to reproduce its structured, step-by-step thinking. The v3
release uses "structural alignment", training the model to reason faithfully rather
than to imitate surface patterns.

### Qwopus-27B

- **Base** — Qwen 3.5-27B
- **HumanEval** — 95.73%
- **Format** — GGUF on HuggingFace; search for "Jackrong Qwopus"
- **Use it for** — Claude-like chain-of-thought on architecture decisions, hard
  debugging, code review

```bash
# List the exact filenames in the repo first — they change between uploads
python3 -c "from huggingface_hub import list_repo_files; [print(f) for f in list_repo_files('Jackrong/Qwopus3.5-27B-v3-GGUF')]"

hf download Jackrong/Qwopus3.5-27B-v3-GGUF <filename>.gguf --local-dir ~/models
llama-server -m ~/models/<filename>.gguf --host 127.0.0.1 --port 8080 -ngl 99 -c 32768
```

> [!note] `hf`, not `huggingface-cli`
> huggingface_hub 1.x removed `huggingface-cli`. Older guides use it; the same
> arguments work with `hf download`.

For Ollama, see [[ai/ollama]] on loading custom GGUF files through a Modelfile.

### Qwopus-GLM-18B (frankenmerge)

- **Experimental** — merges Qwopus reasoning with GLM structure
- **Size** — 9.2 GB at Q4_K_M, against 22 GB for the 35B model it outperforms
- **Use it when** — the 27B is too large for your hardware but you still want strong
  reasoning

> [!note] Community fine-tunes come with no guarantees
> Benchmark figures quoted by merge authors are self-reported and rarely
> independently reproduced. Qwopus is genuinely good, but treat "95.73% HumanEval"
> as a claim rather than a measurement, and evaluate on your own code.

## Comparison

| Model | Type | Active | Disk (Q4_K_M) | RAM needed | Coding | Tool calling | Best for |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Qwen 3.6-27B | Dense | 27B | ~16 GB | 18–20 GB | Excellent | Strong | Primary coding model |
| Qwen 3.6-35B-A3B | MoE | 3B | ~20 GB | 22–24 GB | Good | Moderate | Fast completions |
| Qwen 3.5-27B | Dense | 27B | ~16 GB | 18–20 GB | Very good | Strong | General purpose |
| Qwen 3.5-9B | Dense | 9B | ~6 GB | 8 GB | Good | Weak | Small GPU, focused tasks |
| Qwen 3.5-4B | Dense | 4B | ~3 GB | 4 GB | Basic | Unreliable | Laptop, boilerplate |
| Qwopus-27B | Dense | 27B | ~16 GB | 18–20 GB | Excellent | Strong | Deep reasoning |
| Qwopus-GLM-18B | Merged | 18B | ~9.2 GB | 12 GB | Very good | Moderate | Constrained hardware |

A workable three-model setup:

- **Primary** — Qwen 3.6-27B at Q4_K_M, or `UD-Q4_K_XL` from Unsloth, for daily work
- **Secondary** — Qwen 3.5-9B at Q4_K_M for fast, simple tasks and
  [[ai/parallel-agents|parallel agent threads]]
- **Specialty** — Qwopus-27B for deep reasoning on architecture or debugging

## Picking the right file from a quantizer repo

A repo like [`unsloth/Qwen3.6-35B-A3B-GGUF`](https://huggingface.co/unsloth/Qwen3.6-35B-A3B-GGUF)
ships many different `.gguf` files (28 in November 2026). The naming looks intimidating but follows a
consistent pattern — see [[ai/quantization-glossary#reading-a-quantization-label]].

| You see | What it means | Pick it when |
| --- | --- | --- |
| `Q4_K_M.gguf` | Standard 4-bit K-quant, medium | Default if no `UD-` variant exists |
| `UD-Q4_K_M.gguf` | Unsloth Dynamic, same size | Always prefer over plain `Q4_K_M` |
| `UD-Q4_K_XL.gguf` | Unsloth Dynamic, conservative | Best Q4 quality. ~10% larger, noticeably better output |
| `UD-Q5_K_XL.gguf` | Unsloth Dynamic Q5 | When you can spare ~25% more disk and RAM over Q4 |
| `Q8_0.gguf` | Near-lossless 8-bit | When memory is not a constraint |
| `MXFP4_MOE.gguf` | 4-bit FP format for MoE | Smaller than Q4_K_M on MoE, similar quality |
| `IQ4_XS.gguf`, `IQ3_M.gguf` | Importance-matrix quants | When Q4_K_M does not fit — better than K-quants below Q4 |
| `IQ1_M.gguf`, `IQ2_XXS.gguf` | Extreme compression | Last resort; quality is poor for coding |
| `mmproj-F16.gguf` | Vision encoder | Only for vision-language work, used **alongside** the main file |
| `BF16/*.gguf` | Unquantized 16-bit | Reference quality, ~2× Q8. Almost never right locally |

### Order of preference on a 24 GB GPU

1. `UD-Q4_K_XL` if the repo has it
2. `Q4_K_M` otherwise
3. `UD-Q5_K_M` or `Q5_K_M` if the Q4 file is comfortably under ~14 GB
4. `IQ4_XS` if `Q4_K_M` would not fit

## Where to go next

- [[ai/hardware-requirements]] — whether your machine can run any of this
- [[ai/quantization-glossary]] — decoding the filenames in full
- [[ai/llama-cpp]] — actually running the thing

## Sources

- [Qwen 3.8-Max specs and access](https://www.yottalabs.ai/post/qwen-3-8-max-release-date-specs-how-to-access-2026)
- [Qwen 3.8 Max and 27B open-weights coverage](https://www.latent.space/p/ainews-qwen-38-max24t-and-27b-new)

<!-- uplink -->
Part of [[ai/index|Local LLMs]].
