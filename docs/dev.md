# Developer notes

Engineering / QA reference. User docs live in the root [README](../README.md).

## Destinations (implementation)

| Action | Where it goes |
|--------|----------------|
| **Convert & Save to Photos** | A **custom album** you name (default: `Video to Live Photo`). Album is created if missing; every successful convert in the batch is added. |
| **Export pairs to folder** | Folder from **Export folder…**. HEIC+MOV pairs written **flat** with unique names (`LivePhoto-<id>.HEIC` / `.MOV`). Path remembered via UserDefaults + security-scoped bookmark. |

### Photos album API path

1. `PHPhotoLibrary.requestAuthorization(for: .readWrite)`
2. `PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, …)` filtered by `title`
3. If missing: `PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle:)`
4. Per asset: `PHAssetCreationRequest.forAsset()` (HEIC `.photo` + MOV `.pairedVideo`) then `PHAssetCollectionChangeRequest(for: album).addAssets([placeholder])`

## Duration & trim rules

| Source length | Behavior |
|---------------|----------|
| **≤ 3s** | Keep the **full original** clip (no pad / no loop). |
| **&lt; 1.5s** | Still keep full length; soft warning that Photos may not treat it as ideal Live Photo length. |
| **&gt; 3s** | **Start 3s** / **Center 3s** / **End 3s** / **Custom** sliding window (0.5–3s). |

Cover image defaults to the middle of the selected segment.

## Soft OPEN UX (tip `8854bc1`)

- Drop / choose **appends** to the queue (path duplicates skipped).
- **Start / Center / End** trim applies to every clip; **Custom** window + **Cover image** are per selected clip.
- Cover row: square thumb + scrubber + **Set as Cover** (from preview playhead, clamped to trim). Preview timeline shows the Live Photo window (blue) and Cover tick.
- **Custom** (>3s): inline trim preview above the filmstrip seeks with L/R/mid drag; duration chip on the blue window. Preview Disclosure stays collapsed unless opened.
- **Start / Center / End**: blue Live Photo window without expanding Preview; no filmstrip.
- Queue rows show failure reasons; remove with ✕.
- After a successful run: **Open Photos** and/or **Reveal in Finder**.
- **Cancel** stops between queue items (in-flight may finish). **Retry failed** re-queues only Failed rows.

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
| In-app | **Reveal log** (header) |
| Console.app | `subsystem:com.jim.LivePhotoConverter` |

If `No such file`, you have not launched a build that includes `DropLog` yet — pull tip, rebuild, ⌘R, then retry.

After a crash: paste the last ~30 lines (include `—— session ——`) and note Choose files… vs drag. Always record tip SHA for QA.

## HTML UI preview

```bash
cd preview && python3 -m http.server 8765 --bind 127.0.0.1
# http://127.0.0.1:8765/
```

## Project layout

- `LivePhotoConverter.xcodeproj` — open in Xcode
- `LivePhotoConverter/Sources/` — SwiftUI app + engine
- `project.yml` / `create-xcode-project.sh` — XcodeGen helpers if regenerating
- Smoke gate: [SMOKE.md](SMOKE.md)
