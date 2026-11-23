#!/usr/bin/env bash
# note: ai/llama-cpp.md
# env: fedora-systemd
# timeout: 3000
# Builds llama.cpp on Fedora with the note's lines (CPU only: no GPU here), then runs
# it with a 135M model. CUDA, Metal, Arch and macOS lines are not run.
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/versions.env"

NOTE=ai/llama-cpp
cd /root
# The note's lines are for a person at a prompt: drop sudo (root here), answer yes for dnf.
nosudo() { sed 's/^sudo //; s/dnf install/dnf -y -q install/'; }
# The note's clone, pinned to a release and shallow.
pin() { sed "s|git clone https://github.com/ggml-org/llama.cpp|git clone -q --depth 1 -b $LLAMA_CPP_VERSION https://github.com/ggml-org/llama.cpp|"; }
MODEL=/root/models/$TINY_GGUF_FILE
wait_up() { for _ in $(seq 120); do curl -sf "http://127.0.0.1:${1:-8080}/health" >/dev/null && return 0; sleep 1; done; return 1; }

section "Building from source (Fedora)"
check "dnf install, clone, cmake -B build (from the note, configure only)" \
  bash -c "$(note_block "$NOTE" Fedora 1 | nosudo | pin | sed '/cmake --build/d') >/tmp/conf.log 2>&1"
check_output "cmake -B build run inside build/ fails (the warning)" 'does not appear to contain CMakeLists.txt' \
  bash -c 'cd llama.cpp/build && cmake -B build 2>&1; true'

section "Vulkan (AMD, Intel, and NVIDIA)"
vk=$(note_block "$NOTE" 'Vulkan (AMD' 1)
pkgs=$(sed -n 's/^sudo dnf install //p' <<<"$vk")
check_output "the Fedora line installs four packages, not three (the comment)" '^4$' bash -c "wc -w <<<'$pkgs'"
dnf -y -q install openblas-devel >/dev/null
check_output "without spirv-headers-devel, the Vulkan configure already fails (the tip: earlier than 41% of the build)" 'spirv|SPIRV' \
  bash -c "dnf -y -q install ${pkgs/spirv-headers-devel/} >/dev/null && cd llama.cpp && $(sed -n '/^cmake -B build/p' <<<"$vk") 2>&1 | grep -i -m3 'spirv'; true"
check "with spirv-headers-devel, a clean configure (rm -rf build, as the warning says) and the OpenBLAS + Vulkan build complete (from the note)" \
  bash -c "dnf -y -q install spirv-headers-devel >/dev/null && cd llama.cpp && rm -rf build && $(sed -n '/^cmake -B build/p' <<<"$vk") >/tmp/vk-conf.log 2>&1 && $(sed -n '/^cmake --build/p' <<<"$vk") >/tmp/build.log 2>&1 || { tail -n 30 /tmp/vk-conf.log; tail -n 30 /tmp/build.log; exit 1; }"
for b in llama-server llama-cli; do check "build/bin/$b exists (the note)" test -x llama.cpp/build/bin/$b; done
check_output "OpenBLAS is used (from the note's flags)" 'BLAS' bash -c 'grep -i "blas" /tmp/vk-conf.log | head -3'
export PATH=/root/llama.cpp/build/bin:$PATH
check_output "llama-server --version (from the note)" 'version: ' bash -c 'llama-server --version 2>&1'
check_output "llama-cli --version (from the note)" 'version: ' bash -c 'llama-cli --version 2>&1'

section "Downloading models"
check "pip install huggingface-hub (from the note)" bash -c "$(note_block "$NOTE" 'Downloading models' 1) -q"
check_output "huggingface-cli is gone in huggingface_hub 1.x: the command is hf (the correction)" \
  'command not found|deprecated|hf download|No such file' bash -c 'huggingface-cli --help 2>&1 | head -3; true'
# The note's download is 17 GB: the same command shape runs on the tiny model instead.
check "hf download REPO FILE --local-dir (the note's command, tiny model)" \
  hf download "$TINY_GGUF_REPO" "$TINY_GGUF_FILE" --revision "$TINY_GGUF_REVISION" --local-dir /root/models
check_output "list_repo_files lists the note's Q4_K_M file (from the note)" '^Qwen3\.6-27B-Q4_K_M\.gguf$' \
  bash -c "$(note_block "$NOTE" 'Downloading models' 3)"
sizes=$(python3 -c "
from huggingface_hub import HfApi
info = HfApi().model_info('unsloth/Qwen3.6-27B-GGUF', files_metadata=True)
for s in info.siblings:
    if s.rfilename in ('Qwen3.6-27B-Q4_K_M.gguf', 'Qwen3.6-27B-Q5_K_M.gguf'): print(s.rfilename, round(s.size / 1e9))")
assert_match "Q4_K_M is about 16 GB, Q5_K_M about 20 GB (the note: 17 and 20)" 'Q4_K_M.gguf 1[67].*Q5_K_M.gguf (19|20)' "$(tr -d '\n' <<<"$sizes")"
check_output "community repos (unsloth) need no login (the tip)" '^False$' \
  python3 -c "from huggingface_hub import HfApi; print(bool(HfApi().model_info('unsloth/Qwen3.6-27B-GGUF').gated))"
check_output "the official Qwen/Qwen3-8B-GGUF needs no login either (the correction)" '^False$' \
  python3 -c "from huggingface_hub import HfApi; print(bool(HfApi().model_info('Qwen/Qwen3-8B-GGUF').gated))"

section "llama-server"
help=$(llama-server --help 2>&1)
for f in -m --host --port -ngl -c --parallel -t --chat-template --mmproj --no-kv-offload; do
  assert_match "llama-server has $f (the table)" "(^|[ ,])$f([ ,=]|$)" "$help"
done
# default FLAG: the value in "(default: X" of FLAG's own entry in --help.
cat >/tmp/default.py <<'PY'
import re, sys
flag, lines = sys.argv[1], sys.stdin.read().splitlines()
for i, l in enumerate(lines):
    if re.match(r'^\s*(-[\w-]+,\s*)*' + re.escape(flag) + r'(,|\s|=|$)', l):
        m = re.search(r'default: ([^,)]+)', ' '.join(lines[i:i + 4]))
        print(m.group(1) if m else 'none'); break
PY
default() { python3 /tmp/default.py "$1" <<<"$help"; }
for d in '--temp:0.80' '--top-p:0.95' '--top-k:40' '--min-p:0.05' '--repeat-penalty:1.00' '--repeat-last-n:64' '--presence-penalty:0.00' '--frequency-penalty:0.00'; do
  check_output "default of ${d%%:*} is ${d#*:} (the table)" "^${d#*:}\$" default "${d%%:*}"
done
check_output "--port defaults to 9931, not 8080 (the correction)" '^9931$' default --port
check_output "--jinja is on by default" '^enabled$' default --jinja
check_output "multi-token prediction: --help lists draft/spec flags (the note's grep)" 'draft|spec' \
  bash -c 'llama-server --help 2>&1 | grep -i -e draft -e spec'

srv=$(note_block "$NOTE" 'llama-server' 1 | tr -d '\\\n' | sed "s|/path/to/model.gguf|$MODEL|")
bash -c "$srv" >/tmp/srv.log 2>&1 &
check "llama-server starts with the note's flags (CPU here)" wait_up
check_output "/v1/models lists the model (from the note)" '"object": *"list"' bash -c "$(note_block "$NOTE" 'Verifying it works' 1) -s"
check_output "/v1/chat/completions answers (from the note)" '"role": *"assistant"' \
  bash -c "$(note_block "$NOTE" 'Verifying it works' 2 | sed 's/^curl /curl -s /')"
props() { curl -s "localhost:$1/props" | python3 -c "import json,sys; d=json.load(sys.stdin); g=d['default_generation_settings']; p=g.get('params', g); print(d.get('total_slots'), g.get('n_ctx'), round(p['temperature'], 2), round(p['top_p'], 2), round(p['min_p'], 2))"; }
check_output "  with --parallel 1: one slot" '^1 ' props 8080
check_output "  -c 16384 is capped at the model's training context (8192 for this model)" '^1 8192 ' props 8080
check_output "  and the log says so" 'n_ctx_train|training context|capped|exceeds' bash -c "grep -i -m2 'n_ctx_train\|training context\|capp\|exceed' /tmp/srv.log"
check_output "there is no authentication by default (the note)" '"object": *"list"' curl -s http://127.0.0.1:8080/v1/models
kill %1; wait %1 2>/dev/null || true
llama-server -m "$MODEL" --port 8081 >/tmp/auto.log 2>&1 &
check "without -c and --parallel it starts too" wait_up 8081
props=$(curl -s localhost:8081/props | tr -d '\n ')
assert_match "  it picks the slots by itself (auto, more than 1)" '"total_slots":([2-9]|[1-9][0-9])' "$props"
check_output "  and the context from the model (SmolLM2: 8192 per training)" 'n_ctx_train|n_ctx' bash -c "grep -o 'n_ctx[a-z_]* *= *[0-9]*' /tmp/auto.log | head -3"
kill %1; wait %1 2>/dev/null || true
sampling=$(note_block "$NOTE" 'Sampling parameters' 1 | tr -d '\\\n' | sed "s|model.gguf|$MODEL|; s/-c 32768/-c 2048/")
bash -c "$sampling --port 8082" >/tmp/samp.log 2>&1 &
check "the sampling example starts (from the note)" wait_up 8082
check_output "  and uses temp 0.2, top-p 0.9, min-p 0.05" ' 0\.2 0\.9 0\.05$' props 8082
kill %1; wait %1 2>/dev/null || true
while read -r preset; do
  [[ $preset == --* ]] || continue
  check "preset is accepted: $preset (from the note)" bash -c "timeout 60 llama-server -m $MODEL -c 512 --port 8083 $preset >/tmp/p.log 2>&1 & for i in \$(seq 60); do curl -sf localhost:8083/health >/dev/null && kill %1 && exit 0; sleep 1; done; exit 1"
done < <(note_block "$NOTE" 'Sampling parameters' 2)

section "llama-cli"
cli=$(note_block "$NOTE" 'llama-cli' 1 | tr -d '\\\n' | sed "s|/path/to/model.gguf|$MODEL|")
cli_help=$(llama-cli --help 2>&1)
check_output "llama-cli -p with -st answers once and exits (the correction)" '[A-Za-z]{3}' bash -c "timeout 120 $cli -n 32 -st </dev/null 2>/dev/null"
assert_match "  -st, --single-turn is a llama-cli option" '-st, +--single-turn' "$cli_help"
assert_no_match "llama-cli has no -cnv any more: it always chats (the correction)" '(^|[ ,])-cnv([ ,]|$)' "$cli_help"
check_output "  -cnv moved to llama-completion" '-cnv, +--conversation' bash -c 'llama-completion --help 2>&1'

section "Installing the binaries"
check "cmake --install build --prefix ~/.local (from the note)" \
  bash -c "cd llama.cpp && $(note_block "$NOTE" 'User-local' 1) >/dev/null"
check "  binaries in ~/.local/bin" test -x /root/.local/bin/llama-server
check_output "  shared libraries in ~/.local/lib64 (Fedora)" 'libllama' ls /root/.local/lib64
check "  headers in ~/.local/include" test -f /root/.local/include/llama.h
out=$(env -i PATH=/usr/bin:/bin /root/.local/bin/llama-server --version 2>&1 || true)
check_output "without LD_LIBRARY_PATH the installed binary cannot find its libraries (the warning)" 'error while loading shared libraries: lib[a-z-]+\.so' \
  bash -c "echo '$out'"
check_output "  with LD_LIBRARY_PATH=~/.local/lib64 it runs" 'version: ' \
  bash -c 'env -i PATH=/usr/bin:/bin LD_LIBRARY_PATH=/root/.local/lib64 /root/.local/bin/llama-server --version 2>&1'
check "sudo cmake --install build --prefix /usr/local (from the note)" \
  bash -c "cd llama.cpp && $(note_block "$NOTE" 'System-wide' 1 | nosudo) >/dev/null"
check_output "  the second install is idempotent: files are Up-to-date (the note)" 'Up-to-date' \
  bash -c "cd llama.cpp && cmake --install build --prefix /usr/local"

section "Running under systemd"
useradd -m llm && install -d -o llm /home/llm/models && cp "$MODEL" /home/llm/models/model.gguf && chown llm /home/llm/models/model.gguf
cp -r /root/.local /home/llm/.local && chown -R llm /home/llm/.local
loginctl enable-linger llm
for _ in $(seq 30); do [ -S "/run/user/$(id -u llm)/bus" ] && break; sleep 1; done
mkdir -p /home/llm/.config/systemd/user
note_block "$NOTE" 'Running under systemd' 1 | sed 's/-c 32768/-c 2048/' >/home/llm/.config/systemd/user/llama-server.service
chown -R llm /home/llm/.config
uctl() { runuser -u llm -- env XDG_RUNTIME_DIR="/run/user/$(id -u llm)" "$@"; }
export -f uctl
while read -r line; do
  [[ $line == *journalctl* ]] && continue
  read -ra words <<<"$line"
  check "$line (from the note)" uctl "${words[@]}"
done < <(note_block "$NOTE" 'Running under systemd' 2)
check "the user service answers on 127.0.0.1:8080 (%h expanded to /home/llm)" wait_up 8080
check_output "journalctl --user -u llama-server shows it (from the note, without -f)" 'llama|server' \
  bash -c 'uctl journalctl --user -u llama-server --no-pager | tail -5'
uctl systemctl --user stop llama-server
sed -i '/^Environment="LD_LIBRARY_PATH/d' /home/llm/.config/systemd/user/llama-server.service
uctl systemctl --user daemon-reload; uctl systemctl --user start llama-server || true; sleep 3
check_output "without the Environment= line the service fails to load its libraries (the warning)" 'error while loading shared libraries' \
  bash -c 'uctl journalctl --user -u llama-server --no-pager | tail -20'

skip "CUDA, Metal and the macOS and Arch lines" "no NVIDIA GPU, no Mac, and the env is Fedora"
skip "GPU speed and -ngl offload" "no GPU here: -ngl has no effect on a CPU-only build"
