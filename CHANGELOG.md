# Changelog

All notable changes to this project are documented in this file. The format is
based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this
project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
Releases before 0.5.1 are described in their git tags and in `docs/release-*.md`.

## [Unreleased]

## [0.6.2] — 2026-11-27

### Changed

- Build with [Linen 5.0.0](https://github.com/typednotes/linen/releases/tag/v5.0.0).

## [0.6.1] — 2026-11-27

### Changed

- Build with Linen 4.0.0 at its [release commit](https://github.com/typednotes/linen/commit/037925bc5068c54efd86690b78b258b9c6787959).

## [0.6.0] — 2026-11-26

### Added

- Shared operator settings in TOML or JSON for the HTTP service and native CLI.
- Direct model presets for OpenAI, Anthropic, Scaleway, and Baseten. Direct
  keys can come from startup, an endpoint-bound Secrets record, or an
  authenticated in-memory session handoff.
- Compiled Lean tools with explicit session permission. The standard binary
  includes `lean_version`, and custom builds can call individual MCP tools
  using the stdio adapter.
- Architecture documentation and a specification for startup settings,
  credential handling, and compiled tools.

### Changed

- Updated Linen to 3.0.0 for Lode, the image's prebuilt package cache, and new
  projects. New projects use Lean 4.36.0, and the Lun integration job uses a
  Lean 4.36-compatible Lun revision.
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
