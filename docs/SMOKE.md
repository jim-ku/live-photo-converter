# Mac smoke checklist (Soft OPEN)

Run against tip **`8854bc1`** (or later tip on `main` that includes Soft OPEN polish). Record the tip SHA before filing results.

```bash
cd live-photo-converter
git pull
git rev-parse --short HEAD   # paste into results
```

Build: Xcode 15+ → scheme **LivePhotoConverter** → **My Mac** → ⌘R.

## Pass criteria

Check each row. **PASS** only if all applicable rows are green.

### A. Custom + source longer than 3s

| # | Step | Expected |
|---|------|----------|
| A1 | Drop/add a clip **> 3s** | Appears in queue |
| A2 | Set trim to **Custom** (Defaults or This clip Override) | Custom filmstrip appears **under** the trim picker, **before** Cover |
| A3 | Drag blue window / L–R handles | Window moves; length ≤ 3s; inline preview above strip seeks with active edge |
| A4 | Cover row | Thumb + scrubber + **Set as Cover** work; Cover clamped to trim |
| A5 | Preview Disclosure | Stays **collapsed** unless you open it; convert still works collapsed |

### B. Start / Center / End (clip > 3s)

| # | Step | Expected |
|---|------|----------|
| B1 | Pick **Start 3s** (then Center, then End) | Blue Live Photo window visible **without** expanding Preview |
| B2 | Filmstrip | **No** Custom filmstrip mounted |
| B3 | Cover | Scrub / **Set as Cover** still available |

### C. Cover image

| # | Step | Expected |
|---|------|----------|
| C1 | Drag Cover scrubber | Thumb updates; Default/Override badge **unchanged** |
| C2 | Expand Preview, scrub player, **Set as Cover** | Cover jumps to playhead (clamped into trim) |

### D. Help / Defaults / destinations

| # | Step | Expected |
|---|------|----------|
| D1 | Open **Help** | “How to use” sheet matches README Use section |
| D2 | **Defaults** vs edit This clip | Defaults apply to new/Default-badge clips; per-clip edit → **Override**; Reset clears Override |
| D3 | Destinations → Photos album name | **Convert & Save to Photos** lands in that album |
| D4 | Destinations → **Export folder…** | **Export pairs to folder** writes HEIC+MOV into chosen folder |

### E. Record

| Field | Value |
|-------|--------|
| Tip SHA (short) | ________ |
| macOS version | ________ |
| Xcode version | ________ |
| Result | PASS / FAIL (failing step: ____) |
| Log paste / path | `~/Library/Containers/com.jim.LivePhotoConverter/Data/Library/Application Support/LivePhotoConverter/debug.log` |

Ship Soft OPEN = this checklist green on Jim’s Mac at tip `8854bc1` (or the SHA under test). Separate from Slice A docs landing on `main`.
