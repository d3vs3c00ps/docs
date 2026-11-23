---
title: The openssl command
description: How the CLI is structured, why its interface is inconsistent, the PEM and DER encodings, and what changed in OpenSSL 3
tags: [security, openssl, tls, cryptography, cli]
type: concept
status: complete
---

# The `openssl` command

`openssl` is not one tool. It is a launcher for around fifty independent subcommands,
each written at a different time with its own conventions.

That explains the experience of using it: `-out` sometimes means a certificate and
sometimes a key, `-in` sometimes takes a request and sometimes a certificate, and
whether a flag needs a value is not predictable from its name.

```bash
openssl help                  # every subcommand
openssl list -commands
openssl version -a
```

This note is about the tool. For what the objects *mean*, see
[[security/cryptography/pki-and-x509]] (X.509 and PKI) and [[security/cryptography/tls-protocol]] (the
protocol).

## The shape of the CLI

```text
openssl <subcommand> [options]
```

Subcommands fall into four groups:

| Group | Examples | For |
| --- | --- | --- |
| **Key and parameter management** | `genrsa`, `genpkey`, `ecparam`, `rsa`, `pkey` | Generating and inspecting keys |
| **X.509** | `req`, `x509`, `ca`, `crl`, `pkcs12`, `verify` | Certificates and requests |
| **Cryptographic primitives** | `dgst`, `enc`, `pkeyutl`, `rand`, `speed` | Hashing, signing, encryption |
| **Protocol** | `s_client`, `s_server`, `ciphers` | Talking TLS |

> [!important] The `pkey` family supersedes the algorithm-specific commands
> `genrsa`, `rsa`, `dsa` and `ec` are the original per-algorithm tools. `genpkey`,
> `pkey` and `pkeyutl` are the modern generic equivalents, and they work with any
> algorithm including Ed25519.
>
> Prefer the generic ones in new work. Documentation is full of the old ones, which
> still work. But Ed25519, X25519, ML-KEM and ML-DSA keys are only reachable through
> the `pkey` family:
>
> ```bash
> openssl genrsa -out key.pem 2048                            # old
> openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out key.pem
> openssl genpkey -algorithm ED25519 -out key.pem             # only possible this way
> ```

## PEM and DER

Every object — key, certificate, request, CRL — exists in two encodings.

| | PEM | DER |
| --- | --- | --- |
| Form | Base64 with `-----BEGIN …-----` headers | Raw binary |
| Readable | Yes | No |
| Concatenable | Yes — this is how chains are built | No |
| Typical extensions | `.pem`, `.crt`, `.key`, `.csr` | `.der`, `.cer` |

```bash
openssl x509 -in cert.pem -outform DER -out cert.der
openssl x509 -in cert.der -inform DER -out cert.pem
```

> [!warning] The extension tells you nothing
> `.crt`, `.cer` and `.pem` are used interchangeably and for both encodings. A file
> claiming to be a certificate may be a key, a chain, or a PKCS#12 bundle. Look:
>
> ```bash
> head -1 mystery.crt
> # -----BEGIN CERTIFICATE-----      → PEM certificate
> # -----BEGIN PRIVATE KEY-----      → PEM key, unencrypted
> # -----BEGIN ENCRYPTED PRIVATE KEY----- → PEM key, encrypted
> # binary garbage                   → DER or PKCS#12
> ```
>
> Half of all "the certificate does not work" problems are a file that is not what
> its name suggests.

Because PEM is text, a chain is simply concatenation, leaf first:

```bash
cat server.crt intermediate.crt > fullchain.pem
```

The order matters — leaf, then intermediates, root omitted. Servers read the first
certificate in the file as their own. Put the intermediate first and the server
refuses to start, because that certificate does not match its private key.

## Inspecting anything

The single most useful habit is looking at a file before acting on it:

```bash
openssl x509  -in cert.pem -noout -text        # certificate
openssl req   -in req.csr  -noout -text        # signing request
openssl pkey  -in key.pem  -noout -text        # private key
openssl crl   -in crl.pem  -noout -text        # revocation list
openssl pkcs12 -in bundle.p12 -info -noout     # PKCS#12 bundle
```

`-noout` suppresses re-emitting the object, and `-text` prints the human-readable
form. Together they are the `cat` of the PKI world.

## OpenSSL 3

OpenSSL 3.0 was a significant rework, and its consequences show up in practice.

**Providers** replaced ENGINEs. Algorithms now live in loadable providers — `default`,
`fips`, and `legacy`.

> [!warning] Old files may fail to open on OpenSSL 3
> Algorithms considered obsolete — RC4, DES, MD2, and notably the RC2-based encryption
> in older PKCS#12 files — moved to the `legacy` provider, which is **not loaded by
> default**. A PKCS#12 exported years ago fails with an unhelpful error:
> `Error outputting keys and certificates`, then `digital envelope routines`
> and `unsupported`, with `RC2-40-CBC` named at the end.
>
> ```bash
> openssl pkcs12 -in old.p12 -legacy -nodes -out extracted.pem
> ```

**`openssl rsautl` is deprecated** in favour of `openssl pkeyutl`. It still runs, and
prints a deprecation message first. See [[security/cryptography/openssl/signing]].

> [!warning] Correction
> An earlier version said `openssl dgst -sign` is deprecated too. It is not: it still
> works on OpenSSL 3.5 with no warning. Only `rsautl` is deprecated.

**Default output changed.** `openssl x509 -text` prints slightly differently, which
breaks scripts that grep its output — a good argument for `-noout` plus a specific
flag such as `-subject` or `-enddate` rather than parsing the full dump.

Check what you have, because behaviour differs meaningfully between 1.1.1 and 3.x:

```bash
openssl version
openssl list -providers
```

## Configuration

`openssl.cnf` supplies defaults for `req`, `ca` and `x509`:

```bash
openssl version -d              # where OpenSSL looks
# OPENSSLDIR: "/etc/pki/tls"    on RHEL and Rocky; "/etc/ssl" on openSUSE and Debian
```

Override per invocation:

```bash
OPENSSL_CONF=./my.cnf openssl req -new ...
openssl req -config ./my.cnf -new ...
```

Simple extensions fit on the command line with `-addext` (OpenSSL 1.1.1 and later):

```bash
openssl req -new -key key.pem -subj "/CN=www.example.com" \
  -addext "subjectAltName=DNS:www.example.com,DNS:example.com" -out req.csr
```

A long SAN list, several extension sections, or a CA that you keep (`openssl ca`)
still needs a config file. See [[security/cryptography/certificate-generation]] for
worked ones.

> [!warning] Correction
> An earlier version said anything needing a SAN needs a config file. Since OpenSSL
> 1.1.1, `-addext` adds a SAN from the command line.

## LibreSSL is not OpenSSL

macOS ships LibreSSL as `/usr/bin/openssl`. It is a fork with different flags and
missing subcommands, and scripts written against OpenSSL fail on it in confusing
ways. The version below is an example; it changes with macOS releases:

```bash
openssl version
# LibreSSL 3.3.6      ← not OpenSSL

brew install openssl@3
/opt/homebrew/opt/openssl@3/bin/openssl version
```

## Where to go next

- [[security/cryptography/openssl/commands]] — the commands worth knowing, with examples
- [[security/cryptography/openssl/signing]] — signing and verifying data
- [[security/cryptography/openssl/troubleshooting]] — reading the errors
- [[security/cryptography/pki-and-x509]] — X.509 and PKI concepts

<!-- uplink -->
Part of [[security/cryptography/openssl/index|OpenSSL]].
