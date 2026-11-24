---
title: Signing and verifying with openssl
description: Digital signatures with pkeyutl and dgst, encrypting with the right padding, hashing and HMAC, and the deprecated commands to stop using
tags: [security, openssl, cryptography, signing, integrity]
type: howto
status: complete
---

# Signing and verifying with openssl

Signing proves **who** produced something and that it has not changed. Encryption
hides content. They are different operations with different key usage, and conflating
them is the source of most mistakes here.

| Operation | Uses | Proves or provides |
| --- | --- | --- |
| **Sign** | Your **private** key | Authenticity and integrity |
| **Verify** | The signer's **public** key | That the signature matches |
| **Encrypt** | The recipient's **public** key | Confidentiality |
| **Decrypt** | The recipient's **private** key | — |

## Hashing

```bash
openssl dgst -sha256 file.tar.gz
sha256sum file.tar.gz                    # equivalent, and more common

openssl dgst -sha256 -binary file.tar.gz | openssl base64
```

A hash proves integrity only if it reaches the verifier through a channel the attacker
cannot modify. A checksum published next to the file it describes protects against
corruption, not against tampering — which is exactly what signatures are for.

## HMAC

Integrity **and** authenticity, using a shared secret rather than a key pair:

```bash
openssl dgst -sha256 -hmac "shared-secret" file.txt
```

Used for webhook verification and API request signing. See
[[security/cryptography/tls-protocol]] for HMAC's role in TLS.

## Signing data

The modern way is `pkeyutl`. Because it signs a **digest**, not the file, hash first:

```bash
# Sign
openssl dgst -sha256 -binary file.tar.gz > file.sha256
openssl pkeyutl -sign -inkey key.pem -in file.sha256 \
  -pkeyopt digest:sha256 -out file.sig

# Verify
openssl dgst -sha256 -binary file.tar.gz > file.sha256
openssl pkeyutl -verify -pubin -inkey pub.pem \
  -in file.sha256 -sigfile file.sig -pkeyopt digest:sha256
# Signature Verified Successfully
```

For Ed25519 there is no separate digest step — the algorithm hashes internally:

```bash
openssl pkeyutl -sign -inkey ed25519.pem -rawin -in file.tar.gz -out file.sig
openssl pkeyutl -verify -pubin -inkey ed25519-pub.pem -rawin \
  -in file.tar.gz -sigfile file.sig
```

> [!note] `openssl dgst -sign` is the shorter form
> It hashes and signs in one step:
>
> ```bash
> openssl dgst -sha256 -sign key.pem -out file.sig file.tar.gz
> openssl dgst -sha256 -verify pub.pem -signature file.sig file.tar.gz
> ```
>
> For RSA it uses PKCS#1 v1.5 padding by default. Select PSS with `-sigopt`, on both
> sides:
>
> ```bash
> openssl dgst -sha256 -sign key.pem -sigopt rsa_padding_mode:pss -out file.sig file.tar.gz
> openssl dgst -sha256 -verify pub.pem -sigopt rsa_padding_mode:pss -signature file.sig file.tar.gz
> ```

> [!note] `dgst` can use PSS
> `-sigopt rsa_padding_mode:pss` works with `dgst -sign`, tested with OpenSSL 3.5.
> `dgst` and `pkeyutl` produce the same kind of signature; pick either, and set the
> padding explicitly.

### RSA-PSS

The modern RSA signature padding, and what you should prefer:

```bash
openssl pkeyutl -sign -inkey key.pem -in file.sha256 \
  -pkeyopt digest:sha256 \
  -pkeyopt rsa_padding_mode:pss \
  -pkeyopt rsa_pss_saltlen:-1 \
  -out file.sig

openssl pkeyutl -verify -pubin -inkey pub.pem \
  -in file.sha256 -sigfile file.sig \
  -pkeyopt digest:sha256 \
  -pkeyopt rsa_padding_mode:pss \
  -pkeyopt rsa_pss_saltlen:-1
```

PSS is randomised and has a well-studied security proof. PKCS#1 v1.5 signatures are
not randomised; they are still considered secure, but PSS is the better choice for new
designs. Verification must use the **same** padding mode as signing, which is a common
source of "signature does not verify" when one side was upgraded.

## Encrypting with a public key

```bash
# Encrypt — OAEP padding, explicitly
openssl pkeyutl -encrypt -pubin -inkey pub.pem \
  -pkeyopt rsa_padding_mode:oaep \
  -pkeyopt rsa_oaep_md:sha256 \
  -in secret.txt -out secret.enc

# Decrypt
openssl pkeyutl -decrypt -inkey key.pem \
  -pkeyopt rsa_padding_mode:oaep \
  -pkeyopt rsa_oaep_md:sha256 \
  -in secret.enc -out secret.txt
```

> [!danger] Never use `openssl rsautl`, and never leave padding to the default
> `openssl rsautl` is deprecated as of OpenSSL 3.0. More importantly, both it and
> `pkeyutl` default to **PKCS#1 v1.5** padding, which is vulnerable to Bleichenbacher
> padding-oracle attacks. Specify OAEP explicitly, as above.

> [!important] RSA can only encrypt a very small amount of data
> An RSA key encrypts at most (key size − padding overhead) bytes — roughly 190 bytes
> for a 2048-bit key with OAEP. It is not for encrypting files.
>
> The correct construction is **hybrid**: generate a random symmetric key, encrypt the
> data with it, and encrypt only that key with RSA. That is what TLS, PGP and every
> real system does. If you find yourself wanting to RSA-encrypt a file, use
> `openssl cms` or `age` instead of building it yourself.

## Symmetric encryption

```bash
openssl enc -aes-256-cbc -pbkdf2 -iter 600000 -salt \
  -in file.txt -out file.enc

openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 \
  -in file.enc -out file.txt
```

> [!warning] `openssl enc` without `-pbkdf2` uses a broken key derivation
> The legacy default (`EVP_BytesToKey`) runs the hash **once**, so a guess costs one
> hash and a weak passphrase is quickly brute-forced. OpenSSL 3 prints
> `*** WARNING : deprecated key derivation used.` Always pass `-pbkdf2` and a high
> `-iter`.
>
> The hash is one round of SHA-256 since OpenSSL 1.1.0 (MD5 before). Still one round,
> still weak.
>
> `enc` also provides **no authentication** — an attacker can modify the ciphertext
> and you will not know. For anything that matters, use `openssl cms` with an AEAD
> cipher, or [age](https://github.com/FiloSottile/age), which is designed for this and
> hard to misuse.

## CMS — the format for real use

CMS (formerly PKCS#7) does signing and encryption properly, with certificates, hybrid
encryption and authenticated modes:

```bash
# Sign a file, attaching the certificate and the content
openssl cms -sign -binary -in file.txt -signer cert.pem -inkey key.pem \
  -nodetach -out file.p7s -outform PEM

# Verify against a trusted CA
openssl cms -verify -in file.p7s -inform PEM -CAfile ca.crt -out file.txt

# Encrypt for a recipient's certificate, with an authenticated (AEAD) cipher
openssl cms -encrypt -binary -in file.txt -out file.p7m -outform PEM \
  -aes-256-gcm recipient-cert.pem

openssl cms -decrypt -in file.p7m -inform PEM -inkey key.pem -out file.txt
```

> [!warning] Detached by default, and text mode
> `cms -sign` makes a **detached** signature by default; `-nodetach` keeps the content
> inside. To keep the signature in a separate file, verify with `-content file.txt`.
> Without `-binary`, `cms -sign` and `cms -encrypt` work in S/MIME text mode and turn
> every line ending into CRLF, so the file you get back is not the file you put in.
> `-aes256` is CBC, not authenticated; `-aes-256-gcm` needs OpenSSL 3.0 or later on
> both sides.

CMS handles the hybrid construction, so file size is not a constraint. It is what
S/MIME and many document-signing systems use underneath.

## Signing container images and artifacts

For software artifacts specifically, use purpose-built tooling rather than raw
`openssl` — it handles key storage, transparency logs and verification policy:

```bash
cosign sign-blob --key cosign.key myfile.tar.gz --bundle myfile.bundle
cosign verify-blob --key cosign.pub --bundle myfile.bundle myfile.tar.gz
```

See [[security/supply-chain/cosign]].

## Where to go next

- [[security/cryptography/openssl/commands]] — certificates and keys
- [[security/cryptography/openssl/troubleshooting]] — when verification fails
- [[security/supply-chain/cosign]] — signing artifacts, done properly
- [[security/cryptography/tls-protocol]] — where these primitives are used on the wire

<!-- uplink -->
Part of [[security/cryptography/openssl/index|OpenSSL]].
