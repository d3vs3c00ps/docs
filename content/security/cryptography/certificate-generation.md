---
title: Running your own certificate authority
description: The two OpenSSL routes to a private CA — a one-shot signing script and a stateful openssl ca with config files, revocation and a trust-store install — plus the pitfalls that make hand-rolled certificates fail
tags: [security, tls, openssl, certificates, pki]
type: howto
status: complete
---

# Running your own certificate authority

For internal services, lab environments and mutual TLS between your own components,
a private CA is the normal answer: you control every client, so you control the trust
store, and no public CA will issue for `service-01.internal.example.com` anyway.

This note is the mechanics. For what the pieces *mean* — chain verification, the
X.509 fields, why revocation barely works — see
[[security/cryptography/pki-and-x509]].

> [!warning] This is not a production CA
> Everything below leaves the CA private key unencrypted on disk, next to the
> certificates it signs. That is fine for a lab and unacceptable for anything real,
> where the key belongs in an HSM or KMS and the root CA is kept offline behind an
> intermediate.
>
> If the certificates have to keep working without a human remembering to reissue
> them, do not use this at all — run an internal ACME CA such as `step-ca` and get
> automatic renewal. See [[security/cryptography/acme]].

## Which route

| | [Route 1](#route-1--one-certificate-no-state) — `openssl x509 -req` | [Route 2](#route-2--a-ca-you-keep) — `openssl ca` |
| --- | --- | --- |
| State kept | A `.srl` counter | Serial file **and** an index database |
| Can revoke later | No | Yes |
| Configuration | Flags plus an extensions file | A config file, mandatory |
| Good for | One certificate, now | A CA you will still be using next year |

Route 1 is a signing operation wearing a CA's hat. Route 2 is an actual certificate
authority. If you will ever need to answer "what did this CA issue?", you need
route 2 — that record is not reconstructable afterwards.

## Route 1 — one certificate, no state

A self-contained script that creates a CA and issues one SAN server certificate from
it. Nothing to configure, nothing left behind but the files.

```bash
#!/bin/bash
set -euo pipefail

usage() {
    echo "Usage: $0 [-c CA_NAME] [-s SERVER_NAME] [-o ORG_NAME] [-u OU_NAME]"
    echo "          [-l LOCATION] [-t STATE] [-n COUNTRY] [-d DAYS_VALID]"
    echo "          [-a ALT_NAMES]"
    echo "Example: $0 -c MyRootCA -s www.example.com -o 'Example Corp' \\"
    echo "            -u 'IT Department' -l London -t 'Greater London' -n GB \\"
    echo "            -d 365 -a 'DNS:example.com,DNS:*.example.com,IP:10.0.0.5'"
    exit 1
}

# Defaults
CA_NAME="RootCA"
SERVER_NAME="server.example.com"
ORG_NAME="Example Corp"
OU_NAME="IT"
LOCATION="Example City"
STATE="Example State"
COUNTRY="US"
DAYS_VALID=3650
ALT_NAMES=""

while getopts "c:s:o:u:l:t:n:d:a:h" opt; do
    case $opt in
        c) CA_NAME="$OPTARG" ;;
        s) SERVER_NAME="$OPTARG" ;;
        o) ORG_NAME="$OPTARG" ;;
        u) OU_NAME="$OPTARG" ;;
        l) LOCATION="$OPTARG" ;;
        t) STATE="$OPTARG" ;;
        n) COUNTRY="$OPTARG" ;;
        d) DAYS_VALID="$OPTARG" ;;
        a) ALT_NAMES="$OPTARG" ;;
        h) usage ;;
        \?) echo "Invalid option: -$OPTARG" >&2; usage ;;
    esac
done

# A certificate with no SAN is rejected by every modern client, so default
# the SAN to the CN when the caller did not supply one.
if [ -z "$ALT_NAMES" ]; then
    ALT_NAMES="DNS:${SERVER_NAME}"
fi

mkdir -p ca certs private csr
chmod 700 private

echo "CA:           $CA_NAME"
echo "Server:       $SERVER_NAME"
echo "SAN:          $ALT_NAMES"
echo "Organization: $ORG_NAME / $OU_NAME"
echo "Location:     $LOCATION, $STATE, $COUNTRY"
echo "Validity:     $DAYS_VALID days"

# 1. CA private key
echo "[1/6] Generating CA private key..."
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:4096 \
    -out "ca/${CA_NAME}.key"
chmod 600 "ca/${CA_NAME}.key"

# 2. Self-signed CA certificate, explicitly marked as a CA
echo "[2/6] Generating CA certificate..."
openssl req -x509 -new -nodes -key "ca/${CA_NAME}.key" -sha256 \
    -days "$DAYS_VALID" \
    -out "ca/${CA_NAME}.crt" \
    -subj "/C=$COUNTRY/ST=$STATE/L=$LOCATION/O=$ORG_NAME/OU=$OU_NAME/CN=$CA_NAME" \
    -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
    -addext "keyUsage=critical,keyCertSign,cRLSign" \
    -addext "subjectKeyIdentifier=hash"

# 3. Server private key
echo "[3/6] Generating server private key..."
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:3072 \
    -out "private/${SERVER_NAME}.key"
chmod 600 "private/${SERVER_NAME}.key"

# 4. CSR, carrying the SAN so it survives into the certificate
echo "[4/6] Generating CSR..."
openssl req -new -key "private/${SERVER_NAME}.key" \
    -out "csr/${SERVER_NAME}.csr" \
    -subj "/C=$COUNTRY/ST=$STATE/L=$LOCATION/O=$ORG_NAME/OU=$OU_NAME/CN=$SERVER_NAME" \
    -addext "subjectAltName=${ALT_NAMES}"

# 5. Extensions for the issued certificate
cat > "${SERVER_NAME}.ext" << EOF
authorityKeyIdentifier = keyid,issuer
basicConstraints       = critical,CA:FALSE
keyUsage               = critical,digitalSignature,keyEncipherment
extendedKeyUsage       = serverAuth
subjectKeyIdentifier   = hash
subjectAltName         = ${ALT_NAMES}
EOF

# 6. Sign it
echo "[5/6] Signing server certificate..."
openssl x509 -req -in "csr/${SERVER_NAME}.csr" \
    -CA "ca/${CA_NAME}.crt" -CAkey "ca/${CA_NAME}.key" \
    -CAcreateserial \
    -out "certs/${SERVER_NAME}.crt" \
    -days "$DAYS_VALID" -sha256 \
    -extfile "${SERVER_NAME}.ext"

echo "[6/6] Cleaning up..."
rm -f "${SERVER_NAME}.ext"

echo
echo "CA certificate:     ca/${CA_NAME}.crt"
echo "CA private key:     ca/${CA_NAME}.key"
echo "Server CSR:         csr/${SERVER_NAME}.csr"
echo "Server certificate: certs/${SERVER_NAME}.crt"
echo "Server private key: private/${SERVER_NAME}.key"
```

### Usage

```bash
./generate.sh -c ExampleCA -s bastion-01.example.com \
  -o 'Example Corp' -u 'Platform' \
  -l 'Example City' -t 'Example State' -n FR -d 365 \
  -a 'DNS:bastion-01.example.com,DNS:bastion.example.com,IP:10.0.0.5'
```

The `-extfile` at step 6 is what carries the SAN into the issued certificate.
By default `openssl x509 -req` **drops every CSR extension** — drop that flag and you
get a certificate no browser will accept, with no error at issuance time. OpenSSL 3
can copy them with `-copy_extensions copy`, but then the CSR decides what is
certified. Giving the extensions again with `-extfile` keeps the CA in control.

### Corrections made to the original

> [!warning] The original produced certificates no modern client accepts
> It set the identity **only in the Subject CN**, with no `subjectAltName`. Chrome
> stopped honouring the CN for hostname verification in version 58 (2017), and Go's
> TLS stack has rejected CN-only certificates outright since Go 1.15. Firefox and
> Safari behave the same way. The script above adds SAN to both the CSR and the
> issued certificate, defaulting it to the CN so it can never be forgotten.
>
> Four further fixes:
>
> - **The CA certificate did not declare itself a CA.** Without
>   `basicConstraints=CA:TRUE` and `keyUsage=keyCertSign`, strict verifiers reject
>   the chain. Added, with `pathlen:0` so it cannot issue intermediates.
> - **`extendedKeyUsage=serverAuth` was missing**, and the key usage included
>   `nonRepudiation` and `dataEncipherment`, neither of which a TLS server
>   certificate uses.
> - **The serial file was deleted** at the end (`rm ca/${CA_NAME}.srl`). Keep it:
>   it is the only record of the last serial this CA used.
> - **`genrsa` replaced with `genpkey`.** The per-algorithm commands are the
>   deprecated interface; `genpkey` is the current one and handles every algorithm.

> [!warning] Correction
> An earlier version said that deleting the `.srl` file makes the next run restart
> the numbering, so two certificates can share a serial. On OpenSSL 3 that is not
> true: when the file is missing, `-CAcreateserial` starts from a random 160-bit
> number, so a repeat is practically impossible.

## Route 2 — a CA you keep

`openssl ca` is the subcommand that behaves like an actual authority. It requires a
configuration file and a small directory structure, and in exchange it maintains an
index of everything it has issued — which is what makes revocation possible.

The worked example below issues one certificate covering several nodes of an
internal cluster, with both `serverAuth` and `clientAuth` so the nodes can
authenticate *to each other* as well as to users. That combination is what mutual
TLS between cluster members needs, and it is the usual reason to run a private CA at
all:

```ini
keyUsage         = keyEncipherment, dataEncipherment, digitalSignature
extendedKeyUsage = serverAuth, clientAuth
```

That is what the request (`san.cfg`) asks for. The CA has the last word: an
extension that `[ server_cert ]` in `ca.cnf` already sets wins over the request's. So
the issued certificate gets `keyUsage = digitalSignature, keyEncipherment` from
`[ server_cert ]`, and the request's `dataEncipherment` is dropped. TLS does not use
it anyway.

### The directory layout

`openssl ca` will not create these for you, and fails with an unhelpful error if any
are missing:

```text
.
├── ca.cnf
├── san.cfg
└── ca/
    └── ca_example.com/
        ├── ca_example.com.crt      the CA certificate
        ├── private/
        │   └── ca_example.com.key  the CA private key
        └── db/
            ├── ca_example.com.db       the index — one line per certificate
            ├── ca_example.com.crt.srl  next serial number
            └── ca_example.com.crl.srl  next CRL number
```

### `ca.cnf`

```ini
# OpenSSL root CA configuration file.

# The [default] section contains global constants that can be referred to from
# the entire configuration file. It may also hold settings pertaining to more
# than one openssl command.

[ default ]
# CA Name
ca                      = ca_example.com
# Top dir
dir                     = .

# The next part of the configuration file is used by the openssl req command.
# It defines the CA's key pair, its DN, and the desired extensions for the CA
# certificate.
[ req ]
# RSA key size
default_bits            = 4096
# Protect private key
encrypt_key             = yes
# MD to use
default_md              = sha256
# Input is UTF-8
utf8                    = yes
# Emit UTF-8 strings
string_mask             = utf8only
# Don't prompt for DN
prompt                  = no
# DN section
distinguished_name      = ca_distinguished_name
# Desired extensions
x509_extensions         = custom_req

[ ca_distinguished_name ]
0.domainComponent       = "com"
1.domainComponent       = "example"
commonName              = Example Corp Internal Root CA
stateOrProvinceName     = Example State
countryName             = FR
emailAddress            = ca-admin@example.com
organizationName        = Example Corp
organizationalUnitName  = Platform

[ custom_req ]
subjectKeyIdentifier    = hash
authorityKeyIdentifier  = keyid:always,issuer
basicConstraints        = critical, CA:true
keyUsage                = critical, digitalSignature, cRLSign, keyCertSign

# The remainder of the configuration file is used by the openssl ca command.
# The CA section defines the locations of CA assets, as well as the policies
# applying to the CA.

[ ca ]
# The default CA section
default_ca              = ca_example.com

[ ca_example.com ]
# The CA cert
certificate             = $dir/ca/$ca/$ca.crt
# CA private key
private_key             = $dir/ca/$ca/private/$ca.key
# Certificate archive
new_certs_dir           = $dir/ca/$ca
# Serial number file
serial                  = $dir/ca/$ca/db/$ca.crt.srl
# CRL number file
crlnumber               = $dir/ca/$ca/db/$ca.crl.srl
# Index file
database                = $dir/ca/$ca/db/$ca.db
# Require unique subject
unique_subject          = no
# How long to certify for
default_days            = 3652
# MD to use
default_md              = sha256
# Default naming policy
policy                  = any_pol
# Add email to cert DN
email_in_dn             = no
# Keep passed DN ordering
preserve                = no
# Subject DN display options
name_opt                = ca_default
# Certificate display options
cert_opt                = ca_default
# Copy extensions from CSR
copy_extensions         = copy
# Default cert extensions
x509_extensions         = server_cert
# How long before next CRL
default_crl_days        = 365
# CRL extensions
crl_extensions          = crl_ext

[ match_pol ]
# if the value is "match" then the field value must match the same field in the
# CA certificate. If the value is "supplied" then it must be present.
# Optional means it may be present. Any fields not mentioned are silently
# deleted.
domainComponent         = match
organizationName        = match
organizationalUnitName  = optional
commonName              = supplied

[ any_pol ]
domainComponent         = optional
countryName             = optional
stateOrProvinceName     = optional
localityName            = optional
organizationName        = optional
organizationalUnitName  = optional
commonName              = optional
emailAddress            = optional

# Certificate extensions define what types of certificates the CA is able to
# create.

[ root_ca_ext ]
keyUsage                = critical,keyCertSign,cRLSign
basicConstraints        = critical,CA:true
subjectKeyIdentifier    = hash
authorityKeyIdentifier  = keyid:always

[ signing_ca_ext ]
keyUsage                = critical,keyCertSign,cRLSign
basicConstraints        = critical,CA:true,pathlen:0
subjectKeyIdentifier    = hash
authorityKeyIdentifier  = keyid:always

[ usr_cert ]
# Extensions for client certificates (`man x509v3_config`).
basicConstraints        = CA:FALSE
subjectKeyIdentifier    = hash
authorityKeyIdentifier  = keyid,issuer
keyUsage                = critical, nonRepudiation, digitalSignature, keyEncipherment
extendedKeyUsage        = clientAuth, emailProtection

[ server_cert ]
# Extensions for server certificates (`man x509v3_config`).
basicConstraints        = CA:FALSE
subjectKeyIdentifier    = hash
authorityKeyIdentifier  = keyid,issuer:always
keyUsage                = critical, digitalSignature, keyEncipherment
extendedKeyUsage        = serverAuth, clientAuth

# CRL extensions exist solely to point to the CA certificate that has issued
# the CRL.

[ crl_ext ]
authorityKeyIdentifier  = keyid:always
```

> [!warning] Four things to know about this configuration
> - **`copy_extensions = copy`** lets the CSR add the extensions that
>   `[ server_cert ]` does not set. That is what makes the SAN in `san.cfg` survive
>   into the issued certificate here. It is risky for a real CA. Here
>   `[ server_cert ]` sets `CA:FALSE`, so a CSR asking for `CA:true` still gets
>   `CA:FALSE`. But if the extension section has no `basicConstraints`, or if you use
>   `copy_extensions = copyall`, a crafted CSR mints itself an intermediate CA. A real
>   CA sets `copy_extensions = none` and supplies the extensions itself, for example
>   with `-extfile`.
> - **`policy = any_pol`** accepts any DN. `match_pol` is defined here but unused —
>   a real CA should enforce it.
> - **`default_days = 3652`** is ten years, which only passes because this CA is
>   internal. Public certificates are capped at 200 days as of March 2026, falling
>   to 47 by 2029 — see [[security/cryptography/acme]].
> - `nsCertType` and `nsComment` from the original have been dropped — they are
>   Netscape-era extensions that nothing has consulted for two decades.

### `san.cfg`

The certificate request configuration. This is where the SAN list lives:

```ini
# The main section is named req because the command we are using is req
# (openssl req ...)
[ req ]
# Default key size in bits, used with -new. Overridden by -newkey.
default_bits = 3072

# Default filename to write a private key to. Overridden by -keyout.
default_keyfile = private.key

# If no, a generated private key is not encrypted.
# Equivalent to the -nodes command line option.
encrypt_key = no

# Digest algorithm. Can be overridden on the command line.
default_md = sha256

# If no, disables prompting for certificate fields and takes values from the
# config file directly. It also changes the expected format of the
# distinguished_name and attributes sections.
prompt = no

# If yes, field values are interpreted as UTF-8 strings rather than ASCII.
utf8 = yes

# Section containing the distinguished name fields.
distinguished_name = custom_req_distinguished_name

# Section listing extensions to add to the certificate request. Overridden by
# the -reqexts switch. See x509v3_config(5).
req_extensions = custom_extensions

[ custom_req_distinguished_name ]
countryName         = FR
stateOrProvinceName = Example State
localityName        = Example City
organizationName    = Example Corp
commonName          = cluster.internal.example.com

[ custom_extensions ]
basicConstraints     = CA:FALSE
subjectAltName       = @alt_names
subjectKeyIdentifier = hash
keyUsage             = keyEncipherment, dataEncipherment, digitalSignature
extendedKeyUsage     = serverAuth, clientAuth

[ alt_names ]
DNS.1 = cluster.internal.example.com
DNS.2 = node-01.internal.example.com
DNS.3 = node-02.internal.example.com
DNS.4 = node-03.internal.example.com
IP.1  = 10.0.0.11
IP.2  = 10.0.0.12
IP.3  = 10.0.0.13
```

> [!note] `IP:` entries are not `DNS:` entries
> A client connecting to `https://10.0.0.11/` matches the certificate against the
> **IP** SAN entries, not the DNS ones. A certificate listing only DNS names fails
> when something connects by address — a health check, a load balancer, a
> hardcoded upstream. Include both if either is used.

### The generation script

```bash
#!/bin/bash
set -euo pipefail

ca='ca_example.com'
domain='cluster.internal.example.com'

# create ca directories
mkdir -p "ca/$ca/private"
mkdir -p "ca/$ca/db"
chmod 700 "ca/$ca/private"

# create the files openssl ca expects to already exist.
# the index starts empty, but both counters must contain a valid hex number —
# an empty crl.srl makes `openssl ca -gencrl` fail later
touch "ca/$ca/db/$ca.db"
echo '01' > "ca/$ca/db/$ca.crt.srl"
echo '01' > "ca/$ca/db/$ca.crl.srl"

# generate ca key
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:4096 \
    -out "ca/$ca/private/$ca.key"
chmod 600 "ca/$ca/private/$ca.key"

# generate self-signed certificate for the ca
# -days is mandatory here: req -x509 does NOT read default_days from [ca],
# and silently defaults to 30 days
openssl req -new -x509 -key "ca/$ca/private/$ca.key" -days 3652 \
    -out "ca/$ca/$ca.crt" -config ca.cnf

# generate private key and csr for the server certificate
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:3072 -out "$domain.key"
chmod 600 "$domain.key"
openssl req -new -key "$domain.key" -out "$domain.csr" -config san.cfg

# generate the ca-signed certificate
openssl ca -batch -config ca.cnf -out "$domain.crt" -infiles "$domain.csr"
```

`-batch` skips the interactive confirmation. Drop it the first time so you can read
what the CA is about to sign.

> [!warning] Correction — the original CA certificate expired in 30 days
> The script in the original notes called `openssl req -new -x509` **without
> `-days`**. `default_days = 3652` in the `[ca]` section does not apply: it is read
> by `openssl ca`, not by `openssl req`, which falls back to its own default of
> **30 days**.
>
> The result verifies perfectly on the day you build it, and then fails a month
> later — with a leaf certificate still valid for another ten years, and an error
> that names the leaf rather than the expired root. Confirmed by running it:
>
> ```console
> $ openssl x509 -in ca/ca_example.com/ca_example.com.crt -noout -dates
> notBefore=Aug 12 07:33:17 2026 GMT
> notAfter=Sep 11 07:33:17 2026 GMT      # 30 days
> $ openssl x509 -in cluster.internal.example.com.crt -noout -dates
> notAfter=Aug 11 07:33:18 2036 GMT      # 10 years
> ```
>
> Always pass `-days` explicitly, and always check the **CA** certificate's dates,
> not just the leaf's.

### Issuing more certificates

The CA now exists, so subsequent certificates are two commands. Edit `san.cfg`, or
keep one per host:

```bash
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:3072 -out node-04.key
openssl req -new -key node-04.key -out node-04.csr -config san-node-04.cfg
openssl ca -batch -config ca.cnf -out node-04.crt -infiles node-04.csr
```

Every issuance appends a line to the index, which is the record route 1 never keeps:

```console
$ cat ca/ca_example.com/db/ca_example.com.db
V	360811073318Z		01	unknown	/C=FR/ST=Example State/L=Example City/O=Example Corp/CN=cluster.internal.example.com
```

The first column is the status: `V` valid, `R` revoked, `E` expired.

### Revoking a certificate

This is the entire reason to use `openssl ca` rather than route 1:

```bash
# mark it revoked in the index
openssl ca -config ca.cnf -revoke cluster.internal.example.com.crt

# publish an updated CRL
openssl ca -config ca.cnf -gencrl -out ca/ca_example.com/ca_example.com.crl

# check what it says
openssl crl -in ca/ca_example.com/ca_example.com.crl -noout -text
```

Prove it actually took effect. `openssl verify` ignores revocation unless you ask
for it, so the certificate still passes a plain check — which is exactly the trap:

```console
$ openssl verify -CAfile ca/ca_example.com/ca_example.com.crt cluster.internal.example.com.crt
cluster.internal.example.com.crt: OK                      # revocation not consulted

$ cat ca/ca_example.com/ca_example.com.crt ca/ca_example.com/ca_example.com.crl > bundle.pem
$ openssl verify -crl_check -CAfile bundle.pem cluster.internal.example.com.crt
error 23 at 0 depth lookup: certificate revoked
error cluster.internal.example.com.crt: verification failed
```

`-CRLfile` does the same without building a bundle:

```bash
openssl verify -crl_check -CAfile ca/ca_example.com/ca_example.com.crt \
  -CRLfile ca/ca_example.com/ca_example.com.crl cluster.internal.example.com.crt
```

The CRL is only useful if clients actually fetch it. Point them at it with a
`crlDistributionPoints` extension on issued certificates, and re-run `-gencrl`
before the previous CRL expires — `default_crl_days` in the config governs that, and
an expired CRL is treated as a hard failure by some clients and ignored entirely by
others. See [[security/cryptography/pki-and-x509]] for why none of this works well at
internet scale.

## Trusting the CA

The certificate is worthless until clients trust the CA that signed it. This applies
to both routes.

On openSUSE Leap:

```bash
sudo cp ca/ExampleCA.crt /etc/pki/trust/anchors/example-ca.crt
sudo update-ca-certificates
```

On RHEL, Rocky and Fedora:

```bash
sudo cp ca/ExampleCA.crt /etc/pki/ca-trust/source/anchors/example-ca.crt
sudo update-ca-trust
```

On Debian and Ubuntu:

```bash
sudo cp ca/ExampleCA.crt /usr/local/share/ca-certificates/example-ca.crt
sudo update-ca-certificates
```

Browsers and language runtimes frequently keep their own trust stores — Firefox and
Java both do — so the system store is not always enough.

## Verifying the result

Check the certificate contains what you expect, especially the SAN:

```bash
openssl x509 -in certs/bastion-01.example.com.crt -noout -ext subjectAltName
```

Verify it chains to the CA:

```bash
openssl verify -CAfile ca/ExampleCA.crt certs/bastion-01.example.com.crt
```

Confirm the key and certificate actually belong together — these two must match:

```bash
diff <(openssl x509 -in certs/bastion-01.example.com.crt -noout -pubkey) \
     <(openssl pkey -in private/bastion-01.example.com.key -pubout)
```

Test it end to end against a running service:

```bash
openssl s_client -connect bastion-01.example.com:443 \
  -servername bastion-01.example.com -verify_hostname bastion-01.example.com \
  -CAfile ca/ExampleCA.crt
```

Look for `Verify return code: 0 (ok)`.

> [!tip] `openssl verify` passing does not mean a browser will accept it
> `verify` checks the chain, not the hostname. Name matching is the application's
> job. `s_client` does not check the name either, unless you add `-verify_hostname`:
> without it, a certificate for another name still gives `0 (ok)`. Finish with
> `s_client -verify_hostname`, or with an actual client.

> [!warning] Correction
> An earlier version said that `s_client` checks the hostname. It does not:
> `-servername` only sends the name (SNI). The command above adds `-verify_hostname`.

## Where to go next

- [[security/cryptography/pki-and-x509]] — X.509 fields, chain verification and revocation
- [[security/cryptography/acme]] — automating all of this, including for internal hosts
- [[security/cryptography/openssl/commands]] — the individual invocations used here
- [[security/cryptography/openssl/troubleshooting]] — when verification fails
- [[kubernetes/security/cert-manager]] — automated issuance and renewal in a cluster

<!-- uplink -->
Part of [[security/cryptography/index|Cryptography, PKI and TLS]].
