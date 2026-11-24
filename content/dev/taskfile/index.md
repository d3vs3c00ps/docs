---
title: "Task (Taskfile)"
description: "Task, a single-binary task runner configured in YAML, as a replacement for Make: from the first Taskfile to includes, caching and backup tasks."
tags: [taskfile]
type: moc
status: complete
---

<!-- generated-moc -->

# Task (Taskfile)

Task, a single-binary task runner configured in YAML, as a replacement for Make: from the first Taskfile to includes, caching and backup tasks.


| Note | | What it covers |
| --- | --- | --- |
| [[dev/taskfile/advanced\|Task reference]] | reference | Task (go-task) v3.54 reference — variables and their precedence, env and dotenv, includes, sources/generates and status, preconditions, requires, run modes, loops, prompts, defer, templating, watch and the .taskrc.yml config |
| [[dev/taskfile/backup\|Backup and restore tasks with Task]] | how-to | A Taskfile for backups — timestamped tar archives, retention, preconditions on disk space, a dry run, a restore that asks first, a Prometheus TSDB snapshot and a Grafana dashboard export |
| [[dev/taskfile/quickstart\|Task quick start]] | how-to | Install Task (go-task), write a first Taskfile.yml, list and run tasks, pass variables and arguments, and compare it with a Makefile |
| [[dev/taskfile/troubleshooting\|Task troubleshooting]] | reference | Debugging Task (go-task) v3.54 — verbose and dry runs, tasks that always or never run, the built-in shell versus bash, YAML and quoting traps, empty variables, paths in included Taskfiles, exit codes, experiments and old Taskfile versions |

Part of [[dev/index|Development]].
