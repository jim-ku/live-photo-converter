# Live Photo Converter

Mac app that turns **MP4 / MOV / M4V** clips into Apple **Live Photos** (paired **HEIC** still + **MOV** sharing one asset UUID).

## Destinations (explicit)

| Action | Where it goes |
|--------|----------------|
| **Convert & Save to Photos** | A **custom album** you name (default: `Live Photo Converter`). The album is created if it does not exist; every successful convert in the batch is added to that album. |
| **Export pairs to folder** | A folder you choose with **Export folder…**. HEIC+MOV pairs are written **flat** into that folder with unique names (`LivePhoto-<id>.HEIC` / `.MOV`). The path is remembered (UserDefaults + security-scoped bookmark). |

**Previous gap:** Export already used a folder picker at run time, but the path was not a persistent setting. Photos save added assets to the **library root with no album**. Both are now explicit controls in the **Destinations** section.

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

Key photo defaults to the middle of the selected segment.

## Open & run (Mac)

1. Open `LivePhotoConverter.xcodeproj` in **Xcode 15+**.
2. Scheme **LivePhotoConverter** → **My Mac** → Run (⌘R).
3. Grant **Photos** access (read/write) when saving to an album.

```bash
cd /path/to/live-photo-converter
xcodebuild -scheme LivePhotoConverter -configuration Debug \
  -derivedDataPath ./build build
open ./build/Build/Products/Debug/LivePhotoConverter.app
```

## UX notes (Software Team slices)

- Drop / choose **appends** to the queue (path duplicates skipped).
- **Start / Center / End** trim applies to every clip; **Custom** window + **key photo** are per selected clip.
- Preview timeline shows the Live Photo window (blue) and key-photo tick; player seeks to the keyframe.
- Queue rows show failure reasons; remove with ✕.
- After a successful run: **Open Photos** and/or **Reveal in Finder**.

## Convert (single or batch)

1. Drop **files** or a **folder** (or Choose files / folder).
2. Set **Trim mode** if any clip is longer than 3s.
3. In **Destinations**:
   - Edit **Photos album** name
   - Click **Export folder…** and confirm the path
4. **Convert & Save to Photos** — sequential queue → named album  
   or **Export pairs to folder** — HEIC+MOV into the chosen folder.
5. Import tip for exports: select each HEIC+MOV pair **together** in Photos.

## What the app writes

| Resource | Metadata |
|----------|----------|
| HEIC still | MakerNote Apple key `17` = asset UUID |
| MOV video | `com.apple.quicktime.content.identifier` = same UUID |
| MOV timed track | `com.apple.quicktime.still-image-time` at keyframe time |

## HTML UI preview

```bash
cd preview && python3 -m http.server 8765 --bind 127.0.0.1
# http://127.0.0.1:8765/
```

## Requirements

- macOS 13+, Xcode 15+
- Photos **read/write** permission (album create + add)

## Limitations

- Real Live Photos require macOS
- Sequential batch conversion
- Export folder access uses a security-scoped bookmark after the first pick
