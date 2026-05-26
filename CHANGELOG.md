# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.3.1] - 2026-05-26

### Added
- `--auto-confirm` flag to bypass all interactive confirmation prompts (designed for CI, cron, scripts, and `curl | bash` pipelines).
- `--confirm-threshold=N` to make the large-batch confirmation limit configurable (default: 10000, range 1–1 000 000).
- Explicit TTY detection in confirmation flows: non-interactive runs now fail fast with a clear actionable error instead of hanging on `read`.
- New `require_cli_confirmation()` helper in the PHP worker for centralized, auditable confirmation logic.
- `--reset` is now protected by the same confirmation mechanism (previously only large batches were guarded).

### Changed
- Large batch warning and `--reset` now respect both `--auto-confirm` and the configurable threshold.
- Documentation and inline help updated for all new flags and non-interactive usage patterns.
- Production validation expanded: successfully run via piped execution against WordPress sites with 29 000+ attachments.

### Security
- Prevents accidental mass-regeneration or destructive state reset in automated / non-interactive environments.
- Eliminates a class of operational denial-of-service (hanging on stdin in headless contexts).
- All new flags undergo the same strict input validation as existing options.

### Documentation
- Full changelog extracted to this separate `CHANGELOG.md` file (README now contains only high-level "What's New" summaries and links here).
- Added clear examples for `--auto-confirm` in both direct and piped execution sections.

## [1.2.0] - 2026-04-25

### Added
- `--retry-failed` option to list all previously failed attachments with ID, filename, file path, and exact error message.
- Failed images are now automatically re-queued for processing on subsequent normal runs (no special flag required to retry).

### Changed
- Improved failure reporting and recovery UX.

## [1.1.0] - 2026-04-24

### Added (Security Enhancements)
- Secure temporary file creation via `mktemp` (replaces predictable PID-based names; prevents symlink attacks).
- Comprehensive CLI argument validation (type, range, and format checks on all options).
- Optional SHA-256 integrity verification for `curl | bash` distribution via `REGEN_SCRIPT_HASH` environment variable.
- Hard CLI-only enforcement inside the embedded PHP worker (dies immediately if invoked via web SAPI).
- State directory hardening: `.htaccess` + `index.html` deny web access; restrictive `umask 077`.
- WordPress root ownership + symlink validation with path traversal depth limit (max 10 levels).
- Explicit large-batch confirmation prompt for operations > 10 000 items.
- Structured, machine-readable JSON logging and real-time progress bar with ETA.

### Fixed
- `Undefined array key "REMOTE_ADDR"` PHP warning when running in pure CLI context.
- Integrity verification success message was invisible in certain piped execution scenarios.

### Security
- Defense-in-depth improvements targeting the high-risk `curl | bash` distribution model and state file exposure.

## [1.0.0] - 2026-04-24

### Added
- Initial public release of `regen-images.sh`.
- Append-only journal with `flock` for crash-safe checkpoint/resume.
- Per-attachment error boundaries (try/catch) so one failure never aborts the entire batch.
- Heartbeat-based stale process / zombie detection and recovery.
- Memory pressure monitoring with automatic GC pauses.
- Pre- and post-generation file integrity checks.
- Signal handling (SIGINT / SIGTERM) with graceful state preservation.
- Single-file design (bash orchestrator + self-extracting PHP worker) for zero-dependency deployment.

[Unreleased]: https://github.com/Anasxrt/WordPress-Image-Regeneration/compare/v1.3.1...HEAD
[1.3.1]: https://github.com/Anasxrt/WordPress-Image-Regeneration/releases/tag/v1.3.1
[1.2.0]: https://github.com/Anasxrt/WordPress-Image-Regeneration/releases/tag/v1.2.0
[1.1.0]: https://github.com/Anasxrt/WordPress-Image-Regeneration/releases/tag/v1.1.0
[1.0.0]: https://github.com/Anasxrt/WordPress-Image-Regeneration/releases/tag/v1.0.0
