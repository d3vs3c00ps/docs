---
title: hetty
description: An open-source HTTP intercept proxy — installing the CA, intercepting and replaying requests, and how it compares to Burp and mitmproxy
tags: [security, offensive, http, proxy, web]
type: howto
status: complete
---

# hetty

[hetty](https://github.com/dstotijn/hetty) is an HTTP toolkit for security research —
an intercepting proxy with a web interface, in the same category as Burp Suite and
OWASP ZAP, but small, open source and free.

It sits between a client and a server, recording and optionally modifying traffic.

> [!note] Project status
> The last release is v0.7.0, from March 2022. In July 2026 the author archived the
> old code (tag `legacy-main-2026-07-21`) before a rewrite. This note covers v0.7.0.

> [!warning] Intercept traffic only where you are authorised to
> A proxy sees everything, including credentials and session tokens. Use it against
> your own applications and test environments. Intercepting other people's traffic is
> a different activity with a different name.

**The everyday use is debugging.** Most of what makes it a security tool — seeing
exactly what a client sends, replaying a request with one header changed — is equally
what makes it good for working out why an API integration is failing.

## Installation

```bash
# Release binary (Linux x86_64; use Linux_arm64 on ARM)
curl -fsSL https://github.com/dstotijn/hetty/releases/download/v0.7.0/hetty_0.7.0_Linux_x86_64.tar.gz \
  | sudo tar -xz -C /usr/local/bin hetty

# or
brew install hettysoft/tap/hetty

# or the container image, with the database and CA in ~/.hetty
docker run -v "$HOME/.hetty:/root/.hetty" -p 8080:8080 ghcr.io/dstotijn/hetty:latest
```

> [!warning] Correction
> The note used `go install .../cmd/hetty@latest`, and `docker run` with an extra port
> 8081 and the current directory as `/root/.hetty`. The project documents package
> managers, release binaries and the image above, on port 8080 only. The image was
> built in 2022 for **arm64 only**: on an x86_64 host, use the release binary.

```bash
hetty
# HTTP server listens on :8080: proxy, admin interface and GraphQL API
# Admin interface: http://localhost:8080
```

The proxy and the interface share a port — browse to it directly and hetty serves the
UI rather than proxying.

## Configuring a client

```bash
http_proxy=http://localhost:8080 https_proxy=http://localhost:8080 \
  curl -k https://staging.example.com/api/health
```

For a browser, set the proxy in its settings or use a proxy-switcher extension. Use a
separate browser profile — proxying your normal one records everything you do.

## The CA certificate

To read HTTPS, hetty terminates TLS and re-signs with its own CA. The client must
trust that CA:

```bash
# hetty generates it on first run
ls ~/.hetty/hetty_cert.pem ~/.hetty/hetty_key.pem
```

```bash
# System trust store — openSUSE Leap
sudo cp ~/.hetty/hetty_cert.pem /etc/pki/trust/anchors/hetty.crt
sudo update-ca-certificates
```

`hetty cert install` does the same for the system store (and Firefox, with
`--firefox`), and `hetty cert uninstall` removes it.

Firefox and Java maintain separate stores and need it importing there too — see
[[security/cryptography/openssl/troubleshooting]].

> [!danger] An intercept CA in your trust store can sign anything
> Trusting the hetty CA means anything holding its private key can impersonate **any**
> website to that machine, with no warning. The key sits unencrypted in `~/.hetty/`.
>
> Install it on a dedicated testing machine or profile, never on a daily-use system,
> and remove it when finished:
>
> ```bash
> sudo rm /etc/pki/trust/anchors/hetty.crt && sudo update-ca-certificates
> ```
>
> This applies identically to Burp and mitmproxy — it is the cost of TLS
> interception, not a hetty flaw.

Applications with **certificate pinning** will refuse regardless, which is the control
working correctly.

## Using it

**Projects** scope your work — create one before capturing, or nothing is stored:

```text
Projects → New project → "staging api"
```

> [!warning] Correction
> The example name was `staging-api`. hetty 0.7 refuses it: a project name may only
> contain letters, digits and spaces.

**Proxy logs** show every request and response, with search:

```text
req.method = "POST" AND res.statusCode = "500"
req.url =~ "/api/v1/users"
res.body =~ "error"
```

A bare string (`"error"`) searches the URL, bodies and status of every log entry.
`AND`, `OR` and `NOT` are case sensitive. See the
[filter language](https://hetty.xyz/docs/appendix/filter-lang).

> [!warning] Correction
> The note showed `method:POST AND status_code:500` and `res.body:"error"`. That is
> not hetty's syntax: identifiers are `req.method`, `req.url`, `res.statusCode`,
> `res.body` and so on, with operators `=`, `!=`, `=~` (regex) and `!~`.

**Sender** replays a request with modifications — the core workflow. Find a request in
the log, send it to Sender, change a header or parameter, and resend.

That is how you test authorisation: take a request that worked as user A, change the
object ID to one belonging to user B, and see whether it is refused. Broken object
level authorisation is the most common serious API flaw, and it is found exactly this
way.

**Scope** limits what is recorded, so the log is not drowned in analytics and CDN
traffic.

## Compared with the alternatives

| | hetty | Burp Community | mitmproxy | ZAP |
| --- | --- | --- | --- | --- |
| Licence | Open source | Proprietary, free tier | Open source | Open source |
| Interface | Web | Desktop | Terminal and web | Desktop and API |
| Scripting | No | Limited without Pro | **Python, excellent** | Scripts and API |
| Active scanning | No | Pro only | No | **Yes** |
| Repeater equivalent | Yes | Yes | Yes | Yes |
| Weight | Very light | Heavy | Light | Heavy |

> [!tip] Pick by what you are actually doing
> **hetty** — you want a clean proxy and repeater with a web UI and no Java.
> **mitmproxy** — you want to script transformations; its Python addon API is the best
> of the four and the right choice for automation or CI.
> **ZAP** — you want automated active scanning, including in a pipeline.
> **Burp** — you are doing web application testing professionally; the Pro scanner and
> extension ecosystem remain ahead.
>
> For a systems engineer debugging an API, hetty or mitmproxy. For pipeline scanning,
> ZAP or [[security/offensive/nuclei|nuclei]].

## In a pipeline

hetty has no CLI-driven scanning mode, so it is not a CI tool. For automated checks
against a running application use ZAP's baseline scan or nuclei — see
[[security/devsecops-chain]].

## Non-security uses

Worth stating, because this is where most engineers will actually reach for it:

- **Debugging a client library.** Seeing the literal bytes an SDK sends settles
  arguments about whether a header is being set.
- **Understanding an undocumented API.** Drive the official client through the proxy
  and read what it does.
- **Reproducing a failing request** from a browser as a `curl` command.
- **Testing retry and timeout behaviour** by stalling or failing responses.

For the first and last of those, [[linux/cli/hurl]] and `curl -v` are often enough and
involve no CA installation.

## Where to go next

- [[security/offensive/nuclei]] — automated scanning of what you found manually
- [[linux/cli/hurl]] — scripted HTTP testing without a proxy
- [[security/cryptography/tls-protocol]] — what interception is actually doing to the handshake
- [[security/resources]] — OWASP references for what to test for

<!-- uplink -->
Part of [[security/offensive/index|Offensive tooling]].
