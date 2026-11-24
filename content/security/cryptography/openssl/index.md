---
title: "OpenSSL"
description: "The tool rather than the concepts — how the CLI is put together, the invocations worth keeping, signing data, and decoding the error messages."
tags: [openssl]
type: moc
status: complete
---

<!-- generated-moc -->

# OpenSSL

The tool rather than the concepts — how the CLI is put together, the invocations worth keeping, signing data, and decoding the error messages.


| Note | | What it covers |
| --- | --- | --- |
| [[security/cryptography/openssl/commands\|openssl command reference]] | reference | genpkey, req, x509, pkcs12, verify and s_client — the invocations worth having to hand, with what each flag actually does |
| [[security/cryptography/openssl/introduction\|The openssl command]] | concept | How the CLI is structured, why its interface is inconsistent, the PEM and DER encodings, and what changed in OpenSSL 3 |
| [[security/cryptography/openssl/signing\|Signing and verifying with openssl]] | how-to | Digital signatures with pkeyutl and dgst, encrypting with the right padding, hashing and HMAC, and the deprecated commands to stop using |
| [[security/cryptography/openssl/troubleshooting\|openssl troubleshooting]] | reference | Decoding the error messages — unable to get local issuer, key values mismatch, hostname verification, chain order, and debugging a live handshake |

Part of [[security/cryptography/index|Cryptography, PKI and TLS]].
