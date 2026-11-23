---
title: "Offensive tooling"
description: "Scanners and proxies, framed for defensive use: finding what you exposed by accident, and validating that your own controls work. Only ever against systems you are authorised to test."
tags: [offensive]
type: moc
status: complete
---

<!-- generated-moc -->

# Offensive tooling

Scanners and proxies, framed for defensive use: finding what you exposed by accident, and validating that your own controls work. Only ever against systems you are authorised to test.


| Note | | What it covers |
| --- | --- | --- |
| [[security/offensive/ai-assisted-scanning\|AI-assisted scanning]] | concept | Agentic vulnerability scanners — Vigolium and Lyrie, running them against a local model, and an honest account of what changes and what does not |
| [[security/offensive/hetty\|hetty]] | how-to | An open-source HTTP intercept proxy — installing the CA, intercepting and replaying requests, and how it compares to Burp and mitmproxy |
| [[security/offensive/interactsh\|interactsh]] | how-to | Out-of-band interaction detection — finding blind SSRF and injection, why you should run your own server, and using it to test egress filtering |
| [[security/offensive/naabu\|naabu]] | how-to | Fast port scanning for attack surface inventory — SYN versus CONNECT, chaining into other tools, and using it to find what you did not know you exposed |
| [[security/offensive/nuclei\|nuclei]] | how-to | Template-driven vulnerability scanning — how templates work, running it as a CI gate against your own estate, and writing a template |

Part of [[security/index|Security]].
