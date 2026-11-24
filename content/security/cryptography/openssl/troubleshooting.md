---
title: openssl troubleshooting
description: Decoding the error messages — unable to get local issuer, key values mismatch, hostname verification, chain order, and debugging a live handshake
tags: [security, openssl, tls, troubleshooting]
type: reference
status: complete
---

# openssl troubleshooting

OpenSSL's error messages are precise and unhelpful in equal measure. This is the
translation table.

## Start by looking at the file

Most problems are a file that is not what its name implies:

```bash
head -1 mystery.crt
openssl x509 -in cert.pem -noout -text 2>&1 | head -20
```

| First line | It is |
| --- | --- |
| `-----BEGIN CERTIFICATE-----` | A PEM certificate |
| `-----BEGIN PRIVATE KEY-----` | An unencrypted PKCS#8 key |
| `-----BEGIN ENCRYPTED PRIVATE KEY-----` | An encrypted key |
| `-----BEGIN RSA PRIVATE KEY-----` | A legacy PKCS#1 key |
| `-----BEGIN CERTIFICATE REQUEST-----` | A CSR, not a certificate |
| Binary | DER or PKCS#12 |

## `unable to get local issuer certificate`

The verifier cannot find the certificate that signed this one. Almost always a
**missing intermediate**, not a missing root.

```bash
openssl s_client -connect example.com:443 -servername example.com -showcerts </dev/null
```

Count the certificates returned. A correctly configured server sends the leaf **and**
every intermediate — not the root, which the client already has.

> [!important] This is the classic "works in my browser, fails in curl" bug
> Browsers cache intermediates from previous sites and can fetch missing ones through
> the Authority Information Access (AIA) extension. `curl`, Go and Python do neither,
> and Java does it only when `com.sun.security.enableAIAcaIssuers=true` is set.
>
> So a server sending only its leaf certificate works in a browser and fails
> everywhere else. The fix is on the **server**: configure the full chain.
>
> ```bash
> cat server.crt intermediate.crt > fullchain.pem
> ```
>
> Leaf first, intermediates in order, root omitted.

Verify locally:

```bash
openssl verify -CAfile ca.crt -untrusted intermediate.crt server.crt
```

## `self-signed certificate in certificate chain`

The chain terminates in a certificate the verifier does not trust — usually an
internal CA that has not been installed:

```bash
# openSUSE Leap
sudo cp ca.crt /etc/pki/trust/anchors/internal-ca.crt
sudo update-ca-certificates

# RHEL / Rocky / Fedora
sudo cp ca.crt /etc/pki/ca-trust/source/anchors/internal-ca.crt
sudo update-ca-trust
```

Remember that Java, Node.js, Python's `certifi` and Firefox each maintain **their
own** trust stores, so the system store is often not enough.

## `key values mismatch`

The private key does not correspond to the certificate. Compare them:

```bash
openssl x509 -in cert.pem -noout -pubkey | openssl sha256
openssl pkey -in key.pem -pubout | openssl sha256
```

The two hashes must be identical. This works for every key type. Or with `diff`, which
prints nothing when they match:

```bash
diff <(openssl x509 -in cert.pem -noout -pubkey) \
     <(openssl pkey -in key.pem -pubout)
```

> [!warning] Correction
> An earlier version compared `x509 -modulus` with `pkey -noout -pubout`. Those hashes
> never match, even for the right key: `-modulus` prints `Modulus=...`, and `-noout`
> makes `pkey` print nothing.

Usual cause: a new CSR was generated with a fresh key, and the certificate that came
back was paired with the old one. Keep the key and CSR together.

## `certificate verify failed: Hostname mismatch`

The name being connected to is not in the certificate's `subjectAltName`:

```bash
openssl x509 -in cert.pem -noout -ext subjectAltName
```

> [!warning] Browsers and Go ignore the Subject CN
> A certificate with `CN=www.example.com` and no SAN fails hostname verification in
> Chrome, Firefox and Go programs. curl, Python and OpenSSL still fall back to the CN
> when there is no SAN at all. So such a certificate passes in your scripts and fails
> in the browser, which makes the bug easy to miss.
>
> This is worth checking on every certificate you issue, and is why
> [[security/cryptography/certificate-generation]] had a genuine bug.

> [!warning] Correction
> An earlier version said a CN-only certificate fails in every current client. Tested
> with curl 8.12, Python 3.12 and OpenSSL 3.5: all three accept it for the name in the
> CN. Browsers and Go do not.

Also check SNI — connecting without `-servername` to a virtual-hosted server returns
the default certificate, which naturally will not match:

```bash
openssl s_client -connect example.com:443 -servername example.com </dev/null
```

## `certificate has expired` or `is not yet valid`

```bash
openssl x509 -in cert.pem -noout -dates
date -u
```

"Not yet valid" is nearly always **clock skew** rather than a genuinely future
certificate. Check NTP on both ends — see chrony. A container with a
badly wrong clock produces this on certificates that are perfectly fine.

## `unsupported` on a PKCS#12 file

`error:0308010C:digital envelope routines::unsupported`, with `RC2-40-CBC` or `DES` in
the message. An old PKCS#12 file on OpenSSL 3: its encryption moved to the legacy
provider.

```bash
openssl pkcs12 -in old.p12 -legacy -nodes -out extracted.pem
```

See [[security/cryptography/openssl/introduction]].

The other PKCS#12 errors mean something else:

| Message | Cause |
| --- | --- |
| `Mac verify error: invalid password?` | Wrong passphrase |
| `asn1_d2i_read_bio:not enough data` | Truncated file. Check the size |

> [!warning] Correction
> An earlier version titled this section "`wrong final block length` / `unsupported`"
> and said a wrong passphrase or a truncated file give the same error. Tested with
> OpenSSL 3.5, they do not: see the table above.

## `PEM routines::no start line`

A program that loads PEM files (a web server, a TLS library) was given a file with no
`-----BEGIN` line: DER, or not a certificate at all. In OpenSSL 3, the `openssl` command
itself says `Could not find certificate from <file>` instead, and `x509` reads DER
without `-inform DER`. Check what the file really is:

```bash
openssl x509 -in cert.der -inform DER -noout -text
openssl req -in thing.pem -noout -text        # is it actually a CSR?
```

Convert DER to PEM for the program that needs PEM:

```bash
openssl x509 -in cert.der -inform DER -out cert.pem
```

> [!warning] Correction
> An earlier version said CRLF line endings (a file that went through Windows) cause
> this error. Tested with OpenSSL 3.5: a PEM file with CRLF line endings, or with a
> UTF-8 byte order mark, loads fine. To normalise the file anyway, `dos2unix cert.pem`.
> `file` does not help here: it reports `PEM certificate` with or without CRLF.

## `dh key too small` / `no shared cipher`

The two ends cannot agree on a cipher suite. Typically a modern client against an old
server, or a server configured too strictly for an old client.

```bash
openssl s_client -connect example.com:443 -tls1_2
nmap --script ssl-enum-ciphers -p 443 example.com
```

`dh key too small` specifically means DH parameters below the client's minimum. On
OpenSSL 3 at the default security level, 1024-bit parameters are refused and 2048-bit
ones work. Regenerate them:

```bash
openssl dhparam -out dhparam.pem 2048
```

Better, switch to ECDHE and stop using finite-field DH — see
[[security/cryptography/tls-protocol]].

## `signature does not verify`

For data signatures rather than certificates, this is nearly always a **padding
mismatch**. A signature made with PSS fails with the default PKCS#1 v1.5 verify. It
verifies only with the same PSS options:

```bash
openssl pkeyutl -verify -pubin -inkey pub.pem -in file.sha256 -sigfile file.sig \
  -pkeyopt digest:sha256 \
  -pkeyopt rsa_padding_mode:pss -pkeyopt rsa_pss_saltlen:-1
```

Both sides must use the same padding and the same digest. See
[[security/cryptography/openssl/signing]].

## Debugging a live handshake

```bash
# Everything, including the negotiated suite and the chain
openssl s_client -connect example.com:443 -servername example.com -showcerts </dev/null

# Protocol-level trace — verbose, but definitive
openssl s_client -connect example.com:443 -servername example.com -trace </dev/null

# Which protocol versions are accepted
for v in tls1_2 tls1_3; do
  echo -n "$v: "
  openssl s_client -connect example.com:443 -servername example.com -$v </dev/null >/dev/null 2>&1 \
    && echo OK || echo "not supported"
done
```

> [!warning] Correction
> The earlier loop tested `grep -q "Verify return code"`. `s_client` prints that line
> even when the handshake fails, so every version showed `OK`. The exit code is the
> right test: 0 when the handshake works, 1 when it fails.
>
> It also tried `tls1` and `tls1_1`. OpenSSL 3 refuses them on the client side at the
> default security level (`no protocols available`), so they always showed "not
> supported", whatever the server does. To probe a server for them, add
> `-cipher 'DEFAULT:@SECLEVEL=0'`, or use `nmap --script ssl-enum-ciphers`.

The summary block at the end of `s_client` output is the fastest read: negotiated
protocol, cipher, and `Verify return code: 0 (ok)` or the specific failure.

## A certificate that works with `curl -k` and nothing else

`-k` disables verification, so this only tells you TLS itself works and the trust
chain does not. Walk the list above in order: chain completeness, trust store,
hostname, dates. It is one of those four essentially every time.

## Where to go next

- [[security/cryptography/openssl/commands]] — the commands used here
- [[security/cryptography/tls-protocol]] — what the handshake output means
- [[security/cryptography/pki-and-x509]] — X.509 fields and PKI

<!-- uplink -->
Part of [[security/cryptography/openssl/index|OpenSSL]].
