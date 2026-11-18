# Developer notes

Engineering / QA reference. User docs live in the root [README](../README.md).

## Conversion and delivery

Each queue entry owns a temporary working copy of its source, its current generated pair, a library asset identifier, and delivery results by album name or folder URL. Editing the effective segment or cover invalidates those results. Removing the entry releases its temporary media.

The Photos destination resolves or creates a regular album with read/write access. It commits the HEIC and paired MOV in a library creation transaction, records the resulting asset ID, and then adds the asset to the album. An album retry reuses that ID. Folder export stages both resources within the chosen filesystem and publishes both under an available source-based name using exclusive moves.

## Duration & trim rules

| Source length | Behavior |
|---------------|----------|
| **≤ 3s** | Keep the **full original** clip (no pad / no loop). |
| **&lt; 1.5s** | Still keep full length; soft warning that Photos may not treat it as ideal Live Photo length. |
| **&gt; 3s** | **Start 3s** / **Center 3s** / **End 3s** / **Custom** sliding window (0.5–3s). |

Cover image defaults to the middle of the selected segment.

## Running the regressions

Run `swift test` on a Mac with Xcode. Tests create moving landscape and rotated portrait media, exercise real AVFoundation conversion and PhotoKit resource validation, and use an isolated album store for permission, partial-save, retry, and batch tests. The release checks in [SMOKE.md](SMOKE.md) cover library writes in the signed app.

## What the app writes

| Resource | Metadata |
|----------|----------|
| HEIC still | MakerNote Apple key `17` = asset UUID |
| MOV video | `com.apple.quicktime.content.identifier` = same UUID |
| MOV timed track | `com.apple.quicktime.still-image-time` at Cover (still) time |

## Debug logs (DropLog)

App Sandbox remaps Application Support into the **container**. The host path `~/Library/Application Support/LivePhotoConverter/…` will **not** exist.

| What | Where |
|------|--------|
| Main log | `~/Library/Containers/com.jim.LivePhotoConverter/Data/Library/Application Support/LivePhotoConverter/debug.log` |
| Last line | `…/last-breadcrumb.txt` (same folder) |
| In-app | **Help → Reveal diagnostic log** |
| Console.app | `subsystem:com.jim.LivePhotoConverter` |

If `No such file`, you have not launched a build that includes `DropLog` yet — pull tip, rebuild, ⌘R, then retry.

After a crash: paste the last ~30 lines (include `—— session ——`) and note Choose files… vs drag. Always record tip SHA for QA.

## Historical HTML prototype

```bash
cd preview && python3 -m http.server 8765 --bind 127.0.0.1
# http://127.0.0.1:8765/
```

## Project layout

- `LivePhotoConverter.xcodeproj` — open in Xcode
- `LivePhotoConverter/Sources/` — SwiftUI app + engine
- `project.yml` / `create-xcode-project.sh` — XcodeGen helpers if regenerating
- Smoke gate: [SMOKE.md](SMOKE.md)
