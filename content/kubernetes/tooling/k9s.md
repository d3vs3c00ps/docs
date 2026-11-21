---
title: "k9s"
description: "Somewhere in between CLI and GUI (or web UI), we can find the magic land of TUI"
tags: [kubernetes, tooling, k9s]
type: concept
status: complete
source: https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/k9s.md
license: CC-BY-4.0
upstream_commit: 56563629
upstream_sync: manual
---

# k9s

- Somewhere in between CLI and GUI (or web UI), we can find the magic land of TUI

  - [Text-based user interfaces](https://en.wikipedia.org/wiki/Text-based_user_interface)

  - often using libraries like [curses](https://en.wikipedia.org/wiki/Curses_%28programming_library%29) and its successors

- Some folks love them, some folks hate them, some are indifferent ...

- But it's nice to have different options!

- Let's see one particular TUI for Kubernetes: [k9s](https://k9scli.io/)

## Installing k9s

- If you are using a training cluster or the [shpod](https://github.com/jpetazzo/shpod) image, k9s is pre-installed

- Tested with k9s v0.51.0

- Otherwise, it can be installed easily:

  - with [various package managers](https://k9scli.io/topics/install/)

  - or by fetching a [binary release](https://github.com/derailed/k9s/releases)

- We don't need to set up or configure anything

  (it will use the same configuration as `kubectl` and other well-behaved clients)

- Just run `k9s` to fire it up!

## What kind do we want to see?

- Press `:` to change the type of resource to view

- Then type, for instance, `ns` or `namespace` or `nam[TAB]`, then `[ENTER]`

- Use the arrows to move down to e.g. `kube-system`, and press `[ENTER]`

- Or, type `/sys` to filter the output, and press `[ENTER]` twice

  (once to exit the filter, once to enter the namespace)

> [!warning] Correction
> The original also suggested `/kub`. That filter matches three namespaces
> (`kube-node-lease`, `kube-public`, `kube-system`), so `[ENTER]` does not
> reliably open `kube-system`: in our test with k9s 0.51 it opened `default`.

- We now see the pods in `kube-system`!

## Interacting with pods

- `l` to view logs

- `d` to describe

- `s` to get a shell (won't work if `sh` isn't available in the container image)

- `e` to edit

- `shift-f` to define port forwarding

- `ctrl-k` to kill

- `[ESC]` to get out or get back

## Quick navigation between namespaces

- On top of the screen, we should see shortcuts like this:
  ```
  <0> all
  <1> kube-system
  <2> default
  ```

- Pressing the corresponding number switches to that namespace

  (or shows resources across all namespaces with `0`)

- Locate a namespace with a copy of DockerCoins, and go there!

## Interacting with Deployments

- View Deployments (type `:` `deploy` `[ENTER]`)

- Select e.g. `worker`

- Scale it with `s`

- View its aggregated logs with `l`

## Exit

- Exit at any time with `Ctrl-C`

- k9s will "remember" where you were

  (and go back there next time you run it)

## Pros

- Very convenient to navigate through resources

  (hopping from a deployment, to its pod, to another namespace, etc.)

- Very convenient to quickly view logs of e.g. init containers

- Very convenient to get a (quasi) realtime view of resources

  (if we use `watch kubectl get` a lot, we will probably like k9s)

## Cons

- Doesn't promote automation / scripting

  (if you repeat the same things over and over, there is a scripting opportunity)

- Not all features are available

  (e.g. executing arbitrary commands in containers)

## Conclusion

Try it out, and see if it makes you more productive!

---

> [!info] Adapted from container.training
> This page is derived from [`slides/k8s/k9s.md`](https://github.com/jpetazzo/container.training/blob/565636291ec03abf1f2ab8bf6b935478e00e69a2/slides/k8s/k9s.md)
> in **[container.training](https://github.com/jpetazzo/container.training)** by Jérôme Petazzoni and contributors,
> used under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).
> **Changes were made**: restructured from slides into a single page, remark
> markup converted to Obsidian callouts, referenced files inlined or linked,
> a filter example corrected after testing with k9s 0.51.

<!-- uplink -->
Part of [[kubernetes/tooling/index|Tooling]].
