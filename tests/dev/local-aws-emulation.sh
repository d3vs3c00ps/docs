#!/usr/bin/env bash
# note: dev/local-aws-emulation.md
# env: compose
# timeout: 900
# The AWS CLI and Terraform run as pinned containers on the host network, so
# `localhost:4566` is the emulator, as in the note. The LocalStack licence change and
# the IAM caveats are not tested.
source "$NOTES_ROOT/tests/lib/assert.sh"
source "$NOTES_ROOT/tests/lib/compose.sh"
source "$NOTES_ROOT/tests/versions.env"

NOTE=dev/local-aws-emulation
nb() { note_block "$NOTE" "$@"; }
ok() { "$@"; true; } # for checks on the output of a command that fails
trap 'rc=$?; docker rm -f floci >/dev/null 2>&1; _t_finish "$rc"' EXIT
docker rm -f floci >/dev/null 2>&1 || true
aws() {
  docker run --rm -i --network host -v "$PWD:/aws" \
    -e AWS_ENDPOINT_URL -e AWS_DEFAULT_REGION -e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY \
    "$AWS_CLI_IMAGE" "$@"
}
# The provider is large: cache it across runs, and retry init (downloads can break mid-way).
TF_CACHE=$NOTES_ROOT/.test-results/tf-plugin-cache && mkdir -p "$TF_CACHE"
tf() { docker run --rm --network host -v "$PWD:/w" -w /w -v "$TF_CACHE:/cache" -e TF_PLUGIN_CACHE_DIR=/cache "$TERRAFORM_IMAGE" "$@"; }
ready() { timeout 120 bash -c "$(declare -f aws); AWS_CLI_IMAGE=$AWS_CLI_IMAGE; until aws s3 ls >/dev/null 2>&1; do sleep 1; done"; }
pull "$AWS_CLI_IMAGE" "$TERRAFORM_IMAGE" floci/floci:1.5.27

section "Floci"
check "docker run starts it (from the note)" bash -ec "$(nb Floci 1)"
eval "$(nb 'Pointing tooling at it' 1)"
check "it answers S3 calls within two minutes" ready

section "The AWS CLI"
echo hello >file.txt
check "make a bucket, copy a file, list tables (from the note)" bash -ec "$(declare -f aws); AWS_CLI_IMAGE=$AWS_CLI_IMAGE; $(nb 'Pointing tooling at it' 2)"
check_output "the file is in the bucket" '^hello$' aws s3 cp s3://my-bucket/file.txt -
check_output "any credentials are accepted" 'my-bucket' env AWS_ACCESS_KEY_ID=x AWS_SECRET_ACCESS_KEY=y bash -c "$(declare -f aws); AWS_CLI_IMAGE=$AWS_CLI_IMAGE; aws s3 ls"
check_output "with no credentials at all, the CLI refuses to sign" 'Unable to locate credentials' \
  bash -c "$(declare -f aws); AWS_CLI_IMAGE=$AWS_CLI_IMAGE; unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY; aws s3 ls; true"
check_output "with no region, the CLI fails (why the CI job sets one)" 'region' \
  bash -c "$(declare -f aws); AWS_CLI_IMAGE=$AWS_CLI_IMAGE; unset AWS_DEFAULT_REGION; aws dynamodb list-tables; true"

section "Terraform"
mkdir tf && cd tf
{ cat <<'EOF'
terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = "6.74.0" }
  }
}
resource "aws_s3_bucket" "b" { bucket = "tf-bucket" }
EOF
  nb Terraform 1; } >main.tf
check "terraform init" retry 3 tf init -input=false -no-color
check "terraform apply with the note's provider block" tf apply -auto-approve -input=false -no-color
cd ..
check_output "the bucket Terraform made is in the emulator" 'tf-bucket' aws s3 ls
mkdir tf-bad && sed 's/skip_requesting_account_id  = true/skip_requester_charged      = true/' tf/main.tf >tf-bad/main.tf
cd tf-bad
retry 3 tf init -input=false -no-color >/dev/null
check_output "skip_requester_charged is not a provider argument" 'skip_requester_charged' \
  ok tf validate -no-color
cd ..

section "Compose and CI"
docker rm -f floci >/dev/null
nb Floci 2 >compose.yml
check "the compose file with tag and digest starts it" docker compose up -d
check "it answers" ready
docker compose down >/dev/null 2>&1
check_output "the CI job is valid YAML with a region and a bounded wait" 'us-east-1 timeout 60' \
  node -e 'const j = require(process.env.NOTES_ROOT + "/node_modules/yaml").parse(require("fs").readFileSync(0, "utf8")).jobs.test
console.log(j.env.AWS_DEFAULT_REGION, j.steps[1].run.slice(0, 10))' < <(nb 'In CI' 1)

section "With the Docker socket"
check "it starts with the socket mounted (from the note)" bash -ec "$(nb 'What it can and cannot do' 1)"
check "it answers" ready
check_output "the Lambda API answers" '"Functions"' aws lambda list-functions
