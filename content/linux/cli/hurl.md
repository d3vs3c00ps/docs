---
title: hurl
description: HTTP requests and assertions as plain text — chaining requests with captures, testing APIs in CI, and where it beats curl and shell scripting
tags: [linux, cli, http, testing, api]
type: howto
status: complete
---

# hurl

[Hurl](https://hurl.dev) runs HTTP requests defined in a plain-text file and asserts
on the responses. It is built on `libcurl`, so it behaves like `curl` on the wire, and
adds the two things `curl` lacks: **assertions** and **chaining**.

The problem it solves is the shell script that grows around `curl` — a pipeline of
`jq`, a variable holding a token, an `if` checking a status code, and no clear failure
message when it breaks.

## Installation

```bash
brew install hurl
sudo dnf install hurl        # Fedora
sudo zypper install hurl     # openSUSE Leap 16 ships hurl 6.0
cargo install hurl
```

This note uses hurl 8. Leap's 6.0 package lacks a few features shown below; the
notes say which. The [release page](https://github.com/Orange-OpenSource/hurl/releases)
has static Linux builds for x86_64 and aarch64.

## A first file

```hurl
GET https://api.example.com/health

HTTP 200
[Asserts]
jsonpath "$.status" == "ok"
```

```bash
hurl --test health.hurl
```

```text
Success health.hurl (1 request(s) in 84 ms)
--------------------------------------------------------------------------------
Executed files:    1
Executed requests: 1 (11.6/s)
Succeeded files:   1 (100.0%)
Failed files:      0 (0.0%)
Duration:          86 ms (0h:0m:0s:86ms)
```

## The format

```hurl
POST https://api.example.com/users
Content-Type: application/json
Authorization: Bearer {{token}}
{
  "name": "Alice",
  "email": "alice@example.com"
}

HTTP 201
[Asserts]
header "Location" matches "/users/[0-9]+"
jsonpath "$.id" exists
jsonpath "$.name" == "Alice"
jsonpath "$.roles" count == 1
duration < 500
```

The structure is: request line, headers, an optional body, then the expected response
and its assertions. It reads like the HTTP it describes, which is the main appeal.
`{{token}}` is a variable; see [[#Variables]] below.

## Chaining with captures

The feature that removes most shell glue. Capture a value from one response and use it
in the next:

```hurl
# 1. Authenticate
POST https://api.example.com/login
Content-Type: application/json
{
  "username": "test-user",
  "password": "{{password}}"
}

HTTP 200
[Captures]
token: jsonpath "$.access_token"
user_id: jsonpath "$.user.id"

# 2. Use the token
GET https://api.example.com/users/{{user_id}}
Authorization: Bearer {{token}}

HTTP 200
[Asserts]
jsonpath "$.id" == {{user_id}}

# 3. Clean up
DELETE https://api.example.com/users/{{user_id}}
Authorization: Bearer {{token}}

HTTP 204
```

One file, one command, and a clear report of which step failed and why.

> [!important] This is where it beats a shell script
> The `curl` equivalent needs `jq` to extract the token, a variable to hold it, and an
> `if` per step — and when step three fails, the error is whatever `curl` printed
> plus whatever your `set -e` did. Hurl reports the file, the line, the assertion, and
> the actual value it saw.

## Variables

```bash
hurl --variable host=staging.example.com --variable token="$TOKEN" api.hurl
hurl --variables-file staging.env api.hurl
```

```text
# staging.env
host=staging.example.com
base_path=/api/v1
```

An environment variable named `HURL_VARIABLE_<name>` becomes the variable `<name>`.
That keeps secrets off the command line. `HURL_SECRET_<name>` does the same and also
hides the value in logs and reports:

```bash
export HURL_SECRET_token="$TOKEN"
hurl api.hurl        # the file uses {{token}}
```

> [!warning] There is no `getenv` function
> Hurl has no `{{getenv "..."}}` function and rejects a file that uses one.
> Environment variables reach a file only through the `HURL_VARIABLE_` and
> `HURL_SECRET_` prefixes. Before hurl 8 the prefix was `HURL_` (`HURL_token`), which
> is what Leap's hurl 6.0 reads. `HURL_SECRET_` needs hurl 7.1 or later.

## Assertions

| Query | Asserts on |
| --- | --- |
| `status` | Status code |
| `header "Name"` | A response header |
| `jsonpath "$.field"` | JSON body |
| `xpath "//title"` | XML or HTML body |
| `regex "..."` | The raw body |
| `body` | The whole body |
| `duration` | Response time in ms |
| `certificate "Expire-Date"` | The TLS certificate |
| `cookie "name"` | A cookie, including its attributes |

Predicates: `==`, `!=`, `>`, `<`, `matches`, `contains`, `startsWith`, `endsWith`,
`exists`, `isInteger`, `isString`, `isCollection`.

Filters change the value before the predicate: `count` (the number of items),
`daysAfterNow` (days until a date), and others.

```hurl
GET https://example.com

HTTP 200
[Asserts]
certificate "Expire-Date" daysAfterNow > 30
header "Strict-Transport-Security" exists
header "X-Frame-Options" == "DENY"
duration < 1000
```

> [!tip] The certificate assertion makes hurl a monitoring tool
> `certificate "Expire-Date" daysAfterNow > 30` turns expiry checking into part of the
> same suite that checks your API works. It is the same job as the `openssl x509
> -checkend` loop in [[security/cryptography/openssl/commands]], expressed more clearly and
> alongside the rest of your checks.

## In CI

```yaml
- name: API smoke tests
  env:
    HURL_VARIABLE_host: ${{ env.STAGING_HOST }}
    HURL_SECRET_token: ${{ secrets.API_TOKEN }}
  run: |
    hurl --test \
      --report-junit results.xml \
      --connect-timeout 5 \
      --max-time 30 \
      --error-format long \
      tests/*.hurl

- uses: mikepenz/action-junit-report@v4
  if: always()
  with:
    report_paths: results.xml
```

`--report-junit` and `--report-html` produce output the rest of your CI already
understands. The token goes in through the environment, not the command line, and
as a secret it is hidden in the reports.

Retries, for a service that is still starting:

```bash
hurl --test --retry 10 --retry-interval 2000 health.hurl
```

That is a much better readiness check than `sleep 30`. `--retry-interval` takes
milliseconds; `2s` works too.

## Other useful flags

```bash
hurl --verbose api.hurl                # request and response headers
hurl --very-verbose api.hurl           # bodies too
hurl --json api.hurl | jq              # machine-readable results
hurl --insecure api.hurl               # self-signed certificates
hurl --location api.hurl               # follow redirects
hurl --error-format long api.hurl      # full response body on failure
```

`--error-format long` is worth defaulting to in CI — otherwise a failing assertion
tells you the value was wrong without showing you the response.

## Where it fits

**Good for:** API smoke tests, post-deployment verification, readiness checks, testing
an auth flow end to end, and anything currently held together by `curl` and `jq`.

**Not for:** load testing (use k6 or vegeta), browser behaviour, or anything needing
real logic — there are no loops or conditionals, deliberately.

> [!note] The absence of control flow is the design
> Hurl files stay readable because they cannot branch. When you find yourself wanting
> an `if`, that is the signal to write a test in a real language instead — see
> bdd-with-pytest or table-driven-tests. Hurl is for the
> large set of cases that genuinely are "send this, expect that".

## Where to go next

- [[security/cryptography/openssl/commands]] — deeper TLS inspection
- [[security/offensive/hetty]] — when you need to see the exact bytes

<!-- uplink -->
Part of [[linux/cli/index|Command line tools]].
