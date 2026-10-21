## Video to Live Photo v0.1.0

First public macOS release (Developer ID signed + notarized).

**Requires:** macOS 13+

### Install

1. Download `LivePhotoConverter-0.1.0.dmg` below.
2. Open the DMG → drag **Video to Live Photo** to Applications.
3. On first launch, allow Photos access when prompted.

If Gatekeeper warns: right-click → Open (one-time), or System Settings → Privacy & Security → Open Anyway. The build is notarized; a warning usually means the staple check has not finished yet.

### What’s in 0.1.0

- Drop MP4 / MOV / M4V → Apple Live Photos (HEIC + paired MOV)
- Trim: Start / Center / End 3s, or Custom window (max 3s) with filmstrip
- Cover image scrub + Set as Cover
- Defaults vs per-clip Override
- Save to a Photos album and/or export HEIC+MOV pairs to a folder
- In-app Help

### Smoke / bugs

- Checklist: [`docs/SMOKE.md`](https://github.com/jim-ku/live-photo-converter/blob/main/docs/SMOKE.md)
- Report: [new bug](https://github.com/jim-ku/live-photo-converter/issues/new?template=bug.yml) — include macOS version, tip/tag SHA, exact failing step, log path

### Build base

- Soft OPEN UI: `8854bc1`
- Docs + release kit: tip on `main` at tag time
