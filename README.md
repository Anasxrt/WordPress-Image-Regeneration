# regen-images.sh — Production-Ready WordPress Image Regeneration

> **Author**: Montri Udomariyah

> **Date**: 2026-04-24

> **Version**: 1.1.0

A single-file, production-ready WordPress image regeneration script with durable checkpoint/resume that survives system crashes, fatal PHP errors, SIGINT/SIGTERM interruptions, out-of-memory kills, and database connection drops without losing progress or leaving partial thumbnails.

## What's New in v1.1.0

### Security Enhancements
- **Secure temp files** — Uses `mktemp` instead of predictable PID-based names (prevents symlink attacks)
- **Input validation** — All CLI arguments are validated for type and range
- **SHA-256 integrity check** — Optional hash verification for piped execution via `REGEN_SCRIPT_HASH` env var
- **CLI-only enforcement** — PHP worker blocks execution from web context
- **State directory protection** — `.htaccess` + `index.html` deny web access to state files
- **WordPress root validation** — Verifies file ownership and resolves symlinks
- **Path traversal protection** — Limits directory search depth to 10 levels
- **Large batch confirmation** — Requires explicit "confirm" for >10,000 items
- **Restrictive umask** — All created files are owner-only (077)

### Bug Fixes
- Fixed PHP warning: `Undefined array key "REMOTE_ADDR"` in CLI context
- Fixed integrity verification message not visible in piped execution

## Quick Start

### Direct Execution

```bash
chmod +x regen-images.sh
./regen-images.sh

```

### Via curl (no download needed)

```bash
curl -sSL https://node10.cloudrambo.com/regen-images.sh | bash

```

### With SHA-256 integrity verification

```bash
REGEN_SCRIPT_HASH="89964f95d4933f7e87c44291fefb1eabd106de286b4bd4efeae7b337718683ee" \
  curl -sSL https://node10.cloudrambo.com/regen-images.sh | bash -s -- --dry-run

```

### With custom arguments

```bash
curl -sSL https://node10.cloudrambo.com/regen-images.sh | bash -s -- --batch-size=10 --pause=10

```

## Features
- **Append-only journal with **`flock` — Durable checkpoint/resume that survives crashes, OOM kills, and signal interruptions
- **Per-attachment error boundaries** — Each image is processed in its own `try/catch`; one failure cannot corrupt the batch
- **Real-time progress bar** — Shows percentage, throughput (items/sec), and ETA
- **Signal handling** — SIGINT/SIGTERM triggers graceful shutdown with state preservation
- **Heartbeat-based zombie detection** — Dead or hung processes are automatically detected and recovered
- **Memory monitoring** — Triggers garbage collection and pauses when memory usage exceeds 85%
- **Pre/post file integrity validation** — Verifies source file exists, MIME type is valid, and all generated sizes have non-zero file size
- **Structured JSON logging** — Machine-parseable logs for monitoring and alerting
- **Single file** — No dependencies beyond bash and PHP; works on any WordPress installation

## Usage

### Command-Line Options
| Flag | Description | Default |
| --- | --- | --- |
| --batch-size=N | Number of attachments per batch | 20 |
| --pause=N | Seconds to pause between batches | 5 |
| --stale-threshold=N | Seconds before a process is considered stale | 120 |
| --dry-run | Show what would be processed without regenerating | — |
| --reset | Clear all state and start from scratch | — |
| --status | Show current state summary and exit | — |
| --help | Show all options | — |

### Examples

```bash
# Regenerate all images
./regen-images.sh

# Preview what would be processed
./regen-images.sh --dry-run

# Process 10 images per batch with 10-second pauses
./regen-images.sh --batch-size=10 --pause=10

# Check current state
./regen-images.sh --status

# Reset all state and start fresh
./regen-images.sh --reset

# Custom stale threshold (5 minutes)
./regen-images.sh --stale-threshold=300

```

### Via curl

```bash
# Regenerate all images
curl -sSL https://node10.cloudrambo.com/regen-images.sh | bash

# Dry run
curl -sSL https://node10.cloudrambo.com/regen-images.sh | bash -s -- --dry-run

# Custom batch size
curl -sSL https://node10.cloudrambo.com/regen-images.sh | bash -s -- --batch-size=10 --pause=10

# Check status
curl -sSL https://node10.cloudrambo.com/regen-images.sh | bash -s -- --status

# Reset state
curl -sSL https://node10.cloudrambo.com/regen-images.sh | bash -s -- --reset

# With integrity verification
REGEN_SCRIPT_HASH="89964f95d4933f7e87c44291fefb1eabd106de286b4bd4efeae7b337718683ee" \
  curl -sSL https://node10.cloudrambo.com/regen-images.sh | bash -s -- --dry-run

```

> **Note:** `bash -s --` tells bash to read from stdin and forward everything after `--` as arguments to the script.

### Safer Alternative (Download First)

```bash
curl -sSL https://node10.cloudrambo.com/regen-images.sh -o regen-images.sh
chmod +x regen-images.sh
./regen-images.sh --dry-run    # Inspect first, then run

```

## Output

### Progress Bar

```plaintext
  [████████████████████████████████████░░░░] 75.0% 1102/1470 | ✓ ID 1750: medium, thumbnail, medium_large 3200ms | 2.5/s | ETA: 2m 28s

```

![](images\2026-04-24 - 1776989819.png)

![](images\2026-04-24 - 1776989708.png)

![](images\2026-04-24 - 1776989889.png)
Each line shows:

- **Progress bar** with fill characters
- **Percentage** complete
- **Counter** (processed / total)
- **Status icon**: ✓ success, ✗ failed, ⊘ skipped
- **Attachment ID** and generated sizes
- **Duration** in milliseconds
- **Throughput** (items/second)
- **ETA** in human-readable format

### Status Display

```plaintext
═══════════════════════════════════════════════════════
  REGENERATION STATE
═══════════════════════════════════════════════════════
  Total attachments:     1470
  Completed (success):   185
  Failed:                0
  Skipped:               0
  Pending:               1285
  Last run ID:           29aae0a1
═══════════════════════════════════════════════════════

```

## How Checkpoint/Resume Works

### The Problem with Offset-Based Checkpoints
The naive approach stores a single integer offset:

```bash
echo $offset > checkpoint    # Write offset BEFORE processing
regenerate IDs at offset     # Process batch
echo $next_offset > checkpoint  # Advance offset AFTER

```
This has three fatal flaws:

1. **Write ordering** — If the offset is written before processing, a crash means the batch is re-processed. If written after, a crash means progress is lost.
2. **Positional identity** — `--offset=10` returns different IDs if attachments are added/deleted between runs.
3. **Batch granularity** — If 3 of 5 items succeed before a crash, all 5 are re-processed.

### The Journal-Based Solution
Each attachment is tracked by its **numeric ID** (not offset). After every successful regeneration, a `success` entry is appended to the journal atomically via `flock`:

```json
{"ts":"2026-04-23T22:00:05+07:00","op":"success","run_id":"a1b2c3d4","id":101,"sizes":["thumbnail","medium","large"],"bytes":45231}

```
On restart, the journal is replayed to determine which IDs are already done. If the script crashes, is killed, or the system reboots, the next run automatically resumes from the last successful item.

### State Files

```plaintext
wp-content/uploads/regen-state/
  journal.log      # Append-only journal (source of truth) — never modified, only appended
  snapshot.json    # Compacted state cache (rebuilt from journal if corrupt)
  heartbeat.lock   # PID + timestamp of running process
  regen.log        # Human-readable structured log
  journal.lock     # Lock file for flock
  .htaccess        # Denies web access to state files
  index.html       # Prevents directory listing

```

## Failure Mode Handling
| Failure Mode | How It's Handled |
| --- | --- |
| System crash mid-batch | Journal entries are atomic per-append via flock. On restart, the journal shows exactly which IDs reached success. |
| Fatal PHP error | Caught by per-attachment try/catch(Throwable). The failed entry is appended. Processing continues. |
| SIGINT (Ctrl+C) | Signal handler appends signal entry with remaining IDs, then complete entry. Process exits cleanly. |
| SIGTERM (kill) | Same as SIGINT. |
| OOM kill | Process dies without writing. On restart, heartbeat detection finds the dead PID, recovers in-progress entries, and re-processes them. |
| DB connection drop | Retry wrapper reconnects with exponential backoff. If reconnection fails, current attachment is marked failed. |
| Concurrent runs | flock(LOCK_EX) ensures only one process can append at a time. |
| Zombie/stale process | Heartbeat timeout (default 120s) or dead PID detection triggers recovery. |
| Corrupt journal | Partial lines at end (from crash mid-write) are detected during replay and skipped. Snapshot is rebuildable. |
| Malformed image | Per-attachment error boundary catches the error, logs failed, and continues. |
| Attachment deleted | Pre-validation checks get_post() and file_exists(). If missing, logged as failed. |

## Deploying for `curl | bash` Distribution

### 1. Copy the Script to Your Web Server

```bash
cp regen-images.sh /path/to/your/web-root/regen-images.sh
chmod 644 /path/to/your/web-root/regen-images.sh

```

### 2. Compute the SHA-256 Hash

```bash
sha256sum regen-images.sh
# Output: 89964f95d4933f7e87c44291fefb1eabd106de286b4bd4efeae7b337718683ee  regen-images.sh

```

### 3. Configure Your Web Server
Ensure `.sh` files are served as plain text (not executed):

**Nginx:**

```nginx
location ~ \.sh$ {
    default_type text/plain;
}

```
**Apache (.htaccess):**

```apache
<FilesMatch "\.sh$">
    ForceType text/plain
</FilesMatch>

```

### 4. Verify

```bash
curl -sSL https://your-server.com/regen-images.sh | head -3

```
Should output:

```plaintext
#!/bin/bash
###############################################################################
# regen-images.sh — Production-Ready WordPress Image Regeneration

```

## Requirements
- **Bash** 4.0+ (for `pipefail` and associative array support)
- **PHP** 7.4+ (tested on PHP 8.1)
- **WordPress** 5.0+ (uses `wp_generate_attachment_metadata`)
- **Linux** (uses `flock`, `posix_kill`)

## Architecture
The script is a single file with two sections:

1. **Shell section** (top): Argument parsing, piped-execution detection, WordPress root detection, temp file management, signal trapping, PHP worker execution, and cleanup.
2. **PHP section** (after `__PHP_WORKER_START__`): WordPress bootstrap, `Regen_Logger` (structured JSON logging), `Regen_Journal` (append-only log with `flock`), `Regen_Processor` (batch processing with per-attachment error boundaries, signal handling, memory monitoring, progress bar).
When piped via `curl | bash`, the script detects that `$BASH_SOURCE` is empty, saves stdin to a temp file, passes the original working directory via an environment variable, and re-execs itself. This ensures WordPress root is detected from the user's current directory, not `/tmp/`.

## Changelog

### v1.1.0 (2026-04-24)
- Added secure temp file creation via `mktemp`
- Added input validation for all CLI arguments
- Added optional SHA-256 integrity verification
- Added CLI-only enforcement in PHP worker
- Added state directory protection with `.htaccess`
- Added WordPress root ownership validation
- Added path traversal protection with depth limit
- Added large batch confirmation prompt
- Added restrictive umask (077)
- Fixed `REMOTE_ADDR` warning in CLI context
- Fixed integrity verification message visibility

### v1.0.0 (2026-04-24)
- Initial release

## License
Free to use. No warranty.
