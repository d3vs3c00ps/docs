---
title: Monitoring disk I/O
description: iostat, iotop and pidstat — reading utilisation and await, finding the process responsible, and the numbers that actually indicate a problem
tags: [linux, storage, performance, monitoring, troubleshooting]
type: howto
status: complete
---

# Monitoring disk I/O

"The server is slow" is a storage problem more often than a CPU one, and the tools
that answer it are different from the ones that measure throughput in a benchmark —
see [[linux/storage/benchmark]] for that.

## The first look: `iostat`

```bash
sudo dnf install sysstat        # provides iostat, pidstat, sar

iostat -xz 2
```

`-x` gives extended statistics, `-z` omits idle devices, and `2` repeats every two
seconds.

> [!important] Ignore the first sample
> The first output is an average **since boot**, not the current state. On a machine
> that has been up for months this is meaningless for diagnosing something happening
> now. Always take at least two samples and read the second onwards, or add `-y`
> (`iostat -xzy 2`) to leave the first one out.

```text
Device   r/s     w/s     rkB/s     wkB/s   r_await w_await  aqu-sz  %util
nvme0n1  12.00  340.00   96.00  138240.00    0.32    8.45    2.91   94.20
```

The columns worth reading, in order of usefulness:

| Column | Meaning | Concerning when |
| --- | --- | --- |
| `r_await` / `w_await` | Average time per request, **including queue time**, in ms | Above ~10 ms on SSD, ~20 ms on spinning disk |
| `aqu-sz` | Average queue depth | Consistently above 1–2 means requests are waiting |
| `%util` | Percentage of time the device had at least one request in flight | See the warning below |
| `r/s`, `w/s` | IOPS | Compare against the device's rated figure |
| `rkB/s`, `wkB/s` | Throughput | Compare against the link's capability |

> [!warning] `%util` is misleading on anything modern
> It measures the fraction of time the device was busy with **at least one** request.
> That was a good saturation signal for a single spinning disk, which could serve one
> request at a time.
>
> An NVMe drive handles dozens of requests in parallel, so it can sit at 100% `%util`
> while barely working. Conversely a RAID array can be saturated at 60%.
>
> **Use `await` and `aqu-sz` instead.** Rising latency with a growing queue is real
> saturation; high `%util` on its own is not.

## Which process is responsible

`iostat` tells you the device is busy. `iotop` tells you who is making it busy:

```bash
sudo iotop -o          # only processes actually doing I/O
sudo iotop -oPa        # aggregate totals per process, not per thread
sudo iotop -obn 5      # batch mode, 5 iterations — for scripts and logs
```

`-o` is essential; without it the display is dominated by idle processes. On
RHEL 10 and its rebuilds, `dnf install iotop` installs `iotop-c`, a rewrite in C
with the same options.

Per-process figures without an interactive UI:

```bash
pidstat -d 2                      # I/O per process
pidstat -d 2 -p $(pgrep -d, -f postgres)
```

And straight from the kernel, for one process:

```bash
cat /proc/<pid>/io
# rchar, wchar          — bytes through read()/write(), may be cache
# read_bytes, write_bytes — bytes that actually reached the device
```

> [!tip] `rchar` versus `read_bytes` separates cache hits from real I/O
> A process with a large `rchar` and a near-zero `read_bytes` is reading from the page
> cache and costing the disk nothing. The two being close means it is genuinely
> hitting storage — which is the distinction that decides whether more RAM would help.

## Pressure stall information

The modern saturation metric, and better than any of the above for alerting:

```bash
cat /proc/pressure/io
# some avg10=12.34 avg60=8.21 avg300=4.55 total=1234567
# full avg10=3.21  avg60=2.10 avg300=1.05 total=234567
```

`some` is the percentage of time at least one task was stalled waiting for I/O;
`full` is the percentage where *everything* was. `full` above a few percent means the
machine is genuinely I/O bound, not merely busy.

Per cgroup — so per container or per service:

```bash
cat /sys/fs/cgroup/system.slice/myapp.service/io.pressure
```

See [[containers/cgroups-v2]].

## Historical data

`iostat` shows now. `sar` shows what happened at 3am:

```bash
sudo systemctl enable --now sysstat sysstat-collect.timer

sar -d -p                        # today, by device name
sar -d -p -f /var/log/sa/sa15    # the 15th of this month
sar -b                           # overall I/O rates, today
```

> [!note] Live or history
> With an interval (`sar -d -p 1`), `sar` does not read the history: it samples live,
> every second, until you stop it. Without an interval it reads today's file.

Enabling `sysstat` collection on every server is cheap and repeatedly worth it — the
question "was the disk saturated during last night's incident?" is unanswerable
otherwise.

## Filesystem and layer effects

Slow I/O is often not the device:

```bash
lsblk -t                          # queue depth, scheduler, alignment
cat /sys/block/nvme0n1/queue/scheduler
cat /sys/block/nvme0n1/queue/rotational   # 0 = SSD
```

| Cause | Check |
| --- | --- |
| Wrong scheduler | `none` or `mq-deadline` for NVMe; `bfq` on a desktop spinning disk |
| No TRIM | `systemctl status fstrim.timer` — a full SSD without TRIM slows dramatically |
| Encryption overhead | `cryptsetup status` — check `no_read_workqueue`/`no_write_workqueue` on fast NVMe |
| RAID rebuild | `cat /proc/mdstat` |
| LVM snapshot | Copy-on-write makes every write two writes. See [[linux/storage/lvm]] |
| Filesystem full | Above ~90% most filesystems fragment badly |
| VM without `discard` | The host image grows forever. See qemu |

## A diagnostic sequence

```bash
# 1. Is I/O actually the problem?
cat /proc/pressure/io
uptime                                   # load high but CPU idle → suspect I/O

# 2. Which device?
iostat -xz 2 3

# 3. Which process?
sudo iotop -oPa

# 4. What is it doing?
sudo strace -c -p <pid>                  # syscall summary
sudo lsof -p <pid> | grep REG            # which files

# 5. Was it happening before?
sar -d -p -f /var/log/sa/sa$(date +%d -d yesterday)
```

Step 1 is the one people skip. A high load average with idle CPUs is the signature of
processes blocked in uninterruptible sleep — which is almost always storage:

```bash
ps -eo state,pid,comm | awk '$1 ~ /D/ {print}'
```

Processes in state `D` are waiting on I/O and cannot be killed. A growing count of
them is the clearest signal there is.

## Where to go next

- [[linux/storage/benchmark]] — measuring what a device *can* do
- [[containers/cgroups-v2]] — per-container I/O limits and pressure
- [[linux/cli/top]] — the `wa` column, and where it fits
- [[linux/storage/lvm]] — snapshots and their write amplification

## Sources

- [Tecmint — Monitor Linux disk I/O performance](https://www.tecmint.com/monitor-linux-disk-io-performance/)

<!-- uplink -->
Part of [[linux/storage/index|Storage]].
