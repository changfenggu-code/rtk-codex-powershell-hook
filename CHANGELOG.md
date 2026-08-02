# Changelog

All notable changes to this project will be documented in this file. The format
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions
follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- Windows-native Codex `PreToolUse` adapter using transparent `updatedInput`.
- PowerShell AST planner with `Preserve`, `HookRewrite`, and `DelegateToRtk`.
- Deterministic RTK discovery with bare effective-PATH invocation, explicit
  absolute binding, PATH-collision handling, and bounded Cargo-before-Scoop
  fallbacks.
- Single-process whole-source and GUID-delimited mixed-plan delegation.
- Safe, idempotent install, upgrade, uninstall, backups, and conflict warnings.
- English and Chinese documentation, CI, release packaging, and test suites.
- Reproducible, read-only `rtk read` evaluation with isolated tracking,
  structured output, safety tests, and bilingual evidence reports.
- Complete RTK command-inventory and project-output evaluation with explicit
  applicability classes, task-equivalent aggregation, and bilingual reports.
- RTK 0.44.2 validation baseline and pinned Windows release checksum.

### Changed

- Documented native reads as a deliberate Preserve boundary: explicit
  user-authored `rtk read` remains available, while generated `rtk read`
  candidates are rejected.
- Made the planner's no-learning/no-persistent-cache policy and the installer's
  no-RTK-config-mutation boundary explicit.
- Decoupled read-boundary tests from optional user-level RTK
  `exclude_commands` configuration.
- Centralized absolute RTK binding so already-prefixed commands use the same
  validated executable without another registry rewrite attempt.
- Warned about legacy `AGENTS.md` includes of `RTK.md` without modifying user
  instruction files.
- Added the official Windows `%USERPROFILE%\.local\bin\rtk.exe` convention
  between Cargo and Scoop fallbacks without invoking Unix package managers.
- Pinned and checksum-verified ripgrep in CI and release workflows because RTK
  search adapters require a native `rg.exe`.
- Fetched enough Git history for the previous-commit diff benchmark and made
  that case skip cleanly when `HEAD~1` is unavailable.
