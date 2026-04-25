#!/bin/bash
###############################################################################
# regen-images.sh — Production-Ready WordPress Image Regeneration
#
# Author  : Montri Udomariyah
# Date    : 2026-04-25
# Version : 1.2.0
#
# Single-file solution: shell orchestrator + embedded PHP worker.
#
# ─── Features ─────────────────────────────────────────────────────────────
#   - Append-only journal with flock for durable checkpoint/resume
#   - Per-attachment error boundaries (try/catch Throwable)
#   - Signal handling (SIGINT/SIGTERM) with graceful shutdown
#   - Heartbeat-based zombie/stale-process detection
#   - Memory monitoring with GC and batch pauses
#   - Pre/post file integrity validation
#   - Structured JSON logging
#   - Real-time progress bar with percentage, throughput, and ETA
#   - Failed image listing and retry via --retry-failed
#   - Supports both direct execution and curl|bash piped distribution
#
# ─── Security Enhancements (v1.1.0) ───────────────────────────────────────
#   - Secure temp file creation via mktemp (prevents symlink attacks)
#   - Input validation with type/range checks for all CLI arguments
#   - Optional SHA-256 integrity verification for piped execution
#   - CLI-only enforcement in PHP worker (blocks web execution)
#   - State directory protected with .htaccess + index.html
#   - WordPress root ownership validation
#   - Path traversal protection with depth limit and symlink resolution
#   - Large batch confirmation prompt (>10,000 items)
#   - Restrictive umask (077) for all created files
#
# ─── Direct Execution ─────────────────────────────────────────────────────
#   chmod +x regen-images.sh
#   ./regen-images.sh                          # Regenerate all images
#   ./regen-images.sh --dry-run                # Preview what would be processed
#   ./regen-images.sh --retry-failed           # List failed images from previous runs
#   ./regen-images.sh --batch-size=10 --pause=10
#   ./regen-images.sh --status                 # Show current state
#   ./regen-images.sh --reset                  # Clear all state
#   ./regen-images.sh --stale-threshold=300    # 5-minute stale threshold
#   ./regen-images.sh --help                   # Show all options
#
# ─── Piped Execution (curl | bash) ────────────────────────────────────────
#   Deploy the script to a web server and serve it as plain text.
#   Then users can run it directly from the URL:
#
#   # Regenerate all images
#   curl -sSL https://your-server.com/regen-images.sh | bash
#
#   # With custom arguments (use bash -s -- to pass args)
#   curl -sSL https://your-server.com/regen-images.sh | bash -s -- --dry-run
#   curl -sSL https://your-server.com/regen-images.sh | bash -s -- --batch-size=10 --pause=10
#   curl -sSL https://your-server.com/regen-images.sh | bash -s -- --status
#   curl -sSL https://your-server.com/regen-images.sh | bash -s -- --reset
#
#   # With SHA-256 integrity verification
#   REGEN_SCRIPT_HASH="<sha256>" curl -sSL https://your-server.com/regen-images.sh | bash -s -- --dry-run
#
#   Note: "bash -s --" tells bash to read from stdin and forward
#   everything after "--" as arguments to the script.
#
# ─── Web Server Setup for curl|bash ───────────────────────────────────────
#   1. Copy regen-images.sh to your web server's document root
#   2. Ensure .sh files are served as text/plain (not executed):
#
#      Nginx:
#        location ~ \.sh$ { default_type text/plain; }
#
#      Apache (.htaccess):
#        <FilesMatch "\.sh$"> ForceType text/plain </FilesMatch>
#
#   3. Verify: curl -sSL https://your-server.com/regen-images.sh | head -3
#      Should output: #!/bin/bash
#
# ─── Safer Alternative (download first, then run) ─────────────────────────
#   curl -sSL https://your-server.com/regen-images.sh -o regen-images.sh
#   chmod +x regen-images.sh
#   ./regen-images.sh --dry-run                # Preview what would be processed
#   ./regen-images.sh --retry-failed           # List failed images from previous runs    # Inspect first, then run
#
# ─── State Files ──────────────────────────────────────────────────────────
#   wp-content/uploads/regen-state/
#     journal.log      # Append-only journal (source of truth)
#     snapshot.json    # Compacted state cache (rebuilt from journal if corrupt)
#     heartbeat.lock   # PID + timestamp of running process
#     regen.log        # Human-readable structured log
#     journal.lock     # Lock file for flock
#     .htaccess        # Denies web access to state files
#     index.html       # Prevents directory listing
#
# ─── How Checkpoint/Resume Works ──────────────────────────────────────────
#   Each attachment is tracked by its numeric ID (not offset). After every
#   successful regeneration, a "success" entry is appended to the journal
#   atomically via flock. On restart, the journal is replayed to determine
#   which IDs are already done. If the script crashes, is killed (SIGTERM),
#   or the system reboots, the next run automatically resumes from the last
#   successful item. Stale in-progress entries from dead processes are
#   detected via heartbeat timeout and recovered.
#
# ─── Configuration Reference ──────────────────────────────────────────────
#   --batch-size=N         Items per batch (default: 20)
#   --pause=N              Seconds between batches (default: 5)
#   --stale-threshold=N    Seconds before process is stale (default: 120)
#   --dry-run              Preview without regenerating
#   --reset                Clear all state
#   --status               Show current state
#   --help                 Show all options
###############################################################################

set -euo pipefail

# ─── Security: Restrict file permissions ────────────────────────────────────
umask 077

# ─── Handle Piped Execution (curl | bash) ───────────────────────────────────
# When piped via curl | bash, the script content comes from stdin.
# We detect this by checking if $BASH_SOURCE is empty/unset AND we haven't
# already been re-executed. If piped, save stdin to temp file and re-exec.
if [[ -z "${BASH_SOURCE[0]:-}" ]] && [[ -z "${REGEN_ORIGINAL_CWD:-}" ]]; then
    # Security: Use mktemp for unpredictable temp file names (prevents symlink attacks)
    SCRIPT_FILE=$(mktemp /tmp/regen-script-XXXXXX.sh)
    cat > "$SCRIPT_FILE"
    chmod +x "$SCRIPT_FILE"

    # Security: Optional integrity verification via environment variable
    EXPECTED_HASH="${REGEN_SCRIPT_HASH:-}"
    if [[ -n "$EXPECTED_HASH" ]]; then
        actual=$(sha256sum "$SCRIPT_FILE" | awk '{print $1}')
        if [[ "$actual" != "$EXPECTED_HASH" ]]; then
            echo "ERROR: Script integrity check failed! Expected hash does not match." | tee /dev/stderr > /dev/null
            rm -f "$SCRIPT_FILE"
            exit 1
        fi
        # Use tee to ensure message reaches terminal even in piped context
        echo "Script integrity verified (SHA-256: ${actual:0:16}...)" | tee /dev/stderr > /dev/null
    fi

    REGEN_ORIGINAL_CWD="$(pwd)" exec bash "$SCRIPT_FILE" "$@"
fi

# ─── Defaults ───────────────────────────────────────────────────────────────
BATCH_SIZE=20
PAUSE=5
DRY_RUN="false"
RESET="false"
STATUS="false"
RETRY_FAILED="false"
STALE_THRESHOLD=120

# ─── Argument Parsing with Input Validation ─────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --batch-size=*)
            val="${1#*=}"
            if [[ "$val" =~ ^[0-9]+$ ]] && [ "$val" -gt 0 ] && [ "$val" -le 1000 ]; then
                BATCH_SIZE="$val"
            else
                echo "ERROR: --batch-size must be a positive integer between 1 and 1000"
                exit 1
            fi
            shift ;;
        --pause=*)
            val="${1#*=}"
            if [[ "$val" =~ ^[0-9]+$ ]] && [ "$val" -ge 0 ] && [ "$val" -le 300 ]; then
                PAUSE="$val"
            else
                echo "ERROR: --pause must be a non-negative integer between 0 and 300"
                exit 1
            fi
            shift ;;

        --dry-run)       DRY_RUN="true"; shift ;;
        --reset)         RESET="true"; shift ;;
        --status)        STATUS="true"; shift ;;
        --retry-failed)  RETRY_FAILED="true"; shift ;;
        --stale-threshold=*)
            val="${1#*=}"
            if [[ "$val" =~ ^[0-9]+$ ]] && [ "$val" -gt 0 ] && [ "$val" -le 3600 ]; then
                STALE_THRESHOLD="$val"
            else
                echo "ERROR: --stale-threshold must be a positive integer between 1 and 3600"
                exit 1
            fi
            shift ;;
        -h|--help)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --batch-size=N        Number of attachments per batch (default: 20)"
            echo "  --pause=N             Seconds to pause between batches (default: 5)"
            echo "  --dry-run             Show what would be processed without regenerating"
            echo "  --reset               Clear all state and start from scratch"
            echo "  --status              Show current state summary and exit"
            echo "  --retry-failed        List failed images (use regular run to regenerate them)"
            echo "  --stale-threshold=N   Seconds before a process is considered stale (default: 120)"
            echo "  -h, --help            Show this help message"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use --help for usage information."
            exit 1
            ;;
    esac
done

# ─── WordPress Root Detection ───────────────────────────────────────────────
# When run as a file: start from the script's directory
# When piped (curl | bash): use the original working directory passed via env var
if [[ -n "${REGEN_ORIGINAL_CWD:-}" ]]; then
    WP_ROOT="$REGEN_ORIGINAL_CWD"
elif [[ -n "${BASH_SOURCE[0]:-}" ]] && [[ -f "${BASH_SOURCE[0]:-}" ]]; then
    WP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
else
    WP_ROOT="$(pwd)"
fi

# Security: Limit search depth to prevent unexpected traversal
MAX_DEPTH=10
DEPTH=0

# If wp-load.php not found in script dir, search parent directories
while [[ ! -f "$WP_ROOT/wp-load.php" ]]; do
    WP_ROOT="$(dirname "$WP_ROOT")"
    DEPTH=$((DEPTH + 1))
    if [[ "$WP_ROOT" == "/" ]] || [[ $DEPTH -gt $MAX_DEPTH ]]; then
        echo "ERROR: Cannot find WordPress root (wp-load.php not found within $MAX_DEPTH parent directories)"
        exit 1
    fi
done

# Security: Resolve to real path (follow symlinks)
WP_ROOT="$(cd "$WP_ROOT" && pwd -P)"

# Security: Verify wp-load.php ownership
wp_owner=$(stat -c '%U' "$WP_ROOT/wp-load.php" 2>/dev/null || echo "unknown")
script_owner=$(whoami)
if [[ "$wp_owner" != "$script_owner" ]] && [[ "$wp_owner" != "www-data" ]] && [[ "$wp_owner" != "root" ]]; then
    echo "WARNING: wp-load.php owned by unexpected user: $wp_owner (expected: $script_owner, www-data, or root)"
fi

echo "WordPress root: $WP_ROOT"

# ─── Temp Worker File ───────────────────────────────────────────────────────
# Security: Use mktemp for unpredictable temp file names (prevents symlink attacks)
WORKER_FILE=$(mktemp /tmp/regen-worker-XXXXXX.php)

PHP_PID=""

cleanup() {
    local exit_code=$?
    # Forward signal to PHP child if running
    if [[ -n "$PHP_PID" ]] && kill -0 "$PHP_PID" 2>/dev/null; then
        kill -TERM "$PHP_PID" 2>/dev/null
        wait "$PHP_PID" 2>/dev/null || true
    fi
    # Clean up temp worker file
    rm -f "$WORKER_FILE"
    exit $exit_code
}

trap cleanup INT TERM EXIT

# ─── Extract Embedded PHP ──────────────────────────────────────────────────
# Everything after the __PHP_WORKER_START__ marker is the PHP worker code
awk '/^__PHP_WORKER_START__/{found=1; next} found' "$0" > "$WORKER_FILE"

if [[ ! -s "$WORKER_FILE" ]]; then
    echo "ERROR: Failed to extract PHP worker code from script"
    exit 1
fi

# ─── Execute PHP Worker ────────────────────────────────────────────────────
php "$WORKER_FILE" "$WP_ROOT" "$BATCH_SIZE" "$PAUSE" "$DRY_RUN" "$RESET" "$STATUS" "$STALE_THRESHOLD" &
PHP_PID=$!
wait $PHP_PID
EXIT_CODE=$?

exit $EXIT_CODE

__PHP_WORKER_START__
<?php
/**
 * Regen_Images_Worker — Embedded PHP worker for WordPress image regeneration.
 *
 * This file is extracted from regen-images.sh at runtime and executed via PHP CLI.
 * It bootstraps WordPress via wp-load.php and handles all regeneration logic.
 */

// ─── Security: Enforce CLI-only execution ──────────────────────────────────
if (php_sapi_name() !== 'cli') {
    http_response_code(403);
    die('This script can only be run from the command line.');
}

// ─── Receive Arguments from Shell ──────────────────────────────────────────
global $argv;

// Security: Validate argument count
if ($argc < 2) {
    fwrite(STDERR, "ERROR: Missing required arguments\n");
    exit(1);
}

$wp_root       = $argv[1] ?? getcwd();
$batch_size    = (int)($argv[2] ?? 20);
$pause         = (int)($argv[3] ?? 5);
$dry_run       = ($argv[4] ?? 'false') === 'true';
$reset         = ($argv[5] ?? 'false') === 'true';
$status        = ($argv[6] ?? 'false') === 'true';
$retry_failed  = ($argv[7] ?? 'false') === 'true';
$stale_threshold = (int)($argv[8] ?? 120);

// Security: Validate numeric arguments
if ($batch_size <= 0 || $batch_size > 1000) {
    fwrite(STDERR, "ERROR: batch_size must be between 1 and 1000\n");
    exit(1);
}
if ($pause < 0 || $pause > 300) {
    fwrite(STDERR, "ERROR: pause must be between 0 and 300\n");
    exit(1);
}
if ($stale_threshold <= 0 || $stale_threshold > 3600) {
    fwrite(STDERR, "ERROR: stale_threshold must be between 1 and 3600\n");
    exit(1);
}

// ─── Bootstrap WordPress ───────────────────────────────────────────────────
define('WP_USE_THEMES', false);

// Suppress CLI-specific warnings (e.g., REMOTE_ADDR not set in CLI context)
if (!isset($_SERVER['REMOTE_ADDR'])) {
    $_SERVER['REMOTE_ADDR'] = '127.0.0.1';
}
if (!isset($_SERVER['REQUEST_URI'])) {
    $_SERVER['REQUEST_URI'] = '';
}
if (!isset($_SERVER['HTTP_HOST'])) {
    $_SERVER['HTTP_HOST'] = 'localhost';
}

// Suppress deprecation warnings during bootstrap
error_reporting(E_ALL & ~E_DEPRECATED & ~E_USER_DEPRECATED);

$wp_load_path = rtrim($wp_root, '/') . '/wp-load.php';
if (!file_exists($wp_load_path)) {
    fwrite(STDERR, "ERROR: wp-load.php not found at: $wp_load_path\n");
    exit(1);
}
require_once $wp_load_path;

// Ensure we have WP CLI output functions available
if (!function_exists('WP_CLI')) {
    // Minimal WP_CLI compatibility for stdout with immediate flushing
    class WP_CLI {
        public static function line($msg) {
            echo $msg . "\n";
            if (ob_get_level() > 0) ob_flush();
            flush();
        }
        public static function success($msg) {
            echo "Success: $msg\n";
            if (ob_get_level() > 0) ob_flush();
            flush();
        }
        public static function warning($msg) {
            echo "Warning: $msg\n";
            if (ob_get_level() > 0) ob_flush();
            flush();
        }
        public static function error($msg) {
            echo "Error: $msg\n";
            if (ob_get_level() > 0) ob_flush();
            flush();
        }
    }
}

// Disable output buffering for real-time progress display
if (function_exists('ob_end_flush')) {
    while (ob_get_level() > 0) {
        ob_end_flush();
    }
}
if (function_exists('implicit_flush')) {
    implicit_flush(true);
}

// ─── Configuration ─────────────────────────────────────────────────────────
$state_dir = WP_CONTENT_DIR . '/uploads/regen-state';

// Security: Protect state directory from web access
if (!is_dir($state_dir)) {
    wp_mkdir_p($state_dir);
    // Add .htaccess to deny web access
    $htaccess_path = $state_dir . '/.htaccess';
    if (!file_exists($htaccess_path)) {
        file_put_contents($htaccess_path, "Order deny,allow\nDeny from all\n");
    }
    // Add empty index.html to prevent directory listing
    $index_path = $state_dir . '/index.html';
    if (!file_exists($index_path)) {
        file_put_contents($index_path, '');
    }
}

// ─── Regen_Logger — Structured JSON Logging ────────────────────────────────
class Regen_Logger {
    private $log_path;

    public function __construct(string $state_dir) {
        $this->log_path = $state_dir . '/regen.log';
    }

    public function log(string $level, string $event, array $data = []): void {
        $entry = [
            'ts'    => date('c'),
            'level' => $level,
            'event' => $event,
        ] + $data;

        $line = json_encode($entry, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE) . "\n";
        file_put_contents($this->log_path, $line, FILE_APPEND | LOCK_EX);
    }

    public function info(string $event, array $data = []): void { $this->log('info', $event, $data); }
    public function warning(string $event, array $data = []): void { $this->log('warning', $event, $data); }
    public function error(string $event, array $data = []): void { $this->log('error', $event, $data); }
    public function debug(string $event, array $data = []): void { $this->log('debug', $event, $data); }
}

// ─── Regen_Journal — Append-Only Journal with flock ────────────────────────
class Regen_Journal {
    private $lock_path;
    private $log_path;
    private $snapshot_path;
    private $logger;

    public function __construct(string $state_dir, Regen_Logger $logger) {
        $this->lock_path     = $state_dir . '/journal.lock';
        $this->log_path      = $state_dir . '/journal.log';
        $this->snapshot_path = $state_dir . '/snapshot.json';
        $this->logger        = $logger;
    }

    /**
     * Atomically append a JSON entry to the journal.
     * Uses exclusive flock to prevent concurrent corruption.
     */
    public function append(array $entry): void {
        $lockFp = fopen($this->lock_path, 'c');
        if (!$lockFp) {
            throw new RuntimeException('Cannot open lock file: ' . $this->lock_path);
        }

        if (!flock($lockFp, LOCK_EX)) {
            throw new RuntimeException('Cannot acquire exclusive lock on journal');
        }

        try {
            $logFp = fopen($this->log_path, 'a');
            if (!$logFp) {
                throw new RuntimeException('Cannot open journal file: ' . $this->log_path);
            }

            $entry['ts'] = $entry['ts'] ?? date('c');
            $line = json_encode($entry, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE) . "\n";
            $bytes = fwrite($logFp, $line);

            if ($bytes === false || $bytes !== strlen($line)) {
                throw new RuntimeException('Journal write failed (partial write)');
            }

            fflush($logFp);

            // Force OS-level flush if possible
            if (function_exists('posix_isatty')) {
                // Use fdatasync if available (PHP 8.1+)
                if (function_exists('fdatasync')) {
                    @fdatasync($logFp);
                }
            }

            fclose($logFp);
        } finally {
            flock($lockFp, LOCK_UN);
            fclose($lockFp);
        }
    }

    /**
     * Replay the journal and return the current state map.
     * Skips malformed lines (partial writes from crashes).
     */
    public function replay(): array {
        $states = [];
        $last_run_id = null;

        if (!file_exists($this->log_path)) {
            return ['states' => [], 'last_run_id' => null];
        }

        $fp = fopen($this->log_path, 'r');
        if (!$fp) {
            return ['states' => [], 'last_run_id' => null];
        }

        $line_count = 0;
        $skipped = 0;

        while (($line = fgets($fp)) !== false) {
            $line = trim($line);
            if ($line === '') continue;

            $entry = json_decode($line, true);
            if (!$entry || !isset($entry['op'])) {
                $skipped++;
                continue; // Malformed line — skip (partial write from crash)
            }

            $line_count++;
            $last_run_id = $entry['run_id'] ?? $last_run_id;

            $op = $entry['op'];
            $id = $entry['id'] ?? null;

            if ($id !== null && in_array($op, ['success', 'failed', 'skipped'], true)) {
                $states[$id] = [
                    'status' => $op,
                    'run_id' => $entry['run_id'] ?? null,
                ];
                if ($op === 'success') {
                    $states[$id]['sizes'] = $entry['sizes'] ?? [];
                    $states[$id]['bytes'] = $entry['bytes'] ?? 0;
                }
                if ($op === 'failed') {
                    $states[$id]['error'] = $entry['error'] ?? 'unknown';
                    $states[$id]['retry'] = $entry['retry'] ?? false;
                }
                if ($op === 'skipped') {
                    $states[$id]['reason'] = $entry['reason'] ?? 'already valid';
                }
            }
        }

        fclose($fp);

        if ($skipped > 0) {
            $this->logger->warning('journal_replay_skipped_lines', [
                'total_lines' => $line_count + $skipped,
                'skipped'     => $skipped,
            ]);
        }

        return ['states' => $states, 'last_run_id' => $last_run_id];
    }

    /**
     * Write a compacted snapshot atomically (temp file + rename).
     */
    public function write_snapshot(array $states, string $last_run_id): void {
        $snapshot = [
            'last_run_id'       => $last_run_id,
            'last_compacted_at' => date('c'),
            'states'            => $states,
        ];

        $tmp = $this->snapshot_path . '.tmp.' . getmypid();
        $json = json_encode($snapshot, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE);

        if (file_put_contents($tmp, $json, LOCK_EX) === false) {
            $this->logger->error('snapshot_write_failed', ['tmp' => $tmp]);
            return;
        }

        rename($tmp, $this->snapshot_path);
    }

    /**
     * Load snapshot if it exists and is valid, otherwise return null.
     */
    public function load_snapshot(): ?array {
        if (!file_exists($this->snapshot_path)) {
            return null;
        }

        $data = file_get_contents($this->snapshot_path);
        $snapshot = json_decode($data, true);

        if (!$snapshot || !isset($snapshot['states'])) {
            return null; // Corrupt snapshot
        }

        return $snapshot;
    }
}

// ─── Regen_Processor — Main Processing Engine ──────────────────────────────
class Regen_Processor {
    private $journal;
    private $logger;
    private $config;
    private $run_id;
    private $started_at;
    private $interrupted = false;
    private $processed_count = 0;
    private $success_count = 0;
    private $fail_count = 0;
    private $skip_count = 0;
    private $remaining_ids = [];
    private $last_heartbeat_time = 0;
    private $heartbeat_path;

    public function __construct(Regen_Journal $journal, Regen_Logger $logger, array $config) {
        $this->journal = $journal;
        $this->logger  = $logger;
        $this->config  = $config;
        $this->run_id  = bin2hex(random_bytes(4));
        $this->started_at = time();
        $this->heartbeat_path = $config['state_dir'] . '/heartbeat.lock';
    }

    /**
     * Register signal handlers for graceful shutdown.
     */
    public function register_signal_handlers(): void {
        if (function_exists('pcntl_signal')) {
            pcntl_signal(SIGINT, [$this, 'handle_signal']);
            pcntl_signal(SIGTERM, [$this, 'handle_signal']);
        }
    }

    /**
     * Dispatch pending signals (call this in loops).
     */
    public function dispatch_signals(): void {
        if (function_exists('pcntl_signal_dispatch')) {
            pcntl_signal_dispatch();
        }
    }

    /**
     * Handle SIGINT/SIGTERM — graceful shutdown.
     */
    public function handle_signal(int $signo): void {
        $this->interrupted = true;
        $signal_name = $signo === SIGINT ? 'SIGINT' : 'SIGTERM';

        $this->logger->info('signal_received', [
            'signal'          => $signal_name,
            'processed_count' => $this->processed_count,
            'remaining_count' => count($this->remaining_ids),
        ]);

        // Log remaining IDs for resume
        $this->journal->append([
            'op'              => 'signal',
            'run_id'          => $this->run_id,
            'signal'          => $signal_name,
            'processed_count' => $this->processed_count,
            'remaining_ids'   => array_slice($this->remaining_ids, 0, 100), // Cap at 100
        ]);

        // Write final heartbeat
        $this->pulse(0, 'shutting_down');

        // Complete the run
        $this->journal->append([
            'op'     => 'complete',
            'run_id' => $this->run_id,
            'total'  => $this->processed_count + count($this->remaining_ids),
            'ok'     => $this->success_count,
            'fail'   => $this->fail_count,
            'skip'   => $this->skip_count,
            'note'   => "Interrupted by {$signal_name}",
        ]);

        WP_CLI::warning("Received {$signal_name}. Processed {$this->processed_count} items ({$this->success_count} ok, {$this->fail_count} failed, {$this->skip_count} skipped). Remaining IDs will be processed on next run.");

        exit(0);
    }

    /**
     * Update heartbeat file.
     */
    public function pulse(int $attachment_id, string $status = 'running'): void {
        $data = [
            'pid'                   => getmypid(),
            'run_id'                => $this->run_id,
            'last_heartbeat'        => time(),
            'current_attachment_id' => $attachment_id,
            'status'                => $status,
            'started_at'            => $this->started_at,
            'memory_bytes'          => memory_get_usage(true),
            'processed_count'       => $this->processed_count,
        ];

        file_put_contents($this->heartbeat_path, json_encode($data, JSON_UNESCAPED_SLASHES), LOCK_EX);
        $this->last_heartbeat_time = time();
    }

    /**
     * Detect if a previous process is stale (dead or heartbeat timeout).
     */
    public function detect_stale_process(): ?array {
        if (!file_exists($this->heartbeat_path)) {
            return null;
        }

        $data = json_decode(file_get_contents($this->heartbeat_path), true);
        if (!$data) {
            return null; // Corrupt heartbeat file
        }

        $threshold = $this->config['stale_threshold'] ?? 120;
        $seconds_since = time() - ($data['last_heartbeat'] ?? 0);

        // Check if PID is still alive
        $pid_alive = false;
        if (function_exists('posix_kill') && isset($data['pid'])) {
            $pid_alive = posix_kill((int)$data['pid'], 0);
        }

        if (!$pid_alive || $seconds_since > $threshold) {
            return [
                'stale'           => true,
                'pid'             => $data['pid'] ?? 0,
                'run_id'          => $data['run_id'] ?? null,
                'last_heartbeat'  => $data['last_heartbeat'] ?? 0,
                'current_id'      => $data['current_attachment_id'] ?? 0,
                'stale_seconds'   => $seconds_since,
                'reason'          => $pid_alive ? 'heartbeat_timeout' : 'process_dead',
            ];
        }

        return null;
    }

    /**
     * Recover stale in-progress entries from a previous run.
     */
    public function recover_stale_entries(string $stale_run_id): void {
        $replay = $this->journal->replay();
        $states = $replay['states'];

        // Find IDs that were 'start'ed in the stale run but never completed
        // We need to scan the journal for start entries from the stale run
        $log_path = $this->config['state_dir'] . '/journal.log';
        $stale_in_progress = [];

        if (file_exists($log_path)) {
            $fp = fopen($log_path, 'r');
            if ($fp) {
                while (($line = fgets($fp)) !== false) {
                    $entry = json_decode(trim($line), true);
                    if (!$entry) continue;

                    if (($entry['run_id'] ?? '') !== $stale_run_id) continue;

                    if ($entry['op'] === 'start') {
                        $id = $entry['id'] ?? null;
                        if ($id !== null) {
                            $stale_in_progress[$id] = true;
                        }
                    }

                    if (in_array($entry['op'] ?? '', ['success', 'failed', 'skipped'])) {
                        $id = $entry['id'] ?? null;
                        if ($id !== null) {
                            unset($stale_in_progress[$id]);
                        }
                    }
                }
                fclose($fp);
            }
        }

        foreach ($stale_in_progress as $id => $_) {
            $this->journal->append([
                'op'              => 'recovered',
                'run_id'          => $this->run_id,
                'id'              => $id,
                'original_run_id' => $stale_run_id,
                'stale_seconds'   => time() - ($stale['last_heartbeat'] ?? 0),
            ]);

            $this->logger->info('entry_recovered', [
                'id'              => $id,
                'original_run_id' => $stale_run_id,
            ]);
        }

        if (!empty($stale_in_progress)) {
            WP_CLI::line("Recovered " . count($stale_in_progress) . " in-progress entries from stale run {$stale_run_id}");
        }
    }

    /**
     * Get all attachment IDs from the database, paginated.
     */
    public function get_all_attachment_ids(int $page_size = 500): array {
        global $wpdb;

        $all_ids = [];
        $offset = 0;

        while (true) {
            $ids = $wpdb->get_col($wpdb->prepare(
                "SELECT ID FROM {$wpdb->posts}
                 WHERE post_type = 'attachment'
                 AND post_status = 'inherit'
                 AND post_mime_type IN (%s, %s, %s, %s, %s)
                 ORDER BY ID ASC
                 LIMIT %d OFFSET %d",
                'image/jpeg', 'image/png', 'image/gif', 'image/webp', 'image/avif',
                $page_size,
                $offset
            ));

            if (empty($ids)) {
                break;
            }

            foreach ($ids as $id) {
                $all_ids[] = (int) $id;
            }

            $offset += $page_size;
        }

        return $all_ids;
    }

    /**
     * Get registered image sizes from WordPress.
     */
    public function get_registered_sizes(): array {
        global $_wp_additional_image_sizes;

        $sizes = [];

        // Default sizes
        foreach (['thumbnail', 'medium', 'medium_large', 'large'] as $size) {
            $sizes[$size] = [
                'width'  => get_option("{$size}_size_w"),
                'height' => get_option("{$size}_size_h"),
            ];
        }

        // Additional sizes from themes/plugins
        if (is_array($_wp_additional_image_sizes)) {
            foreach ($_wp_additional_image_sizes as $size => $data) {
                $sizes[$size] = $data;
            }
        }

        return $sizes;
    }

    /**
     * Bootstrap: load state, detect stale processes, enqueue pending IDs.
     */
    public function bootstrap(): array {
        // Ensure state directory exists
        if (!is_dir($this->config['state_dir'])) {
            wp_mkdir_p($this->config['state_dir']);
        }

        // Step 1: Check for stale process
        $stale = $this->detect_stale_process();
        if ($stale) {
            $this->logger->info('stale_process_detected', $stale);
            WP_CLI::line("Stale process detected (PID {$stale['pid']}, {$stale['stale_seconds']}s ago, reason: {$stale['reason']})");
            $this->recover_stale_entries($stale['run_id']);
        }

        // Step 2: Load current state from journal replay
        $replay = $this->journal->replay();
        $states = $replay['states'];

        // Step 3: Query all attachment IDs
        WP_CLI::line("Querying attachment IDs from database...");
        $all_ids = $this->get_all_attachment_ids();
        WP_CLI::line("Found " . count($all_ids) . " image attachments in database.");

        // Step 4: Filter out already-successful IDs
        $pending_ids = [];
        foreach ($all_ids as $id) {
            if (!isset($states[$id]) || $states[$id]['status'] !== 'success') {
                $pending_ids[] = $id;
            }
        }

        $already_done = count($all_ids) - count($pending_ids);
        WP_CLI::line("Already completed: {$already_done}");
        WP_CLI::line("Pending: " . count($pending_ids));

        // Step 5: Init new run
        $this->journal->append([
            'op'     => 'init',
            'run_id' => $this->run_id,
            'pid'    => getmypid(),
        ]);

        // Step 6: Enqueue pending IDs
        foreach ($pending_ids as $id) {
            $this->journal->append([
                'op'     => 'enqueue',
                'run_id' => $this->run_id,
                'id'     => $id,
            ]);
        }

        // Step 7: Write initial heartbeat
        $this->pulse(0, 'bootstrapped');

        return $pending_ids;
    }

    /**
     * Process a single attachment with full error boundary.
     */
    public function process_attachment(int $attachment_id): array {
        $result = [
            'id'     => $attachment_id,
            'status' => 'unknown',
            'error'  => null,
        ];

        $start_time = microtime(true);

        try {
            // ─── Pre-validation ─────────────────────────────────────────
            $attachment = get_post($attachment_id);
            if (!$attachment || $attachment->post_type !== 'attachment') {
                throw new RuntimeException("Attachment ID {$attachment_id} not found in database");
            }

            $file_path = get_attached_file($attachment_id);
            if (!$file_path || !file_exists($file_path)) {
                throw new RuntimeException("Source file missing for attachment {$attachment_id}");
            }

            // Validate it's actually an image
            $mime_type = wp_check_filetype($file_path);
            $allowed_mimes = ['image/jpeg', 'image/png', 'image/gif', 'image/webp', 'image/avif'];
            if (!in_array($mime_type['type'], $allowed_mimes, true)) {
                throw new RuntimeException("File is not a supported image type: {$mime_type['type']}");
            }

            // Record start with heartbeat
            $this->journal->append([
                'op'        => 'start',
                'run_id'    => $this->run_id,
                'id'        => $attachment_id,
                'heartbeat' => time(),
            ]);
            $this->pulse($attachment_id, 'processing');

            // ─── Regeneration ───────────────────────────────────────────
            if (!function_exists('wp_generate_attachment_metadata')) {
                require_once ABSPATH . 'wp-admin/includes/image.php';
            }

            $metadata = wp_generate_attachment_metadata($attachment_id, $file_path);

            if (empty($metadata) || !is_array($metadata)) {
                throw new RuntimeException("wp_generate_attachment_metadata returned empty/invalid result");
            }

            // ─── Post-validation ────────────────────────────────────────
            // Verify generated sizes exist and have non-zero size
            $base_path = dirname($file_path);
            $generated_sizes = [];

            if (isset($metadata['sizes']) && is_array($metadata['sizes'])) {
                foreach ($metadata['sizes'] as $size_name => $size_info) {
                    $size_path = $base_path . '/' . $size_info['file'];

                    if (!file_exists($size_path)) {
                        throw new RuntimeException("Generated file missing: {$size_info['file']}");
                    }

                    $size_bytes = filesize($size_path);
                    if ($size_bytes === 0 || $size_bytes === false) {
                        throw new RuntimeException("Generated file is zero bytes: {$size_info['file']}");
                    }

                    $generated_sizes[] = $size_name;
                }
            }

            // Update attachment metadata
            wp_update_attachment_metadata($attachment_id, $metadata);

            // Calculate total output size
            $total_bytes = filesize($file_path) ?: 0;
            if (isset($metadata['sizes'])) {
                foreach ($metadata['sizes'] as $size_info) {
                    $size_path = $base_path . '/' . $size_info['file'];
                    $total_bytes += filesize($size_path) ?: 0;
                }
            }

            // Record success
            $this->journal->append([
                'op'     => 'success',
                'run_id' => $this->run_id,
                'id'     => $attachment_id,
                'sizes'  => $generated_sizes,
                'bytes'  => $total_bytes,
            ]);

            $duration_ms = round((microtime(true) - $start_time) * 1000);

            $result['status']    = 'success';
            $result['sizes']     = $generated_sizes;
            $result['bytes']     = $total_bytes;
            $result['duration_ms'] = $duration_ms;

        } catch (Throwable $e) {
            $duration_ms = round((microtime(true) - $start_time) * 1000);
            $error_msg = $e->getMessage();

            // Truncate very long error messages
            if (strlen($error_msg) > 500) {
                $error_msg = substr($error_msg, 0, 500) . '...';
            }

            // Record failure
            $this->journal->append([
                'op'     => 'failed',
                'run_id' => $this->run_id,
                'id'     => $attachment_id,
                'error'  => $error_msg,
                'retry'  => false,
            ]);

            $result['status']    = 'failed';
            $result['error']     = $error_msg;
            $result['duration_ms'] = $duration_ms;
        }

        return $result;
    }

    /**
     * Check memory usage and trigger GC if needed.
     */
    public function check_memory_usage(): void {
        $limit = $this->memory_limit_bytes();
        if ($limit <= 0) return; // Unlimited

        $current = memory_get_usage(true);
        $threshold = $limit * 0.85;

        if ($current > $threshold) {
            $pct = round($current / $limit * 100, 1);
            $this->logger->warning('memory_high', [
                'current_mb'  => round($current / 1024 / 1024, 1),
                'limit_mb'    => round($limit / 1024 / 1024, 1),
                'percentage'  => $pct,
            ]);

            gc_collect_cycles();

            $after = memory_get_usage(true);
            $this->logger->info('memory_after_gc', [
                'current_mb' => round($after / 1024 / 1024, 1),
                'freed_mb'   => round(($current - $after) / 1024 / 1024, 1),
            ]);
        }
    }

    private function memory_limit_bytes(): int {
        $limit = ini_get('memory_limit');
        if ($limit === '-1') return -1;
        $unit = strtolower(substr(trim($limit), -1));
        $value = (int) trim($limit);
        switch ($unit) {
            case 'g': return $value * 1024 * 1024 * 1024;
            case 'm': return $value * 1024 * 1024;
            case 'k': return $value * 1024;
            default:  return $value;
        }
    }

    /**
     * Pause between batches, checking for signals.
     */
    private function pause_between_batches(int $seconds): void {
        WP_CLI::line("  Pausing {$seconds}s between batches...");
        for ($i = $seconds; $i > 0; $i--) {
            if ($this->interrupted) break;
            sleep(1);
            $this->dispatch_signals();
        }
    }

    /**
     * Render a progress bar string.
     */
    private function progress_bar(int $done, int $total, int $width = 40): string {
        if ($total <= 0) $total = 1;
        $pct = $done / $total;
        $filled = (int) round($width * $pct);
        $empty = $width - $filled;
        $bar = str_repeat('█', $filled) . str_repeat('░', $empty);
        $percent = number_format($pct * 100, 1);
        return "[{$bar}] {$percent}%";
    }

    /**
     * Format seconds into H:M:S.
     */
    private function format_duration(int $seconds): string {
        $h = intdiv($seconds, 3600);
        $m = intdiv($seconds % 3600, 60);
        $s = $seconds % 60;
        if ($h > 0) return sprintf('%dh %dm %ds', $h, $m, $s);
        if ($m > 0) return sprintf('%dm %ds', $m, $s);
        return sprintf('%ds', $s);
    }

    /**
     * Main run loop.
     */
    public function run(array $attachment_ids): void {
        $this->register_signal_handlers();

        $batch_size = $this->config['batch_size'] ?? 20;
        $pause_seconds = $this->config['pause'] ?? 5;
        $this->remaining_ids = $attachment_ids;

        $batches = array_chunk($attachment_ids, $batch_size);
        $total_batches = count($batches);
        $total_items = count($attachment_ids);
        $run_start = microtime(true);

        WP_CLI::line("");
        WP_CLI::line("═══════════════════════════════════════════════════════");
        WP_CLI::line("  REGENERATION STARTED");
        WP_CLI::line("═══════════════════════════════════════════════════════");
        WP_CLI::line("  Run ID:          {$this->run_id}");
        WP_CLI::line("  Total items:     {$total_items}");
        WP_CLI::line("  Batch size:      {$batch_size}");
        WP_CLI::line("  Total batches:   {$total_batches}");
        WP_CLI::line("═══════════════════════════════════════════════════════");
        WP_CLI::line("");

        foreach ($batches as $batch_index => $batch) {
            if ($this->interrupted) break;

            $batch_num = $batch_index + 1;

            foreach ($batch as $idx => $id) {
                if ($this->interrupted) break;

                // Update remaining
                $this->remaining_ids = array_slice($batch, $idx);

                $result = $this->process_attachment($id);
                $this->processed_count++;

                // Calculate progress stats
                $elapsed = microtime(true) - $run_start;
                $items_per_sec = $elapsed > 0 ? $this->processed_count / $elapsed : 0;
                $remaining = $total_items - $this->processed_count;
                $eta_seconds = $items_per_sec > 0 ? (int) ($remaining / $items_per_sec) : 0;
                $progress_bar = $this->progress_bar($this->processed_count, $total_items);

                // Build status line
                $sizes_str = '';
                if ($result['status'] === 'success' && !empty($result['sizes'])) {
                    $sizes_str = implode(', ', $result['sizes']);
                }
                $error_str = '';
                if ($result['status'] === 'failed' && !empty($result['error'])) {
                    $error_str = $result['error'];
                }
                $dur_str = isset($result['duration_ms']) ? "{$result['duration_ms']}ms" : '';

                // Print progress line
                $icon = $result['status'] === 'success' ? '✓' : ($result['status'] === 'failed' ? '✗' : '⊘');
                $detail = $sizes_str ?: ($error_str ?: 'skipped');
                WP_CLI::line("  {$progress_bar} {$this->processed_count}/{$total_items} | {$icon} ID {$id}: {$detail} {$dur_str} | {$items_per_sec}/s | ETA: " . $this->format_duration($eta_seconds));

                // Update counters
                switch ($result['status']) {
                    case 'success': $this->success_count++; break;
                    case 'failed':  $this->fail_count++; break;
                    case 'skipped': $this->skip_count++; break;
                }

                // Log structured
                $this->logger->info('attachment_' . $result['status'], [
                    'id'     => $id,
                    'status' => $result['status'],
                ] + ($result['error'] ? ['error' => $result['error']] : [])
                  + (!empty($result['sizes']) ? ['sizes' => $result['sizes']] : [])
                  + (isset($result['duration_ms']) ? ['duration_ms' => $result['duration_ms']] : []));

                // Check memory
                $this->check_memory_usage();

                // Dispatch signals
                $this->dispatch_signals();
            }

            // Pause between batches
            if ($batch_index < $total_batches - 1 && !$this->interrupted) {
                $this->pause_between_batches($pause_seconds);
            }
        }

        $run_duration = (int) round(microtime(true) - $run_start);

        // Final summary
        WP_CLI::line("");
        WP_CLI::line("═══════════════════════════════════════════════════════");
        WP_CLI::line("  RUN COMPLETE — {$this->run_id}");
        WP_CLI::line("═══════════════════════════════════════════════════════");
        WP_CLI::line("  Total processed: {$this->processed_count}");
        WP_CLI::line("  Successful:      {$this->success_count}");
        WP_CLI::line("  Failed:          {$this->fail_count}");
        WP_CLI::line("  Skipped:         {$this->skip_count}");
        WP_CLI::line("  Duration:        " . $this->format_duration($run_duration));
        WP_CLI::line("═══════════════════════════════════════════════════════");

        // Write completion entry
        $this->journal->append([
            'op'     => 'complete',
            'run_id' => $this->run_id,
            'total'  => $this->processed_count,
            'ok'     => $this->success_count,
            'fail'   => $this->fail_count,
            'skip'   => $this->skip_count,
            'duration_seconds' => $run_duration,
        ]);

        // Write snapshot
        $replay = $this->journal->replay();
        $this->journal->write_snapshot($replay['states'], $this->run_id);

        $this->logger->info('run_complete', [
            'run_id'   => $this->run_id,
            'total'    => $this->processed_count,
            'ok'       => $this->success_count,
            'fail'     => $this->fail_count,
            'skip'     => $this->skip_count,
            'duration' => $run_duration,
        ]);
    }

    /**
     * Show current state summary.
     */
    public function show_status(): void {
        $replay = $this->journal->replay();
        $states = $replay['states'];

        $total = count($states);
        $success = 0;
        $failed = 0;
        $skipped = 0;

        foreach ($states as $id => $state) {
            switch ($state['status']) {
                case 'success': $success++; break;
                case 'failed':  $failed++; break;
                case 'skipped': $skipped++; break;
            }
        }

        // Get total attachments
        $all_ids = $this->get_all_attachment_ids();
        $total_attachments = count($all_ids);
        $pending = $total_attachments - $success;

        WP_CLI::line("");
        WP_CLI::line("═══════════════════════════════════════════════════════");
        WP_CLI::line("  REGENERATION STATE");
        WP_CLI::line("═══════════════════════════════════════════════════════");
        WP_CLI::line("  Total attachments:     {$total_attachments}");
        WP_CLI::line("  Completed (success):   {$success}");
        WP_CLI::line("  Failed:                {$failed}");
        WP_CLI::line("  Skipped:               {$skipped}");
        WP_CLI::line("  Pending:               {$pending}");
        $last_run = $replay['last_run_id'] ?? 'none';
        WP_CLI::line("  Last run ID:           {$last_run}");
        WP_CLI::line("═══════════════════════════════════════════════════════");

        // Check for stale process
        $stale = $this->detect_stale_process();
        if ($stale) {
            WP_CLI::line("");
            WP_CLI::line("  WARNING: Stale process detected!");
            WP_CLI::line("  PID: {$stale['pid']}, Run: {$stale['run_id']}");
            WP_CLI::line("  Last heartbeat: {$stale['stale_seconds']}s ago");
            WP_CLI::line("  Reason: {$stale['reason']}");
        }
    }

    /**
     * Show what would be processed (dry run).
     */
    public function show_dry_run(): void {
        $replay = $this->journal->replay();
        $states = $replay['states'];

        $all_ids = $this->get_all_attachment_ids();
        $pending = [];

        foreach ($all_ids as $id) {
            if (!isset($states[$id]) || $states[$id]['status'] !== 'success') {
                $pending[] = $id;
            }
        }

        WP_CLI::line("");
        WP_CLI::line("═══════════════════════════════════════════════════════");
        WP_CLI::line("  DRY RUN — What would be processed");
        WP_CLI::line("═══════════════════════════════════════════════════════");
        WP_CLI::line("  Total attachments: " . count($all_ids));
        WP_CLI::line("  Already completed: " . (count($all_ids) - count($pending)));
        WP_CLI::line("  Would process:     " . count($pending));
        WP_CLI::line("═══════════════════════════════════════════════════════");

        if (!empty($pending)) {
            WP_CLI::line("");
            WP_CLI::line("  Pending attachment IDs:");
            $display = array_slice($pending, 0, 50);
            foreach ($display as $id) {
                $attachment = get_post($id);
                $title = $attachment ? $attachment->post_title : '(no title)';
                $status = isset($states[$id]) ? $states[$id]['status'] : 'new';
                WP_CLI::line("    ID {$id}: {$title} [{$status}]");
            }
            if (count($pending) > 50) {
                WP_CLI::line("    ... and " . (count($pending) - 50) . " more");
            }
        }
    }

    /**
     * List and optionally retry failed images.
     */
    public function retry_failed(bool $do_retry = false): array {
        $replay = $this->journal->replay();
        $states = $replay['states'];

        // Collect failed IDs
        $failed_ids = [];
        foreach ($states as $id => $state) {
            if ($state['status'] === 'failed') {
                $failed_ids[] = (int)$id;
            }
        }

        if (empty($failed_ids)) {
            WP_CLI::line("");
            WP_CLI::line("═══════════════════════════════════════════════════════");
            WP_CLI::line("  NO FAILED IMAGES FOUND");
            WP_CLI::line("═══════════════════════════════════════════════════════");
            WP_CLI::success("All images are in success state. Nothing to retry.");
            return [];
        }

        // Sort for consistent display
        sort($failed_ids);

        WP_CLI::line("");
        WP_CLI::line("═══════════════════════════════════════════════════════");
        if ($do_retry) {
            WP_CLI::line("  RETRYING FAILED IMAGES");
        } else {
            WP_CLI::line("  FAILED IMAGES (use --retry-failed to regenerate)");
        }
        WP_CLI::line("═══════════════════════════════════════════════════════");
        WP_CLI::line("  Total failed: " . count($failed_ids));
        WP_CLI::line("");

        foreach ($failed_ids as $id) {
            $attachment = get_post($id);
            $file_path = $attachment ? get_attached_file($id) : false;
            $title = $attachment ? $attachment->post_title : '(no title)';

            $state = $states[$id] ?? [];
            $error = $state['error'] ?? 'unknown error';

            WP_CLI::line("  ID {$id}: {$title}");
            if ($file_path) {
                WP_CLI::line("          File: {$file_path}");
            } else {
                WP_CLI::line("          File: [MISSING]");
            }
            WP_CLI::line("          Error: {$error}");
            WP_CLI::line("");
        }

        if ($do_retry) {
            WP_CLI::line("═══════════════════════════════════════════════════════");
            WP_CLI::line("  Starting retry for " . count($failed_ids) . " failed images...");
            WP_CLI::line("═══════════════════════════════════════════════════════");
            WP_CLI::line("");
            return $failed_ids;
        } else {
            WP_CLI::line("═══════════════════════════════════════════════════════");
            WP_CLI::line("  Use --retry-failed to regenerate " . count($failed_ids) . " failed images");
            WP_CLI::line("═══════════════════════════════════════════════════════");
            return [];
        }
    }

    /**
     * Reset all state.
     */
    public function reset_state(): void {
        $state_dir = $this->config['state_dir'];

        foreach (['journal.log', 'snapshot.json', 'heartbeat.lock', 'regen.log', 'journal.lock'] as $file) {
            $path = $state_dir . '/' . $file;
            if (file_exists($path)) {
                unlink($path);
            }
        }

        WP_CLI::success("All state files cleared. Next run will start fresh.");
    }
}

// ─── Main Execution ────────────────────────────────────────────────────────
try {
    // Initialize logger and journal
    $logger = new Regen_Logger($state_dir);
    $journal = new Regen_Journal($state_dir, $logger);

    $config = [
        'state_dir'       => $state_dir,
        'batch_size'      => $batch_size,
        'pause'           => $pause,
        'stale_threshold' => $stale_threshold,
    ];

    $processor = new Regen_Processor($journal, $logger, $config);

    // Handle --reset
    if ($reset) {
        $processor->reset_state();
        exit(0);
    }

    // Handle --status
    if ($status) {
        $processor->show_status();
        exit(0);
    }

    // Handle --retry-failed (list failed images)
    if ($retry_failed) {
        $processor->retry_failed(false);
        exit(0);
    }

    // Handle --dry-run
    if ($dry_run) {
        $processor->show_dry_run();
        exit(0);
    }

    // Bootstrap: load state, detect stale, enqueue pending
    $pending_ids = $processor->bootstrap();

    // Security: Confirm large batch operations
    if (count($pending_ids) > 10000) {
        WP_CLI::warning("Large batch detected: " . count($pending_ids) . " items to process.");
        WP_CLI::line("This may take a long time and consume significant resources.");
        WP_CLI::line("Type 'confirm' to proceed, or Ctrl+C to cancel:");
        $handle = fopen("php://stdin", "r");
        $input = trim(fgets($handle));
        fclose($handle);
        if ($input !== 'confirm') {
            WP_CLI::line("Aborted.");
            exit(0);
        }
    }

    if (empty($pending_ids)) {
        WP_CLI::line("");
        WP_CLI::line("No pending attachments. All images are up to date.");
        exit(0);
    }

    // Run regeneration
    $processor->run($pending_ids);

} catch (Throwable $e) {
    fwrite(STDERR, "FATAL ERROR: " . $e->getMessage() . "\n");
    fwrite(STDERR, $e->getTraceAsString() . "\n");
    exit(1);
}
