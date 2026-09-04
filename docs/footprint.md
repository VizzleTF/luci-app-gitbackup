# Disk footprint

Measured on 2026-09-04 against a stock `openwrt/rootfs:x86_64-25.12.4` image, one package at a
time, with `du -sx /` and `apk info -s`. Package versions are the ones the 25.12.4 feeds served
on that date.

## Totals

| state | flash used | packages |
|---|---:|---:|
| stock 25.12.4 | 14.7 MiB | 136 |
| + `gitbackup` | 42.1 MiB | 146 |
| + `luci-app-gitbackup` | 42.3 MiB | 147 |

`gitbackup` is 282 KiB and `luci-app-gitbackup` is 182 KiB. The remaining 27.6 MiB is a real Git
client and its dependencies, installed once.

## What the dependencies are for

| dependency | installed | needed for |
|---|---:|---|
| `git` | 11 MiB | the Git client itself |
| `libopenssl3` | 6.3 MiB | required by `git` |
| `git-http` | 5.0 MiB | `git fetch https://`, which fails with `remote-https is not a git command` without it |
| `openssh-client` | 898 KiB | `git fetch git@…` with a known-hosts file that is honoured — see [ADR 0006](adr/0006-openssh-client-over-dbclient.md) |
| `libcurl4`, `libnghttp2` | 606 KiB | required by `git-http` |
| `openssh-keygen` | 352 KiB | generating the deploy key |
| `ca-bundle` | 177 KiB | TLS to the provider |
| `coreutils-stat` | 100 KiB | reading modes and ownership; the base image ships no `stat` |
| `jsonfilter` | 24 KiB | reading the manifest from shell |

## Reproducing the measurement

On a running router with both packages built into `dist/noarch/`:

```sh
sh tools/size-report.sh <router-id>     # writes dist/size-report.json
```

The router must be up, on 25.12.x, with neither package installed yet. CI runs this on every
push and prints the result in the job summary.
