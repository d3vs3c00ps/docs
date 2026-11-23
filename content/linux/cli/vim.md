---
title: vim
description: Making invisible characters visible — line numbers, whitespace, tabs and trailing spaces
tags: [linux, cli, editor, vim]
type: reference
status: complete
---

# vim

Notes on the settings that come up when a file "looks fine" but is not — mixed
indentation, trailing whitespace, missing final newline.

## Line numbers

```vim
:set number
:set nu           " abbreviation
```

Relative numbers, which make `5j` and `12dd` easy to judge:

```vim
:set relativenumber
:set nu rnu       " both — current line absolute, others relative
```

## Showing whitespace

`list` mode renders characters that are otherwise invisible, and `listchars`
controls how each is drawn.

```vim
:set list
```

Just spaces:

```vim
:set listchars+=space:␣
```

Everything at once — line ends, tabs, trailing spaces, and markers for text scrolled
off either side:

```vim
:set listchars=eol:¬,tab:>·,trail:~,extends:>,precedes:<,space:␣
:set list
```

| Item | Shows |
| --- | --- |
| `eol` | End of line |
| `tab` | A tab, as a lead character plus padding |
| `trail` | Trailing whitespace |
| `extends` | Line continues beyond the right edge |
| `precedes` | Line continues beyond the left edge |
| `space` | Every space |

> [!note] `:set list` is what actually enables it
> `listchars` only defines the glyphs. Setting it without `:set list` changes
> nothing. This is a common cause of confusion. `:set nolist` turns it back
> off.

> [!tip] Showing every space is usually too much
> `space:␣` makes ordinary prose unreadable. For day-to-day work, leave `space` out
> and keep `tab` and `trail` — those are the two that indicate real problems. Bring
> in `space` only when hunting a specific alignment bug.

To make these permanent, put them in `~/.vimrc` without the leading colon:

```vim
set number
set list
set listchars=tab:>·,trail:~,extends:>,precedes:<
```

## Highlighting trailing whitespace instead

An alternative that stands out more, and does not alter the rest of the display:

```vim
:match ErrorMsg /\s\+$/
```

And to remove it throughout the file:

```vim
:%s/\s\+$//e
```

The trailing `e` suppresses the error when there is nothing to substitute, which
keeps it safe to run from a mapping or a script.

## Where to go next

- [[linux/shell/shell-tips]] — the shell around the editor
- markdown — where trailing whitespace is actually significant

<!-- uplink -->
Part of [[linux/cli/index|Command line tools]].
