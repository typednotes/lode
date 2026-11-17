# Changelog

All notable changes to this project are documented in this file. The format is
based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this
project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
Releases before 0.5.1 are described in their git tags and in `docs/release-*.md`.

## [Unreleased]

### Changed

- `autoImplicit` is back to Lean's default (on): it automates implicit binders,
  which are still fully checked, so it is not a weakening (agents-md standard v4).
  Warnings still fail the build (`lake build --wfail`).

## [0.5.1] — 2026-11-17

### Added

- A standard-library Python HTTP client example (`Examples/client.py`).
- A scripted walkthrough that generates a Lean project and checks it in Lun
  (`Examples/guide/run.py`), and an interactive version
  (`Examples/interactive/run.py`) to chat with Lode and then call the result.
- SVG rendering of a compiled graph and its latest outcomes
  (`Examples/graph_svg.py`; `viz`/`svg` in the interactive example).

### Changed

- The agent is told to check graph programs with `lun_build`, since the Lean
  language server does not see graphs written inside `lun.json`.
- Builds are stricter: implicit auto-bound variables are disabled and CI treats
  every compiler warning as an error.
