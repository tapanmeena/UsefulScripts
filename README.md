---
title: UsefulScripts
description: Homelab and workstation shell scripts for a Raspberry Pi running Immich, plus a macOS development machine
author: tapanmeena
ms.date: 2026-09-04
ms.topic: reference
keywords:
  - bash
  - raspberry pi
  - homelab
  - immich
  - automation
---

# UsefulScripts

Shell scripts for a Raspberry Pi homelab running Immich, Docker, and external USB drives, plus a macOS development machine. Each script stands alone, shares one small library, and installs as a scheduled job when that makes sense.

## Scripts

| Script | What it does | Runs on | Requires | Scheduled |
|--------|--------------|---------|----------|-----------|
| `repo-sweep` | Ranks git repositories by at-risk work: unpushed commits, stashes, uncommitted changes | Mac, Pi | git | manual |
| `space-hog` | Categorised, age-aware disk reclaim report, including APFS local snapshots | Mac, Pi | du, find | manual |
| `disk-runway` | Forecasts days until each filesystem fills, and names what grew | Mac, Pi | df, awk | hourly sample |
| `hdd-sentinel` | SMART health that alerts on change, plus the USB bus faults SMART cannot see | Pi | smartctl, jq | daily 06:00 |
| `immich-to-pixel` | Copies new Immich assets to a Pixel over adb so Google Photos backs them up | Pi | curl, jq, adb | manual |
| `rpistats` | One-screen health dashboard: CPU, memory, storage, network, Docker, Immich | Pi | none | manual |

Additional scripts land as each phase completes. See the [roadmap](#roadmap).

## Quickstart

```sh
git clone https://github.com/tapanmeena/UsefulScripts.git
cd UsefulScripts
./install.sh
./install.sh --check
```

The installer symlinks every script into `~/.local/bin` without its `.sh` extension, so `immich-to-pixel.sh` becomes the command `immich-to-pixel`. It also seeds example config files and registers the scheduled scripts as systemd user timers on Linux or launchd agents on macOS.

To install onto the Pi from your Mac:

```sh
./install.sh --target arcadia
```

That syncs the repository over rsync, then runs the installer on the remote host.

### Installer options

| Flag | Effect |
|------|--------|
| `--prefix DIR` | Symlink target directory, default `~/.local/bin` |
| `--check` | Report link, config, dependency, and timer status for every script |
| `--no-timers` | Install commands without scheduling anything |
| `--target HOST` | rsync to `HOST` and install there over SSH |
| `--uninstall` | Remove symlinks and timers, leaving configs and state untouched |
| `--dry-run` | Print the plan without changing anything |

## Conventions

Every script in this repository follows the same contract, which keeps them predictable and composable.

### Configuration

Configuration lives in `~/.config/<script-name>.conf` as plain shell variable assignments. These files hold API keys, so `load_config` refuses to read one that group or others can access. Fix a rejected file with `chmod 600`.

Values in the config file take precedence over environment variables. Every script also accepts `--config PATH` to override the location.

### Privileges

`hdd-sentinel` is the only script that needs root, because `smartctl` talks to the device directly. It uses passwordless sudo when available so it can still run from a user timer. Grant it narrowly:

```sh
echo "$USER ALL=(root) NOPASSWD: $(command -v smartctl)" | sudo tee /etc/sudoers.d/hdd-sentinel
```

### Scheduling on a headless machine

systemd user timers only run while a session exists unless lingering is enabled. On a Pi you almost certainly want:

```sh
sudo loginctl enable-linger "$USER"
```

`./install.sh --check` warns when this is missing.

### State

Persistent state lives in `~/.local/state/<script-name>/`. That includes sync cursors, metric history, lock files, and notification cooldown stamps. Removing a state directory is always safe; the script rebuilds what it needs on the next run.

### Command line

Every script supports `--help` and, where it can change anything, `--dry-run`. Output on stdout stays pipeable, while progress bars and diagnostics go to stderr.

### Exit codes

| Code | Meaning |
|------|---------|
| 0 | Healthy, or the work completed |
| 1 | Warning threshold crossed |
| 2 | Critical threshold crossed, or the script failed |
| 64 | Usage error |
| 75 | Another copy already holds the lock |

Code 75 lets cron distinguish "already running" from "the job failed", which matters once a job runs every minute.

### Notifications

Scripts report through `notify` and `notify_dedupe` in the shared library rather than calling a service directly. The backend comes from `NOTIFY_BACKEND` in the script config and defaults to `syslog`, which needs nothing installed. Push backends such as ntfy are a small addition to one function when you want them.

`notify_dedupe` suppresses repeats of the same alert key inside a cooldown window. Without it, a health check running every minute turns into noise within a day, and noisy alerts get ignored.

### Bash compatibility

macOS ships bash 3.2 and will not ship anything newer, so the shared library and every script that runs on the Mac stay compatible with it. Scripts that only ever run on the Pi may use bash 5 features freely.

Each script declares its target in the banner, and the installer reads that line to decide where to install:

```sh
# Runs on: Pi (bash 5)
# Runs on: Mac + Pi (bash 3.2 safe)
# Requires: curl jq adb
```

Constructs to avoid in bash 3.2 code: `declare -A`, `mapfile`, `readarray`, `${var,,}`, `${array[-1]}`, `&>>`, `globstar`, `readlink -f`, `date -d`, `stat -c`, and `sed -i` without an argument. The shared library provides `_realpath`, `stat_size`, `stat_mode`, `stat_mtime`, `sed_inplace`, and `date_days_ago` as portable replacements.

One further trap: expanding an empty array as `"${arr[@]}"` under `set -u` is an unbound variable error in bash 3.2. Guard the expansion with a count check.

## Shared library

`lib/common.sh` holds everything the scripts have in common. Because the installer symlinks scripts into `~/.local/bin`, `dirname "$0"` points at the symlink rather than the repository, so every script opens with this three-line resolver:

```sh
_lib="$(dirname "$0")/lib/common.sh"
[ -f "$_lib" ] || _lib="$(dirname "$(readlink "$0")")/lib/common.sh"
. "$_lib"
```

The fallback is only reached when the script runs through a symlink, and the installer always creates absolute ones.

| Group | Functions |
|-------|-----------|
| Output | `info`, `ok`, `warn`, `die`, `debug`, `section`, `kv` |
| Progress | `render_progress`, `clear_progress`, `finish_progress` |
| Config and state | `load_config`, `state_dir`, `require_tools`, `require_linux` |
| Concurrency | `with_lock`, `on_exit` |
| Alerting | `notify`, `notify_dedupe` |
| Formatting | `human_bytes`, `human_duration`, `sparkline` |
| Portability | `_realpath`, `stat_size`, `stat_mode`, `stat_mtime`, `sed_inplace`, `date_days_ago`, `is_macos`, `is_linux`, `is_utf8` |
| Data | `csv_append`, `retry` |

`with_lock` uses `flock` where it exists and falls back to an atomic `mkdir` with a PID file on macOS, which has no `flock` binary. It reaps locks left behind by killed runs and returns 75 when another copy holds the lock.

`on_exit` maintains a handler stack because bash traps overwrite each other, so the library and the script would otherwise fight over `EXIT`.

## Schedule

The installer reads this table from `install.sh` and generates the platform units.

| Script | When | Arguments |
|--------|------|-----------|
| `hdd-sentinel` | Daily at 06:00 | `--quiet` |
| `wan-watch` | Every minute | `--probe` |
| `disk-runway` | Hourly | `--sample` |
| `obsidian-daily` | Daily at 23:50 | none |

Check what is actually running with `./install.sh --check`.

## Roadmap

Foundation and the Mac-side scripts are complete. Remaining scripts arrive in phases.

| Phase | Scripts | Status |
|-------|---------|--------|
| 0 | `lib/common.sh`, `install.sh`, CI | Done |
| 1 | `repo-sweep`, `space-hog` | Done |
| 2 | `disk-runway`, `hdd-sentinel` | Done |
| 3 | `wan-watch`, `boot-story` | Pending |
| 4 | `obsidian-daily`, plus retrofitting the two original scripts onto the library | Pending |

## Development

```sh
shellcheck -x -s bash lib/common.sh *.sh
shfmt -d -i 4 -ci .
bash -n lib/common.sh *.sh
```

Continuous integration runs the same checks, plus a lint pass that rejects bash 4 constructs in files whose banner declares them bash 3.2 safe.
