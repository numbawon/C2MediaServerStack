#!/usr/bin/env python3
"""Fetch lyrics from LRCLIB into sidecar files beside every track.

    fetch-lyrics.py                       # the whole library
    fetch-lyrics.py --limit 50 --dry-run  # try it on a few tracks

Writes `<track>.lrc` for synced lyrics and `<track>.txt` for plain ones.
Audio files are never opened for writing: no tag is rewritten, a
hardlinked copy elsewhere is untouched, and undoing it is deleting the
sidecars. Navidrome reads both (before its lyrics plugin) and so does
Plex, which never sees what the Navidrome plugin fetches on the fly.

Skips tracks that already have a sidecar or embedded lyrics, and tracks
LRCLIB did not have when asked in the last 30 days (remembered in
MISS_FILE), so a re-run only asks about new music. Instrumentals are
recorded as misses rather than written.

LRCLIB is a free community service: requests identify this project, run
a few at a time, and back off when it asks. Runs on the host as the
media user, so sidecars get normal ownership.
"""
import argparse
import concurrent.futures
import json
import os
import re
import threading
import time
import urllib.error
import urllib.parse
import urllib.request

import mutagen

ROOT = os.environ.get("MUSIC_ROOT", "/mnt/Media/Music")
MISS_FILE = os.environ.get("LYRICS_MISS_FILE",
                           os.path.expanduser("~/.cache/mediastack/lyrics-misses.json"))
RETRY_AFTER = 30 * 86400
API = "https://lrclib.net/api"
UA = "C2MediaServerStack fetch-lyrics/1.0 (https://github.com/numbawon/C2MediaServerStack)"
AUD = (".mp3", ".flac", ".m4a", ".ogg", ".opus", ".ape", ".wma", ".wav")
lock = threading.Lock()


def get(path, params, tries=5):
    url = f"{API}/{path}?" + urllib.parse.urlencode(params)
    for i in range(tries):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": UA})
            with urllib.request.urlopen(req, timeout=30) as r:
                return json.loads(r.read())
        except urllib.error.HTTPError as e:
            if e.code == 404:
                return None
            if e.code in (429, 500, 502, 503, 504) and i < tries - 1:
                time.sleep(10 * (i + 1))
                continue
            raise
        except (urllib.error.URLError, TimeoutError):
            if i < tries - 1:
                time.sleep(10 * (i + 1))
                continue
            raise


def clean(title):
    """Drop what LRCLIB's titles rarely carry: featured artists, remaster notes."""
    t = re.sub(r"\s*[\(\[](feat\.?|ft\.?|featuring|with)\b[^\)\]]*[\)\]]", "", title, flags=re.I)
    t = re.sub(r"\s*[\(\[][^\)\]]*remaster[^\)\]]*[\)\]]", "", t, flags=re.I)
    t = re.sub(r"\s+-\s+(\d{4}\s+)?remaster(ed)?.*$", "", t, flags=re.I)
    return t.strip()


def has_embedded(m):
    tags = getattr(m, "tags", None) or {}
    try:
        keys = list(tags.keys())
    except Exception:
        return False
    return any(str(k).startswith("USLT") or str(k).lower() in ("lyrics", "unsyncedlyrics", "\xa9lyr")
               for k in keys)


def lookup(path):
    """Return ('lrc'|'txt', text) or (None, reason)."""
    try:
        m = mutagen.File(path)
        e = mutagen.File(path, easy=True) or {}
    except Exception:
        return None, "unreadable"
    if m is None:
        return None, "unreadable"
    if has_embedded(m):
        return None, "embedded"
    artist = ((e.get("artist") or e.get("albumartist") or [""])[0]).strip()
    title = ((e.get("title") or [""])[0]).strip()
    album = ((e.get("album") or [""])[0]).strip()
    dur = int(round(getattr(m.info, "length", 0) or 0))
    if not artist or not title or not dur:
        return None, "no tags"

    hit = get("get", {"artist_name": artist, "track_name": title, "album_name": album, "duration": dur})
    if not hit and clean(title) != title:
        hit = get("get", {"artist_name": artist, "track_name": clean(title), "album_name": album, "duration": dur})
    if not hit:
        # Search ignores the album, which is what a compilation or a
        # re-release needs; the duration check keeps it to the same take.
        res = get("search", {"artist_name": artist, "track_name": clean(title)}) or []
        near = [r for r in res if abs((r.get("duration") or 0) - dur) <= 2]
        near.sort(key=lambda r: (not r.get("syncedLyrics"), abs((r.get("duration") or 0) - dur)))
        hit = near[0] if near else None
    if not hit:
        return None, "not found"
    if hit.get("instrumental"):
        return None, "instrumental"
    if hit.get("syncedLyrics"):
        return "lrc", hit["syncedLyrics"]
    if hit.get("plainLyrics"):
        return "txt", hit["plainLyrics"]
    return None, "empty"


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--limit", type=int, default=0, help="stop after this many lookups")
    ap.add_argument("--dry-run", action="store_true", help="look up, but write nothing")
    ap.add_argument("--workers", type=int, default=2)
    ap.add_argument("--pause", type=float, default=0.25, help="seconds each worker waits between tracks")
    a = ap.parse_args()

    misses = {}
    if os.path.exists(MISS_FILE):
        misses = json.load(open(MISS_FILE))
    now = time.time()

    todo = []
    for r, _, fs in os.walk(ROOT):
        names = set(fs)
        for f in sorted(fs):
            if not f.lower().endswith(AUD):
                continue
            stem = os.path.splitext(f)[0]
            if stem + ".lrc" in names or stem + ".txt" in names:
                continue
            p = os.path.join(r, f)
            if now - misses.get(p, 0) < RETRY_AFTER:
                continue
            todo.append(p)
    if a.limit:
        todo = todo[:a.limit]
    print(f"{len(todo)} tracks to look up", flush=True)

    counts = {"lrc": 0, "txt": 0}
    reasons = {}
    done = 0

    def work(p):
        # One track's failure must not end the run: LRCLIB answers 503
        # in bursts, and a lookup that exhausts its retries raised through
        # the executor and killed a pass 30 000 tracks from done. An
        # errored track is not recorded as a miss, so the next run retries.
        try:
            kind, text = lookup(p)
        except Exception as e:
            kind, text = None, "error"
        time.sleep(a.pause)
        return p, kind, text

    with concurrent.futures.ThreadPoolExecutor(a.workers) as ex:
        for p, kind, text in ex.map(work, todo):
            done += 1
            if kind:
                counts[kind] += 1
                if not a.dry_run:
                    out = os.path.splitext(p)[0] + "." + kind
                    with open(out, "w", encoding="utf-8") as fh:
                        fh.write(text.rstrip() + "\n")
                    os.chmod(out, 0o644)
            else:
                reasons[text] = reasons.get(text, 0) + 1
                if text in ("not found", "instrumental", "empty"):
                    with lock:
                        misses[p] = now
            if done % 500 == 0:
                print(f"  {done}/{len(todo)}  synced {counts['lrc']}  plain {counts['txt']}  {reasons}", flush=True)
                if not a.dry_run:
                    os.makedirs(os.path.dirname(MISS_FILE), exist_ok=True)
                    json.dump(misses, open(MISS_FILE, "w"))

    if not a.dry_run:
        os.makedirs(os.path.dirname(MISS_FILE), exist_ok=True)
        json.dump(misses, open(MISS_FILE, "w"))
    verb = "found" if a.dry_run else "wrote"
    print(f"{verb} {counts['lrc']} synced and {counts['txt']} plain; skipped {reasons}", flush=True)


if __name__ == "__main__":
    main()
