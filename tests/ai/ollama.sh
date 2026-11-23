#!/usr/bin/env bash
# note: ai/ollama.md
# env: fedora-systemd
# timeout: 1500
# Installs Ollama with the note's script (pinned version) and runs the 135M model from
# a GGUF file; the note's 27B models are only checked to exist in the library.
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/versions.env"

NOTE=ai/ollama
mkdir -p /work/ol && cd /work/ol
MODEL=/work/ol/tiny.gguf
curl -sfL -o "$MODEL" "https://huggingface.co/$TINY_GGUF_REPO/resolve/$TINY_GGUF_REVISION/$TINY_GGUF_FILE"
src() { curl -sf "https://raw.githubusercontent.com/ollama/ollama/v$OLLAMA_VERSION/$1"; }
up() { for _ in $(seq 60); do curl -sf http://127.0.0.1:11434/api/version >/dev/null && return 0; sleep 1; done; return 1; }

section "Installation"
install_line=$(note_block "$NOTE" Installation 1 | grep -m1 'install.sh')
check "the install script, read first, then run (pinned to $OLLAMA_VERSION)" \
  bash -c "curl -fsSL https://ollama.com/install.sh -o install.sh && grep -q 'systemctl' install.sh && OLLAMA_VERSION=$OLLAMA_VERSION sh install.sh >/tmp/install.log 2>&1"
check_output "  the note's line is that script piped to sh" 'curl -fsSL https://ollama.com/install.sh \| sh' echo "$install_line"
check_output "ollama --version is the pinned one" "$OLLAMA_VERSION" bash -c 'ollama --version 2>&1'
check "the Linux installer sets up a systemd service (the note)" systemctl is-enabled -q ollama
check "  and it is running" up
check_output "the Fedora COPR ferdnyc/ollama (from the note)" 'ferdnyc|ollama|Enabling|enabled' \
  bash -c "dnf -y copr enable ferdnyc/ollama 2>&1 | tail -3; true"

section "Basic usage"
check_output "the service listens on 127.0.0.1:11434 (the note)" '127\.0\.0\.1:11434' bash -c 'ss -ltn | grep 11434'
for m in qwen3.6:27b qwen3.5:27b qwen3.5:9b qwen3.5:4b; do
  check_output "$m exists in the Ollama library (the note's list)" '^200$' \
    curl -s -o /dev/null -w '%{http_code}' -H 'Accept: application/vnd.docker.distribution.manifest.v2+json' \
    "https://registry.ollama.ai/v2/library/${m%%:*}/manifests/${m##*:}"
done

section "Loading a custom GGUF"
note_block "$NOTE" 'custom GGUF' 1 | sed "s|/path/to/your-model.gguf|$MODEL|; s/num_ctx 32768/num_ctx 4096/" >Modelfile.custom
# The 135M model can ramble for minutes: cap its answer so ollama run returns.
echo 'PARAMETER num_predict 32' >>Modelfile.custom
check_output "ollama create from a GGUF file (from the note)" 'success' bash -c "$(note_block "$NOTE" 'custom GGUF' 2 | sed -n 1p) 2>&1"
check_output "ollama list shows it (from the note)" '^my-custom-model' ollama list
check_output "ollama run answers (from the note, one prompt)" '.' bash -c 'timeout 120 ollama run my-custom-model "Say hi" 2>/dev/null'
check_output "  the Modelfile's num_ctx is kept" 'num_ctx +4096' ollama show my-custom-model --parameters

section "Modelfiles"
note_block "$NOTE" Modelfiles 1 | sed "s|^FROM qwen3.6:27b|FROM $MODEL|; s/num_ctx 32768/num_ctx 4096/" >Modelfile.golang
check_output "ollama create go-assistant -f Modelfile.golang (from the note, tiny model)" 'success' \
  bash -c "$(note_block "$NOTE" Modelfiles 2 | sed -n 1p) 2>&1"
params=$(ollama show go-assistant --parameters)
assert_match "  temperature 0.3 is set" 'temperature +0\.3' "$params"
assert_match "  top_p 0.9 is set" 'top_p +0\.9' "$params"
check_output "  the SYSTEM prompt is set" 'senior Go developer' ollama show go-assistant --system
types=$(src api/types.go)
assert_match "default temperature is 0.8 (the table)" 'Temperature: +0\.8,' "$types"
assert_match "default top_p is 0.9 (the table)" 'TopP: +0\.9,' "$types"
assert_match "default repeat_penalty is 1.0, not 1.1 (the correction)" 'RepeatPenalty: +1\.0,' "$types"
cfg=$(src envconfig/config.go)
assert_match "the default context is 4k/32k/256k by VRAM, not 2048 (the correction)" 'default: 4k/32k/256k based on VRAM' "$cfg"
printf 'FROM %s\n' "$MODEL" >Modelfile.plain && ollama create plain -f Modelfile.plain >/dev/null 2>&1
curl -s localhost:11434/api/generate -d '{"model":"plain","prompt":"hi","stream":false,"options":{"num_predict":1}}' >/dev/null
check_output "  here, on CPU, a model with no num_ctx runs with 4096" '"context_length": *4096' \
  bash -c 'curl -s localhost:11434/api/ps'
curl -s localhost:11434/api/generate -d '{"model":"plain","prompt":"hi","stream":false,"options":{"num_predict":1,"num_ctx":8192}}' >/dev/null
check_output "num_ctx can be set per request, in options (the correction)" '"context_length": *8192' \
  bash -c 'curl -s localhost:11434/api/ps'

section "API"
api=$(note_block "$NOTE" API 1)
check_output "GET /api/tags lists the models (from the note)" '"name": *"go-assistant' bash -c "$(grep '/api/tags' <<<"$api") -s"
chat=$(sed -n '/# Native API/,/^}'"'"'/p' <<<"$api" | sed '1d; s/qwen3.6:27b/plain/; s/^curl /curl -s /')
check_output "POST /api/chat (from the note)" '"role": *"assistant"' bash -c "$chat"
oai=$(sed -n '/# OpenAI-compatible/,/^}'"'"'/p' <<<"$api" | sed '1d; s/qwen3.6:27b/plain/; s/^curl /curl -s /')
check_output "POST /v1/chat/completions, the OpenAI-compatible one (from the note)" '"object": *"chat.completion"' bash -c "$oai"
check_output "there is no authentication (the warning)" '"models"' curl -s http://127.0.0.1:11434/api/tags

section "Environment variables"
assert_match "OLLAMA_NUM_PARALLEL defaults to 1 (the table)" 'Uint\("OLLAMA_NUM_PARALLEL", 1\)' "$cfg"
assert_match "OLLAMA_MAX_LOADED_MODELS defaults to 0, meaning automatic, not 1 (the correction)" 'Uint\("OLLAMA_MAX_LOADED_MODELS", 0\)' "$cfg"
check_output "  and 0 means 3 per GPU, at least 3 (the table)" 'defaultModelsPerGPU \* max\(len\(g(pus)?\), 1\)' bash -c 'curl -sf "https://raw.githubusercontent.com/ollama/ollama/v'$OLLAMA_VERSION'/server/sched.go"'
check_output "  defaultModelsPerGPU is 3" 'var defaultModelsPerGPU = 3' bash -c 'curl -sf "https://raw.githubusercontent.com/ollama/ollama/v'$OLLAMA_VERSION'/server/sched.go"'
check_output "the service stores models in /usr/share/ollama/.ollama/models: the ollama user's ~ (the table)" 'blobs' \
  ls /usr/share/ollama/.ollama/models
note_block "$NOTE" 'Environment variables' 2 >/tmp/override.conf
check "systemctl edit ollama, with the note's override (fed on stdin)" bash -c 'systemctl edit --stdin ollama </tmp/override.conf'
systemctl restart ollama && up
check_output "  OLLAMA_HOST=0.0.0.0 now binds all interfaces" '(0\.0\.0\.0|\*):11434' bash -c 'ss -ltn | grep 11434'
check_output "  OLLAMA_NUM_PARALLEL=2 reaches the server" 'OLLAMA_NUM_PARALLEL:2' bash -c 'journalctl -u ollama --no-pager | grep -o "OLLAMA_NUM_PARALLEL:[0-9]*" | tail -1'

skip "yay, brew" "Arch and macOS: the env is Fedora"
