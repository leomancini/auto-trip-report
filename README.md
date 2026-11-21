# auto-trip-report

Curates the best photos from a trip using a fully local vision model
(Ollama + Qwen2.5-VL) — no cloud, no API tokens.

Given a folder of photos it:

1. Extracts EXIF **date taken** and **GPS lat/lng** from every photo
2. Scores each photo 1–10 with the vision model (sharpness, composition, interest)
3. Removes near-duplicates: burst shots / retakes (time + GPS + perceptual hash)
   and the same place shot again on another day (model's scene tag + GPS)
4. Labels each pick **primary** (works big: hero/scenic/landmark shots) or
   **secondary** (works small: food, details, close-ups)
5. Writes `report.json` and copies picks into `out/primary/` and `out/secondary/`

## Usage

```bash
.venv/bin/python analyze.py ~/Pictures/japan-trip
```

Options:

- `--model qwen2.5vl:7b` — any Ollama vision model (`qwen2.5vl:32b` for higher
  quality, slower)
- `--out out` — output directory
- `--min-score 5` — drop photos scoring below this

Supports JPG/PNG/HEIC (iPhone) and reads folders recursively.

## Output

`out/report.json` contains every photo and every pick with:
`name, path, datetime, lat, lng, score, scene_tag, description, shot_type`.

Analysis results are cached in `cache.json` (keyed by file content), so
re-runs only analyze new photos.

## Setup (already done on this machine)

```bash
brew install ollama && brew services start ollama
ollama pull qwen2.5vl:7b
python3 -m venv .venv
.venv/bin/pip install pillow pillow-heif imagehash requests
```

## Mac app

`TripReportApp/` is a native SwiftUI version of both scripts (no Python needed;
it still uses Ollama for the vision model). Projects — a set of photos plus the
guide generated from them — are saved automatically under
`~/Library/Application Support/TripReport/`.

```bash
cd TripReportApp
xcodebuild -project TripReport.xcodeproj -scheme TripReport -configuration Release -derivedDataPath build build
open "build/Build/Products/Release/Trip Report.app"
```

Or open `TripReportApp/TripReport.xcodeproj` in Xcode and press Run.

The app reads this folder's `cache.json` automatically when the photos live
underneath it, so photos already scored by `analyze.py` aren't scored again.
