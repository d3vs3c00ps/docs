#!/usr/bin/env bash
# note: ai/models.md
# env: go
# timeout: 600
# Only the repositories and the download commands are checked: the 27B files are not
# downloaded, and the benchmark scores are the model authors' claims.
source "$NOTES_ROOT/tests/lib/assert.sh"

NOTE=ai/models
export DEBIAN_FRONTEND=noninteractive
apt-get -qq update >/dev/null && apt-get -qq install -y python3-venv >/dev/null
python3 -m venv /opt/hf && export PATH=/opt/hf/bin:$PATH
pip install -q huggingface-hub
b=$(note_block "$NOTE" 'Qwopus-27B' 1)

section "Qwopus-27B"
check_output "the note's list_repo_files line lists GGUF files in Jackrong/Qwopus3.5-27B-v3-GGUF" '\.gguf$' \
  bash -c "$(grep '^python3' <<<"$b")"
check_output "huggingface-cli is gone in huggingface_hub 1.x (the correction)" 'command not found|No such file' \
  bash -c 'huggingface-cli --help 2>&1 | head -2; true'
check_output "  hf download takes the same arguments: REPO FILE --local-dir" '--local-dir' bash -c 'hf download --help 2>&1'
check_output "the old name Jackrong/Qwopus-27B-v3-GGUF does not exist (the correction)" '^(401|404)$' \
  curl -s -o /dev/null -w '%{http_code}' https://huggingface.co/api/models/Jackrong/Qwopus-27B-v3-GGUF
assert_match "  the note uses hf download" '^hf download Jackrong/Qwopus3.5-27B-v3-GGUF ' "$b"

section "Picking the right file from a quantizer repo"
n=$(python3 -c "from huggingface_hub import list_repo_files; print(sum(f.endswith('.gguf') for f in list_repo_files('unsloth/Qwen3.6-35B-A3B-GGUF')))")
check_output "unsloth/Qwen3.6-35B-A3B-GGUF ships many .gguf files (the note: 28 in November 2026): $n" '^([2-9][0-9]|1[5-9])$' echo "$n"

skip "HumanEval and other scores" "the model authors' figures; not reproducible here"
skip "llama-server on the 27B file" "needs ~17 GB of memory; llama-server itself is tested in ai/llama-cpp"
