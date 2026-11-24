---
title: YAML
description: Block scalars, chomping indicators, flow styles and data types — how YAML handles multi-line strings and whitespace
tags: [dev, yaml, syntax]
type: reference
status: complete
---

# YAML

Most of YAML is obvious. Multi-line strings are not, and that is where nearly all
YAML confusion comes from. This is the reference for that part.

Heavily used by [[automation/ansible/intro|Ansible]] and
[[kubernetes/index|Kubernetes]], so worth getting right once.

## Block scalars

Two block styles, each with three chomping variants.

| Style | Newlines inside | Name |
| --- | --- | --- |
| `\|` | **preserved** | literal |
| `>` | **folded into spaces** | folded |

### Literal — `|`

Newlines are kept exactly as written:

```yaml
description: |
  First line
  Second line

  After a blank line
```

Becomes:

```text
First line
Second line

After a blank line
```

Use it for anything where line structure matters: scripts, configuration file
contents, certificates.

### Folded — `>`

Single newlines become spaces; blank lines become a single newline:

```yaml
description: >
  This long sentence
  will be joined into
  one line.

  This is a second paragraph.
```

Becomes:

```text
This long sentence will be joined into one line.
This is a second paragraph.
```

Use it for prose you want to wrap in the source without wrapping in the value —
long descriptions, commit messages, `msg:` strings.

> [!warning] A more-indented line is not folded
> Folding stops for any line indented further than the first. That is deliberate —
> it lets you embed a code block inside folded prose — but it surprises people whose
> indentation drifted by accident.

## Chomping indicators

These control what happens to the newlines at the **end** of the block.

| Indicator | Name | Trailing newlines |
| --- | --- | --- |
| *(none)* | clip | exactly one kept |
| `-` | strip | all removed |
| `+` | keep | all kept |

So there are six combinations:

```yaml
literal_clip: |
  text
literal_strip: |-
  text
literal_keep: |+
  text

folded_clip: >
  text
folded_strip: >-
  text
folded_keep: >+
  text
```

`>-` is the one worth memorising: a long string folded to one line with **no**
trailing newline. It is what you want for a long command or a long Jinja expression:

```yaml
- name: A long command
  ansible.builtin.command: >-
    /opt/app/bin/tool --config /etc/app/config.yml
    --log-level debug --timeout 30
```

## Flow styles

For single-line values:

| Style | Escapes processed | Notes |
| --- | --- | --- |
| double quoted `"` | **yes** | the only style where `\n` and `\t` mean anything |
| single quoted `'` | no | `''` is a literal `'` |
| plain (unquoted) | no | cannot contain `: ` or ` #`, cannot start with most punctuation |

```yaml
double: "line one\nline two"     # two actual lines
single: 'line one\nline two'     # a literal backslash-n
plain:  line one                 # fine
broken: value: with colon        # INVALID
fixed:  "value: with colon"      # fine
```

## Summary table

How each style treats whitespace and special characters:

| Converted as | `>` | `\|` | plain | `"` | `'` | `>-` | `>+` | `\|-` | `\|+` |
| --- | :-: | :-: | :-: | :-: | :-: | :-: | :-: | :-: | :-: |
| Trailing space (before a line break) | keep | keep | strip | strip | strip | keep | keep | keep | keep |
| Leading space (on a later line) | newline | newline | strip | strip | strip | newline | newline | newline | newline |
| Single newline | space | `\n` | space | space | space | space | space | `\n` | `\n` |
| Double newline | `\n` | `\n\n` | `\n` | `\n` | `\n` | `\n` | `\n` | `\n\n` | `\n\n` |
| Final newline | `\n` | `\n` | — | — | — | — | `\n` | — | `\n` |
| Final double newline | — | — | — | — | — | — | `\n\n` | — | `\n\n` |
| `\n` escape honoured | no | no | no | **yes** | no | no | no | no | no |
| Line continuation with `\` | no | no | no | **yes** | no | no | no | no | no |
| `#` or `:` allowed in value | yes | yes | **no** | yes | yes | yes | yes | yes | yes |
| Can start on the key's line | no | no | **yes** | **yes** | **yes** | no | no | no | no |

## Indentation

Indentation is significant, and **tabs are forbidden** — a tab anywhere in
structural position is a parse error. This is the single most common YAML failure.

A block scalar's indentation is set by its first non-empty line, and everything more
indented than that is content:

```yaml
script: |
  #!/bin/bash
  if true; then
      echo "the extra indent here is preserved"
  fi
```

If the first line needs to be indented relative to the block, state the indentation
explicitly with a digit:

```yaml
script: |2
    this line keeps two leading spaces
```

## Data types

YAML infers types, which is occasionally unhelpful:

```yaml
string:  hello
integer: 42
float:   3.14
boolean: true
null_1:  null
null_2:  ~
null_3:              # an empty value is null
list:    [a, b, c]
dict:    {k: v}
date:    2026-08-10  # parsed as a date, not a string
```

> [!warning] The Norway problem
> YAML 1.1 treats `y`, `yes`, `on`, `true` — and `n`, `no`, `off`, `false` — as
> booleans, in lower case, Capitalised or UPPER case (`yEs` stays a string). So a
> country list containing `NO` for Norway yields `false`. Quote anything that should
> stay a string:
>
> ```yaml
> countries: ["NO", "SE", "DK"]
> version: "1.10"      # unquoted this is the float 1.1
> port: "8080"         # if the consumer wants a string
> ```
>
> YAML 1.2 restricted booleans to `true`/`false`, but many parsers — including
> PyYAML, which Ansible uses — still implement 1.1 behaviour. PyYAML leaves out only
> `y` and `n`, which stay strings.

To check what a value actually became in Ansible:

```yaml
- ansible.builtin.debug:
    msg: "{{ myvar | type_debug }}"
```

## Documents

One file can hold several documents, separated by `---`, and optionally terminated by
`...`:

```yaml
---
kind: first
---
kind: second
...
```

The leading `---` is conventional but optional for a single document. The `...`
terminator is almost never needed.

## Anchors and aliases

Reuse a block instead of repeating it — `&` defines an anchor, `*` references it, and
`<<:` merges a mapping:

```yaml
defaults: &defaults
  adapter: postgres
  host: localhost

development:
  <<: *defaults
  database: dev_db

test:
  <<: *defaults
  database: test_db
```

Useful in `docker-compose.yml` and CI configuration. Note Ansible does not resolve
anchors across separate files, only within one document.

## Linting

```bash
yamllint .
```

Worth running in CI. It catches tabs, inconsistent indentation, trailing whitespace
and duplicate keys — the last of which most parsers accept silently, keeping only the
final value.

<!-- uplink -->
Part of [[dev/index|Development]].
