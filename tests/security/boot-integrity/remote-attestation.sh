#!/usr/bin/env bash
# note: security/boot-integrity/remote-attestation.md
# env: rocky
source "$NOTES_ROOT/tests/lib/assert.sh"

NOTE=security/boot-integrity/remote-attestation
dnf -y -q install swtpm swtpm-tools tpm2-tools tpm2-abrmd dbus-daemon openssl >/dev/null 2>&1

# A software TPM behind a resource manager; nothing touches the host's TPM or kernel.
mkdir -p /tmp/tpmstate
swtpm socket --tpm2 --tpmstate dir=/tmp/tpmstate --server type=tcp,port=2321 \
  --ctrl type=tcp,port=2322 --flags not-need-init,startup-clear --daemon
DBUS_SESSION_BUS_ADDRESS=$(dbus-daemon --session --fork --print-address)
export DBUS_SESSION_BUS_ADDRESS
tpm2-abrmd --session --tcti=swtpm:port=2321 --allow-root 2>/dev/null &
export TPM2TOOLS_TCTI=tabrmd:bus_type=session
retry 10 tpm2_getcap properties-fixed
cd "$(mktemp -d)"

section "The mechanism"
# The quote flow from the note's diagram, done by hand with tpm2-tools.
tpm2_createek -c ek.ctx -G rsa -u ek.pub >/dev/null
check "an Attestation Key is created under the EK" \
  tpm2_createak -C ek.ctx -c ak.ctx -G rsa -g sha256 -s rsassa -u ak.pub -f pem -n ak.name
check_output "the AK is a restricted signing key: it signs only TPM-made data" 'restricted' \
  bash -c 'tpm2_readpublic -c ak.ctx | grep attributes -A1'
nonce=$(openssl rand -hex 16)
check "the agent quotes PCRs 0, 7 and 10 with the verifier's nonce" \
  tpm2_quote -c ak.ctx -l sha256:0,7,10 -q "$nonce" -m quote.msg -s quote.sig -o quote.pcrs -g sha256
cp ak.pub /tmp/ak.pub
quote() { tpm2_checkquote -u /tmp/ak.pub -m quote.msg -s quote.sig -f quote.pcrs -g sha256 -q "$1"; }
check "the verifier checks the signature and the nonce" quote "$nonce"
check_fails "the same quote fails for another nonce: no replay (as the note says)" quote "$(openssl rand -hex 16)"
cp quote.pcrs good.pcrs
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out fake.key
openssl pkey -in fake.key -pubout -out /tmp/fake.pub
openssl dgst -sha256 -sign fake.key -out fake.sig quote.msg
check_fails "a quote signed outside the TPM, with another key, fails against the known AK" \
  tpm2_checkquote -u /tmp/ak.pub -m quote.msg -s fake.sig -f quote.pcrs -g sha256 -q "$nonce"
# A restricted key may sign outside data, but never data that starts with
# TPM_GENERATED_VALUE (0xff "TCG"), the marker every quote carries.
check_fails "the TPM refuses to sign forged quote data with the AK" \
  bash -c 'cat quote.msg >forged && tpm2_sign -c ak.ctx -g sha256 -o s.sig forged'
tpm2_pcrextend "10:sha256=$(printf evil | sha256sum | cut -d' ' -f1)"
nonce2=$(openssl rand -hex 16)
tpm2_quote -c ak.ctx -l sha256:0,7,10 -q "$nonce2" -m q2.msg -s q2.sig -o q2.pcrs -g sha256 >/dev/null
check_fails "after PCR 10 moves, the new quote's PCR values differ" cmp -s good.pcrs q2.pcrs
check_fails "the old signed quote does not match the new PCR values: an agent cannot lie about them" \
  tpm2_checkquote -u /tmp/ak.pub -m quote.msg -s quote.sig -f q2.pcrs -g sha256 -q "$nonce"
check "the new quote verifies with its own values and nonce" \
  tpm2_checkquote -u /tmp/ak.pub -m q2.msg -s q2.sig -f q2.pcrs -g sha256 -q "$nonce2"

section "From boot to runtime: IMA"
if [[ -r /sys/kernel/security/ima/ascii_runtime_measurements ]]; then
  check_output "the IMA runtime log (from the note)" 'ima' bash -c "$(note_block "$NOTE" 'From boot to runtime' 1)"
else
  skip "ls and cat of /sys/kernel/security/ima" "the container shares the Docker VM's kernel, which shows no IMA log here"
fi
skip "the ima_policy, ima_appraise and ima_template boot parameters" \
  "kernel command line: needs a VM; checked against the kernel's kernel-parameters.txt and ima_policy.c instead"

section "Keylime"
dnf -y -q install keylime-verifier keylime-registrar keylime-tenant keylime-agent-rust >/dev/null 2>&1
for b in keylime_registrar keylime_verifier keylime_agent keylime_tenant; do
  check "Rocky 10 packages $b (the table's components)" command -v "$b"
done
check_output "the tenant is the CLI for enrolling nodes" 'usage|Usage' bash -c 'keylime_tenant --help 2>&1 | head -5'
skip "a full Keylime enrolment and key release" \
  "needs the registrar, verifier and agent with TLS and an EK certificate chain; the quote mechanism is checked above"
