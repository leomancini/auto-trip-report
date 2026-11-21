#!/usr/bin/env python3
"""
Generate a static HTML gallery from a report.json produced by analyze.py.

Layout: timeline rail on the left showing the current day/time while
scrolling; mosaic photo feed in the middle (primaries 2x2, secondaries 1x1
with visible labels); sticky map on the right whose dot follows the photo
in view.

Hiding photos: hover a photo and click the x. Hidden photos are remembered
by the browser (localStorage) and survive page regeneration. Click
"save list" in the header to download hidden.json — drop that file into the
out directory and the next generate_report.py run excludes those photos
from the page entirely.

Usage:
  .venv/bin/python generate_report.py trips/2026-07-10-trip/out
"""

import argparse
import html
import json
import time
from collections import defaultdict
from datetime import date, datetime
from pathlib import Path

from zoneinfo import ZoneInfo

import requests
from PIL import Image
from PIL.ExifTags import IFD
from pillow_heif import register_heif_opener
from timezonefinder import TimezoneFinder

WMO_CODES = {
    0: ("☀️", "Clear"), 1: ("\U0001f324", "Mostly clear"),
    2: ("⛅️", "Partly cloudy"), 3: ("☁️", "Overcast"),
    45: ("\U0001f32b", "Fog"), 48: ("\U0001f32b", "Icy fog"),
    51: ("\U0001f326", "Light drizzle"), 53: ("\U0001f326", "Drizzle"),
    55: ("\U0001f327", "Heavy drizzle"), 56: ("\U0001f327", "Freezing drizzle"),
    57: ("\U0001f327", "Freezing drizzle"), 61: ("\U0001f327", "Light rain"),
    63: ("\U0001f327", "Rain"), 65: ("\U0001f327", "Heavy rain"),
    66: ("\U0001f327", "Freezing rain"), 67: ("\U0001f327", "Freezing rain"),
    71: ("\U0001f328", "Light snow"), 73: ("\U0001f328", "Snow"),
    75: ("\U0001f328", "Heavy snow"), 77: ("\U0001f328", "Snow grains"),
    80: ("\U0001f326", "Showers"), 81: ("\U0001f327", "Showers"),
    82: ("\U0001f327", "Heavy showers"), 85: ("\U0001f328", "Snow showers"),
    86: ("\U0001f328", "Snow showers"), 95: ("⛈", "Thunderstorm"),
    96: ("⛈", "Thunderstorm w/ hail"), 99: ("⛈", "Thunderstorm w/ hail"),
}


def add_weather(photos: list[dict], cache_file: Path) -> None:
    """Attach hourly weather (Open-Meteo, cached) to each photo with GPS+time."""
    cache = json.loads(cache_file.read_text()) if cache_file.exists() else {}
    groups: dict[tuple, list[dict]] = defaultdict(list)
    for p in photos:
        p["weather"] = ""
        if p["lat"] is not None and p["datetime"]:
            groups[(round(p["lat"], 1), round(p["lng"], 1))].append(p)

    for (lat, lng), plist in groups.items():
        dates = [p["datetime"][:10] for p in plist]
        start, end = min(dates), max(dates)
        ckey = f"{lat},{lng},{start},{end}"
        if ckey not in cache:
            try:
                cache[ckey] = requests.get(
                    "https://api.open-meteo.com/v1/forecast"
                    f"?latitude={lat}&longitude={lng}"
                    f"&start_date={start}&end_date={end}"
                    "&hourly=temperature_2m,weather_code,is_day"
                    "&temperature_unit=fahrenheit&timezone=auto",
                    timeout=30).json()
                cache_file.write_text(json.dumps(cache))
            except Exception as e:
                print(f"  ! weather fetch failed for {lat},{lng}: {e}")
                continue
        hourly = cache[ckey].get("hourly", {})
        index = {t: i for i, t in enumerate(hourly.get("time", []))}
        for p in plist:
            i = index.get(p["datetime"][:14] + "00")
            if i is None:
                continue
            icon, desc = WMO_CODES.get(hourly["weather_code"][i], ("", ""))
            if not hourly["is_day"][i] and hourly["weather_code"][i] <= 1:
                icon, desc = "\U0001f319", "Clear night"
            p["weather"] = f'{icon} {round(hourly["temperature_2m"][i])}°F {desc}'

register_heif_opener()


def add_timezones(photos: list[dict]) -> None:
    """Derive each photo's timezone from its GPS position (photos without
    GPS inherit from the nearest photo in time), then compute the absolute
    UTC instant so ordering stays correct across timezone changes."""
    tf = TimezoneFinder()
    ordered = sorted(photos, key=lambda p: p["datetime"] or "9999")
    for p in ordered:
        p["zone"] = ""
        if p["lat"] is not None and p["datetime"]:
            p["zone"] = tf.timezone_at(lat=p["lat"], lng=p["lng"]) or ""
    last = ""
    for p in ordered:  # forward-fill, then back-fill the leading gap
        if p["zone"]:
            last = p["zone"]
        elif last:
            p["zone"] = last
    last = ""
    for p in reversed(ordered):
        if p["zone"]:
            last = p["zone"]
        elif last:
            p["zone"] = last
    for p in ordered:
        p["tz"], p["utc"] = "", None
        if p["datetime"] and p["zone"]:
            dt = datetime.fromisoformat(p["datetime"]).replace(
                tzinfo=ZoneInfo(p["zone"]))
            p["tz"] = dt.tzname() or ""
            p["utc"] = dt.timestamp()
        elif p["datetime"]:
            p["utc"] = datetime.fromisoformat(p["datetime"]).timestamp()


def build_summary(photos: list[dict], cache_file: Path) -> dict:
    """Reverse-geocode photo clusters to place names (cached) and assemble
    an ordered trip summary: cities visited, countries, dates, duration."""
    cache = json.loads(cache_file.read_text()) if cache_file.exists() else {}
    located = sorted(
        (p for p in photos if p["lat"] is not None and p["utc"] is not None),
        key=lambda p: p["utc"])

    stats: dict[str, dict] = {}
    countries: dict[str, float] = {}
    for p in located:
        key = f"{round(p['lat'], 1)},{round(p['lng'], 1)}"
        if key not in cache:
            try:
                r = requests.get(
                    "https://nominatim.openstreetmap.org/reverse",
                    params={"lat": p["lat"], "lon": p["lng"],
                            "format": "json", "zoom": 10},
                    headers={"User-Agent": "auto-trip-report/1.0"},
                    timeout=30).json()
                a = r.get("address", {})
                cache[key] = {
                    "city": (a.get("city") or a.get("town") or a.get("village")
                             or a.get("county") or a.get("state") or ""),
                    "country": a.get("country", ""),
                }
                cache_file.write_text(json.dumps(cache))
                time.sleep(1)  # Nominatim asks for <=1 request/sec
            except Exception as e:
                print(f"  ! geocode failed for {key}: {e}")
                cache[key] = {"city": "", "country": ""}
        info = cache[key]
        if info["city"]:
            s = stats.setdefault(info["city"],
                                 {"first": p["utc"], "last": p["utc"], "n": 0})
            s["last"] = p["utc"]
            s["n"] += 1
        if info["country"]:
            countries.setdefault(info["country"], p["utc"])

    # keep places where the trip actually lingered, not drive-through
    # waypoints: a real stop spans >= 45 min or has a solid photo count
    significant = {c: s for c, s in stats.items()
                   if s["last"] - s["first"] >= 2700 or s["n"] >= 8}
    cities = sorted(significant or stats, key=lambda c: stats[c]["first"])
    dts = sorted(p["datetime"] for p in photos if p["datetime"])
    start = date.fromisoformat(dts[0][:10]) if dts else None
    end = date.fromisoformat(dts[-1][:10]) if dts else None
    return {
        "cities": cities,
        "countries": sorted(countries, key=countries.get),
        "start": start, "end": end,
        "days": (end - start).days + 1 if start else 0,
    }


def block_label(dt_iso: str) -> str:
    """'2026-07-11T14:03' -> 'Friday Afternoon' (uses the photo's local hour)."""
    if not dt_iso:
        return "Undated"
    dt = datetime.fromisoformat(dt_iso)
    h = dt.hour
    part = ("Morning" if 5 <= h < 12 else "Afternoon" if 12 <= h < 17
            else "Evening" if 17 <= h < 21 else "Night")
    return f"{dt.strftime('%A')} {part}"


def format_date_range(start: date, end: date) -> str:
    if start == end:
        return start.strftime("%B %-d, %Y")
    if start.year != end.year:
        return f"{start.strftime('%b %-d, %Y')} – {end.strftime('%b %-d, %Y')}"
    if start.month != end.month:
        return f"{start.strftime('%b %-d')} – {end.strftime('%b %-d, %Y')}"
    return f"{start.strftime('%B %-d')}–{end.strftime('%-d, %Y')}"

CSS = """
:root { color-scheme: dark; }
* { box-sizing: border-box; margin: 0; }
body {
  font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
  background: #111; color: #eee;
  max-width: 1680px; margin: 0 auto;
  padding: 0 clamp(16px, 2.5vw, 44px);
}
.layout { display: flex; gap: 26px; align-items: flex-start; }
main { flex: 1; min-width: 0; padding: 2rem 0 6rem; }
aside {  /* map column, on the left */
  width: 32vw; position: sticky; top: 0;
  height: 100vh; padding: 14px 0; flex-shrink: 0;
  display: flex; flex-direction: column; gap: 12px;
}
.infogrid { display: grid; grid-template-columns: 1fr 1fr; gap: 12px; }
.icard {
  background: #1c1c1e; border-radius: 12px; padding: 18px 20px;
  aspect-ratio: 1 / 1; display: flex; flex-direction: column;
  justify-content: center; gap: 6px;
}
/* the clock + digital time live together in one wide card */
.icard.clock-time {
  grid-column: span 2; aspect-ratio: auto; flex-direction: row;
  align-items: center; gap: 22px; padding: 20px 24px;
}
.icard.clock-time .ct-text { display: flex; flex-direction: column; gap: 4px; }
.ilabel {
  font-size: .66rem; text-transform: uppercase; letter-spacing: .09em;
  color: #777; font-weight: 600;
}
.ival { color: #fff; }
#dc-date { font-size: 1.75rem; font-weight: 700; line-height: 1.15; }
#dc-time { font-size: 1.4rem; font-weight: 700;
           font-variant-numeric: tabular-nums; }
#dc-weather { font-size: 1.4rem; font-weight: 700; }
#aclock {
  width: 84px; height: 84px; border-radius: 50%; flex-shrink: 0;
  border: 2px solid #3a3a3c; position: relative;
}
#aclock .hand {
  position: absolute; left: 50%; bottom: 50%; background: #fff;
  border-radius: 4px; transform-origin: bottom center;
}
#hh { width: 4px; height: 22px; }
#mh { width: 3px; height: 33px; }
.icard.weather { flex-direction: row; align-items: center; gap: 14px; }
.icard.weather .wx-icon { font-size: 60px; line-height: 1; }
.icard.weather .wx-text { display: flex; flex-direction: column; gap: 4px; }
/* only animate the clock hands and viewer cone once the user starts
   scrolling — never on initial page load */
body.anim #aclock .hand { transition: transform .4s ease-out; }
body.anim .cone { transition: transform .5s ease-out, opacity .3s; }
/* the map sits on a permanent white backing; the map itself fades in/out on
   top of it, so any fade reveals white rather than the dark page */
.mapwrap { flex: 1; min-height: 0; border-radius: 12px; overflow: hidden;
           background: #fff; position: relative; }
#map { position: absolute; inset: 0; background: transparent;
       opacity: 0; transition: opacity .25s; }
#map.ready { opacity: 1; }
/* grayscale only the tiles, so the blue location dot stays blue */
#map .maplibregl-canvas { filter: grayscale(1); }

@media (max-width: 900px) { aside { display: none; } }

.summary { padding: 2.2rem 0 1.3rem; border-bottom: 1px solid #2a2a2c; }
.summary h1 { font-size: 1.9rem; margin-bottom: .35rem; letter-spacing: -.01em; }
.summary .sub { color: #aaa; font-size: 1rem; }
.summary .controls { margin-top: .7rem; font-size: .78rem; color: #777; }
.summary .controls button {
  background: none; border: none; color: #aaa; cursor: pointer;
  font: inherit; padding: 0; text-decoration: underline;
}
.day { margin-top: 1.5rem; }
.feed { display: flex; flex-direction: column; gap: 12px; }
.block {
  font-size: .78rem; text-transform: uppercase; letter-spacing: .09em;
  color: #888; font-weight: 600; margin: 1.7rem 0 .1rem;
}
.feed > .block:first-child { margin-top: 0; }
/* Justified rows (à la Google Photos): each card's flex-basis/grow is set
   inline from its real aspect ratio, so photos keep their true shape
   (portraits stay tall), rows fill the full width, and there's never an
   empty slot. Primaries use a taller target row height than secondaries. */
.pgrid, .sgrid { display: flex; flex-wrap: wrap; }
.pgrid { gap: 12px; }
.sgrid { gap: 8px; }
.pgrid .card { height: 320px; }
.sgrid .card { height: 190px; }
.card { border-radius: 10px; overflow: hidden; background: #1c1c1e;
        position: relative; flex-grow: 1; }
.card img { width: 100%; height: 100%; object-fit: cover; display: block; }
"""

JS = """
// ---- hiding photos (persisted in localStorage; export via save list) ----
const allCards = Array.from(document.querySelectorAll('.card[data-name]'));

const visible = c => c.offsetParent !== null;
function currentOf(list) {
  let cur = null;
  const line = innerHeight * 0.55;
  for (const c of list) {
    if (visible(c) && c.getBoundingClientRect().top < line) cur = c;
  }
  return cur || list.find(visible) || list[0];
}

// ---- date/time card above the map ----
const tsCards = allCards.filter(c => c.dataset.ts);
const dcDate = document.getElementById('dc-date');
const dcTime = document.getElementById('dc-time');
const handH = document.getElementById('hh');
const handM = document.getElementById('mh');
function updateTimeline() {
  if (!tsCards.length) return;
  const cur = currentOf(tsCards);
  const d = new Date(cur.dataset.ts);
  dcDate.textContent = d.toLocaleDateString(undefined,
    { weekday: 'long', month: 'long', day: 'numeric' });
  dcTime.textContent =
    d.toLocaleTimeString(undefined, { hour: 'numeric', minute: '2-digit' }) +
    (cur.dataset.tz ? ' ' + cur.dataset.tz : '');
  const wx = (cur.dataset.weather || '').trim();
  const sp = wx.indexOf(' ');
  document.getElementById('wx-icon').textContent = sp > 0 ? wx.slice(0, sp) : '';
  document.getElementById('dc-weather').textContent =
    sp > 0 ? wx.slice(sp + 1) : wx;
  const h = d.getHours() % 12 + d.getMinutes() / 60;
  handH.style.transform = 'translateX(-50%) rotate(' + h * 30 + 'deg)';
  handM.style.transform =
    'translateX(-50%) rotate(' + d.getMinutes() * 6 + 'deg)';
}

// ---- map with scroll-following animated dot (OpenFreeMap dark) ----
const geoCards = allCards.filter(c => c.dataset.lat);
let updateMap = () => {};
if (geoCards.length && window.maplibregl) {
  const byTime = geoCards.slice().sort((a, b) =>
    (+a.dataset.utc || 0) - (+b.dataset.utc || 0));
  const path = byTime.map(c => [+c.dataset.lng, +c.dataset.lat]); // lng,lat
  const FOLLOW_ZOOM = 15;

  // start the map already at the (possibly hash-restored) location so it
  // never teleports from a default view on load
  function startCenter() {
    const m = location.hash.match(/^#t=([^,]+),/);
    if (m) {
      const ts = decodeURIComponent(m[1]);
      const c = byTime.find(x => x.dataset.ts === ts);
      if (c) return [+c.dataset.lng, +c.dataset.lat];
    }
    return path[0];
  }
  const center0 = startCenter();

  const map = new maplibregl.Map({
    container: 'map',
    style: 'https://tiles.openfreemap.org/styles/positron',
    center: center0,
    zoom: FOLLOW_ZOOM,
    attributionControl: false,
  });
  map.addControl(new maplibregl.NavigationControl({ showCompass: false }));
  map.scrollZoom.disable();

  let mapReady = false;
  let lastTarget = '';
  map.on('load', () => {
    // declutter: keep roads, water, and major place labels only
    const noise = /poi|transit|airport|aeroway|housenumber|building|barrier|ferry|oneway|place_(hamlet|isolated|island|level|other|suburb|quarter|neighbourhood|village)|water_name|road_shield|highway-shield|label-(path|waterway)|landuse_residential|landcover_(ice|glacier)|sand|cemetery|pitch|rail|path|footway|pedestrian|boundary|admin|aerialway|helipad/i;
    for (const l of map.getStyle().layers) {
      if (noise.test(l.id))
        map.setLayoutProperty(l.id, 'visibility', 'none');
    }
    map.resize();  // container may have grown after layout settled
    // hard-jump to the current photo's location (no animation), THEN reveal,
    // so the map never appears to move on load
    const c = currentOf(geoCards);
    const ll = [+c.dataset.lng, +c.dataset.lat];
    lastTarget = ll.join(',');
    dot.setLngLat(ll);
    pointCone(c);
    map.jumpTo({ center: ll, zoom: FOLLOW_ZOOM });
    mapReady = true;
    document.getElementById('map').classList.add('ready');
  });

  const dotEl = document.createElement('div');
  dotEl.style.cssText = 'width:110px;height:110px;position:relative;';
  const cone = document.createElement('div');
  cone.className = 'cone';
  cone.style.cssText = 'position:absolute;inset:0;opacity:0;' +
    'background:conic-gradient(from -30deg at 50% 50%,' +
    'rgba(10,132,255,.45) 0deg 60deg,transparent 60deg);' +
    '-webkit-mask:radial-gradient(circle at 50% 50%,#000 12%,transparent 62%);' +
    'mask:radial-gradient(circle at 50% 50%,#000 12%,transparent 62%);';
  const dotCore = document.createElement('div');
  dotCore.style.cssText = 'position:absolute;left:50%;top:50%;width:16px;' +
    'height:16px;transform:translate(-50%,-50%);border-radius:50%;' +
    'background:#0a84ff;border:2.5px solid #fff;' +
    'box-shadow:0 0 0 1px rgba(0,0,0,.25),0 1px 4px rgba(0,0,0,.4)';
  dotEl.append(cone, dotCore);
  const dot = new maplibregl.Marker({ element: dotEl })
    .setLngLat(center0).addTo(map);

  let coneAngle = 0;
  function pointCone(card) {
    const h = card.dataset.heading;
    if (h === undefined) { cone.style.opacity = '0'; return; }
    // rotate via shortest arc so 350deg -> 10deg doesn't spin backwards
    const delta = ((+h - (coneAngle % 360 + 360) % 360) + 540) % 360 - 180;
    coneAngle += delta;
    cone.style.opacity = '1';
    cone.style.transform = 'rotate(' + coneAngle + 'deg)';
  }

  let anim = null;
  function slideDot(to) {
    const from = dot.getLngLat();
    const t0 = performance.now(), dur = 500;
    cancelAnimationFrame(anim);
    function step(t) {
      const k = Math.min(1, (t - t0) / dur);
      const e = 1 - Math.pow(1 - k, 3);
      dot.setLngLat([from.lng + (to[0] - from.lng) * e,
                     from.lat + (to[1] - from.lat) * e]);
      if (k < 1) anim = requestAnimationFrame(step);
    }
    anim = requestAnimationFrame(step);
  }
  // a hop counts as "huge" if the destination is far across the viewport,
  // measured in screen pixels at the current zoom (not raw distance)
  function isBigHop(to) {
    const p1 = map.project(dot.getLngLat()), p2 = map.project(to);
    const el = map.getContainer();
    return Math.hypot(p2.x - p1.x, p2.y - p1.y)
           > 0.6 * Math.min(el.clientWidth, el.clientHeight);
  }

  const mapEl = document.getElementById('map');
  updateMap = () => {
    const c = currentOf(geoCards);
    const ll = [+c.dataset.lng, +c.dataset.lat];
    const key = ll.join(',');
    if (key === lastTarget) return;
    lastTarget = key;
    if (!mapReady) {  // pre-load: snap, never animate
      dot.setLngLat(ll);
      pointCone(c);
      map.jumpTo({ center: ll, zoom: Math.max(map.getZoom(), FOLLOW_ZOOM) });
    } else if (isBigHop(ll)) {
      // big hop (new area/day): don't slide across the map. Fade the whole
      // map (tiles + pin together, so they're perfectly in sync) out,
      // teleport underneath, fade back in.
      cancelAnimationFrame(anim);
      map.stop();
      mapEl.style.opacity = '0';
      setTimeout(() => {
        dot.setLngLat(ll);
        pointCone(c);
        map.jumpTo({ center: ll, zoom: Math.max(map.getZoom(), FOLLOW_ZOOM) });
        mapEl.style.opacity = '1';
      }, 250);
    } else {          // nearby: smooth follow
      pointCone(c);
      slideDot(ll);
      map.easeTo({ center: ll, zoom: Math.max(map.getZoom(), FOLLOW_ZOOM),
                   duration: 500 });
    }
  };
}

// ---- remember scroll position in the URL hash (#t=<datetime>,<offset>) ----
let lastHashWrite = 0;
function updateHash() {
  const now = performance.now();
  if (now - lastHashWrite < 400) return;  // Safari throttles replaceState
  lastHashWrite = now;
  const cur = currentOf(tsCards);
  if (!cur || !cur.dataset.ts) return;
  const off = Math.round(cur.getBoundingClientRect().top);
  history.replaceState(null, '',
    '#t=' + encodeURIComponent(cur.dataset.ts) + ',' + off);
}
function restoreFromHash() {
  const m = location.hash.match(/^#t=([^,]+),(-?\\d+)/);
  if (!m) return;
  const ts = decodeURIComponent(m[1]);
  const card = tsCards.find(c => c.dataset.ts === ts);
  if (!card) return;
  scrollTo(0, card.getBoundingClientRect().top + scrollY - +m[2]);
}

// we restore scroll ourselves from the hash; stop the browser from doing
// its own async scroll restore, which would fire a spurious scroll event
// and animate the clock/cone into place on reload
if ('scrollRestoration' in history) history.scrollRestoration = 'manual';

let ticking = false, booted = false;
addEventListener('scroll', () => {
  if (booted) document.body.classList.add('anim');  // only after first paint
  if (!ticking) {
    ticking = true;
    requestAnimationFrame(() => {
      ticking = false; updateMap(); updateTimeline(); updateHash();
    });
  }
}, { passive: true });
restoreFromHash();
updateMap();
updateTimeline();
// enable transitions only after the initial position has painted, so a
// reload never animates the clock hands or the direction cone
requestAnimationFrame(() => requestAnimationFrame(() => { booted = true; }));
"""


def read_heading(path: Path) -> float | None:
    """Compass direction (degrees from north) the camera faced, from EXIF."""
    try:
        with Image.open(path) as img:
            gps = img.getexif().get_ifd(IFD.GPSInfo)
            direction = gps.get(17)  # GPSImgDirection
            return None if direction is None else float(direction) % 360
    except Exception:
        return None


def make_thumb(src: Path, dest: Path, max_edge: int) -> tuple | None:
    """Create the thumbnail if needed; return its (width, height)."""
    try:
        if not dest.exists():
            with Image.open(src) as img:
                img = img.convert("RGB")
                img.thumbnail((max_edge, max_edge))
                img.save(dest, format="JPEG", quality=85)
        with Image.open(dest) as t:
            return t.size
    except Exception as e:
        print(f"  ! thumb failed for {src.name}: {e}")
        return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("out_dir", type=Path, help="the analyze.py --out directory")
    args = ap.parse_args()

    report = json.loads((args.out_dir / "report.json").read_text())
    web = args.out_dir / "web"
    web.mkdir(exist_ok=True)

    hidden_file = args.out_dir / "hidden.json"
    hidden = set(json.loads(hidden_file.read_text())) if hidden_file.exists() else set()
    if hidden:
        print(f"Excluding {len(hidden)} photos listed in {hidden_file}")

    add_timezones(report["selected"])
    add_weather(report["selected"], args.out_dir / "weather_cache.json")
    by_day = defaultdict(list)
    for p in report["selected"]:
        if p["name"] in hidden:
            continue
        by_day[(p["datetime"] or "unknown")[:10]].append(p)

    shown = [p for day in by_day.values() for p in day]
    summary = build_summary(shown, args.out_dir / "geo_cache.json")

    cities = summary["cities"]
    if not cities:
        title = "Trip report"
    elif len(cities) <= 6:
        title = " → ".join(cities)
    else:
        title = f"{cities[0]} → {cities[1]} → … → {cities[-1]}"

    bits = []
    if summary["start"]:
        bits.append(format_date_range(summary["start"], summary["end"]))
        bits.append(f'{summary["days"]} day{"s" if summary["days"] != 1 else ""}')
    bits.append(f"{len(shown)} photos")
    if len(cities) > 1:
        bits.append(f"{len(cities)} places")
    if len(summary["countries"]) > 1:
        bits.append(" · ".join(summary["countries"]))

    parts = [
        "<!doctype html><meta charset='utf-8'><title>Trip report</title>",
        "<meta name='viewport' content='width=device-width, initial-scale=1'>",
        "<link rel='stylesheet' href='https://unpkg.com/maplibre-gl@5.6.0/dist/maplibre-gl.css'>",
        "<script src='https://unpkg.com/maplibre-gl@5.6.0/dist/maplibre-gl.js'></script>",
        f"<style>{CSS}</style>",
        "<header class='summary'>",
        f"<h1>{html.escape(title)}</h1>",
        f'<p class="sub">{html.escape(" · ".join(bits))}</p>',
        "</header>",
        # map column first (left), photo feed second (right)
        "<div class='layout'><aside>"
        "<div class='infogrid'>"
        "<div class='icard clock-time'>"
        "<div id='aclock'><div class='hand' id='hh'></div>"
        "<div class='hand' id='mh'></div></div>"
        "<div class='ct-text'><span class='ilabel'>Date</span>"
        "<span class='ival' id='dc-date'></span></div></div>"
        "<div class='icard'><span class='ilabel'>Time</span>"
        "<span class='ival' id='dc-time'></span></div>"
        "<div class='icard weather'><span class='wx-icon' id='wx-icon'></span>"
        "<div class='wx-text'><span class='ilabel'>Weather</span>"
        "<span class='ival' id='dc-weather'></span></div></div>"
        "</div>"
        "<div class='mapwrap'><div id='map'></div></div></aside><main>",
    ]

    def build_card(p) -> str | None:
        kind = p["shot_type"]
        src = args.out_dir / kind / p["name"]
        thumb = web / (Path(p["name"]).stem + ".jpg")
        if not src.exists():
            return None
        size = make_thumb(src, thumb, 1600 if kind == "primary" else 600)
        if size is None:
            return None
        # aspect ratio drives the justified layout: flex-basis is the width
        # this photo would take at the row's target height; flex-grow lets
        # wider photos claim more of the leftover width
        row_h = 320 if kind == "primary" else 190
        ar = max(0.4, min(2.6, size[0] / size[1]))
        style = f' style="flex-basis:{ar * row_h:.0f}px;flex-grow:{ar:.3f}"'
        attrs = f' data-name="{html.escape(p["name"])}"'
        if p["datetime"]:
            attrs += (f' data-ts="{p["datetime"]}" data-tz="{p["tz"]}"'
                      f' data-utc="{p["utc"] or ""}"')
        if p["weather"]:
            attrs += f' data-weather="{html.escape(p["weather"])}"'
        if p["lat"] is not None:
            attrs += f' data-lat="{p["lat"]}" data-lng="{p["lng"]}"'
            heading = read_heading(src)
            if heading is not None:
                attrs += f' data-heading="{heading:.0f}"'
        return (
            f'<div class="card {kind}"{attrs}{style}>'
            f'<img src="web/{thumb.name}" loading="lazy" alt=""></div>'
        )

    for day in sorted(by_day):
        day_photos = sorted(by_day[day],
                            key=lambda p: p["utc"] if p["utc"] is not None
                            else float("inf"))
        # group the day's photos into contiguous time-of-day blocks
        blocks: list[tuple[str, list]] = []
        for p in day_photos:
            b = block_label(p["datetime"])
            if not blocks or blocks[-1][0] != b:
                blocks.append((b, []))
            blocks[-1][1].append(p)

        section: list[str] = []
        for name, bphotos in blocks:
            primaries, secondaries = [], []
            for p in bphotos:
                card = build_card(p)
                if card is None:
                    continue
                (primaries if p["shot_type"] == "primary" else
                 secondaries).append(card)
            grids = ""
            if primaries:
                grids += f"<div class='pgrid'>{''.join(primaries)}</div>"
            if len(secondaries) > 1:  # a lone detail shot looks stranded; drop
                grids += f"<div class='sgrid'>{''.join(secondaries)}</div>"
            if grids:
                section.append(
                    f"<h2 class='block'>{html.escape(name)}</h2>{grids}")
        if section:
            parts.append(
                f"<section class='day'><div class='feed'>{''.join(section)}"
                "</div></section>")

    parts.append("</main></div>")
    parts.append(f"<script>{JS}</script>")

    out = args.out_dir / "report.html"
    out.write_text("".join(parts))
    print(f"Wrote {out} ({len(shown)} photos shown)")


if __name__ == "__main__":
    main()
