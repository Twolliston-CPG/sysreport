# sysreport

> One command that tells you whether a Linux host is healthy: a readable report for a human, JSON
> for a script, and an exit code a monitor can act on.

Week 1, Lab 4 of the [Mastery curriculum](../../../../README.md). The assignment is in
[`labs/lab-04-bash-sysreport.md`](../../labs/lab-04-bash-sysreport.md).

**Tested on:** Arch Linux (kernel 7.2), bash 5.3, 2 vCPU / 4 GB GCP VM.

## Quick start

```bash
cd curriculum/week-01/Documentation/lab-04-bash-sysreport
./sysreport.sh                      # human-readable report
./sysreport.sh --format json | jq . # machine-readable
./sysreport.sh --threshold 1; echo "exit: $?"   # force a breach, exit 1
```

Runs in about 0.13 s (five runs: 0.127 to 0.139 s).

## Usage

```
sysreport.sh [OPTIONS]

  -f, --format FORMAT      table or json (default: table)
  -o, --output FILE        write the report to FILE instead of stdout
  -t, --threshold N        warn above N percent, 1-100 (default: 80)
  -h, --help               show this message
```

| Exit code | Meaning |
|---|---|
| 0 | everything is under the threshold |
| 1 | a check exceeded it (disk, inodes or memory) |
| 2 | the script was misused or something unexpected failed |

Keeping "over threshold" (1) apart from "the script broke" (2) is deliberate. A monitor can page on
1 and open a bug on 2.

**Requirements:** Linux with `/proc`, bash 4+ (it uses `mapfile`), and `awk`, `ps`, `df`, `ss`,
`who`, `uptime`. `jq` is required for `--format json`. `systemctl` is optional.

## What it reports

Host (name, kernel, distro, uptime, UTC time), CPU (cores, load average, load per core), memory and
swap, disk and inode usage per filesystem, processes (total, zombies, top five by CPU and memory),
listening TCP ports with their owning process, failed systemd units, and logged-in users.

Disk, inode and memory usage above the threshold are flagged `OVER` and make the exit code 1.

### Example: table

```
sysreport  2026-10-30T23:27:54Z  (threshold 80%)

== Host ==
  hostname  lab
  kernel    7.2.11-arch1-1
  distro    Arch Linux
  uptime    up 2 hours, 15 minutes

== CPU ==
  cores     2
  load      0.05  0.03  0.00   (1/5/15 min)
  pressure  0.03 per core

== Memory ==
  used      0.5 / 3.8 GiB (13.0%)   ok
  available 3.3 GiB
  swap used 0.0 GiB

== Disk ==
  mount                         size    used   use
  /                              22G    2.1G   10%  ok

== Inodes ==
  mount                        use
  /                            n/a  ok

== Processes ==
  total 181   zombies 0
  top by CPU:
        PID   CPU%   MEM%  COMMAND
       4565    5.2    0.3  sshd-session
          1    0.0    0.4  systemd
  ...

== Listening TCP ==
  0.0.0.0:22                   -
  [::]:22                      -
  (process is "-" when it belongs to another user)

== systemd ==
  no failed units

== Logins ==
  arch       pts/0    Oct 30 21:16     203.0.113.7

== Result ==
  OK  everything under 80%
```

(Trimmed. The real report also lists the other top processes and listeners. The address in the
Logins row is a documentation address, not the real one.)

### Example: JSON

```bash
./sysreport.sh -f json | jq -c '{ok, host, memory, disks, inodes}'
```

```json
{"ok":true,
 "host":{"name":"lab","kernel":"7.2.11-arch1-1","distro":"Arch Linux","uptime":"up 2 hours, 15 minutes"},
 "memory":{"total_gib":3.8,"used_gib":0.5,"available_gib":3.3,"used_pct":13.1,"swap_used_gib":0.0,"over":false},
 "disks":[{"mount":"/","size":"22G","used":"2.1G","use_pct":10,"over":false}],
 "inodes":[{"mount":"/","use_pct":null,"over":false}]}
```

`null` means "not measurable here", not zero. This root filesystem is btrfs, which has no fixed
inode table.

## What this demonstrates

- **A monitoring contract in the exit codes.** 0, 1 and 2 mean healthy, breached and broken, and
  each was tested (see below).
- **Graceful degradation.** Without `systemctl` the script warns on stderr, skips that section, and
  still exits 0. The warning never lands in the report or in piped JSON.
- **Output that is safe to pipe.** No color codes when stdout is not a terminal, when `NO_COLOR` is
  set, or when writing to `--output`. JSON is built with `jq -n`, so values are escaped correctly.
- **A clean ShellCheck run**, with one suppression that is explained where it is used.

## Key decisions

| Decision | Chose | Rejected | Why |
|---|---|---|---|
| Memory source | `/proc/meminfo`, `MemAvailable` | `free`, `MemFree` | `MemFree` ignores reclaimable cache, so "used" always looks alarming |
| JSON | `jq -n --arg/--argjson` | hand-built `printf` | Breaks the first time a value contains a quote |
| Top-five lists | `awk 'NR<=5'` | `... \| head -5` | `head` closes the pipe early, `ps` gets SIGPIPE, and `pipefail` turns that into an intermittent failure |
| Looping over `df` output | `while ... done < <(df ...)` | `df ... \| while ...` | A pipe runs the loop in a subshell, so `EXIT_CODE=1` set inside it is lost and a full disk exits 0 |
| Unexpected failures | `ERR` trap that exits 2 | letting `set -e` exit with the failing command's code | A failing `grep` would exit 1 and look like a threshold breach |
| Hostname | `uname -n` | `hostname` | `hostname` is not installed on minimal images (see "What broke") |
| Failed systemd units | listed, no effect on exit code | exit 1 on any failed unit | Exit 1 is reserved for the threshold, as specified |
| Process owners | unprivileged, shown as `-` when hidden | `sudo ss` | A monitoring script should not escalate privileges silently |

## Tested

| Test | Exit | Result |
|---|---|---|
| Normal run | 0 | full report |
| `--threshold 1` | 1 | memory and disk flagged `OVER` |
| `--bogus`, `-f xml`, `-t 0`, `-t 101`, `-t abc`, `-f` with no value | 2 | usage or a clear error on stderr, nothing on stdout |
| `NO_COLOR=1 ./sysreport.sh \| cat` | 0 | zero escape codes |
| `-o FILE` | 0 | file has no escape codes. An unwritable path exits 2 with one error line |
| Run as `nobody` | 0 | no crash, no stderr |
| `systemctl` missing from `PATH` | 0 | warning on stderr, `"available": false` in JSON |
| Full disk (8 MB ext4 loopback at 100%) | 1 | `/tmp/fulldisk 100% OVER` |
| Inode exhaustion (ext4, 32 inodes) | 1 | space shows 1% `ok`, inodes show 100% `OVER` |
| `ps` replaced by a stub that fails | 2 | error naming the line (before the trap it exited 3 with no message) |
| `shellcheck sysreport.sh` | 0 | clean |

## What broke and how I fixed it

### 1. `hostname: command not found`
**What I saw:** the first real run died with exit 127.
**What was actually wrong:** `hostname` comes from the `inetutils` package, which Arch's minimal
cloud image does not install. It is not part of the base system.
**How I found it:** the error named the command, and `command -v hostname` returned nothing.
**Prevention:** use `uname -n`, which is always present. I check for external tools when I write
a collector, not after it fails. There is still no up-front `need` check for the remaining tools.

### 2. The `Logins` row lost the IP address and split the time
**What I saw:** `arch|pts/0|Oct 30|21:16` where the last column should have been the client address.
**What was actually wrong:** I assumed `who` prints the login time as two fields (`2026-10-30 23:10`).
On this system it prints three (`Oct 30 21:16`), so everything after it shifted by one and the
address was dropped.
**How I found it:** I compared the raw `who` output with what the script printed.
**Prevention:** anchor on the optional `(host)` at the end of the line instead of counting fields
from the front. Verified against the real line and against synthetic ISO-style lines with and
without a host.

### 3. A stray bash error before my own error message
**What I saw:** `-o /nonexistent/x.txt` printed a raw `No such file or directory` from bash, then
my `ERROR: cannot write to:` line.
**What was actually wrong:** I wrote `: > "$OUTPUT" 2>/dev/null`. Bash processes redirections left
to right, so it tried to open the file before the `2>/dev/null` took effect.
**How I found it:** the unwritable-path test showed two error lines instead of one.
**Prevention:** put `2>/dev/null` first: `: 2>/dev/null > "$OUTPUT"`.

### 4. The error trap blamed the wrong command
**What I saw:** with a failing `ps`, the message read `at line 132: wc -l`, and the real exit code
was 3, not `wc`'s.
**What was actually wrong:** `$BASH_COMMAND` is the last stage of a pipeline. The failure came from
`ps` earlier in the pipeline and reached the trap through `pipefail`. The line number is right and
the command name is not.
**How I found it:** injecting a failing `ps` stub and reading the message against the code.
**Prevention:** none in code yet. Read the line number first, and treat the command name in a
pipeline failure as "somewhere on this line". With `set -E` the trap also fires once in the `$(...)`
subshell and once in the parent, so one failure prints two lines.

## Known limitations

- **Listening process names are usually `-`.** `ss` only reports owners of sockets you own, and
  services like `sshd` run as root.
- **Top-by-CPU is a lifetime average.** `ps` divides CPU time by the process's age, so a new
  process can show a high figure on an idle host. It is not a live sample.
- **The inode check does nothing on btrfs.** It reports `n/a`. It was exercised on ext4 only.
- **Only the "no `systemctl`" path was tested.** A host that has `systemctl` but is not running
  systemd, such as a container, takes a different branch (a `/run/systemd/system` check) that I
  could not reproduce.
- **A failure partway through `--output` leaves a partly written file.**
- **Linux only.** It reads `/proc`, and `mapfile` needs bash 4+, so macOS's bash 3.2 will not run it.
- **Mount points containing `|` would be split wrongly.**
- **Only tested on Arch Linux.**

## Files

| File | What it is |
|---|---|
| `sysreport.sh` | the whole tool, one file |
| `README.md` | this file |
| `LICENSE` | MIT, covering the files in this folder |
