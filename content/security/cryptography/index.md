---
title: "Cryptography, PKI and TLS"
description: "The primitives, the identity layer built on them, and the protocol that consumes both. Start at Cryptography foundations and work outwards."
tags: [cryptography]
type: moc
status: complete
---

<!-- generated-moc -->

# Cryptography, PKI and TLS

The primitives, the identity layer built on them, and the protocol that consumes both. Start at [[security/cryptography/foundations|Cryptography foundations]] and work outwards.

## Sections

- [[security/cryptography/openssl/index|OpenSSL]]

## Notes in this section

| Note | | What it covers |
| --- | --- | --- |
| [[security/cryptography/acme\|ACME]] | concept | The protocol behind Let's Encrypt — how domain control is proved, the three challenge types and when to use each, ARI, CAA, and the shrinking certificate lifetimes that make automation mandatory |
| [[security/cryptography/certificate-generation\|Running your own certificate authority]] | how-to | The two OpenSSL routes to a private CA — a one-shot signing script and a stateful openssl ca with config files, revocation and a trust-store install — plus the pitfalls that make hand-rolled certificates fail |
| [[security/cryptography/foundations\|Cryptography foundations]] | concept | The primitives everything else is built from — symmetric and asymmetric encryption, hashes, MACs, key derivation, signatures and key agreement — each with a worked openssl example |
| [[security/cryptography/pki-and-x509\|PKI and X.509 certificates]] | reference | What a certificate is, how a chain of trust is verified, every X.509 field that matters, and running a CA — with the revocation problem stated honestly |
| [[security/cryptography/post-quantum\|Post-quantum cryptography]] | concept | What a quantum computer actually breaks, why key exchange is urgent and signatures are not, the NIST standards, and how to turn on hybrid key exchange today |
| [[security/cryptography/tls-protocol\|The TLS protocol]] | concept | How TLS actually works — the four sub-protocols, the handshake, cipher suite anatomy, what TLS 1.3 changed, Certificate Transparency, and what to configure today |

Part of [[security/index|Security]].
