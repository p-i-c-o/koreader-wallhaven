# KOReader Wallhaven

> KOReader plugin + laptop companion for syncing Wallhaven wallpapers with dedupe and Kobo-ready processing.

<p align="center">
  <img alt="Status: Beta" src="https://img.shields.io/badge/Status-Beta-yellow">
  <img alt="Category: Software" src="https://img.shields.io/badge/Category-Software-0366d6">
  <img alt="Version" src="https://img.shields.io/badge/Version-0.1.0-orange">
</p>



## Overview
- **Goal:** Provide a practical Wallhaven workflow for Kobo devices: one-tap collection sync on-device, plus optional laptop-side sync/processing.
- **Why:** Avoid manual wallpaper management and repeated downloads while keeping device-side controls simple.
- **Scope:** KOReader plugin (sync + manual search + settings UI), collection dedupe, robust status/logging, laptop sync script with crop+resize pipeline.
- **Out of scope:** Account management, OAuth flows, cloud storage sync, or server-side caching.

## Highlights
- Collection sync with duplicate avoidance (by wallpaper ID).
- Menu-driven KOReader UX with editable settings.
- Detailed logs + smart user notifications (API key issues, network/DNS, timeout, rate limits).
- Laptop script that reuses existing raw files and processes backlog automatically.

## Quick Start
1. Copy `release/wallpaperfetch.koplugin` to Kobo plugins folder.
2. Put API key in `scripts/wallhaven.cred` (replace placeholder).
3. Restart KOReader and use `Wallpaper Fetch` menu.

## Repo Layout
- `/release/wallpaperfetch.koplugin` — KOReader plugin (Lua + shell scripts + config).
- `/laptop_sync.py` — Laptop-side sync and processing tool.
- `/requirements.txt` — Python dependencies for laptop tool.
- `/wallhaven.cred` — Local API key placeholder for laptop script.

## Docs
- **How it works:** Plugin offers `Sync`, `Edit Sync Settings`, and `Manual Search` flows.
- **Build / Assembly:** No build step; copy plugin folder directly to KOReader plugins path.
- **Config / Calibration:** `scripts/wallpapers.conf` controls sync/search behavior.
- **Testing / Validation:** Run sync and inspect plugin logs/status files under plugin `logs/` directory.
- **Troubleshooting:** Smart notifications surface common failures; full diagnostics are written to logs.

## Notes / Design Log
- Collection sync intentionally ignores manual search filters; it pulls collection contents as-is.
- All runtime temp/log/status artifacts are kept inside plugin directory (no `/tmp` dependency).
- Sync includes scan-first behavior to detect pending downloads and support confirm prompts for large syncs.

## Roadmap
- [ ] Add explicit dry-run summary screen in KOReader.
- [ ] Add optional "max downloads per sync" guardrail in UI.
- [ ] Add optional output naming modes for processed laptop files.

## Results
- **What works:** Collection sync, manual search fetch, duplicate skipping, configurable menu fields, robust logging.
- **What doesn’t (yet):** Automated background scheduling.
- **Data:** Logs include request URLs, extracted counts, and detailed failure reasons.

## Requirements
- **Parts / Materials:** Kobo device running KOReader, Wallhaven API key.
- **Tools:** Shell environment on Kobo for script execution, optional laptop terminal.
- **Software:** KOReader, Python 3.10+ (laptop), `requests` + `Pillow`.
- **Skills assumed:** Basic file copy to Kobo storage and editing a text config/API key file.

## How to Contribute
- Open issues with reproduction steps and relevant log snippets.
- Keep shell scripts POSIX-compatible.
- Keep user-facing messages concise and actionable.

## Credits
- Wallhaven API for wallpaper metadata/content endpoints.
- KOReader plugin framework.

## Disclaimer
This project was built with substantial AI assistance (code generation, refactoring, and documentation).
All final behavior and integration were manually reviewed and vetted before publication.
