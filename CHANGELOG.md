# Changelog

All notable changes to this project will be documented in this file. The format
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions
follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- Windows-native Codex `PreToolUse` adapter using transparent `updatedInput`.
- PowerShell AST planner with `Preserve`, `HookRewrite`, and `DelegateToRtk`.
- Exact RTK path binding for both rewrite and final execution.
- Single-process whole-source and GUID-delimited mixed-plan delegation.
- Safe, idempotent install, upgrade, uninstall, backups, and conflict warnings.
- English and Chinese documentation, CI, release packaging, and test suites.
- Reproducible, read-only `rtk read` evaluation with isolated tracking,
  structured output, safety tests, and bilingual evidence reports.
- RTK 0.44.2 validation baseline and pinned Windows release checksum.

### Changed

- Documented native reads as a deliberate Preserve boundary: explicit
  user-authored `rtk read` remains available, while generated `rtk read`
  candidates are rejected.
- Made the planner's no-learning/no-persistent-cache policy and the installer's
  no-RTK-config-mutation boundary explicit.
