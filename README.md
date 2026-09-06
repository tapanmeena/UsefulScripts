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

Shell scripts for a Raspberry Pi homelab running Immich, Docker, and external USB drives, plus a macOS development machine. Each script stands alone, shares one small library, and installs as a scheduled job when that makes sense.

## Scripts

| Script | What it does | Runs on | Requires | Scheduled |
|--------|--------------|---------|----------|-----------|
| `repo-sweep` | Ranks git repositories by at-risk work: unpushed commits, stashes, uncommitted changes | Mac, Pi | git | manual |
| `space-hog` | Categorised, age-aware disk reclaim report, including APFS local snapshots | Mac, Pi | du, find | manual |
| `disk-runway` | Forecasts days until each filesystem fills, and names what grew | Mac, Pi | df, awk | hourly sample |
| `hdd-sentinel` | SMART health that alerts on change, plus the USB bus faults SMART cannot see | Pi | smartctl, jq | daily 06:00 |
| `wan-watch` | Continuous connection quality, bufferbloat grading, and outage records | Pi | ping, awk | probe every minute |
| `boot-story` | Explains why the machine last rebooted, with ranked evidence | Pi | journalctl | manual |
| `obsidian-daily` | Writes commits, photo counts and Pi health into the Obsidian daily note | Mac, Pi | git | daily 23:50 |
| `immich-to-pixel` | Copies new Immich assets to a Pixel over adb so Google Photos backs them up | Pi | curl, jq, adb | manual |
| `rpistats` | System health plus cached storage forecasts, drive health, WAN quality, and reboot context | Pi | awk, jq | manual |

Every script supports `--help`, and every script that can change something supports `--dry-run`.

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

## Live health in rpistats

`rpistats` collects one set of readings for its human, one-line, or JSON report.
CPU usage comes from the second `top` sample, with a 0.2-second interval by
default. RAM usage is total minus available memory, taken from one `free -b`
snapshot. Missing values are shown as unavailable instead of a bare percent
sign or an invented zero. Temperature and clock readings fall back to sysfs when
`vcgencmd` does not provide them.

Container reports distinguish healthy, unhealthy, starting, stopped, and absent
containers. Running without a health check is reported explicitly. Docker access
failures are unknown, not proof that containers stopped. Services in transition
are warnings; failed or inactive configured services are critical. Empty
`SERVICES` or `IMMICH_CONTAINERS` settings disable those checks.

Power diagnostics decode the current and historical bits of `get_throttled`.
Active undervoltage or throttling is critical. Frequency caps, temperature-limit
flags, historical events, and unrecognized bits are warnings. Historical flags
mean the event occurred since boot, not that it is happening now.

Storage discovery uses `findmnt` JSON instead of assuming every drive is an
`sdX` partition. Mounted block filesystems, including NVMe and mapper devices,
are listed with their full paths. Squashfs and ISO images are omitted unless
explicitly expected. Configure expected mount paths one per line; spaces inside
a path are preserved:

```sh
EXPECTED_MOUNTS="/mnt/photos
/mnt/backup drive"
```

A missing expected mount is critical, even if its directory still exists on the
root filesystem. If the mount inventory cannot be read, the check is unknown
rather than falsely reporting a missing disk. Do not put directory paths here
unless they are actual mount points.

Temperature defaults are 60/70 degrees Celsius; root usage is 90/95 percent;
other disks and RAM are 85/95 percent. Warning and critical limits are inclusive
and must be ordered. These settings and `CPU_SAMPLE_SECONDS` are included in
[examples/rpistats.conf.example](examples/rpistats.conf.example). Standard Pi
utilities such as `top`, `free`, `findmnt`, `ip`, and `systemctl` supply the live
readings; `jq` is required for structured data handling.

### Output and health exits

```sh
rpistats
rpistats --oneline
rpistats --json
rpistats --json --check
```

`--json` emits one JSON object with `schema_version: 1`, the overall status,
`health_exit_code`, system metrics, power flags, filesystems, interfaces,
services, containers, and cached summaries. Numeric readings remain numbers;
unavailable readings are `null`. Cached entries include age, the observed
severity, and findings. JSON and one-line output are mutually exclusive.

`--check` opts into health-based exit codes: 0 for healthy, 1 for warnings or
unknown required checks, and 2 for critical findings. Configured stale or
unavailable cache sources count as warnings; unconfigured optional sources do
not. Without `--check`, a completed report still exits successfully when health
is degraded, preserving the daily-note integration. Invalid configuration or
missing required tools can still fail the command.

The existing one-line fields and `cpu`/`ram` prefixes remain compatible with
Obsidian. A compact `power` field and the cached status fields are appended;
unhealthy containers and missing expected mounts are named in the summary.

## Cached monitoring in rpistats

`rpistats` reads the latest summaries from the monitoring scripts. Opening the
dashboard does not run those scripts, send notifications, probe the network,
query SMART, or update their comparison baselines. Its existing live CPU, memory,
filesystem, service, and container checks still run.

- Storage forecasts refresh with `disk-runway --sample` or `--report` and expire
  after two hours.
- SMART and USB/I/O findings refresh with `hdd-sentinel`, including `--json`, and
  expire after 26 hours.
- The latest probe and 24-hour WAN report refresh with `wan-watch --probe` and
  expire after five minutes.
- The reboot verdict and confidence refresh with `boot-story`, including
  `--quiet`, and remain valid until the next boot by default.

The existing hourly, daily, and per-minute jobs refresh the first three
summaries. Run `boot-story` after each reboot to refresh its verdict; it is not
scheduled automatically. Run producers as the same user as `rpistats`, with the
same `XDG_STATE_HOME`. HDD checks can still use passwordless sudo internally.

Disk sampling remains silent with `--quiet` and does not send forecast
notifications. Explicit disk reports keep their existing alerts and exit codes.
A forecast needs at least three time-separated samples, and its timestamp comes
from the latest sample, not the time you opened the report.

Use [examples/rpistats.conf.example](examples/rpistats.conf.example) for the
dashboard settings. `STATUS_SOURCES` selects a space-separated subset of
`disk-runway hdd-sentinel wan-watch boot-story`; set it to an empty string to
disable all cached summaries. `RUNWAY_MAX_AGE`, `HDD_MAX_AGE`, `WAN_MAX_AGE`, and
`BOOT_MAX_AGE` are non-negative integer seconds. Zero disables age-based expiry,
but a changed boot ID always makes an older snapshot stale.

Missing state and configuration are shown as `not configured`. A configured
source without a readable, valid snapshot is `unavailable`. Missing measurements,
sleeping drives, or an indeterminate reboot cause are `unknown`, not healthy.
Stale results remain visible with their age and previous severity. Cache write
failures leave the previous snapshot intact and do not change the producer's
health exit code.

`rpistats --oneline` keeps the existing fields and ` | ` separators, then appends
compact `runway`, `hdd`, `wan`, and `boot` status fields. It does not add sample
ages or fluctuating WAN statistics to daily notes. Cached warnings do not change
the default exit code; `--check` opts into health-based exits.

Snapshots are private files at
`${XDG_STATE_HOME:-$HOME/.local/state}/<source>/status.tsv`. The shared
`write_status_snapshot NAME LEVEL [EPOCH]` helper reads tab-separated `label`,
`severity`, and `summary` rows from stdin and replaces the snapshot atomically.
Its header contains format version `1`, epoch seconds, overall severity, and boot
ID. Valid severities are `ok`, `warn`, `crit`, and `unknown`; the dashboard
validates this format and never sources it as shell code.

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

### Pipelines under set -o pipefail

Every script sets `pipefail`, which makes two common idioms unsafe:

- `producer | grep -q pattern` exits on the first match and sends SIGPIPE to the producer, so the pipeline reports failure even though the match succeeded. Count with `grep -c` instead, since that reads all input.
- `x="$(cmd 2>/dev/null || echo fallback)"` keeps whatever the failing command already wrote to stdout and appends the fallback. Capture first, then test.

Both have caused real bugs here, including a check that silently could not detect a thermal shutdown.

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
| Config and state | `load_config`, `state_dir`, `write_status_snapshot`, `require_tools`, `require_linux` |
| Concurrency | `with_lock`, `acquire_lock`, `on_exit` |
| Alerting | `notify`, `notify_dedupe` |
| Formatting | `human_bytes`, `human_duration`, `sparkline` |
| Portability | `_realpath`, `stat_size`, `stat_mode`, `stat_mtime`, `sed_inplace`, `date_days_ago`, `is_macos`, `is_linux`, `is_utf8` |
| Data | `csv_append`, `retry` |

`with_lock` uses `flock` where it exists and falls back to an atomic `mkdir` with a PID file on macOS, which has no `flock` binary. It reaps locks left behind by killed runs and returns 75 when another copy holds the lock. The command runs in the current shell, so it may be a function; `flock <file> <cmd>` cannot do that because it execs. Linear scripts that cannot wrap their work in a function use `acquire_lock` instead, which holds the lock until the process exits.

`on_exit` maintains a handler stack because bash traps overwrite each other, so the library and the script would otherwise fight over `EXIT`.

## Schedule

The installer reads this table from `install.sh` and generates the platform units.

| Script | When | Arguments |
|--------|------|-----------|
| `hdd-sentinel` | Daily at 06:00 | `--quiet` |
| `wan-watch` | Every minute | `--probe` |
| `disk-runway` | Hourly | `--sample` |
| `obsidian-daily` | Daily at 23:50 | none |

Scripts are installed only on the platform their banner declares, so the Pi gets `hdd-sentinel` and `wan-watch` while the Mac gets `obsidian-daily`.

Check what is actually running with `./install.sh --check`.

## Roadmap

All planned scripts are built and running.

| Phase | Scripts | Status |
|-------|---------|--------|
| 0 | `lib/common.sh`, `install.sh`, CI | Done |
| 1 | `repo-sweep`, `space-hog` | Done |
| 2 | `disk-runway`, `hdd-sentinel` | Done |
| 3 | `wan-watch`, `boot-story` | Done |
| 4 | `obsidian-daily`, plus retrofitting the two original scripts onto the library | Done |

## Development

```sh
shellcheck -x -s bash lib/common.sh *.sh .github/*.sh tests/*.sh
shfmt -d -i 4 -ci .
for script in lib/common.sh *.sh .github/*.sh tests/*.sh; do
  bash -n "$script"
done
for test_script in tests/*.sh; do
  bash "$test_script"
done
```

The cached monitoring tests use temporary state directories and mocked Linux,
SMART, and network commands. They do not need a Pi or access real monitoring
state. They require bash, awk, and jq.

Continuous integration runs these checks and fixture tests, plus a lint pass that
rejects bash 4 constructs in files whose banner declares them bash 3.2 safe.
