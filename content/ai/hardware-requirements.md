---
title: Hardware requirements
description: Sizing a local model to your machine — the memory rule of thumb, GPU versus CPU, partial offload, and the KV-cache trap on Apple Silicon
tags: [ai, hardware, llm, performance]
type: reference
status: complete
---

# Hardware requirements

> [!note] Not tested locally
> Sizing advice for GPUs, Apple Silicon and RAM. It needs the hardware it describes;
> the llama-server flags are tested in [[ai/llama-cpp]].

Which [[ai/models|model]] and [[ai/quantization-glossary|quantization]] your hardware
can actually run. The binding constraint is almost always **memory** — GPU VRAM, or
system RAM.

## The rule of thumb

For Q4_K_M:

> **RAM or VRAM needed ≈ (parameters in billions × 0.5) + 2 GB**

The 2 GB covers the KV cache, which scales with context length, plus the runtime and
CUDA or Vulkan buffers.

Adjust the multiplier for other quantizations:

| Quantization | Multiplier |
| --- | --- |
| `Q8_0` | params × 1.0 + 2 GB |
| `Q5_K_M` | params × 0.65 + 2 GB |
| `Q4_K_M` | params × 0.5 + 2 GB |
| `Q3_K_M` | params × 0.4 + 2 GB |

## Sizing table

| Model | Quantization | Model file | Total needed | Fits on |
| --- | --- | --- | --- | --- |
| Qwen 3.6-27B | Q4_K_M | ~16 GB | ~18 GB | 24 GB GPU, or 32 GB system RAM |
| Qwen 3.6-27B | Q5_K_M | ~20 GB | ~22 GB | 24 GB GPU (tight), or 32 GB RAM |
| Qwen 3.6-27B | Q8_0 | ~29 GB | ~31 GB | 2× 24 GB GPUs, or 48 GB+ RAM |
| Qwen 3.5-27B | Q4_K_M | ~16 GB | ~18 GB | as 3.6-27B |
| Qwen 3.5-9B | Q4_K_M | ~6 GB | ~8 GB | 8 GB GPU, or 16 GB RAM |
| Qwen 3.5-9B | Q8_0 | ~10 GB | ~12 GB | 12 GB GPU, or 16 GB RAM |
| Qwen 3.5-4B | Q4_K_M | ~3 GB | ~4 GB | any modern GPU, or 8 GB RAM |
| Qwopus-27B | Q4_K_M | ~16 GB | ~18 GB | as Qwen 27B |
| Qwopus-GLM-18B | Q4_K_M | ~9.2 GB | ~12 GB | 12 GB GPU, or 16 GB RAM |
| Qwen 3.6-35B-A3B (MoE) | Q4_K_M | ~20 GB | ~22 GB | 24 GB GPU, or 32 GB RAM |

These assume a 4K–8K context. For 32K, add 2–4 GB.

## GPU versus CPU

### GPU

- **5–20× faster** than CPU
- **Required** for responsive editor use with 27B-class models
- Expect 10–30 tokens/second on a 27B Q4_K_M with a modern GPU

| Platform | Backend | Build flag | Notes |
| --- | --- | --- | --- |
| NVIDIA | CUDA | `-DGGML_CUDA=ON` | Best performance. Needs the CUDA toolkit. |
| AMD | Vulkan | `-DGGML_VULKAN=ON` | Cross-platform, good performance. |
| Intel | Vulkan | `-DGGML_VULKAN=ON` | Works, slower than NVIDIA or AMD. |
| macOS | Metal | automatic | No flag needed. M-series is very capable. |

### CPU

Viable below about 9B parameters. On a 27B expect 2–8 tokens/second, which is too
slow to work with interactively but fine for batch or offline tasks. It scales with
core count — set threads with `-t`.

### Partial offload

When a model does not fit entirely in VRAM, split it across GPU and CPU:

```bash
llama-server -m model.gguf -ngl 24 -c 8192
```

`-ngl` sets how many transformer layers go to the GPU; the rest run on CPU.

Finding the split:

1. Start at `-ngl 99` — everything on GPU.
2. On an out-of-memory error, drop by 5–10 and retry.
3. More layers on GPU means faster inference.
4. Even 50% offload is far quicker than pure CPU.

## Configurations by machine

### Workstation — 24 GB GPU, 64 GB RAM

Runs anything comfortably.

| Use | Model | Quant | Flags |
| --- | --- | --- | --- |
| Daily coding | Qwen 3.6-27B | Q4_K_M | `-ngl 99 -c 32768` |
| Deep reasoning | Qwopus-27B | Q4_K_M | `-ngl 99 -c 32768` |
| Fast tasks | Qwen 3.5-9B | Q5_K_M | `-ngl 99 -c 16384` |

### Mid-range — 12 GB GPU, 32 GB RAM

| Use | Model | Quant | Flags |
| --- | --- | --- | --- |
| Daily coding | Qwopus-GLM-18B | Q4_K_M | `-ngl 99 -c 16384` |
| Alternative | Qwen 3.6-27B | Q4_K_M | `-ngl 24 -c 8192` (partial offload) |
| Fast tasks | Qwen 3.5-9B | Q4_K_M | `-ngl 99 -c 16384` |

### Laptop — 6 GB GPU

The 6 GB limit is the hard case. VRAM must hold the model layers **and** the KV cache
**and** the compute buffers — these are separate allocations, so fitting the layers is
not enough.

| Use | Model | Quant | Flags | Notes |
| --- | --- | --- | --- | --- |
| Best quality | Qwen 3.6-27B | Q4_K_M | `-ngl 10 -c 4096 --no-kv-offload` | 10 layers on GPU (~2.5 GB), rest on CPU. ~2.5 tok/s |
| **Recommended** | Qwen 3.5-9B | Q4_K_M | `-ngl 99 -c 16384` | Fits entirely in 6 GB. ~15–25 tok/s |
| Fast | Qwen 3.5-4B | Q5_K_M | `-ngl 99 -c 8192` | ~40 tok/s. Good for parallel agent threads |

> [!tip] `--no-kv-offload` on small GPUs
> Forces the KV cache into CPU RAM instead of VRAM. Essential on 6 GB cards running
> large models with partial offload — without it, context creation fails with
> `failed to allocate compute buffers`.

> [!warning] 27B on 6 GB is not worth it
> With only 10 layers on GPU you get about 2.5 tok/s, so a 300-token answer takes one
> to two minutes. **Qwen 3.5-9B fits fully in 6 GB** at 15–25 tok/s and is the
> practical daily driver on such a laptop. Keep the 27B for occasional deep reasoning
> where quality genuinely outweighs speed.

### Laptop — 8 GB GPU

| Use | Model | Quant | Flags |
| --- | --- | --- | --- |
| Coding | Qwen 3.5-9B | Q4_K_M | `-ngl 99 -c 8192` |
| Lightweight | Qwen 3.5-4B | Q5_K_M | `-ngl 99 -c 8192` |

### Apple Silicon

Unified memory means CPU and GPU share one pool, so the model file size dominates and
there is no VRAM/RAM split to manage. Always run `-ngl 99` so every layer uses Metal.
Size the model to leave roughly 8–10 GB free for macOS and everything else.

| Unified memory | Use | Model | Quant | Flags |
| --- | --- | --- | --- | --- |
| 16 GB | Daily coding | Qwen 3.5-9B | Q5_K_M | `-ngl 99 -c 8192 --parallel 1` |
| 16 GB | Stretch | Qwen 3.6-27B | Q4_K_M | `-ngl 99 -c 8192 --parallel 1` (tight) |
| 18–24 GB | Daily coding | Qwen 3.6-27B | Q4_K_M | `-ngl 99 -c 16384 --parallel 1` |
| 32 GB | Daily coding | Qwen 3.6-27B | Q4_K_M | `-ngl 99 -c 16384 --parallel 1` |
| 36 GB | Daily coding | Qwen 3.6-27B | Q4_K_M | `-ngl 99 -c 16384 --parallel 1` |
| 36 GB | Long context | Qwen 3.6-27B | Q4_K_M | `-ngl 99 -c 32768 --parallel 1` |
| 48 GB+ | Max quality | Qwen 3.6-27B | Q8_0 | `-ngl 99 -c 32768 --parallel 1` |

#### The KV cache trap

> [!danger] Always set `-c` and `--parallel` explicitly on Apple Silicon
> llama.cpp auto-computes context and parallel slots from available RAM. On a 36 GB
> Mac with a 27B Q4_K_M it will happily choose something like `n_parallel = 4` and
> `n_ctx_seq = 161792` per slot — four times 161K tokens of KV cache **on top of** the
> 17 GB model. That exceeds physical memory, macOS swaps 15+ GB to disk, memory
> pressure goes critical and generation crawls.

```bash
# Start here — model (~17 GB) + KV cache (~4 GB) ≈ 21 GB, no swap
llama-server -m model.gguf -ngl 99 -c 16384 --parallel 1

# Step up only if you need very large files in context (~25 GB total)
llama-server -m model.gguf -ngl 99 -c 32768 --parallel 1
```

If you genuinely need concurrent slots for
[[ai/parallel-agents|parallel agent threads]], budget roughly 4 GB per extra slot at
16K context. Two slots costs about 8 GB, still safe on 36 GB.

#### A starting point for a 36 GB Mac

Start with **Qwen 3.6-27B at Q4_K_M** — prefer `UD-Q4_K_XL` from Unsloth if the repo
has it, otherwise `Q4_K_M`. See
[[ai/models#picking-the-right-file-from-a-quantizer-repo]].

- **Capability** — the dense 27B is the strongest local coding model, with reliable
  tool calling for [[ai/zed-local-llm|Zed]].
- **Fit** — ~17 GB model plus ~4 GB KV cache at 16K context is about 21 GB. Comfortable
  in 36 GB with no swap.
- **Why start at Q4** — it is faster and leaves the most memory for context and other
  applications. Step up to Q5_K_M (~22 GB) once Q4 is proven. Avoid Q8_0 (~29 GB):
  with a 16K cache you would be at ~33 GB and crowding the OS.

Pair it with **Qwen 3.5-9B** at Q5_K_M as a fast secondary, and optionally
**Qwopus-27B** at Q4_K_M — same footprint — for hard debugging and architecture work.

### Why unified memory changes things

On M-series Macs the CPU and GPU share one pool, so:

- A 32 GB Mac loads a 27B Q4_K_M entirely "on GPU" via Metal
- No partial offload is needed — the whole model is in the shared pool
- Metal performance is competitive with mid-range discrete GPUs
- 16 GB Macs handle 9B comfortably, or 27B at Q4_K_M with tight margins

llama.cpp detects Metal automatically; no build flags required.

## Monitoring

### Linux

```bash
nvidia-smi                  # NVIDIA GPU memory
vulkaninfo | grep -i memory # AMD/Intel via Vulkan
free -h                     # system RAM
watch -n 1 nvidia-smi       # during inference
```

### macOS

```bash
sudo memory_pressure
```

Or Activity Monitor's Memory tab.

When `llama-server` starts, its log prints how many layers were offloaded and how
much memory each component took. Read it to confirm the model fits before blaming
anything else.

## Where to go next

- [[ai/models]] — which model to pick once you know what fits
- [[ai/quantization-glossary]] — what the quantization labels mean
- [[ai/llama-cpp]] — building and running the server

If the machine doing the inference is not the machine you are sitting at:

- [[containers/podman]] and [[containers/docker]] — running the server in a
  container. A GPU is not namespaced: the device node and the driver have to be
  passed in explicitly, and the driver version inside the image must match the host
  kernel module
- advanced — VFIO passthrough of a whole GPU to a VM, which
  is the alternative when you want isolation a container cannot give you. Note the
  numbers on this page still apply: passthrough does not reduce what the model needs,
  it only changes who owns the card
- [[kubernetes/mlops/index]] — the same engines under a scheduler, with the
  device-plugin machinery that makes a GPU a schedulable resource

<!-- uplink -->
Part of [[ai/index|Local LLMs]].
