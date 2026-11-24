---
title: The TLS protocol
description: How TLS actually works — the four sub-protocols, the handshake, cipher suite anatomy, what TLS 1.3 changed, Certificate Transparency, and what to configure today
tags: [security, tls, cryptography, networking]
type: concept
status: complete
---

# The TLS protocol

This note is about the **protocol**: how a TLS session is negotiated, what a cipher
suite actually names, and what to configure in 2026.

For the **primitives** it combines — AEAD, HKDF, Diffie–Hellman, signatures — see
[[security/cryptography/foundations]]. For the **certificates** themselves — X.509
structure, PKI hierarchy, running a CA — see [[security/cryptography/pki-and-x509]].
The notes are deliberately split: one is the wire protocol, one is the identity layer
it depends on, one is the maths underneath both.

## Overview

Secure Sockets Layer (SSL) was developed by Netscape from 1994. Version 3, from
1996, was the last. **Transport Layer Security** (TLS) is its successor under the
IETF.

TLS sits above the transport layer of the TCP/IP model, which makes it largely
transparent to applications such as HTTP or SMTP. It provides encryption, message
integrity, and authentication of a server — and optionally a client — through X.509
certificates. It uses **asymmetric cryptography for authentication and key
agreement**, then **symmetric cryptography for the bulk data**, because the latter is
orders of magnitude faster.

> [!warning] SSL is dead, and the name is not
> Every version of SSL is deprecated and insecure — SSL 3.0 was killed by POODLE and
> formally deprecated by RFC 7568. TLS 1.0 and 1.1 were deprecated by RFC 8996 in
> 2021. "SSL" survives only in library names (`openssl`) and configuration
> directives (`ssl_certificate`). When someone says SSL, they mean TLS.

The protocol is made of four sub-protocols:

1. **Handshake** — negotiation and authentication
2. **Record** — framing and protection of the actual data
3. **Change Cipher Spec** — the switch-over signal (removed in TLS 1.3)
4. **Alert** — errors and notifications

## Handshake protocol

Governs establishing a connection: server and/or client authentication, negotiation
of algorithms, and derivation of symmetric keys.

The sequence below is the **TLS 1.2** handshake. TLS 1.3 restructures it
considerably — see [below](#what-tls-13-changed).

### 1. ClientHello

The client opens with:

- **Version** — the highest SSL/TLS version it supports
- **Random** — 32 bytes, used later in key derivation. TLS 1.2 defined them as a
  4-byte timestamp plus 28 random bytes; current stacks make all 32 bytes random
- **CipherSuite** — the suites it supports, in descending order of preference
- **Session ID** — identifies the session, for resumption (optional)
- **Extensions** — Server Name Indication (SNI), Signed Certificate Timestamp (SCT),
  `encrypt_then_mac`, and others

### 2. ServerHello

The server replies with:

- **Version** — the highest version it supports
- **Random** — its own 32 bytes
- **Session ID** — the identifier for this session
- **CipherSuite** — the single suite chosen. The server follows either the client's
  order of preference (the OpenSSL default) or its own order, if it is set to
  enforce one
- **Extensions** — those it supports in return

### 3. Certificate

The server sends its X.509 certificate, carrying its public key.

### 4. ServerKeyExchange

The server sends an ephemeral key-exchange parameter, signed with its private key.
This step is omitted in a static RSA exchange, where no ephemeral parameter exists —
which is precisely why static RSA has no forward secrecy.

### 5. ServerHelloDone

The server signals that it has finished and is waiting.

### 6. ClientKeyExchange

Having validated the certificate, the client generates its own ephemeral value:

- **With RSA** — the client generates the pre-master secret and sends it encrypted
  under the server's public key.
- **With (EC)DHE** — the client sends its public Diffie-Hellman parameter in the
  clear; security rests on the discrete logarithm problem, not on secrecy of the
  parameter.

Both sides now derive the same shared secret, and from it the session keys, **which
are never transmitted**.

### 7. ChangeCipherSpec

The client signals that it is switching to the negotiated parameters.

### 8. Finished

The first message protected under the new keys, and a hash over the whole handshake
— which is what makes downgrade attacks detectable.

## Record protocol

Carries the application data, encapsulated uniformly. Its jobs:

- **Confidentiality** — data encrypted with keys derived during the handshake.
- **Integrity and authenticity** — verified through a MAC, or through the
  authentication tag of an AEAD mode.
- **Encapsulation** — a consistent framing that the peer can parse.

Processing order:

1. **Segmentation** — data split into fragments of at most 16 KB.
2. **Compression** — using the negotiated algorithm.
3. **MAC** — a keyed hash over the data, with the MAC key. It is not a signature:
   both sides hold the key. With an AEAD suite, steps 3 and 4 are one operation.
4. **Encryption** — under the negotiated cipher and key.
5. **Header** — content type, protocol version, and fragment length, then handed to
   the transport layer.

The receiver reverses it: check the header, decrypt, verify the MAC, reassemble.

> [!warning] Never enable TLS compression
> TLS compression existed through TLS 1.2 and was **removed in TLS 1.3**. In practice
> it has been disabled everywhere since 2012, when the **CRIME** attack showed that
> compressing attacker-influenced data alongside secrets leaks those secrets.

## Change Cipher Spec protocol

A single one-byte message telling the Record layer that subsequent records use the
newly negotiated parameters. **Removed in TLS 1.3**, where it survives only as a
dummy message for middlebox compatibility.

## Alert protocol

Error and notification messages, in two classes:

- **Fatal** — the connection is torn down immediately.
- **Warning** — advisory; `close_notify` is the common one.

## Cipher suites

A cipher suite names the combination of mechanisms used for a session. In TLS 1.2
the form is:

```text
TLS_<key exchange>_WITH_<bulk cipher>_<mode>_<hash>
```

- **Key exchange** — how the shared secret is agreed, and how the exchange is
  authenticated: `RSA`, `ECDHE_RSA`, `ECDHE_ECDSA`, `PSK`.
- **Bulk cipher and mode** — protects the application data. Either a cipher plus a
  separate HMAC (`AES_256_CBC_SHA384`) or a combined AEAD mode (`AES_256_GCM`).
- **Hash** — used for the HMAC and for key derivation.

So `TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384` means: ephemeral elliptic-curve
Diffie-Hellman, authenticated by an RSA certificate, with AES-256 in GCM, and SHA-384
for derivation.

### Key derivation

All key exchanges produce a `pre_master_secret`. The master secret comes from the
pseudo-random function:

```text
PRF(pre_master_secret, "master secret", ClientHello.random + ServerHello.random)
```

where `PRF(secret, label, seed) = P_hash(secret, label || seed)`, an iterated HMAC
construction:

```text
P_hash(secret, seed) = HMAC_hash(secret, A(1) || seed) || HMAC_hash(secret, A(2) || seed) || ...
   with A(0) = seed, A(i) = HMAC_hash(secret, A(i-1))
```

The master secret is 48 bytes — two iterations with P_SHA-256. Session keys then come
from:

```text
PRF(master_secret, "key expansion", ClientHello.random + ServerHello.random)
```

whose output is split into client and server MAC keys, encryption keys and IVs. This
is RFC 5246. TLS 1.3 replaces the whole scheme with HKDF.

### Key exchange methods

**Diffie-Hellman** — variants include DHE (ephemeral), ECDH, ECDHE, and the
anonymous ADH. In DHE the public parameters vary per session. To prevent a
machine-in-the-middle, each side proves it generated its values, either by signing
them with its private key (RSA, DSS, ECDSA) or by authenticating with a pre-shared
key.

**RSA** — the same key serves both key transport and authentication. This is the
problem: **static RSA provides no forward secrecy**. An attacker who records traffic
today and obtains the server's private key later can decrypt all of it
retrospectively. Removed entirely in TLS 1.3.

**PSK** — pre-shared keys, RFC 4279. It requires distributing keys over a secure
channel beforehand, which is rarely practical outside constrained or embedded
deployments.

> [!important] Forward secrecy is the reason to use ephemeral exchanges
> Perfect Forward Secrecy means compromise of a long-term private key does not expose
> past sessions, because the session keys were derived from ephemeral values that no
> longer exist. Any suite whose key exchange is not ephemeral fails this.

### Message authentication

Where the suite does not use an AEAD mode, integrity comes from HMAC:

```text
HMAC(K, m) = H( (K ⊕ opad) || H( (K ⊕ ipad) || m ) )
```

> [!note] What HMAC gives you
> HMAC remains a secure MAC even when the underlying hash is not collision-resistant,
> and its nested construction is immune to the **length-extension** attacks that break
> naive `H(key || message)` constructions. HMAC-SHA-1 is still considered sound for
> authentication despite SHA-1 being broken for signatures. HMAC is not "twice as
> strong" as its hash.

### Encryption modes

| Mode | What it is |
| --- | --- |
| **CBC** | Cipher Block Chaining — each block depends on the previous one. Encryption only; needs a separate MAC. |
| **CBC-HMAC** | CBC plus HMAC. Compute the MAC over the *ciphertext* (`encrypt_then_mac`) to avoid padding-oracle leaks. |
| **GCM** | Galois/Counter Mode — AEAD. Takes a key, IV, plaintext and additional authenticated data; outputs ciphertext plus an authentication tag. Confidentiality and authenticity in one pass. |
| **CCM** | Counter with CBC-MAC — AEAD. CBC-MAC for the tag, CTR for encryption, both under the same key. Common in constrained and IoT settings. |

Prefer AEAD modes: GCM, CCM, or ChaCha20-Poly1305. CBC suites were the vector for
BEAST (TLS 1.0 only) and Lucky 13 (every version up to 1.2), and TLS scanners such
as SSL Labs mark them as weak.

## What TLS 1.3 changed

TLS 1.3 (RFC 8446, August 2018) is less an increment than a redesign.

**A shorter handshake.** Key exchange and authentication happen in one flight,
reducing a full handshake from 2-RTT to **1-RTT**. Everything after ServerHello is
encrypted, including the server's certificate. Resumed sessions can use **0-RTT**,
sending application data in the first packet.

> [!warning] 0-RTT data is replayable
> The early data in a 0-RTT handshake has no protection against replay, by
> construction. It is safe only for idempotent requests. Do not accept 0-RTT for
> anything that changes state.

**Legacy cryptography removed**, not merely discouraged:

- Gone: RC4, 3DES, MD5, SHA-1 signatures, all export-grade ciphers, compression.
- Gone: static RSA, static DH, and every non-forward-secret key exchange.
- **Forward secrecy is mandatory** — there is no way to configure it away.

**Simplified suite naming.** A TLS 1.3 suite names only the AEAD algorithm and the
hash used for key derivation, because the key exchange is negotiated separately:

```text
TLS_AES_256_GCM_SHA384
```

**Other changes** — all symmetric encryption is AEAD; key derivation uses HKDF;
record content types are encrypted to resist traffic analysis; and resumption is
PSK-based, so the server need not hold session state.

## Certificate Transparency

CT addresses a structural weakness of the PKI: any trusted CA can issue a
certificate for any domain, and historically nobody would notice.

It works by requiring certificates to be published in **append-only, publicly
auditable logs**, built as Merkle trees so entries cannot be altered retroactively.
Google, Cloudflare, Let's Encrypt, Sectigo and others operate logs.

| Component | Role |
| --- | --- |
| **Logs** | Append-only Merkle-tree records of every certificate submitted |
| **SCTs** | Signed Certificate Timestamps — a log's signed promise to include a certificate. Browsers require several, from different operators |
| **Monitors** | Watch the logs for certificates issued for your domains, and alert you. [crt.sh](https://crt.sh) is the usual starting point |
| **Auditors** | Verify that logs behave correctly and stay consistent |

An SCT reaches the client in one of three ways: embedded in the certificate as an
X.509 extension, delivered as a TLS extension during the handshake, or included in a
stapled OCSP response. In practice it is almost always embedded.

Chrome has required CT compliance for publicly trusted certificates since April 2018,
and Safari enforces its own policy.

> [!tip] Set up CT monitoring for your own domains
> It is free and takes minutes, and it is the only practical way you will learn that
> somebody mis-issued a certificate for your domain. It also reliably catches your
> own colleagues issuing certificates you did not know about.

## What to configure today

### TLS 1.3

Use these three. RFC 8446 makes `TLS_AES_128_GCM_SHA256` mandatory to implement,
and the other two "SHOULD" be implemented. OpenSSL enables all three by default:

- `TLS_AES_256_GCM_SHA384`
- `TLS_AES_128_GCM_SHA256`
- `TLS_CHACHA20_POLY1305_SHA256` — notably faster on mobile and ARM without AES
  hardware acceleration

> [!note] Mandatory to implement
> Only `TLS_AES_128_GCM_SHA256` is a MUST in RFC 8446.

### TLS 1.2, while you still need it

In order of preference:

1. `TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384`
2. `TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256`
3. `TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384`
4. `TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256`
5. `TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256`
6. `TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256`

### Never

- **RC4** — broken, RFC 7465
- **DES and 3DES** — 3DES is limited by the Sweet32 birthday bound
- **Export-grade** suites — FREAK, Logjam
- **Anonymous** suites (`TLS_DH_anon_*`) — no authentication at all
- **NULL encryption** — no confidentiality at all
- **MD5** anywhere, **SHA-1** for signatures
- **Static RSA or static DH** — no forward secrecy

### Key exchange and curves

Prefer **ECDHE**. Use **DHE** at 3072 bits if you must — 2048 is the floor.

Curves, in order: **X25519** (RFC 7748) for anything new, then **P-256**, the most
widely supported, and **P-384**. Avoid binary curves.

Ahead of all of them, offer the hybrid post-quantum group **X25519MLKEM768**. It is
the default in OpenSSL 3.5, Go 1.24, current Chrome and Firefox, and the major CDNs,
and it costs one line of configuration:

```text
X25519MLKEM768:X25519:P-256
```

Because it is hybrid, it is no weaker than X25519 even if ML-KEM is later broken, and
it defeats "harvest now, decrypt later" recording today. See
[[security/cryptography/post-quantum]].

> [!note] P-521 is not a security concern
> P-224 is too small. P-521 is simply slower and less widely deployed than P-384, with
> no practical benefit: it is over-provisioned, not weak.

### Certificates and hashes

- **ECDSA** — preferred for new deployments: smaller keys, faster handshakes.
- **RSA** — 2048 bits minimum, 3072 recommended.
- **EdDSA** (Ed25519) — excellent properties, but publicly trusted CAs cannot issue
  it: the CA/Browser Forum Baseline Requirements allow only RSA and ECDSA keys. Fine
  for an internal CA whose clients support it.
- Hashes — **SHA-256** minimum, **SHA-384** where you want margin. SHA-512 offers no
  practical advantage over SHA-384 here.

> [!note] 3072, not 4096
> 4096-bit RSA costs noticeably more CPU per handshake, for a margin nobody can
> currently exploit at 3072. Use 3072, or move to ECDSA P-256, which beats both.

### Server checklist

1. Disable TLS 1.0 and 1.1. Support 1.2 and 1.3 only.
2. Let the client's preference order win on modern stacks, or enforce server
   preference if you must support old clients.
3. Enable **HSTS**.
4. Staple OCSP responses only if your CA still runs OCSP. Let's Encrypt shut its
   OCSP service down in August 2025 and publishes CRLs instead; the CA/Browser Forum
   made OCSP optional for publicly trusted CAs.
5. Monitor CT logs for your domains.

Do not hand-write the cipher list. Use the
[Mozilla SSL Configuration Generator](https://ssl-config.mozilla.org/) and pick the
`modern` profile unless something forces `intermediate`.

### Standards worth citing

- **RFC 8446** — TLS 1.3
- **RFC 8996** — deprecating TLS 1.0 and 1.1
- **NIST SP 800-52 Rev. 2** — TLS implementation guidelines
- **PCI DSS** — forbids SSL and early TLS; TLS 1.2 or later is the usual way to
  comply

## Where to go next

- [[security/cryptography/foundations]] — the primitives underneath every suite named here
- [[security/cryptography/pki-and-x509]] — X.509, PKI, chain verification and revocation
- [[security/cryptography/post-quantum]] — what breaks, and the hybrid group to turn on now
- [[security/cryptography/acme]] — getting and renewing the certificates automatically
- [[security/cryptography/certificate-generation]] — a scripted CA and server certificate
- [[servers/nginx]] · [[servers/apache]] — where the configuration actually goes
- [[kubernetes/security/cert-manager]] — automating issuance in a cluster

<!-- uplink -->
Part of [[security/cryptography/index|Cryptography, PKI and TLS]].
