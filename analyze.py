#!/usr/bin/env python3
"""
auto-trip-report: curate the best photos from a trip.

Given a folder of photos, this script:
  1. Extracts EXIF date-taken and GPS lat/lng from every photo
  2. Scores each photo with a local vision model via Ollama (no cloud, no tokens)
  3. Groups near-duplicate / same-scene shots (time + GPS + perceptual hash,
     plus the model's scene tag across days) and keeps only the best of each
  4. Labels each selected photo primary (big/hero) or secondary (small/supporting)
  5. Writes report.json and copies picks into out/primary/ and out/secondary/

Usage:
  .venv/bin/python analyze.py /path/to/photos [--model qwen2.5vl:7b] [--out out]
"""

import argparse
import base64
import difflib
import hashlib
import io
import json
import math
import shutil
import sys
from datetime import datetime
from pathlib import Path

import imagehash
import requests
from PIL import Image
from PIL.ExifTags import IFD, GPSTAGS
from pillow_heif import register_heif_opener

register_heif_opener()

OLLAMA_URL = "http://localhost:11434/api/chat"
EXTENSIONS = {".jpg", ".jpeg", ".png", ".heic", ".heif", ".webp", ".tiff"}

# Two photos are considered "same scene" candidates when taken within
# this many minutes and meters of each other.
SCENE_MINUTES = 12
SCENE_METERS = 150
# phash hamming distance at or below this = near-identical frame
PHASH_NEAR_DUP = 12
# Rapid-succession shots of the same thing: taken within this many seconds
# and this few meters count as the same moment even if the frame shifted
# enough (people moving, reframing) to fool the perceptual hash.
BURST_SECONDS = 30
BURST_METERS = 25
# Same scene_tag within this distance (meters) counts as the same place
# even across different days.
LANDMARK_METERS = 500
# Any two photos this close in time and space get compared image-to-image by
# the model even when their tags disagree — catches the same storefront or
# street shot from a few steps down the block (different framing fools the
# hash, different tags fool the tag match).
PROXIMITY_MINUTES = 15
PROXIMITY_METERS = 250
# Tag similarity at or above this = same place, no model check needed.
TAG_SIM_STRONG = 0.75
# Tag similarity at or above this (when nearby) = ask the model to compare
# the two photos directly.
TAG_SIM_MAYBE = 0.35

ANALYSIS_SCHEMA = {
    "type": "object",
    "properties": {
        "score": {"type": "integer", "minimum": 1, "maximum": 10},
        "scene_tag": {"type": "string"},
        "description": {"type": "string"},
        "shot_type": {"type": "string", "enum": ["primary", "secondary"]},
    },
    "required": ["score", "scene_tag", "description", "shot_type"],
}

PROMPT = """You are curating photos from a multi-day trip for a travel report.
Analyze this photo and respond with JSON:

- score: 1-10 photo quality. Judge sharpness, exposure, composition, and how
  interesting/evocative it is. Blurry, badly exposed, dark, or accidental
  shots score 1-3. Competent snapshots 4-6. Great shots 7-8. Standouts 9-10.
- scene_tag: a kebab-case slug identifying the PLACE or SUBJECT, chosen so
  that any two photos of the same place or subject get the SAME tag. Base it
  ONLY on the most prominent, permanent thing actually visible — the venue,
  room, landmark, artwork, or dish. Do NOT invent creative or specific names,
  do NOT guess a city or business name, and do NOT tag by incidental details,
  passing people, or your interpretation. Prefer broad, stable, reusable tags
  ("antique-store-interior", "lakefront-boardwalk", "art-museum-gallery",
  "mexican-lunch") over unique ones. When two shots show the same room or
  scene from a slightly different angle or step, they MUST share one tag.
- description: one sentence describing only what is literally visible.
- shot_type: "primary" if it genuinely works as a large hero image (sharp,
  well-exposed, striking wide scenic view, landmark, or strong composition
  that tells the story of the place); "secondary" if it is a supporting
  detail (food, signs, close-ups, textures, small moments) or is dark,
  cluttered, or unremarkable and better shown small. A dark, blurry, or
  accidental photo is never primary.
"""


def find_photos(root: Path) -> list[Path]:
    return sorted(
        p for p in root.rglob("*")
        if p.suffix.lower() in EXTENSIONS and not p.name.startswith(".")
    )


def to_degrees(value) -> float:
    d, m, s = (float(x) for x in value)
    return d + m / 60.0 + s / 3600.0


def read_exif(img: Image.Image) -> dict:
    out = {"datetime": None, "lat": None, "lng": None}
    exif = img.getexif()
    if not exif:
        return out

    try:
        dt = exif.get_ifd(IFD.Exif).get(0x9003) or exif.get(0x0132)
    except Exception:
        dt = exif.get(0x0132)
    if dt:
        try:
            out["datetime"] = datetime.strptime(str(dt), "%Y:%m:%d %H:%M:%S").isoformat()
        except ValueError:
            pass

    try:
        gps_raw = exif.get_ifd(IFD.GPSInfo)
        gps = {GPSTAGS.get(k, k): v for k, v in gps_raw.items()}
        if "GPSLatitude" in gps and "GPSLongitude" in gps:
            lat = to_degrees(gps["GPSLatitude"])
            lng = to_degrees(gps["GPSLongitude"])
            if gps.get("GPSLatitudeRef") == "S":
                lat = -lat
            if gps.get("GPSLongitudeRef") == "W":
                lng = -lng
            out["lat"] = round(lat, 6)
            out["lng"] = round(lng, 6)
    except Exception:
        pass
    return out


def haversine_m(lat1, lng1, lat2, lng2) -> float:
    r = 6371000
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dp = math.radians(lat2 - lat1)
    dl = math.radians(lng2 - lng1)
    a = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * r * math.asin(math.sqrt(a))


def encode_for_model(img: Image.Image, max_edge=1024) -> str:
    img = img.convert("RGB")
    img.thumbnail((max_edge, max_edge))
    buf = io.BytesIO()
    img.save(buf, format="JPEG", quality=85)
    return base64.b64encode(buf.getvalue()).decode()


def analyze_with_model(model: str, image_b64: str) -> dict:
    resp = requests.post(
        OLLAMA_URL,
        json={
            "model": model,
            "messages": [{"role": "user", "content": PROMPT, "images": [image_b64]}],
            "format": ANALYSIS_SCHEMA,
            "stream": False,
            "options": {"temperature": 0.1},
        },
        timeout=300,
    )
    resp.raise_for_status()
    return json.loads(resp.json()["message"]["content"])


# Words too generic to indicate the same place — without this, every
# "*-shop-interior" or "urban-street-*" tag matches every other one.
GENERIC_TOKENS = {
    "interior", "exterior", "urban", "street", "scene", "shop", "store",
    "storefront", "building", "city", "view", "photo", "outdoor", "indoor",
    "room", "display", "sign", "wall", "area", "district", "market", "vintage",
    "art", "small", "big", "old", "new", "the", "a", "of", "in", "at",
}


def tag_similarity(a: str, b: str) -> float:
    """Fuzzy match scene tags on their distinctive words only:
    'cloud-gate-fountain' ~ 'cloudgate-mosaic' but not
    'coffee-shop-interior' ~ 'stationery-shop-interior'."""
    ta = set(a.lower().split("-")) - GENERIC_TOKENS
    tb = set(b.lower().split("-")) - GENERIC_TOKENS
    if not ta or not tb:
        # a tag made entirely of generic words only matches identical tags
        return 1.0 if a.lower() == b.lower() else 0.0
    jaccard = len(ta & tb) / len(ta | tb)
    na, nb = "".join(sorted(ta)), "".join(sorted(tb))
    return max(jaccard, difflib.SequenceMatcher(None, na, nb).ratio())


SAME_SUBJECT_SCHEMA = {
    "type": "object",
    "properties": {"same_subject": {"type": "boolean"}},
    "required": ["same_subject"],
}


def llm_same_subject(model: str, b64_a: str, b64_b: str) -> bool:
    """Ask the vision model whether two photos show the same place/subject."""
    resp = requests.post(
        OLLAMA_URL,
        json={
            "model": model,
            "messages": [{
                "role": "user",
                "content": (
                    "You are deduplicating photos for a travel report. Answer "
                    "true ONLY if these two photos clearly show the same "
                    "specific subject or place — the same landmark, the same "
                    "storefront, the same room, the same artwork — shot more "
                    "than once (different angles or times still count). Two "
                    "different shops, streets, rooms, or meals that merely "
                    "look similar are NOT the same subject. If you are not "
                    "certain they are the same, answer false. "
                    'Respond with JSON: {"same_subject": true or false}'
                ),
                "images": [b64_a, b64_b],
            }],
            "format": SAME_SUBJECT_SCHEMA,
            "stream": False,
            "options": {"temperature": 0.0},
        },
        timeout=300,
    )
    resp.raise_for_status()
    return json.loads(resp.json()["message"]["content"])["same_subject"]


def file_key(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        h.update(f.read(1 << 20))  # first 1MB is plenty to identify a photo
    h.update(str(path.stat().st_size).encode())
    return h.hexdigest()


def load_photo(path: Path) -> dict | None:
    try:
        with Image.open(path) as img:
            meta = read_exif(img)
            meta["phash"] = str(imagehash.phash(img))
            meta["image_b64"] = encode_for_model(img)
            return meta
    except Exception as e:
        print(f"  ! skipping {path.name}: {e}", file=sys.stderr)
        return None


def cluster_scenes(photos: list[dict]) -> list[list[dict]]:
    """Group photos taken close together in time and space."""
    ordered = sorted(photos, key=lambda p: p["datetime"] or "9999")
    clusters, current = [], []
    for p in ordered:
        if current:
            prev = current[-1]
            same = False
            if p["datetime"] and prev["datetime"]:
                gap_min = abs(
                    (datetime.fromisoformat(p["datetime"])
                     - datetime.fromisoformat(prev["datetime"])).total_seconds()
                ) / 60
                same = gap_min <= SCENE_MINUTES
                if same and None not in (p["lat"], prev["lat"]):
                    same = haversine_m(p["lat"], p["lng"], prev["lat"], prev["lng"]) <= SCENE_METERS
            if not same:
                clusters.append(current)
                current = []
        current.append(p)
    if current:
        clusters.append(current)
    return clusters


def same_moment(a: dict, b: dict) -> bool:
    """Two frames of the same instant: either near-identical perceptually,
    or shot within a few seconds and meters (a burst / rapid reframe that
    moved too much for the hash to catch)."""
    if imagehash.hex_to_hash(a["phash"]) - imagehash.hex_to_hash(b["phash"]) \
            <= PHASH_NEAR_DUP:
        return True
    if a["datetime"] and b["datetime"]:
        gap = abs((datetime.fromisoformat(a["datetime"])
                   - datetime.fromisoformat(b["datetime"])).total_seconds())
        if gap <= BURST_SECONDS and (
                None in (a["lat"], b["lat"]) or
                haversine_m(a["lat"], a["lng"], b["lat"], b["lng"])
                <= BURST_METERS):
            return True
    return False


def split_by_phash(cluster: list[dict]) -> list[list[dict]]:
    """Within a scene cluster, group frames that capture the same moment
    (near-identical hash or same-spot burst)."""
    groups: list[list[dict]] = []
    for p in cluster:
        for g in groups:
            if any(same_moment(p, m) for m in g):
                g.append(p)
                break
        else:
            groups.append([p])
    return groups


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("photos_dir", type=Path)
    ap.add_argument("--model", default="qwen2.5vl:7b")
    ap.add_argument("--out", type=Path, default=Path("out"))
    ap.add_argument("--min-score", type=int, default=5,
                    help="drop photos scoring below this")
    args = ap.parse_args()

    paths = find_photos(args.photos_dir)
    if not paths:
        sys.exit(f"No photos found in {args.photos_dir}")
    print(f"Found {len(paths)} photos")

    cache_path = Path(__file__).parent / "cache.json"
    cache = json.loads(cache_path.read_text()) if cache_path.exists() else {}

    photos = []
    for i, path in enumerate(paths, 1):
        key = file_key(path)
        meta = load_photo(path)
        if meta is None:
            continue
        image_b64 = meta.pop("image_b64")
        if key in cache:
            analysis = cache[key]
        else:
            print(f"[{i}/{len(paths)}] analyzing {path.name} ...")
            try:
                analysis = analyze_with_model(args.model, image_b64)
            except Exception as e:
                print(f"  ! model failed on {path.name}: {e}", file=sys.stderr)
                continue
            cache[key] = analysis
            cache_path.write_text(json.dumps(cache, indent=1))
        photos.append({"path": str(path), "name": path.name, **meta, **analysis})

    # --- selection ---
    # 1. Same-moment near-duplicates: keep the best frame of each burst/retake.
    survivors = []
    for cluster in cluster_scenes(photos):
        for group in split_by_phash(cluster):
            best = max(group, key=lambda p: p["score"])
            best["duplicates_beaten"] = len(group) - 1
            survivors.append(best)

    # 2. Same place on different days / different angles: dedupe by fuzzy
    #    scene_tag similarity when photos are within LANDMARK_METERS (or
    #    either lacks GPS). Borderline pairs are confirmed by showing the
    #    model both photos.
    survivors.sort(key=lambda p: -p["score"])
    b64_cache: dict[str, str] = {}

    def b64_of(p):
        if p["path"] not in b64_cache:
            with Image.open(p["path"]) as img:
                b64_cache[p["path"]] = encode_for_model(img)
        return b64_cache[p["path"]]

    selected = []
    for p in survivors:
        if p["score"] < args.min_score:
            continue
        dupe = False
        for s in selected:
            sim = tag_similarity(p["scene_tag"], s["scene_tag"])
            # Photos taken close together in time and space always get
            # compared image-to-image, because the model often tags the same
            # place (a storefront, a street, a landmark) two different ways
            # or from a few steps away (tags alone can't be trusted here).
            proximate = False
            if None not in (p["lat"], s["lat"], p["datetime"], s["datetime"]):
                gap_min = abs(
                    (datetime.fromisoformat(p["datetime"])
                     - datetime.fromisoformat(s["datetime"])).total_seconds()
                ) / 60
                proximate = gap_min <= PROXIMITY_MINUTES and haversine_m(
                    p["lat"], p["lng"], s["lat"], s["lng"]) <= PROXIMITY_METERS
            if sim < TAG_SIM_MAYBE and not proximate:
                continue
            if not proximate and None not in (p["lat"], s["lat"]) and \
               haversine_m(p["lat"], p["lng"], s["lat"], s["lng"]) > LANDMARK_METERS:
                continue
            if sim >= TAG_SIM_STRONG:
                dupe = True
            else:
                try:
                    dupe = llm_same_subject(args.model, b64_of(p), b64_of(s))
                except Exception as e:
                    print(f"  ! pairwise check failed ({p['name']} vs "
                          f"{s['name']}): {e}", file=sys.stderr)
                    dupe = sim >= 0.5
            if dupe:
                print(f"  ~ dropping {p['name']} ({p['scene_tag']}) as dupe "
                      f"of {s['name']} ({s['scene_tag']})")
                break
        if not dupe:
            selected.append(p)

    selected.sort(key=lambda p: p["datetime"] or "9999")

    # --- output ---
    args.out.mkdir(parents=True, exist_ok=True)
    for kind in ("primary", "secondary"):
        d = args.out / kind
        if d.exists():
            shutil.rmtree(d)
        d.mkdir()
    for p in selected:
        shutil.copy2(p["path"], args.out / p["shot_type"] / p["name"])

    report = {
        "generated": datetime.now().isoformat(),
        "model": args.model,
        "total_photos": len(photos),
        "selected": [
            {k: p[k] for k in ("name", "path", "datetime", "lat", "lng",
                               "score", "scene_tag", "description", "shot_type")}
            for p in selected
        ],
        "all_photos": [
            {k: p[k] for k in ("name", "path", "datetime", "lat", "lng",
                               "score", "scene_tag", "description", "shot_type")}
            for p in sorted(photos, key=lambda p: p["datetime"] or "9999")
        ],
    }
    (args.out / "report.json").write_text(json.dumps(report, indent=2))

    n_primary = sum(1 for p in selected if p["shot_type"] == "primary")
    print(f"\nAnalyzed {len(photos)} photos -> selected {len(selected)} "
          f"({n_primary} primary, {len(selected) - n_primary} secondary)")
    print(f"Report: {args.out / 'report.json'}")
    print(f"Picks copied to {args.out}/primary and {args.out}/secondary")


if __name__ == "__main__":
    main()
