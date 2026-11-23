---
title: nuclei
description: Template-driven vulnerability scanning — how templates work, running it as a CI gate against your own estate, and writing a template
tags: [security, offensive, scanning, nuclei, cicd]
type: howto
status: complete
---

# nuclei

[nuclei](https://github.com/projectdiscovery/nuclei) is a fast, template-driven
scanner. Every check is a YAML file describing a request and what a vulnerable
response looks like, and the community template repository holds thousands of them
(about 13,700 in release v10.5.1).

> [!warning] Only scan what you are authorised to scan
> nuclei sends real requests, including exploitation attempts for some templates.
> Running it against infrastructure you do not own is unauthorised testing, whatever
> your intent. Scope it explicitly, and prefer your own staging environments.

**Where this note treats it as defensive:** the most valuable use is running it
against your **own** services, continuously, as a check that a known class of
misconfiguration has not reappeared.

## Installation

```bash
go install -v github.com/projectdiscovery/nuclei/v3/cmd/nuclei@latest

# or
brew install nuclei

# or the container image (multi-arch)
docker run --rm projectdiscovery/nuclei:v3.11.1 -version
```

```bash
nuclei -update-templates
nuclei -tl | wc -l          # how many templates are installed
```

## Basic use

```bash
nuclei -u https://staging.example.com
nuclei -l targets.txt
nuclei -u https://staging.example.com -severity critical,high
nuclei -u https://staging.example.com -tags cve,exposure
nuclei -u https://staging.example.com -o results.txt -j
```

Useful selectors:

| Flag | Selects |
| --- | --- |
| `-severity` | `info`, `low`, `medium`, `high`, `critical` |
| `-tags` | `cve`, `exposure`, `misconfig`, `default-login`, `takeover` |
| `-t` | A specific template or directory |
| `-et` | Exclude templates |
| `-id` | One template by ID |

> [!important] `-tags exposure,misconfig` is the defensively useful subset
> The CVE templates test for known vulnerable versions, which your dependency scanning
> already covers better — see [[security/supply-chain/sbom-lifecycle]].
>
> The templates that find things nothing else does are the **exposure** and
> **misconfiguration** ones: an exposed `.git` directory, a debug endpoint left
> enabled, a default login, an unauthenticated metrics endpoint, a publicly readable
> bucket. Those are configuration mistakes no SAST tool or SBOM will ever surface.

## Rate limiting

```bash
nuclei -l targets.txt -rate-limit 50 -c 10 -bulk-size 25 -timeout 10
```

| Flag | Meaning | Default |
| --- | --- | --- |
| `-rate-limit` | Requests per second, globally | 150 |
| `-c` | Concurrent templates | 25 |
| `-bulk-size` | Hosts scanned in parallel per template | 25 |
| `-timeout` | Per-request timeout, in seconds | 10 |

Defaults are aggressive enough to affect a small production service. Start low.

## As a CI gate

The genuinely useful integration — scan your own deployment after it goes to staging:

```yaml
- name: Scan staging
  run: |
    nuclei -u https://staging.example.com \
      -tags exposure,misconfig,default-login \
      -severity medium,high,critical \
      -j -o nuclei.json \
      -rate-limit 30

    if [ -s nuclei.json ]; then
      echo "Findings:"; jq -r '.["template-id"] + ": " + .info.name' nuclei.json
      exit 1
    fi
```

This catches the failure mode that everything else misses: a debug flag or an exposed
endpoint that is correct in the manifest and wrong in the running system.

Pair it with the deploy-stage controls in [[security/devsecops-chain]].

## Writing a template

Templates are the reason to use nuclei rather than a fixed scanner — you can encode
checks specific to your estate.

```yaml
id: internal-debug-endpoint

info:
  name: Internal debug endpoint exposed
  author: platform-team
  severity: high
  description: The /debug/pprof endpoint should never be reachable externally.
  tags: exposure,misconfig

http:
  - method: GET
    path:
      - "{{BaseURL}}/debug/pprof/"

    matchers-condition: and
    matchers:
      - type: status
        status:
          - 200

      - type: word
        part: body
        words:
          - "Types of profiles available"
        condition: and
```

```bash
nuclei -u https://staging.example.com -t ./templates/internal-debug-endpoint.yaml
nuclei -validate -t ./templates/
```

That specific check is worth having. Go's `net/http/pprof` is enabled by importing it,
which is easy to do accidentally, and it exposes heap dumps and goroutine stacks
without authentication — see http-server-basics.

### Matcher types

| Type | Matches on |
| --- | --- |
| `status` | HTTP status code |
| `word` | Literal strings in the response |
| `regex` | A pattern |
| `binary` | Byte sequences |
| `dsl` | Expressions — `len(body) > 1000`, `duration > 5` |

`matchers-condition: and` requires all of them, which is how you avoid false
positives. A `status: 200` matcher alone will match every soft-404 on the internet.

### Extractors

Pull values out for reporting:

```yaml
    extractors:
      - type: regex
        part: body
        regex:
          - 'version"\s*:\s*"([0-9.]+)"'
        group: 1
```

## Out-of-band detection

Some vulnerability classes — blind SSRF, blind command injection, some XXE — produce
no visible response. nuclei detects them through an interaction server:

```yaml
http:
  - raw:
      - |
        GET /?url=http://{{interactsh-url}} HTTP/1.1
        Host: {{Hostname}}

    matchers:
      - type: word
        part: interactsh_protocol
        words:
          - "http"
```

By default nuclei registers with the **public** interactsh servers (`oast.pro`,
`oast.live`, `oast.fun` and others), so the target is told to call a host on the
internet. Point it at your own server with `-iserver`, or turn these templates off
with `-ni` (`-no-interactsh`):

```bash
nuclei -u https://staging.example.com -iserver https://oast.example.com -itoken "$TOKEN"
nuclei -u https://staging.example.com -ni
```

See [[security/offensive/interactsh]] for how that works and why you should run your
own server.

## Template trust

> [!danger] Templates are executable, and you are pulling them from the internet
> `nuclei-templates` is a large community repository. A template can issue arbitrary
> requests, and some perform genuine exploitation rather than detection.
>
> For scanning your own staging, that is usually acceptable. Before running anything
> against production, pin a reviewed template set rather than tracking the repository:
>
> ```bash
> git clone --depth 1 --branch v10.5.1 \
>   https://github.com/projectdiscovery/nuclei-templates reviewed-templates
> # review, delete what you do not want, then:
> nuclei -t ./reviewed-templates/ -u https://prod.example.com
> ```
>
> `-severity` and `-tags` filters do not remove the risk — read the templates you
> intend to run.

## Where to go next

- [[security/offensive/naabu]] — finding the services to scan
- [[security/offensive/interactsh]] — out-of-band detection
- [[security/devsecops-chain]] — where a scan belongs in a pipeline
- [[security/resources]] — the broader reference material

<!-- uplink -->
Part of [[security/offensive/index|Offensive tooling]].
