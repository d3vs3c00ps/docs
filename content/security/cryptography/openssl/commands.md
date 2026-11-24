---
title: openssl command reference
description: genpkey, req, x509, pkcs12, verify and s_client — the invocations worth having to hand, with what each flag actually does
tags: [security, openssl, tls, certificates, cheatsheet]
type: reference
status: complete
---

# openssl command reference

The commands that come up repeatedly. For the tool's structure see
[[security/cryptography/openssl/introduction]]; for what the objects mean,
[[security/cryptography/pki-and-x509]].

## Generating keys

```bash
# RSA — 2048 minimum, 3072 recommended
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:3072 -out key.pem

# ECDSA — smaller and faster, prefer for new deployments
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out key.pem

# Ed25519 — best properties, support still uneven
openssl genpkey -algorithm ED25519 -out key.pem

# Encrypted with a passphrase
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:3072 \
  -aes-256-cbc -out key.pem
```

Inspect, and extract the public half:

```bash
openssl pkey -in key.pem -noout -text
openssl pkey -in key.pem -pubout -out pub.pem
```

Add or remove a passphrase:

```bash
openssl pkey -in key.pem -aes-256-cbc -out key-enc.pem   # add
openssl pkey -in key-enc.pem -out key.pem                # remove
```

> [!warning] Check the mode of every private key file
> OpenSSL 3 creates a **new** private key file with mode `600`. It does not change
> the mode of a file that **already exists**: write a key over an old `644` file and
> the key stays readable by everyone. Copies made with `cp`, and files written by
> other tools, follow your umask. A key readable by everyone is not a key.
>
> ```bash
> umask 077       # before generating
> chmod 600 key.pem
> ```

> [!note] Key file permissions
> Tested with OpenSSL 3.5: `genpkey`, `req -keyout` and `pkey` with a cipher create a
> new key file with mode `600`. Only an existing file keeps its old mode.

## Certificate signing requests

```bash
openssl req -new -key key.pem -out req.csr \
  -subj "/C=FR/ST=Example State/L=Example City/O=Example Corp/CN=www.example.com" \
  -addext "subjectAltName=DNS:www.example.com,DNS:example.com"
```

Key and CSR in one step:

```bash
openssl req -newkey rsa:3072 -nodes -keyout key.pem -out req.csr \
  -subj "/CN=www.example.com" \
  -addext "subjectAltName=DNS:www.example.com"
```

`-nodes` means "no DES": do not encrypt the key. Use it for a key a daemon must read
at boot without a passphrase. OpenSSL 3.0 renamed it `-noenc`; `-nodes` still works
as a deprecated alias.

> [!danger] A CSR without `subjectAltName` produces an unusable certificate
> Browsers stopped honouring the Subject CN for hostname verification years ago, and
> Go's TLS stack rejects CN-only certificates outright. curl, Python and OpenSSL still
> fall back to the CN when there is no SAN, so a CN-only certificate can pass your
> scripts and still fail in every browser.
>
> Always `-addext "subjectAltName=..."`, and always verify it survived into the
> issued certificate:
>
> ```bash
> openssl x509 -in cert.pem -noout -ext subjectAltName
> ```
>
> See [[security/cryptography/certificate-generation]], where this was a real bug.

Inspect and verify a CSR:

```bash
openssl req -in req.csr -noout -text
openssl req -in req.csr -noout -verify        # is the self-signature valid
```

## Self-signed certificates

For a lab or an internal service:

```bash
openssl req -x509 -newkey rsa:3072 -nodes \
  -keyout key.pem -out cert.pem -days 365 \
  -subj "/CN=www.example.com" \
  -addext "subjectAltName=DNS:www.example.com,DNS:localhost,IP:127.0.0.1" \
  -addext "basicConstraints=critical,CA:FALSE" \
  -addext "keyUsage=critical,digitalSignature,keyEncipherment" \
  -addext "extendedKeyUsage=serverAuth"
```

## Inspecting certificates

```bash
openssl x509 -in cert.pem -noout -text          # everything

openssl x509 -in cert.pem -noout -subject
openssl x509 -in cert.pem -noout -issuer
openssl x509 -in cert.pem -noout -dates
openssl x509 -in cert.pem -noout -serial
openssl x509 -in cert.pem -noout -fingerprint -sha256
openssl x509 -in cert.pem -noout -ext subjectAltName
openssl x509 -in cert.pem -noout -purpose
```

Is it expiring soon?

```bash
openssl x509 -in cert.pem -noout -checkend 2592000    # 30 days; exit 1 if it will
```

That exit code makes it directly usable in monitoring:

```bash
for c in /etc/pki/tls/certs/*.pem; do
  openssl x509 -in "$c" -noout -checkend 2592000 >/dev/null \
    || echo "EXPIRING: $c ($(openssl x509 -in "$c" -noout -enddate))"
done
```

## Signing a CSR with your own CA

```bash
openssl x509 -req -in req.csr \
  -CA ca.crt -CAkey ca.key -CAcreateserial \
  -out cert.pem -days 365 -sha256 \
  -extfile ext.cnf
```

```text
# ext.cnf
basicConstraints       = critical,CA:FALSE
keyUsage               = critical,digitalSignature,keyEncipherment
extendedKeyUsage       = serverAuth
subjectKeyIdentifier   = hash
authorityKeyIdentifier = keyid,issuer
subjectAltName         = DNS:www.example.com,DNS:example.com
```

Extensions in the CSR are **not** copied automatically — `-extfile` is how they reach
the certificate. This is the single most common reason a SAN disappears between
request and issuance.

## Verifying

```bash
openssl verify -CAfile ca.crt cert.pem
openssl verify -CAfile ca.crt -untrusted intermediate.crt cert.pem
openssl verify -CApath /etc/ssl/certs cert.pem
```

Does this key match this certificate? Compare the public keys. The two hashes must
be identical. This works for every key type (RSA, ECDSA, Ed25519):

```bash
openssl x509 -in cert.pem -noout -pubkey | openssl sha256
openssl pkey -in key.pem -pubout | openssl sha256
```

Or with `diff`, which prints nothing when they match:

```bash
diff <(openssl x509 -in cert.pem -noout -pubkey) \
     <(openssl pkey -in key.pem -pubout)
```

> [!warning] Compare like with like
> `x509 -modulus` and `pkey -noout -pubout` never give the same hash: `-modulus` prints
> `Modulus=...`, not a PEM key, and `-noout` makes `pkey` print nothing at all. For
> RSA, the modulus form needs the same command on both sides:
> `openssl rsa -in key.pem -noout -modulus`.

## PKCS#12

Bundling a key, certificate and chain into one file, for Java, Windows or a browser:

```bash
openssl pkcs12 -export -out bundle.p12 \
  -inkey key.pem -in cert.pem -certfile chain.pem \
  -name "www.example.com"
```

Unpacking one:

```bash
openssl pkcs12 -in bundle.p12 -info -noout
openssl pkcs12 -in bundle.p12 -nokeys -out certs.pem
openssl pkcs12 -in bundle.p12 -nocerts -nodes -out key.pem
openssl pkcs12 -in bundle.p12 -legacy -nodes -out all.pem   # old file, OpenSSL 3
```

## s_client

Testing a live endpoint. The tool you reach for when a TLS connection misbehaves:

```bash
openssl s_client -connect example.com:443 -servername example.com
```

`-servername` sets SNI, and omitting it on a virtual-hosted server gets you the
default certificate rather than the one you meant to test.

```bash
# Show the chain the server actually sends
openssl s_client -connect example.com:443 -servername example.com -showcerts </dev/null

# Verify against a specific CA
openssl s_client -connect example.com:443 -CAfile ca.crt </dev/null

# Force a protocol version
openssl s_client -connect example.com:443 -tls1_2
openssl s_client -connect example.com:443 -tls1_3

# STARTTLS
openssl s_client -connect mail.example.com:587 -starttls smtp
openssl s_client -connect ldap.example.com:389 -starttls ldap

# Just the expiry
openssl s_client -connect example.com:443 -servername example.com </dev/null 2>/dev/null \
  | openssl x509 -noout -dates
```

> [!tip] `</dev/null` is what stops it hanging
> `s_client` connects and then waits for you to type, because it is also an
> interactive client. Redirecting stdin makes it print the handshake and exit, which
> is what you want in a script.

Serve TLS for a quick test:

```bash
openssl s_server -accept 4433 -cert cert.pem -key key.pem -www
```

## Cipher suites

```bash
openssl ciphers -v 'HIGH:!aNULL:!MD5'
openssl ciphers -v -s -tls1_3
```

See [[security/cryptography/tls-protocol]] for what to actually configure.

## Miscellaneous

```bash
openssl rand -hex 32
openssl rand -base64 32
openssl dgst -sha256 file.tar.gz
openssl speed rsa2048 ecdsap256
openssl s_time -connect example.com:443
```

`openssl rand` is a genuinely good password generator, and available on every server.

## Where to go next

- [[security/cryptography/openssl/signing]] — signing and verifying data
- [[security/cryptography/openssl/troubleshooting]] — decoding the errors
- [[security/cryptography/certificate-generation]] — a scripted CA using these commands

<!-- uplink -->
Part of [[security/cryptography/openssl/index|OpenSSL]].
