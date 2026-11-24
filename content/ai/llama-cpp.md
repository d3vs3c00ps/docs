---
title: llama.cpp
description: Building and running the primary local inference engine — GPU backends, llama-server, sampling parameters, systemd, and downloading GGUF models
tags: [ai, llm, inference, llama-cpp]
type: howto
status: complete
---

# llama.cpp

> [!note] Partly tested
> Tested on Fedora 44, CPU only, by building build `b12647` with the Fedora, OpenBLAS
> and Vulkan lines and running a 135M model. CUDA, Metal, the macOS and Arch lines,
> GPU speed and `-ngl` offload are not tested: there was no GPU.

[llama.cpp](https://github.com/ggml-org/llama.cpp) is the primary inference engine
for running GGUF models locally. It gives you a CLI for quick testing and an
OpenAI-compatible HTTP server that [[ai/zed-local-llm|Zed]] and most other tools can
talk to directly.

See [[ai/ollama]] for the simpler alternative that trades control for convenience.

## Building from source

All platforms need a C/C++ compiler, CMake 3.14 or newer, and Git.

### Fedora

```bash
sudo dnf install cmake gcc-c++ git openssl-devel
git clone https://github.com/ggml-org/llama.cpp
cd llama.cpp
cmake -B build
cmake --build build --config Release -j$(nproc)
```

Binaries land in `build/bin/`. The two you will use are `llama-server` and
`llama-cli`.

#### OpenBLAS CPU acceleration

Worth enabling even when you also have a GPU, since it speeds up whatever layers end
up on CPU:

```bash
sudo dnf install openblas-devel
cmake -B build -DGGML_BLAS=ON -DGGML_BLAS_VENDOR=OpenBLAS
cmake --build build --config Release -j$(nproc)
```

> [!warning] Run `cmake -B build` from the repository root
> It must run in the directory containing `CMakeLists.txt`. If you `cd build` first
> and then run `cmake -B build`, CMake looks for `CMakeLists.txt` in the current
> directory and fails with *"does not appear to contain CMakeLists.txt"*. To
> reconfigure cleanly:
>
> ```bash
> cd ~/path/to/llama.cpp && rm -rf build && cmake -B build ...
> ```

### Arch Linux

The AUR has ready-made packages:

```bash
yay -S llama.cpp          # CPU only
yay -S llama.cpp-vulkan   # with Vulkan GPU support
```

Or build from source as above, substituting
`pacman -S cmake gcc git openssl`.

### macOS

[Homebrew](https://formulae.brew.sh/formula/llama.cpp) is the easiest path — a
prebuilt bottle, Metal enabled by default, binaries on your PATH:

```bash
brew install llama.cpp
brew upgrade llama.cpp    # later
```

Metal acceleration needs no flags. M-series chips benefit from unified memory — see
[[ai/hardware-requirements]].

Build from source only if you need something newer than the current bottle, or
custom flags:

```bash
xcode-select --install
brew install cmake
git clone https://github.com/ggml-org/llama.cpp
cd llama.cpp
cmake -B build
cmake --build build --config Release -j$(sysctl -n hw.ncpu)
```

Metal remains the default for source builds too.

## GPU acceleration

GPU inference is 5–20× faster than CPU and effectively required for interactive use
above 9B parameters.

### CUDA (NVIDIA)

```bash
cmake -B build -DGGML_CUDA=ON
cmake --build build --config Release -j$(nproc)
```

> [!warning] Fedora 43+ ships GCC 15, which CUDA 12.x rejects
> The build fails with `gcc versions later than 14 are not supported`. CUDA does not
> yet support GCC 15. Use **Vulkan** instead — it performs within 5–10% of CUDA for
> inference and has no compiler version restriction.

### Vulkan (AMD, Intel, and NVIDIA)

Works with any GPU that has a Vulkan driver, and is the recommended backend on
Fedora 43+ for the reason above.

```bash
# Fedora — four packages, all required
sudo dnf install vulkan-headers vulkan-loader-devel glslc spirv-headers-devel

# Arch
sudo pacman -S vulkan-headers vulkan-icd-loader glslang spirv-headers

cmake -B build -DGGML_BLAS=ON -DGGML_BLAS_VENDOR=OpenBLAS -DGGML_VULKAN=ON
cmake --build build --config Release -j$(nproc)
```

> [!tip] `spirv-headers-devel` is easy to miss on Fedora
> `vulkan-headers`, `vulkan-loader-devel` and `glslc` alone are not enough. In
> current builds the `cmake -B build ... -DGGML_VULKAN=ON` step already fails and
> names SPIR-V. Older builds got to about 41% and died with
> `fatal error: spirv/unified1/spirv.hpp: No such file or directory`. After
> installing it, reconfigure from a clean `build` directory.

### Metal (macOS)

Automatic. It is the default GPU backend on macOS builds.

### Partial offload

When the model does not fit entirely in VRAM:

```bash
llama-server -m model.gguf -ngl 30
```

`-ngl` sets how many transformer layers go to the GPU. Start high, reduce on
out-of-memory. `-ngl 0` is pure CPU. See [[ai/hardware-requirements]] for finding the
split.

## llama-server

The OpenAI-compatible API at `/v1/chat/completions` is what editors connect to.

```bash
llama-server \
  -m /path/to/model.gguf \
  --host 127.0.0.1 \
  --port 8080 \
  -ngl 99 \
  -c 16384 \
  --parallel 1
```

| Flag | Purpose |
| --- | --- |
| `-m` | Path to the GGUF file |
| `--host` | Bind address. `127.0.0.1` for local only, `0.0.0.0` to expose on the network |
| `--port` | HTTP port. The default is 9931 in current builds, so pass `--port 8080` as above |
| `-ngl` | Layers offloaded to GPU — `99` means all that fit |
| `-c` | Context window in tokens. **Always set explicitly**. A value above the model's training context is capped to it |
| `--parallel` | Concurrent request slots. **Set to `1`** for single-user editor work |
| `-t` | CPU threads, default auto |
| `--chat-template` | Override the template, normally auto-detected from the model |
| `--mmproj` | Multimodal projector, for vision-language models |
| `--no-kv-offload` | Keep the KV cache in CPU RAM rather than VRAM |

> [!danger] Always set `-c` and `--parallel` explicitly
> Left to itself, llama.cpp sizes the context and the number of slots from available
> RAM, and each extra slot multiplies the KV cache by `-c` tokens. On a 36 GB machine
> this can allocate tens of gigabytes of cache and drive the system into swap. The
> full explanation is in [[ai/hardware-requirements]].

> [!note] `--host 0.0.0.0` publishes an unauthenticated API
> `llama-server` has no authentication by default. Binding it to all interfaces
> exposes model inference — and whatever is in its context — to anyone who can reach
> the port. Keep it on `127.0.0.1` unless you have deliberately put a reverse proxy
> with authentication in front.

### Sampling parameters

Sampling controls **how** the next token is chosen from the probability
distribution. The defaults are general-purpose; for code you almost always want lower
temperature.

```bash
llama-server -m model.gguf -ngl 99 -c 32768 \
  --temp 0.2 \
  --top-p 0.9 \
  --top-k 40 \
  --min-p 0.05 \
  --repeat-penalty 1.05
```

| Flag | Default | For code | What it does |
| --- | --- | --- | --- |
| `--temp` | 0.8 | **0.1–0.3** | Scales the distribution. Lower is more deterministic and hallucinates fewer APIs. `0.0` is greedy. |
| `--top-p` | 0.95 | **0.9** | Nucleus sampling — only tokens whose cumulative probability reaches `top_p`. `1.0` disables it. |
| `--top-k` | 40 | **40** | Only the top K tokens. A hard ceiling on randomness. `0` disables it. |
| `--min-p` | 0.05 | **0.05** | Drops tokens below `min_p × top_token_prob`. Adapts to the model's confidence — a better modern alternative to top-k. |
| `--repeat-penalty` | 1.0 | **1.05–1.1** | Penalises recently seen tokens. Above ~1.3 the model starts avoiding necessary repetition such as loop variables and function names. |
| `--repeat-last-n` | 64 | 64 | How far back the repeat penalty looks |
| `--presence-penalty` | 0.0 | 0.0 | Flat penalty for any token already seen |
| `--frequency-penalty` | 0.0 | 0.0 | Penalty proportional to occurrence count |

Presets:

```bash
# Deterministic code generation
--temp 0.1 --top-p 0.95 --top-k 40 --repeat-penalty 1.05

# Balanced coding
--temp 0.3 --top-p 0.9 --top-k 40 --repeat-penalty 1.05

# Creative writing and brainstorming
--temp 0.8 --top-p 0.95 --top-k 50 --repeat-penalty 1.1
```

> [!important] Thinking models want a *higher* temperature
> For models with a thinking mode, use `--temp 0.6 --top-p 0.95`, per Qwen's own
> recommendation. Pushing the temperature down to 0.1 as you would for a standard
> coding model measurably degrades reasoning quality — the chain of thought needs
> some exploration to be useful.

### Verifying it works

```bash
curl http://localhost:8080/v1/models
```

Then a completion:

```bash
curl http://localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "any",
    "messages": [{"role": "user", "content": "Hello, what model are you?"}]
  }'
```

### Running under systemd

```ini
# ~/.config/systemd/user/llama-server.service
[Unit]
Description=llama.cpp inference server
After=network.target

[Service]
# Required for a user-local install via cmake --install --prefix ~/.local:
# systemd starts with a clean environment and will not find ~/.local/lib64.
Environment="LD_LIBRARY_PATH=%h/.local/lib64"
ExecStart=%h/.local/bin/llama-server \
    -m %h/models/model.gguf \
    --host 127.0.0.1 \
    --port 8080 \
    -ngl 99 \
    -c 32768 \
    --temp 0.6 \
    --top-p 0.95 \
    --repeat-penalty 1.05
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
```

> [!tip] `%h` beats hardcoding the home directory
> systemd expands `%h` to the user's home, so the same unit file works for any user
> and can be checked into a dotfiles repository unchanged.

> [!warning] `LD_LIBRARY_PATH` is mandatory for `~/.local` installs
> Without it the service fails immediately with
> `error while loading shared libraries: libllama-common.so.0`.

```bash
systemctl --user daemon-reload
systemctl --user enable --now llama-server
journalctl --user -u llama-server -f
```

See [[linux/boot/systemd]] for unit file mechanics generally.

## llama-cli

For quick interactive testing without a server:

```bash
llama-cli -m /path/to/model.gguf -ngl 99 -c 4096 \
  -p "Write a Go function that reverses a string"
```

`llama-cli` always runs as a chat: after the `-p` prompt it waits for the next turn.
Add `-st` (`--single-turn`) to answer once and exit:

```bash
llama-cli -m /path/to/model.gguf -ngl 99 -c 4096 -st \
  -p "Write a Go function that reverses a string"
```

> [!warning] Correction: `-cnv` is not a `llama-cli` option any more
> The original used `llama-cli ... -cnv` for conversation mode. Conversation is now
> the only `llama-cli` mode, and `-cnv` / `-no-cnv` moved to the `llama-completion`
> tool.

## Downloading models

Models must be **GGUF**. Raw `safetensors` or PyTorch weights are the training
format, three to four times larger, and llama.cpp cannot read them.

```bash
pip install huggingface-hub
```

```bash
# Q4_K_M — recommended starting point, ~17 GB
hf download unsloth/Qwen3.6-27B-GGUF Qwen3.6-27B-Q4_K_M.gguf --local-dir ~/models

# Q5_K_M — better quality, ~20 GB
hf download unsloth/Qwen3.6-27B-GGUF Qwen3.6-27B-Q5_K_M.gguf --local-dir ~/models
```

> [!warning] Correction: the command is `hf`
> The original used `huggingface-cli download`. huggingface_hub 1.x removed
> `huggingface-cli`; the same arguments work with `hf download`.

See [[ai/quantization-glossary]] and [[ai/hardware-requirements]] to pick the variant.

> [!tip] Two repository traps
> **Gated repos** — some repositories require a HuggingFace login and terms
> acceptance before download. Community repos such as `unsloth/` are public. (The
> original said the official `Qwen/…-GGUF` repositories are gated; `Qwen/Qwen3-8B-GGUF`
> is not. Check the model page, or `HfApi().model_info(repo).gated`.)
>
> **safetensors repos** — a repository *without* `-GGUF` in the name holds raw
> PyTorch weights, often ~58 GB across 15 files, which llama.cpp cannot use. Always
> pick the `-GGUF` repository and a single `.gguf` file.

List what a repository actually offers before downloading:

```bash
python3 -c "
from huggingface_hub import list_repo_files
for f in list_repo_files('unsloth/Qwen3.6-27B-GGUF'):
    print(f)
"
```

Manually: the model page on HuggingFace, "Files and versions". Trusted quantizers are
`unsloth`, `bartowski` and `lmstudio-community`.

## Installing the binaries

### User-local, no sudo

```bash
cmake --install build --prefix ~/.local
```

Binaries go to `~/.local/bin/`, shared libraries to `~/.local/lib64/`, headers to
`~/.local/include/`.

`~/.local/bin` is on the PATH by default on Fedora. Check:

```bash
which llama-server
```

If not, add to `~/.zshrc` or `~/.bashrc`:

```bash
export PATH="$HOME/.local/bin:$PATH"
```

### System-wide

```bash
sudo cmake --install build --prefix /usr/local
```

### Verify

```bash
llama-server --version
llama-cli --version
```

Re-run the same install command after every rebuild — `cmake --install` is idempotent
and only updates what changed.

## Updating

```bash
cd llama.cpp
git pull
cmake -B build    # same flags as your original configure
cmake --build build --config Release -j$(nproc)
```

On Homebrew installs, `brew upgrade llama.cpp` instead.

The project moves fast; check the
[release notes](https://github.com/ggml-org/llama.cpp/releases) for breaking changes
before updating.

## Multi-token prediction

Some models are trained with **multi-token prediction** (MTP) heads — extra output
layers that guess the next few tokens rather than one. llama.cpp can use them as a
built-in speculative decoding draft, so the main model verifies several tokens per
forward pass instead of generating them one at a time.

Where a model supports it, this is close to free throughput: the output is
*identical*, because the main model still verifies every token — only rejected
guesses cost anything.

The gain depends on how predictable the text is. Code, with its repetitive structure
and boilerplate, benefits considerably more than prose, and acceptance rates on
well-structured source can be high enough to make a noticeable difference to
interactive editing.

Support and flag names are still moving. Check `llama-server --help | grep -i -e draft
-e spec` on your build rather than copying flags from a blog post, and confirm the
GGUF actually carries MTP weights — most do not, and the flags then do nothing.

Background: [Multi-token prediction in llama.cpp](https://johnpaulwile.substack.com/p/multi-token-prediction-mtp-in-llamacpp).

## Where to go next

- [[ai/llama-swap]] — running several models behind one endpoint
- [[ai/zed-local-llm]] — connecting the editor
- [[ai/open-webui]] — a chat interface in front of this server
- [[ai/hardware-requirements]] — sizing `-ngl` and `-c` for your machine

<!-- uplink -->
Part of [[ai/index|Local LLMs]].
