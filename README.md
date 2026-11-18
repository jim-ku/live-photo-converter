# Video to Live Photo

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

**Binary install (when available):** download the notarized DMG from [Releases](https://github.com/jim-ku/live-photo-converter/releases) → open → drag to Applications. `v0.1.0` ships after Jim Mac notarization (see [docs/RELEASE.md](docs/RELEASE.md)). Until that asset exists, build from source as above.

Optional CLI build:

```bash
xcodebuild -scheme LivePhotoConverter -configuration Debug \
  -derivedDataPath ./build build
open "./build/Build/Products/Debug/Video to Live Photo.app"
```

## Use

1. Drop MP4, MOV, or M4V videos or a folder into the window. Use the **+** menu to append more. The queue shows the original filenames and skips repeated source paths.
2. Select a video. For clips over three seconds, choose **Start**, **Center**, **End**, or **Custom**. Drag the custom window or enter its start and duration. Shorter clips use their full length. **Trim defaults** applies to clips that inherit settings. **Reset** restores inheritance.
3. Use **Play selected segment** to review motion. Scrub the playhead and choose **Use current frame as cover**, or use the cover slider and frame-step buttons. The white line on the timeline marks the cover.
4. In the bottom bar, choose **Photos album** or **Folder**. Enter an album name or choose a folder, then save or export. The action count shows how many clips still need delivery there. Switch destinations to deliver the same edits again.
5. Use **Open Photos** or **Reveal in Finder** to inspect the result. Exports use the source name with matching HEIC and MOV extensions. Existing names get a numbered suffix. Select both files together when importing a pair into Photos.

The queue supports arrow-key selection and Delete. Command-Return starts the selected output action. **Stop after this clip** leaves remaining items pending. **Retry failed** acts on failures for the selected destination. If an asset reached the library before album placement failed, retry adds that asset to the album.

## Troubleshoot

| Symptom | What to try |
|---------|-------------|
| Photos permission denied | Grant **Photos** read/write when prompted (System Settings → Privacy & Security → Photos). |
| “No such file” for the log | Launch the app once (⌘R) so the container path is created, then **Help → Reveal diagnostic log**. |
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

- [Mac smoke checklist](docs/SMOKE.md) — release checks
- [Developer notes](docs/dev.md) — Photos API, metadata, eng/QA notes
- [Release runbook](docs/RELEASE.md) — maintainers: Developer ID → notarytool → DMG → `gh release`
- [CI workflow](.github/workflows/ci.yml) — builds the app and runs `swift test` on macOS
- [Changelog](CHANGELOG.md)

## Sponsors

Support development via [GitHub Sponsors](https://github.com/sponsors/jim-ku). The repo **Sponsor** button is enabled through [`.github/FUNDING.yml`](.github/FUNDING.yml).

## License

[MIT](LICENSE) © 2026 Jim Ku (jim-ku)
