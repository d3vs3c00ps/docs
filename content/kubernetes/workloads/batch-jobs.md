---
title: "Executing batch jobs"
description: "Jobs and CronJobs — retries, completions and parallelism, deadlines, schedules, overlap and clean-up"
tags: [kubernetes, kubectl, jobs, cronjob]
type: lab
status: complete
source: https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/batch-jobs.md
license: CC-BY-4.0
upstream_commit: 56563629
upstream_sync: manual
---

# Executing batch jobs

Each workload type fits a kind of work:

| Type | For |
| --- | --- |
| Deployment | stateless web apps, and workers that run forever |
| Pod | a one-off run you do not care about: nothing restarts it if it fails |
| Job | background work that must finish, even if it takes hours |
| CronJob | Jobs on a schedule, like the UNIX `cron` daemon and its `crontab` files |

## Creating a Job

A Job creates a Pod. If the Pod fails, the Job creates another one. It keeps trying
until a Pod succeeds, or until it reaches the Job's *backoff limit*
(`spec.backoffLimit`, 6 by default). The delay between tries grows each time.

> [!example] Hands-on
> - Create a Job that has a 50% chance of success:
>   ```bash
>   kubectl create job flipcoin --image=alpine -- sh -c 'exit $(($RANDOM%2))'
>   ```

## Our Job in action

The Job creates Pods named `flipcoin-xxxxx`, labelled `job-name=flipcoin`. When one
succeeds, the Job is complete. Each failed Pod stays, in `Error` state, so you can read
its logs.

> [!example] Hands-on
> - Check the status of the Pod(s) created by the Job:
>   ```bash
>   kubectl get pods --selector=job-name=flipcoin
>   ```
>
> - Wait for the Job to finish, then look at it:
>   ```bash
>   kubectl wait --for=condition=complete job/flipcoin --timeout=10m
>   kubectl get job flipcoin
>   ```

The wait can be long: the delays between tries add up to about ten minutes over six
retries. With no luck at all, seven Pods fail (the first try and six retries), and the Job gets
the condition `Failed` with the reason `BackoffLimitExceeded`. Then
`kubectl wait --for=condition=failed` is the one that returns.

## Completions and parallelism

`spec.completions` says how many Pods must succeed (default 1). `spec.parallelism`
says how many may run at the same time (default 1). `kubectl create job` has no option
for either: write a manifest.

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: parallel
spec:
  completions: 6
  parallelism: 3
  completionMode: Indexed
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: work
          image: alpine
          command: ["sh", "-c", "echo item $JOB_COMPLETION_INDEX; sleep 2"]
```

With `completionMode: Indexed`, each Pod gets a number from 0 to `completions - 1` in
the `JOB_COMPLETION_INDEX` variable. Use it to pick the part of the work that Pod does.

## Setting a time limit

`spec.activeDeadlineSeconds` limits how long a Job may run. It is unlimited by default.
When the Job is older than the limit, its Pods are stopped and deleted, and the Job fails
with the reason `DeadlineExceeded`, even if retries are left.

A Pod can have its own `spec.activeDeadlineSeconds` too. They have different effects:
the Job's deadline stops the whole Job, a Pod's deadline stops only that Pod, and the
Job then tries again.

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: too-slow
spec:
  activeDeadlineSeconds: 5
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: work
          image: alpine
          command: ["sleep", "60"]
```

## Cleaning up

Finished Jobs and their Pods stay until you delete them. `spec.ttlSecondsAfterFinished`
deletes them automatically, that many seconds after the Job completes or fails:

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: cleanup
spec:
  ttlSecondsAfterFinished: 30
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: work
          image: alpine
          command: ["true"]
```

Deleting a Job with `kubectl delete job` deletes its Pods too.

## Scheduling periodic background work

A CronJob creates a Job at set times. The name comes from the UNIX `crond`. Its
*schedule* has five fields, separated by spaces:

| Field | Values |
| --- | --- |
| minute | 0–59 |
| hour | 0–23 |
| day of the month | 1–31 |
| month | 1–12 |
| day of the week | 0–6, 0 = Sunday |

`*` means every value, and `/N` means every N: `*/3 * * * *` is every three minutes.
[crontab.guru](https://crontab.guru/) helps to write schedules. The schedule uses the
time zone of the controller manager, usually UTC. Set `spec.timeZone`
(`Europe/Paris`, for example) to use another one.

## Creating a Cron Job

Let's create a simple job to be executed every three minutes. Make sure the job ends:
by default, a new run starts even if the last one is still running.

> [!example] Hands-on
> - Create the Cron Job:
>   ```bash
>   kubectl create cronjob every3mins --schedule="*/3 * * * *" \
>           --image=alpine -- sleep 10
>   ```
>
> - Check the resource that was created:
>   ```bash
>   kubectl get cronjobs
>   ```

`spec.concurrencyPolicy` decides what happens when a run is due and the last one is
still running:

| Value | Effect |
| --- | --- |
| `Allow` | the default: both run |
| `Forbid` | the new run is skipped |
| `Replace` | the old run is stopped, the new one starts |

## Cron Jobs in action

At each scheduled time, the CronJob creates a Job, named after the CronJob and the
time. The Job creates a Pod and makes sure it completes, creating another one if it
fails, for example because its node fails.

> [!example] Hands-on
> - Check the Jobs that are created:
>   ```bash
>   kubectl get jobs
>   ```

It takes up to three minutes before the first Job appears. To run one now, without
waiting for the schedule:

```bash
kubectl create job every3mins-now --from=cronjob/every3mins
```

A CronJob keeps the last 3 successful Jobs and the last failed one
(`successfulJobsHistoryLimit` and `failedJobsHistoryLimit`), and deletes older ones.
`kubectl patch cronjob every3mins -p '{"spec":{"suspend":true}}'` stops new runs
without deleting anything.

---

> [!info] Adapted from container.training
> This page is derived from [`slides/k8s/batch-jobs.md`](https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/batch-jobs.md)
> in **[container.training](https://github.com/jpetazzo/container.training)** by Jérôme Petazzoni and contributors,
> used under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).
> **Changes were made**: restructured from slides into a single page, remark
> markup converted to Obsidian callouts, referenced files inlined or linked.
> Rewritten as prose, with examples for completions, deadlines and clean-up, and
> sections on concurrency, time zones and history added.

<!-- uplink -->
Part of [[kubernetes/workloads/index|Workloads]].
