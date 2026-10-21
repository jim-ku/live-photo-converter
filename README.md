# Live Photo Converter

Mac app that turns **MP4 / MOV / M4V** clips into Apple **Live Photos** (paired **HEIC** still + **MOV** sharing one asset UUID).

## Install

1. Clone or pull this repo:
   ```bash
   git clone https://github.com/jim-ku/live-photo-converter.git
   cd live-photo-converter && git pull
   git rev-parse --short HEAD   # note the tip SHA for smoke / bug reports
   ```
2. Open `LivePhotoConverter.xcodeproj` in **Xcode 15+** (macOS 13+).
3. Scheme **LivePhotoConverter** → destination **My Mac** → Run (⌘R).

Signed DMG installs via [Releases](https://github.com/jim-ku/live-photo-converter/releases) will land in a later milestone. Until then, build from source as above.

Optional CLI build:

```bash
xcodebuild -scheme LivePhotoConverter -configuration Debug \
  -derivedDataPath ./build build
open ./build/Build/Products/Debug/LivePhotoConverter.app
```

## Use

Matches in-app **Help → How to use**:

1. **Drop or append** — Drop MP4/MOV/M4V files or a folder onto the dashed area. With a queue open, use the thin bar under Queue, or **Add files** / **Add folder**.
2. **Defaults vs Override** — **Defaults** (toolbar) set the app trim for new drops and Default-badge clips. Editing **This clip**’s mode or custom window sets **Override** for that clip only; **Reset** clears it.
3. **Trim (clips longer than 3s)** — Choose **Start 3s** / **Center 3s** / **End 3s** / **Custom**. Clips **≤ 3s** keep the full original (no pad / no loop). Soft warning if under ~1.5s.
4. **Custom filmstrip** — In Custom mode: drag the blue window to move; pull L/R handles to set length (max 3s). Inline preview above the strip seeks with the active edge. Preview Disclosure stays collapsed until you open it. Start/Center/End show the blue Live Photo window without expanding Preview and without a filmstrip.
5. **Cover image** — Still frame for the Live Photo (this clip only). Drag the scrubber, or expand Preview and scrub the player, then tap **Set as Cover**. Does not change Default/Override.
6. **Preview** — Starts collapsed (no player until you expand). Collapse tears the player down. Switching clips while collapsed stays quiet.
7. **Export / Photos** — Under **Destinations**, set **Photos album** name and/or **Export folder…**. Then **Convert & Save to Photos** (named album) or **Export pairs to folder** (flat `LivePhoto-<id>.HEIC` / `.MOV`). Import tip for exports: select each HEIC+MOV pair **together** in Photos.
8. **Reveal log** — Toolbar **Reveal log** opens the debug log in Finder if something fails.

After a successful run: **Open Photos** and/or **Reveal in Finder**. **Cancel** stops between queue items. **Retry failed** re-queues only Failed rows.

## Troubleshoot

| Symptom | What to try |
|---------|-------------|
| Photos permission denied | Grant **Photos** read/write when prompted (System Settings → Privacy & Security → Photos). |
| “No such file” for the log | Launch the app once (⌘R) so the container path is created, then **Reveal log**. |
| Convert fails / crash | Note tip SHA (`git rev-parse --short HEAD`), copy last ~30 log lines (include `—— session ——`), and file a [bug report](https://github.com/jim-ku/live-photo-converter/issues/new?template=bug.yml). |
| Export folder won’t stick | Pick the folder again with **Export folder…** (security-scoped bookmark). |
| Live Photo looks wrong length | Confirm trim mode and Cover; clips ≤3s keep full length; >3s use Start/Center/End/Custom (max 3s window). |

**Log path** (App Sandbox — the host `~/Library/Application Support/…` path does **not** exist):

```text
~/Library/Containers/com.jim.LivePhotoConverter/Data/Library/Application Support/LivePhotoConverter/debug.log
```

Also: `…/last-breadcrumb.txt` in the same folder; Console.app filter `subsystem:com.jim.LivePhotoConverter`.

```bash
LOG=~/Library/Containers/com.jim.LivePhotoConverter/Data/Library/Application\ Support/LivePhotoConverter/debug.log
tail -n 40 "$LOG"
open -R "$LOG"
```

## Requirements

- macOS 13+, Xcode 15+
- Photos **read/write** for album create + add

## Limitations

- Real Live Photos require macOS
- Sequential batch conversion
- Export folder access uses a security-scoped bookmark after the first pick

## Docs

- [Mac smoke checklist](docs/SMOKE.md) — Soft OPEN gate on tip
- [Developer notes](docs/dev.md) — Photos API, metadata, eng/QA notes
- [Changelog](CHANGELOG.md)

## Sponsors

Support development via [GitHub Sponsors](https://github.com/sponsors/jim-ku). The repo **Sponsor** button is enabled through [`.github/FUNDING.yml`](.github/FUNDING.yml).

## License

[MIT](LICENSE) © 2026 Jim Ku (jim-ku)
