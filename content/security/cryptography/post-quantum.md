---
title: Post-quantum cryptography
description: What a quantum computer actually breaks, why key exchange is urgent and signatures are not, the NIST standards, and how to turn on hybrid key exchange today
tags: [security, cryptography, post-quantum, tls, pki]
type: concept
status: complete
---

# Post-quantum cryptography

A sufficiently large quantum computer breaks every asymmetric algorithm currently in
production use. Not weakens — **breaks**. RSA, Diffie–Hellman, ECDH, ECDSA and
Ed25519 all rest on factoring or discrete logarithms, and Shor's algorithm solves
both in polynomial time.

Nobody has built that machine, and estimates of when range from a decade to never.
The reason to act now is narrower and more concrete than the headline, and it is
worth being precise about it.

## What is actually at risk

| Primitive | Quantum impact | What to do |
| --- | --- | --- |
| **RSA, DH, ECDH, ECDSA, EdDSA** | Broken by Shor's algorithm | Replace |
| **AES-128** | Grover's algorithm halves the search exponent | Acceptable; prefer 256 for long-lived data |
| **AES-256** | Effectively unaffected | Keep |
| **SHA-256** | Reduced preimage margin, collision resistance largely unchanged | Keep; SHA-384 for margin |
| **HMAC** | Effectively unaffected | Keep |

So the damage is confined to **asymmetric** cryptography. Symmetric ciphers and hashes
need at most a size bump. Grover's algorithm gives a quadratic speedup on brute-force
search, which sounds devastating and is not: it parallelises poorly, so its practical
advantage against AES-128 is far smaller than the naive 2^128 → 2^64 reading suggests.

> [!important] The urgency is unevenly distributed
> **Key exchange is urgent. Signatures are not.**
>
> An adversary can record encrypted traffic today and decrypt it years later, once a
> quantum computer exists — **"harvest now, decrypt later"**. The traffic is already
> captured; nothing you do in 2031 helps. So the exposure of a session key is the
> confidentiality lifetime of the data it protected, which for medical records, legal
> archives or state secrets is decades.
>
> A signature, by contrast, only has to resist forgery *while it is being trusted*.
> Nobody can retroactively forge a signature you verified last year. Signature
> migration matters, but you can do it when the machine actually gets close.
>
> If you only do one thing, do hybrid key exchange.

## The standards

NIST finalised three standards on **13 August 2024**, after an eight-year open
competition:

| Standard | Algorithm | Was called | Job |
| --- | --- | --- | --- |
| **FIPS 203** | ML-KEM | CRYSTALS-Kyber | Key encapsulation — lattice |
| **FIPS 204** | ML-DSA | CRYSTALS-Dilithium | Signatures — lattice |
| **FIPS 205** | SLH-DSA | SPHINCS+ | Signatures — hash-based |

Two more are in the pipeline. **HQC** was selected on 11 March 2025 as a backup KEM
built on error-correcting codes rather than lattices, so that a future break of
lattice assumptions does not take out both options at once. NIST planned a draft
standard around 2026 and a final one around 2027. **FN-DSA** (FALCON) is planned as
FIPS 206. In NIST IR 8547 (October 2026), both standards are still "under
development".

**SLH-DSA is the conservative choice.** Its security rests only on the hash function
underneath, which is far better understood than lattices — the price is very large
signatures and slow signing. It is the right pick for firmware and root-of-trust
signing, where keys live for decades and you sign rarely.

### Everything gets bigger

This is the practical cost, and it is the part that breaks systems:

| Object | Classical | Post-quantum |
| --- | --- | --- |
| Public key | X25519: **32 B** | ML-KEM-768: **1184 B** |
| Key exchange message | X25519: **32 B** | ML-KEM-768 ciphertext: **1088 B** |
| Signature | Ed25519: **64 B** | ML-DSA-65: **3309 B** |
| Signature (hash-based) | — | SLH-DSA-128s: **7856 B** |

A TLS ClientHello carrying an ML-KEM key no longer fits in one packet. Certificate
chains carrying ML-DSA signatures grow by 10 KB or more. Expect to find hardcoded
buffer sizes, middleboxes that choke on large handshake records, and embedded devices
that cannot hold the keys at all.

## Hybrid key exchange, which is what actually ships

Nobody deploys post-quantum algorithms alone. The deployed construction is
**hybrid**: run a classical and a post-quantum key exchange together and combine both
shared secrets, so the session is safe unless *both* are broken.

That hedges the real risk, which is not quantum computers — it is that ML-KEM is
young (Kyber was first published in 2017, the standard in 2024) and X25519 dates from
2006. A lattice break would be far more likely than a
quantum computer in the near term, and hybrid means such a break costs you nothing.

The deployed name is **X25519MLKEM768**, and it is already the majority case in some
telemetry:

| Where | Since |
| --- | --- |
| Chrome | 124 (April 2024) with the pre-standard Kyber draft; switched to X25519MLKEM768 in **131** (Nov 2024) |
| Firefox | **132** on desktop; **135** for QUIC/HTTP3 |
| OpenSSL | **3.5** (April 2025) — offered by default |
| Go | **1.24** — enabled by default in `crypto/tls` |
| Cloudflare, AWS, Google | Server-side, on by default |

> [!warning] The Kyber draft and ML-KEM are incompatible
> `X25519Kyber768Draft00` is not `X25519MLKEM768`. The changes NIST made when
> finalising FIPS 203 broke wire compatibility, so anything still offering the draft
> group simply fails to negotiate with a modern peer and falls back to classical
> X25519 — silently. If you pinned a group name in 2024, check it.

## Turning it on

Most of the time this is already done for you, and the useful work is *verifying*
rather than configuring.

Check what your OpenSSL can do:

```bash
openssl version                       # need 3.5 or later
openssl list -kem-algorithms          # ML-KEM-512 / 768 / 1024
openssl list -signature-algorithms | grep -i -e ML-DSA -e SLH-DSA
```

Check whether a server negotiates it:

```console
$ openssl s_client -connect cloudflare.com:443 -groups X25519MLKEM768 </dev/null 2>&1 \
    | grep -i "Negotiated TLS1.3 group"
Negotiated TLS1.3 group: X25519MLKEM768
```

If the server does not support it the connection still succeeds — it just falls back
to a classical group, which is exactly the failure mode to watch for. Grep for the
group name; do not assume. After a fallback, OpenSSL 3.5 prints no
`Negotiated TLS1.3 group` line at all, only `Peer Temp Key: X25519, 253 bits`, so the
grep above prints nothing.

Generate post-quantum keys, for experimenting:

```bash
openssl genpkey -algorithm ML-KEM-768 -out mlkem.pem
openssl genpkey -algorithm ML-DSA-65  -out mldsa.pem
openssl pkey -in mldsa.pem -noout -text | head
```

Pin the group list on a server or client that supports it:

```bash
# OpenSSL client
openssl s_client -connect example.com:443 -groups X25519MLKEM768:X25519:P-256

# nginx — the group list is passed straight to OpenSSL, so this works on any
# nginx linked against 3.5 or later
# ssl_ecdh_curve X25519MLKEM768:X25519:secp256r1;
```

> [!note] Order matters, and so does keeping the classical fallback
> List the hybrid group first and a classical group after it. A post-quantum-only
> configuration will fail against most of the internet, and gains nothing over hybrid.

## Certificates are the slow half

Key exchange migrated quickly because it is invisible: both endpoints agree on a
group and nothing else in the world needs to know. Certificates are the opposite —
every relying party, trust store, HSM and CA has to agree at once.

As of 2026 there is **no publicly trusted post-quantum certificate** you can buy and
deploy on a website. The blockers are real:

- Root programmes must add PQ roots, and roots take years to become ubiquitous.
- An ML-DSA chain adds roughly 10–15 KB to every handshake.
- HSMs and hardware roots of trust need firmware support that mostly does not exist.
- Certificate Transparency logs, OCSP and CRL formats all need to accommodate the
  new sizes.

Where signatures *are* migrating first is where the verifier is controlled: firmware
and secure-boot signing, code signing, and software update channels. If you sign
firmware, SLH-DSA is worth planning for now — see
[[security/boot-integrity/index|Boot integrity]] and
[[security/supply-chain/index|Supply chain]].

## The timelines that will drive your work

- **NIST IR 8547** (final, October 2026) — every quantum-vulnerable public-key
  algorithm (RSA, ECDSA, EdDSA, DH, ECDH), at every key size, is deprecated after
  **2030** and disallowed after **2035**. RSA-3072 and P-256 are included. That is
  everything you are running.
- **US federal systems** — Executive Order 14412 and OMB memo M-26-15 want
  post-quantum key establishment on high-value systems by 31 December 2030, and
  post-quantum signatures by 31 December 2031.
- **NSA CNSA 2.0** — National Security Systems must migrate on a published schedule,
  with software and firmware signing first. If you sell to US government, this
  arrives before the general deadlines do.
- Sector regulators (finance, health) are converging on the same 2030–2035 window.

> [!note] The final IR 8547
> The November 2024 draft deprecated only the 112-bit algorithms (RSA-2048, P-224)
> after 2030. The final report deprecates all of them after 2030, whatever the key
> size.

2035 sounds distant. It is not, for anything with a ten-year replacement cycle:
industrial controllers, medical devices, vehicles, smart meters, HSMs. Those need
decisions now.

## What to do, in order

1. **Inventory.** You cannot migrate what you cannot find. Produce a cryptographic
   bill of materials: which algorithms, key sizes and libraries, in which services,
   protecting what data, with what confidentiality lifetime. This is the step
   everyone skips and it is the one that takes a year.
2. **Rank by harvest-now risk.** Long-lived confidential data crossing a network you
   do not control is first. Ephemeral internal traffic is last.
3. **Turn on hybrid key exchange where it is free.** Modern browsers, Go, OpenSSL 3.5
   and the major CDNs give it to you for a configuration line. Do this now.
4. **Move symmetric material to 256-bit** for anything long-lived.
5. **Fix crypto-agility.** The lasting problem is not ML-KEM, it is that algorithm
   choices are hardcoded across your estate. Make them configuration.
6. **Plan the signature migration** — do not execute it yet, except for firmware.
7. **Test for size.** Run your stack against a PQ-enabled server and find the
   middlebox that drops a 3 KB ClientHello before it finds you.

> [!warning] Two things to be sceptical of
> **QKD is not the answer.** Quantum key distribution needs dedicated optical
> hardware, does not scale, does not authenticate, and does not solve the problem
> post-quantum algorithms solve. NSA and the UK NCSC both advise against it for
> general use. If a vendor leads with QKD, ask why.
>
> **"Quantum-safe" is not a certification.** Ask which FIPS standard, which
> parameter set, and whether the deployment is hybrid. Proprietary or unstandardised
> PQC is worse than the classical algorithm it replaces.

## Where to go next

- [[security/cryptography/foundations]] — the primitives being replaced, and the KEM/DEM split that makes it possible
- [[security/cryptography/tls-protocol]] — where the hybrid group is negotiated
- [[security/cryptography/pki-and-x509]] — the certificate side, and why it lags
- [[security/security-roadmap]] — sequencing this against everything else

<!-- uplink -->
Part of [[security/cryptography/index|Cryptography, PKI and TLS]].
