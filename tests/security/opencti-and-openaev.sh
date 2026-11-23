#!/usr/bin/env bash
# note: security/opencti-and-openaev.md
# env: leap
source "$NOTES_ROOT/tests/lib/assert.sh"

NOTE=security/opencti-and-openaev
COMPOSE=v5.7.0
block() { note_block "$NOTE" "$@"; }
case $(uname -m) in x86_64) a=x86_64 ;; aarch64) a=aarch64 ;; esac
# The stack wants about 16 GB of RAM: it is not started. docker compose config checks
# the files and the .env without a Docker daemon.
mkdir -p /usr/local/lib/docker/cli-plugins
curl -fsSL --retry 5 -o /usr/local/lib/docker/cli-plugins/docker-compose \
  "https://github.com/docker/compose/releases/download/$COMPOSE/docker-compose-linux-$a"
chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
docker() { [[ $1 == compose ]] && shift && /usr/local/lib/docker/cli-plugins/docker-compose "$@"; }
export -f docker
cd "$(mktemp -d)"

section "Running them"
check "clone xtm-docker and copy the sample (from the note)" bash -ec "$(block 'Running them' 1)"
cd xtm-docker
gen=$(block 'Running them' 2 | sed 's/^docker compose up -d$/docker compose config -q/')
out=$(bash -ec "$gen" 2>&1) && rc=0 || rc=$?
assert_eq "the secret generation and docker compose config pass (from the note)" 0 "$rc"
assert_no_match "what is left with changeme is SMTP and IMAP only" '^[0-9]+:(MINIO|RABBITMQ|POSTGRES|OPENSEARCH|OPENCTI|OPENAEV|XTM_ONE|PLATFORM)' "$out"
# shellcheck disable=SC1091
set -a && source .env && set +a
uuid='^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
for k in OPENCTI_ADMIN_TOKEN OPENCTI_HEALTHCHECK_ACCESS_KEY OPENAEV_ADMIN_TOKEN OPENAEV_HEALTHCHECK_KEY; do
  assert_match "$k is a UUIDv4" "$uuid" "${!k}"
done
assert_eq "OPENCTI_ENCRYPTION_KEY is 32 bytes of base64" 32 "$(printf %s "$OPENCTI_ENCRYPTION_KEY" | base64 -d | wc -c)"
assert_eq "every generated password differs" 11 "$(printf '%s\n' "$MINIO_ROOT_PASSWORD" "$RABBITMQ_DEFAULT_PASS" "$POSTGRES_PASSWORD" \
  "$OPENSEARCH_ADMIN_PASSWORD" "$OPENCTI_ADMIN_PASSWORD" "$OPENAEV_ADMIN_PASSWORD" "$XTM_ONE_ADMIN_PASSWORD" \
  "$XTM_ONE_POSTGRES_PASSWORD" "$XTM_ONE_SECRET_KEY" "$PLATFORM_REGISTRATION_TOKEN" "$OPENAEV_ADMIN_ENCRYPTION_SALT" | sort -u | wc -l)"

section "The old command (the correction)"
cp .env.sample old.env
sed -i "s/ChangeMe/$(openssl rand -hex 16)/g" old.env
check_output "it leaves the lowercase OpenCTI admin password at changeme" '^OPENCTI_ADMIN_PASSWORD=changeme$' cat old.env
check_output "and the admin token is not a UUID" '^OPENCTI_ADMIN_TOKEN=[0-9a-f]{32}_UUIDv4$' cat old.env
check_output "and the OpenAEV token stays all zeros" '^OPENAEV_ADMIN_TOKEN=0{8}-' cat old.env

section "Stack contents"
services=$(docker compose config --services)
for s in opencti openaev elasticsearch redis rabbitmq pgsql minio; do
  assert_match "the stack runs $s" "$s" "$services"
done
skip "docker compose up -d" "the stack needs about 16 GB of RAM, more than a shared test host should give"
