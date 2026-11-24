---
title: scalpel
description: Recovering deleted files from a disk image by file signature with scalpel
tags: [linux, cli, forensics, recovery, storage]
type: howto
status: complete
---

# Recovering files with `scalpel`

`scalpel` is a forensic file-carving tool: it scans a block device or disk image
for known file signatures and extracts anything that matches, regardless of the
filesystem metadata. That makes it useful when files have been deleted or the
filesystem itself is damaged.

> [!warning] Work on an image, never the live disk
> Always take an image first with `dd` and carve the image. Writing to a disk you
> are trying to recover from can overwrite the very data you want back.

## 1. Find the file signature

`scalpel` is far more effective when you restrict the search to specific file
types, which means you need each type's magic bytes. Read the first bytes of a
known-good file of that type:

```console
$ hexdump -C -n 32 document.pdf
00000000  25 50 44 46 2d 31 2e 35  0a 25 e4 f0 ed f8 0a 34  |%PDF-1.5.%.....4|
00000010  20 30 20 6f 62 6a 0a 3c  3c 2f 46 69 6c 74 65 72  | 0 obj.<</Filter|
```

Here the PDF signature is `25 50 44 46 2d 31` — the ASCII `%PDF-1`.

## 2. Declare the type in the configuration

Add a line to `scalpel.conf`:

```text
pdf     y    30000000    \x25\x50\x44\x46\x2d\x31    \x25\x25\x45\x4f\x46\x0a
```

The fields are:

| Field | Value | Meaning |
| --- | --- | --- |
| extension | `pdf` | extension given to carved files |
| case sensitive | `y` | match the signature case-sensitively |
| size | `30000000` | maximum size of a carved file, here 30 MB |
| header | `\x25\x50\x44\x46\x2d\x31` | the magic bytes found above, `%PDF-1` |
| footer | `\x25\x25\x45\x4f\x46\x0a` | optional end marker, `%%EOF` and a newline |

With a footer, `scalpel` stops each file at the first footer after the header. With
no footer, every file is cut at the maximum size.

> [!warning] `min:max` sizes need scalpel 1.90 or later
> Only scalpel 1.90 and later (2.0, built from source) read a minimum size. Debian and
> Ubuntu ship 1.60. It reads `1000000:30000000` as a maximum of 1 MB, with no error,
> and cuts every file at 1 MB.

> [!note] `REVERSE` for files with several footers
> A PDF that was edited in place can contain several `%%EOF` markers. Add `REVERSE`
> after the footer to search backwards from the maximum size and keep the *last*
> footer. The risk: if the next file on the disk is also a PDF, the carved file runs
> into it.

## 3. Run the search

`scalpel` is not packaged for openSUSE Leap 16 or EPEL. Debian and Ubuntu have it
(`apt install scalpel`).

```bash
scalpel -c scalpel.conf -o output_folder /dev/sda
scalpel -c scalpel.conf -o output_folder image_dd.img
```

`-o` must point at an empty or missing directory. `scalpel` refuses to write into a
directory that already holds files, to keep the evidence clean. Each type gets a
sub-directory (`pdf-0-0/`), and `audit.txt` lists every carved file with its
offset in the image.

<!-- uplink -->
Part of [[linux/cli/index|Command line tools]].
