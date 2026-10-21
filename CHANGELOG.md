# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- Product display name renamed to **Video to Live Photo** (Dock, window title, default Photos album, usage strings). Bundle id `com.jim.LivePhotoConverter` and repo URL unchanged.

## [0.1.0] — unreleased until GitHub Release

First public cut. App UI base Soft OPEN tip [`8854bc1`](https://github.com/jim-ku/live-photo-converter/commit/8854bc19add18dec84898b70b7276294b7e34a71); docs + release kit land on later tip (see git history). Tag `v0.1.0` only after notarized DMG exists.

### Added

- Soft OPEN trim UX: Custom filmstrip under trim picker before Cover; Start/Center/End blue Live Photo window without expanding Preview; Cover thumb / scrub / Set as Cover.
- Help → How to use; Defaults vs per-clip Override; Photos album + Export folder destinations.
- Sponsors funding YAML (`.github/FUNDING.yml`).
- Slice A docs: MIT `LICENSE`, user README (Install → Use → Troubleshoot), `docs/SMOKE.md`, `docs/dev.md`, bug issue template, changelog.
- Slice B prep: `docs/RELEASE.md`, `scripts/macos-release.sh`, `scripts/make-dmg.sh`, paste-ready CI (`docs/ci-workflow.yml` → `.github/workflows/ci.yml`), marketing version `0.1.0`, release-notes draft.

### Notes

- Notarized DMG + GitHub Release are **not** cut until Jim Mac signs with Developer ID (Linux box cannot notarize).
