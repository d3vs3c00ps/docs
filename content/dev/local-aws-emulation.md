---
title: Local AWS emulation
description: Running AWS services on your machine for development and tests — Floci, the LocalStack situation, wiring up the SDK and Terraform, and where emulation stops being trustworthy
tags: [dev, aws, cloud, testing, docker]
type: howto
status: complete
---

# Local AWS emulation

Developing against real AWS is slow, costs money, needs credentials on every
developer's machine, and makes CI depend on someone else's uptime. An emulator gives
you S3, DynamoDB and friends on `localhost` with no account at all.

## Floci

[Floci](https://blog.stephane-robert.info/docs/cloud/aws/floci/) is an MIT-licensed
local AWS emulator. It became interesting because **LocalStack's community edition
began requiring authentication in March 2026**, which removed the previous default
answer for unauthenticated local development.

```bash
docker run -d --name floci -p 4566:4566 floci/floci:1.5.27
```

```yaml
services:
  floci:
    image: floci/floci:1.5.27@sha256:78ee619e895a01a5c0db9d1037082bf487807290583a4e78300de2b6e041a9b1
    ports:
      - "4566:4566"
```

Pinning by digest as well as tag is worth doing here for the reasons in
[[security/secure-container-images]] — a mutable tag on a service your tests depend on
is a reproducibility problem.

## Pointing tooling at it

Everything routes through one endpoint variable:

```bash
export AWS_ENDPOINT_URL=http://localhost:4566
export AWS_DEFAULT_REGION=us-east-1
export AWS_ACCESS_KEY_ID=test
export AWS_SECRET_ACCESS_KEY=test
```

```bash
aws s3 mb s3://my-bucket
aws s3 cp ./file.txt s3://my-bucket/
aws dynamodb list-tables
```

The credentials are placeholders — the emulator does not check them, but the SDKs
refuse to sign a request without something present.

### Terraform

```hcl
provider "aws" {
  region                      = "us-east-1"
  access_key                  = "test"
  secret_key                  = "test"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true
  s3_use_path_style           = true

  endpoints {
    s3       = "http://localhost:4566"
    dynamodb = "http://localhost:4566"
    lambda   = "http://localhost:4566"
  }
}
```

The `skip_*` flags matter: without them the provider checks the `test` keys against
the real AWS STS, and asks the EC2 metadata service for credentials, before it uses
your endpoints. `s3_use_path_style` sends `localhost:4566/my-bucket` instead of
`my-bucket.localhost:4566`, a host name that does not resolve.

### In CI

A GitHub Actions job:

```yaml
jobs:
  test:
    runs-on: ubuntu-latest
    services:
      floci:
        image: floci/floci:1.5.27
        ports: ["4566:4566"]
    env:
      AWS_ENDPOINT_URL: http://localhost:4566
      AWS_DEFAULT_REGION: us-east-1
      AWS_ACCESS_KEY_ID: test
      AWS_SECRET_ACCESS_KEY: test
    steps:
      - uses: actions/checkout@v4
      - run: timeout 60 sh -c 'until aws s3 ls >/dev/null 2>&1; do sleep 1; done'
      - run: go test ./...
```

Set the region too: without it every `aws` call fails, and the wait loop never ends.
The `timeout` stops it after a minute if the emulator never comes up. The wait loop is
not optional — the container accepts connections before the services
are ready, and the first test fails intermittently without it. See
[[linux/cli/hurl]] for a tidier readiness check.

## What it can and cannot do

S3 and DynamoDB are stateful and behave close enough to the real thing for most
tests. EC2, Lambda and RDS are backed by real Docker containers, which means giving
the emulator the Docker socket:

```bash
docker run -d --name floci -p 4566:4566 \
  -u root -v /var/run/docker.sock:/var/run/docker.sock \
  floci/floci:1.5.27
```

> [!danger] Mounting the Docker socket gives that container the host
> Anything that can talk to `/var/run/docker.sock` can start a privileged container
> with the host filesystem mounted. On a developer laptop that is a considered
> trade-off; on shared CI infrastructure it is a privilege escalation path into the
> runner and everything else it builds.
>
> Run the Lambda-capable configuration locally, and keep CI to the services that do
> not need it. The same reasoning as
> [[containers/containerd/hardening#the-socket-is-the-whole-security-boundary|the containerd socket]].

> [!warning] An emulator is not AWS, and the differences are where bugs live
> IAM is the big one: emulators typically accept any credentials and skip
> authorisation entirely, so a policy that is wrong in production passes every local
> test. Eventual consistency, throttling, service quotas, cross-region behaviour and
> error responses under load are all either absent or approximated.
>
> Use it for the fast inner loop and for tests of *your* logic. Keep a smaller suite
> running against real AWS in a sandbox account for anything touching IAM,
> networking, or a service's failure modes — that is where the emulator will have been
> quietly lying to you.

## The alternatives

| Option | Notes |
| --- | --- |
| **Floci** | MIT, no authentication required |
| **LocalStack** | The most complete. Community edition now requires an account; the interesting services are in the paid tiers |
| **MinIO** | S3 only, and excellent at it. The right choice if S3 is all you need |
| **DynamoDB Local** | Amazon's own, DynamoDB only. Authoritative for that service |
| **A sandbox AWS account** | Not local, but genuinely accurate. Pair with strict budget alarms |

> [!tip] Single-service emulators are more trustworthy than general ones
> MinIO implements S3 properly because that is all it does; DynamoDB Local is written
> by the team that writes DynamoDB. A general emulator covers more surface at lower
> fidelity.
>
> If your application uses two AWS services, two focused emulators will behave more
> like production than one that covers thirty.

## Where to go next

- [[security/secure-container-images]] — pinning the images this depends on
- [[linux/cli/hurl]] — readiness checks that are not `sleep 30`

## Sources

- [Floci — un émulateur AWS local](https://blog.stephane-robert.info/docs/cloud/aws/floci/)
  (in French)

<!-- uplink -->
Part of [[dev/index|Development]].
