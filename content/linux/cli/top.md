---
title: top
description: Interactive keys for top, and how to read the tasks, CPU, memory and swap summary lines
tags: [linux, cli, monitoring, performance]
type: reference
status: complete
---

# `top`

The default process monitor on almost every system. Most of its value is in the
interactive keys and in reading the four summary lines correctly.

## Interactive keys

| Key | Effect |
| --- | --- |
| `z` | Toggle colour |
| `c` | Toggle between the program name and the full command line, with its arguments |
| `Shift+P` | Sort by CPU utilisation |
| `Shift+M` | Sort by memory utilisation |
| `1` | Expand the CPU line into one line per core |
| `i` | Toggle idle processes in or out of the list |
| `m` | Cycle the memory display — text, then bar graphs |
| `t` | Cycle the CPU display |
| `k` | Kill a process by PID |
| `W` | Write the current layout to `~/.config/procps/toprc` |
| `h` | Help |
| `q` | Quit |

## Command-line options

```bash
top -U alice        # processes of a user: real, effective, saved or filesystem UID
top -u alice        # same, but matches the effective UID only
top -p 1234,5678    # only these PIDs
top -b -n 1         # batch mode, one iteration — for scripts and logs
top -d 5            # refresh every 5 seconds
```

> [!warning] Correction — `-c` does not restore the last session
> The original version of this note described `top -c` as "starts top with the last
> closed state". It does not. `-c` reverses the saved state of the **command-line
> display**, the same as pressing `c` once running. With no saved layout, that turns
> the full command line on.
>
> Persisting a layout is a separate mechanism: arrange the display how you want it,
> then press `W`. Current procps-ng writes `~/.config/procps/toprc` (older versions
> wrote `~/.toprc`, which is still read if it exists). Subsequent runs read that file
> automatically.

> [!tip] Batch mode is the one worth remembering
> `top -b -n 1` prints a single non-interactive snapshot, which is what you want from
> a script, a cron job, or when capturing state during an incident:
>
> ```bash
> top -b -n 1 | head -20 >> /tmp/load-snapshot.txt
> ```

## Reading the summary

### Tasks

The second line breaks processes down by state:

```text
Tasks: 212 total, 1 running, 211 sleep, 0 d-sleep, 0 stopped, 0 zombie
```

| State | Meaning |
| --- | --- |
| `total` | The sum across every state |
| `running` | Running, or ready to run and waiting for a CPU |
| `sleep` | Waiting for an event — the normal state for most processes |
| `d-sleep` | Uninterruptible sleep, usually waiting for disk I/O |
| `stopped` | Suspended, typically by a signal such as `SIGSTOP` |
| `zombie` | Finished, but waiting for its parent to reap the exit status |

Recent procps-ng (4.0.5 on Leap 16) splits `sleep` and `d-sleep`. Older versions
print a single `sleeping` count.

> [!note] Zombies are a bug in the parent, not the child
> A zombie holds nothing but a process table entry — it cannot be killed, because it
> is already dead. It disappears when the parent calls `wait()`. A growing zombie
> count means a parent process is not reaping its children. If the parent exits, the
> zombies are re-parented to `init` and cleaned up. See [[linux/cli/kill]].

### CPU

The third line shows what the processors are doing, as percentages:

| Field | Meaning |
| --- | --- |
| `us` | Running user processes |
| `sy` | Running kernel code |
| `ni` | Running user processes with a positive nice value (niced) |
| `id` | Idle |
| `wa` | Waiting for I/O |
| `hi` | Servicing hardware interrupts |
| `si` | Servicing software interrupts |
| `st` | Steal — virtual CPU time lost to the hypervisor |

The three worth watching:

- **`id` low** — the CPU is saturated.
- **`wa` high** — the CPU is idle while processes wait for disk I/O. Adding CPU
  will not help; the bottleneck is storage.
- **`st` high** — you are on a VM and the host is oversubscribed. Nothing inside the
  guest can fix it.

> [!warning] Correction — `wa` is disk I/O only
> The original note said `wa` covers storage *or network* I/O. It does not. `wa`
> counts idle time while a process waits for block I/O (a disk). A process that
> waits for the network is just sleeping, and its wait shows as `id`.

### Memory

```text
MiB Mem :   3898.5 total,    385.2 free,   1167.0 used,   2346.2 buff/cache
```

| Field | Meaning |
| --- | --- |
| `total` | Physical RAM installed |
| `free` | Completely unused |
| `used` | `total` minus `avail Mem` |
| `buff/cache` | Kernel buffers and page cache |

> [!note] The fields do not add up to `total`
> Since procps-ng 4.0, `used` is `total` minus `avail Mem`. Part of `buff/cache`
> cannot be freed, so it counts in `used` too, and `free + used + buff/cache` is
> more than `total`. Older versions computed `used` as `total - free - buff/cache`.

> [!important] `free` being near zero is normal and healthy
> Linux uses otherwise-idle memory for the page cache, and hands it back the moment a
> process needs it. The number that tells you whether you are short of memory is
> **`avail Mem`** on the swap line, not `free`.

> [!warning] Correction — top reports in binary units, not decimal
> The original note stated that "the top utility reports memory consumption in
> decimal", immediately after correctly explaining the difference. That contradicts
> the header, which says `MiB`. A **mebibyte** is 1024², a megabyte is 1000². `top`
> labels its output `MiB` because it is genuinely reporting mebibytes — binary units.

### Swap

```text
MiB Swap:   3898.0 total,   3898.0 free,      0.0 used.   2731.5 avail Mem
```

| Field | Meaning |
| --- | --- |
| `total` | Total swap space |
| `free` | Unused swap |
| `used` | Swap in use |
| `avail Mem` | Memory available for new processes **without swapping** |

Swapping trades memory pressure for disk latency, so sustained swap use is worth
investigating. A non-zero `used` on its own is not alarming — the kernel proactively
swaps out pages nothing has touched. Steadily *increasing* `used`, with `avail Mem`
falling, is the signal that matters. See [[linux/storage/swap]].

## Where to go next

- [[linux/cli/kill]] — acting on what you found
- [[linux/storage/swap]] — configuring swap and swappiness
- [[linux/cli/journalctl]] — the logs behind the symptom

<!-- uplink -->
Part of [[linux/cli/index|Command line tools]].
