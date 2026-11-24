---
title: PKI and X.509 certificates
description: What a certificate is, how a chain of trust is verified, every X.509 field that matters, and running a CA — with the revocation problem stated honestly
tags: [security, tls, pki, certificates, x509, openssl]
type: reference
status: complete
---

# PKI and X.509 certificates

Asymmetric cryptography gives you a key pair and no way to know whose it is. Anyone
can generate a key pair claiming to be `example.com`, and nothing about the maths
says otherwise.

A **certificate** closes that gap. It is a signed statement — nothing more — that a
particular public key belongs to a particular name. Everything below follows from
that one sentence.

> [!note] Prerequisite
> This note assumes the primitives: key pairs, signatures, and why signing with a
> private key proves authorship. See [[security/cryptography/foundations]].

## Public Key Infrastructure (PKI)

A PKI binds a public key to an identity by means of a **certificate authority**
(CA). The CA is the trusted third party that vouches for public keys.

So when Leia wants to talk to Luke, Luke sends her a message signed by Han — the CA
— whom Leia already knows and trusts. That signed message is what we call a
**certificate**. Leia can verify the signature using her copy of Han's public key,
and can then talk to Luke with confidence.

It is also common to have a **chain of trust**. Leia wants to talk to Luke, but Han
does not know Luke — Han knows Chewbacca, and Chewbacca knows Luke. Luke presents
his certificate chain: one certificate from Chewbacca attesting that the public key
belongs to Luke, and one from Han attesting that the signing key belongs to
Chewbacca. Without knowing Chewbacca directly, Leia can verify Chewbacca's key via
Han, and if her trust in Han is transitive she can then trust Luke.

> [!note] Transitive
> A *transitive* relation is one where, if it holds for `a` and `b`, and for `b` and
> `c`, then it also holds for `a` and `c`.

## X.509

X.509 is the standard for PKI. It defines the format of a public key certificate.
It is an ITU-T standard. The IETF profile that the internet uses is
[RFC 5280](https://www.rfc-editor.org/rfc/rfc5280).

| Version | Year | What it added |
| --- | --- | --- |
| 1 | 1988 | The basic certificate |
| 2 | 1993 | Issuer and subject unique identifiers (almost never used) |
| 3 | 1996 | Extensions — SAN, key usage, basic constraints. Every certificate you meet today |

> [!note] RFCs are not versions
> RFC 2459 (1999) and RFC 5280 (2008) both profile version 3, and RFC 5280 replaced
> RFC 2459 through RFC 3280.

An X.509 v3 certificate has this structure:

```text
Certificate
├── Version
├── Serial Number
├── Algorithm ID
├── Issuer
├── Validity
│   ├── Not Before
│   └── Not After
├── Subject
├── Subject Public Key Info
├── Issuer Unique Identifier   (optional)
├── Subject Unique Identifier  (optional)
└── Extensions                 (optional)
Certificate Signature Algorithm
Certificate Signature
```

### Version, Serial, Algorithm ID and Validity

| Field | Meaning |
| --- | --- |
| **Version** | the X.509 version |
| **Serial** | a unique number assigned by the CA to each certificate it issues |
| **Algorithm ID** | must match the `Certificate Signature Algorithm` field |
| **Validity** | two dates bounding the period the certificate is valid for |

### Issuer and Subject

Both are Distinguished Names (DN). The issuer DN names the CA, the subject DN names
the holder. As a string, a DN is written on a single line
([RFC 4514](https://www.rfc-editor.org/rfc/rfc4514), which replaced RFC 1779):

| Attribute | Meaning |
| --- | --- |
| `CN` | CommonName |
| `L` | LocalityName |
| `ST` | StateOrProvinceName |
| `O` | OrganizationName |
| `OU` | OrganizationalUnitName |
| `C` | CountryName |

```text
C=US, ST=Example State, L=Example City, O=Example Corp, CN=www.example.com
```

That is the form `openssl x509 -noout -subject` prints.

When connecting to an HTTPS site, the browser checks the name against the
certificate. Additional names can be given in the Subject Alternative Name
extension.

> [!warning] Browsers ignore CN entirely now
> Name matching has used **SAN** exclusively since Chrome 58 (2017); a certificate
> with only a CN and no `subjectAltName` is rejected outright. Go's TLS stack does
> the same. Treat CN as cosmetic and always populate SAN — see
> [[security/cryptography/certificate-generation]] for a config that does.
>
> OpenSSL is the exception: `openssl verify -verify_hostname` still falls back to the
> CN when a certificate has no SAN. Its `OK` does not prove that a browser will
> accept the certificate.

### Subject Public Key Info

Holds the key algorithm and its parameters:

```text
algorithm: rsaEncryption
key size:  2048
exponent:  0x10001
modulus:   00:ec:82:3f:78:b6...
```

### Extensions

Introduced in version 3. There are critical and non-critical extensions; only
non-critical ones may be ignored by a client that does not understand them.

| Extension | Purpose |
| --- | --- |
| Subject Key Identifier | identifies this certificate's public key |
| Authority Key Identifier | identifies the key that signed it |
| Subject Alternative Name | additional DNS names or IPs the certificate covers |
| Basic Constraints | whether this is a CA, and the maximum chain depth |

**Authority and Subject Key Identifiers** help a verifier find the right issuer
certificate, which matters when a CA has several signing keys or was renewed. The
identifier is usually the 160-bit SHA-1 hash of the public key (RFC 5280, method 1),
and that is what OpenSSL computes for `subjectKeyIdentifier = hash`.

### SNI

Server Name Indication lets a client send the hostname it wants **during the TLS
handshake**, before the certificate is chosen. That is what allows one IP address
to serve many hostnames each with its own certificate.

> [!note] SNI is per hostname
> SNI picks the certificate per *hostname*, and the mechanism matters: without
> SNI the server must pick a certificate before it knows which site was requested,
> which is why one IP could historically host only one HTTPS site.

### Wildcard certificates

A wildcard certificate covers multiple subdomains.

A browser accepts a certificate for `*.example.com` when connecting to
`www.example.com`, `login.example.com` or `smtp.example.com`. But the parent domain
`example.com` itself will **not** match, and neither will a deeper name such as
`a.b.example.com` — the wildcard covers exactly one label.

## Certificate signing requests

A CA does not generate your key — you do, and it never leaves your machine. What you
send is a **Certificate Signing Request**: your public key, the name you are
claiming, and the extensions you would like, all signed with your own private key to
prove you actually hold it.

```text
private key   ──►  stays on your machine, forever
public key    ──►  CSR  ──►  CA  ──►  certificate
```

The CA verifies that self-signature, checks the name claim by whatever policy it
applies — for a public CA that is
[[security/cryptography/acme|ACME domain validation]] — then keeps the fields it is
willing to certify, discards the rest, and signs the result.

> [!warning] A CSR is a request, not an instruction
> The CA decides what ends up in the certificate. By default `openssl x509 -req`
> **drops every CSR extension**. It keeps them only with `-copy_extensions copy`
> (OpenSSL 3.0 and later), or you give them again with `-extfile`. `openssl ca`
> copies them only when `copy_extensions` is set. That is why a `subjectAltName` so
> often disappears between request and issuance.
>
> Always verify the issued certificate rather than the request:
>
> ```bash
> openssl x509 -in cert.pem -noout -ext subjectAltName
> ```

For the commands — generating keys, building a CSR with SAN, inspecting all of it —
see [[security/cryptography/openssl/commands]].

## How a chain is actually verified

Worth knowing in order, because every verification error you will ever read maps to
one of these steps failing:

1. **Build a path** from the leaf certificate up to a certificate in the local trust
   store, using each certificate's Issuer to find its parent. The server sends the
   leaf and any intermediates; the root comes from your trust store, not the wire.
2. **Check every signature** in the path — each certificate verified with its
   issuer's public key.
3. **Check validity dates** on every certificate in the path, not just the leaf.
4. **Check `basicConstraints`** — every non-leaf must have `CA:TRUE`, and `pathlen`
   must not be exceeded. This is what stops a leaf certificate being used to issue
   others.
5. **Check `keyUsage` and `extendedKeyUsage`** — a CA needs `keyCertSign`, a web
   server needs `serverAuth`.
6. **Check revocation**, in theory. See below.
7. **Match the name** against the SAN. The application must ask for it. A plain
   `openssl verify` does not check any name, so its `OK` tells you nothing about
   whether a browser will accept the certificate. Add `-verify_hostname` to check one:

   ```bash
   openssl verify -CAfile root.pem -untrusted intermediate.pem \
     -verify_hostname www.example.com leaf.pem
   ```

> [!important] The root is never sent, and never needs to be
> A server should send the leaf plus intermediates and stop. Sending the root wastes
> bytes and changes nothing: if the client already trusts it, it has its own copy,
> and if it does not, a copy supplied by the server proves nothing.

## Revocation, and why it does not work

A certificate is valid until it expires. If the private key leaks before then, you
need to tell the world — and this is the part of PKI that has never functioned.

| Mechanism | What it is | Why it fails |
| --- | --- | --- |
| **CRL** | A signed list of revoked serials, published by the CA | Grows to megabytes, is cached, and is always stale |
| **OCSP** | Ask the CA about one certificate, live | Tells the CA every site you visit, and adds a round trip |
| **OCSP stapling** | The server fetches its own OCSP response and attaches it | Good, but optional, and often silently broken |

The fatal flaw is **soft-fail**. If a browser cannot reach the OCSP responder, it
proceeds anyway — because failing closed would mean an outage every time a CA had a
bad day. But an attacker positioned to use a stolen key is also positioned to block
the OCSP request — so the check reliably stops only the adversaries who were not
attacking you in the first place. Chrome removed online OCSP
checking years ago in favour of pushed lists of high-value revocations, and Let's
Encrypt has ended OCSP service in favour of CRLs.

> [!important] The industry's actual answer is short lifetimes
> If a certificate expires in weeks rather than a year, a leaked key is exposed for
> weeks, and no revocation infrastructure has to work at all. That is the reasoning
> behind the collapse of maximum lifetimes to 47 days by 2029 — and why it forces
> automation. See [[security/cryptography/acme]].

For an **internal** CA the picture is better, because you control every client and
can distribute a CRL that is actually consulted — and because your certificate count
is small enough for the list to stay small. That only works if the CA kept a record
of what it issued, which is the difference between the two routes in
[[security/cryptography/certificate-generation]].

## Running your own CA

You do not need a public CA to have a working PKI. For internal services, lab
environments and mutual TLS between your own components, running a small CA is
normal — you control every client, so you also control the trust store.

OpenSSL gives you two routes, and the difference between them is **state**:

| | `openssl x509 -req` | `openssl ca` |
| --- | --- | --- |
| Configuration | Command-line flags plus an extensions file | A config file, mandatory |
| Serial numbers | A single `.srl` counter | A serial file plus an index database |
| Record of what was issued | None | `index.txt`, one line per certificate |
| Revocation and CRLs | Not possible | Supported |
| Policy on the Subject DN | None | Enforced field by field |
| Good for | A certificate you need once | A CA you intend to keep |

The first is a signing operation. The second is a certificate authority: it remembers
what it issued, which is exactly what you need in order to revoke any of it later.

> [!warning] Both routes discard your CSR's extensions by default
> `x509 -req` drops them unless you pass `-copy_extensions copy` or `-extfile`; `ca`
> drops them unless the config sets `copy_extensions`. This is the most common
> reason a `subjectAltName` vanishes between request and issuance — and a
> certificate with no SAN is rejected by every modern client.

Worked examples of both routes — the configuration files, the generation scripts,
installing the CA into a trust store and verifying the result — are in
[[security/cryptography/certificate-generation]].

For anything that has to keep working without a human, run an internal ACME CA
instead. See [[security/cryptography/acme]].

## Testing a deployed configuration

Qualys' [SSL Server Test](https://www.ssllabs.com/ssltest/index.html) for anything
publicly reachable. See nginx and apache for wiring the
certificate into a web server.

## Where to go next

- [[security/cryptography/foundations]] — the signatures and key pairs this is built on
- [[security/cryptography/acme]] — getting certificates issued automatically instead
- [[security/cryptography/certificate-generation]] — a scripted lab CA
- [[security/cryptography/tls-protocol]] — how the certificate is used in a handshake
- [[security/cryptography/openssl/commands]] — the invocations, in one place

<!-- uplink -->
Part of [[security/cryptography/index|Cryptography, PKI and TLS]].
