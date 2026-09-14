#!/usr/bin/env python3
"""File Lidarr's albums into the library's category folders.

    lidarr-file-categories.py            # dry run: print what would move
    lidarr-file-categories.py --apply
    lidarr-file-categories.py --apply --artist "Green Day"

The music library is laid out as

    Artist/
      Albums/  Singles & EPs/  Live/  Compilations/  Remixes/  Other/
        Artist - Year - Album/
          Artist - Album - 01 - Title.flac

Lidarr cannot produce the category level itself. Its only type token,
{Album Type}, is the MusicBrainz primary type (Album / EP / Single), and
Live, Compilation and Remix are secondary types it has no token for. So
Lidarr names everything up to the album folder
(Settings > Media Management, see README "Music") and this script adds the
category from the album's primary + secondary types.

For every track file Lidarr has mapped to an album that is NOT already
under a category folder:
  1. Lidarr's own RenameFiles puts it at Artist/<album folder>/<name>
     (this is what fixes tracks dumped loose in the artist folder);
  2. the album folder is moved under its category, merging into an
     existing one and never overwriting a file;
  3. Lidarr rescans the artist so it re-matches the moved files (it
     writes MusicBrainz ids into the tags, so they match back exactly).

Files already under a category are never touched, and neither is
anything Lidarr has not mapped. Run by mediastack-lidarr-filer.timer
so new imports get filed within minutes.

Runs in a container on `edge` (Lidarr is not reachable from the host)
with the library mounted at /music, the same path Lidarr uses, and as
the media user so ownership is unchanged.
"""
import argparse
import fcntl
import json
import os
import shutil
import sys
import time
import urllib.request

BASE = os.environ.get("LIDARR_URL", "http://lidarr:8686").rstrip("/")
API_KEY = os.environ.get("LIDARR_API_KEY", "")
LOCK_DIR = os.environ.get("LIDARR_FILER_LOCK_DIR", "/music")
CATEGORIES = ("Albums", "Singles & EPs", "Live", "Compilations", "Remixes", "Other")
OTHER_SECONDARY = {"soundtrack", "spokenword", "interview", "audiobook", "audio drama",
                   "demo", "mixtape/street", "field recording"}


def api(method, path, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(f"{BASE}/api/v1/{path}", data=data, method=method,
                                 headers={"X-Api-Key": API_KEY, "Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=300) as r:
        raw = r.read().decode()
        return json.loads(raw) if raw.strip() else None


def run_command(body, timeout=1800):
    cmd = api("POST", "command", body)
    deadline = time.time() + timeout
    while time.time() < deadline:
        st = api("GET", f"command/{cmd['id']}")
        if st["status"] in ("completed", "failed", "aborted", "cancelled"):
            return st["status"]
        time.sleep(3)
    return "timeout"


def secondary_names(album):
    out = set()
    for s in album.get("secondaryTypes") or []:
        out.add((s if isinstance(s, str) else s.get("name", "")).lower())
    return out


def category(album):
    sec = secondary_names(album)
    if "live" in sec:
        return "Live"
    if sec & {"remix", "dj-mix"}:
        return "Remixes"
    if "compilation" in sec:
        return "Compilations"
    if sec & OTHER_SECONDARY:
        return "Other"
    primary = (album.get("albumType") or "").lower()
    if primary == "album":
        return "Albums"
    if primary in ("ep", "single"):
        return "Singles & EPs"
    return "Other"


def rel_parts(path, artist_path):
    return os.path.relpath(path, artist_path).split(os.sep)


def unfiled(trackfiles, artist_path):
    """Mapped track files inside this artist's own folder but not under a category.

    Files Lidarr maps to an artist can live in ANOTHER artist's folder:
    collaborations filed by hand under the other name (David Guetta &
    Avicii tracks under Avicii/Other). Their relative path starts with
    `..`, and treating them as unfiled made RenameFiles pull them out of
    Avicii's folder. Anything outside the artist folder is left alone.
    """
    out = []
    for f in trackfiles:
        if not f.get("albumId"):
            continue
        parts = rel_parts(f["path"], artist_path)
        if parts[0] == ".." or parts[0] in CATEGORIES:
            continue
        out.append(f)
    return out


def merge_move(src, dst, log):
    """Move directory src to dst, merging into dst if it exists. Never overwrites."""
    if not os.path.isdir(src):
        log(f"      {src} is not on disk (Lidarr's record is stale), left for the next run")
        return 1
    if not os.path.exists(dst):
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        os.rename(src, dst)
        return 0
    skipped = 0
    for entry in os.listdir(src):
        s, d = os.path.join(src, entry), os.path.join(dst, entry)
        if os.path.isdir(s) and os.path.isdir(d):
            skipped += merge_move(s, d, log)
        elif os.path.exists(d):
            log(f"      kept both: {d} already exists, left {s}")
            skipped += 1
        else:
            os.rename(s, d)
    if not os.listdir(src):
        os.rmdir(src)
    return skipped


def file_artist(artist, apply, log):
    apath = artist["path"]
    albums = {a["id"]: a for a in api("GET", f"album?artistId={artist['id']}")}
    tfs = api("GET", f"trackfile?artistId={artist['id']}")
    todo = unfiled(tfs, apath)
    if not todo:
        return 0, 0, 0

    # Lidarr's paths can be stale: files moved by hand while its scans
    # were failing (a single unreadable filename aborts a whole library
    # scan). Refresh this artist before trusting them.
    if any(not os.path.exists(f["path"]) for f in todo):
        if apply:
            status = run_command({"name": "RescanFolders", "folders": [apath],
                                  "artistIds": [artist["id"]], "addNewArtists": False})
            if status != "completed":
                log(f"  {artist['artistName']}: stale paths and rescan {status}, skipping artist")
                return 0, 0, 1
            tfs = api("GET", f"trackfile?artistId={artist['id']}")
            todo = unfiled(tfs, apath)
            if not todo:
                return 0, 0, 0
        else:
            log(f"  {artist['artistName']}: Lidarr has stale paths; --apply rescans the artist first")

    # 1. Lidarr names them: loose tracks and odd folders become album
    #    folders. Only unfiled ids are passed -- Lidarr's preview also lists
    #    every filed track, since its format has no category level, and
    #    renaming those would flatten the library.
    preview = {x["trackFileId"]: x["newPath"] for x in api("GET", f"rename?artistId={artist['id']}")}
    to_rename = [f["id"] for f in todo if f["id"] in preview]
    planned = {f["id"]: preview.get(f["id"], f["path"]) for f in todo}
    if apply and to_rename:
        status = run_command({"name": "RenameFiles", "artistId": artist["id"], "files": to_rename})
        if status != "completed":
            log(f"  {artist['artistName']}: RenameFiles {status}, skipping artist")
            return 0, 0, 1
        tfs = api("GET", f"trackfile?artistId={artist['id']}")
        todo = unfiled(tfs, apath)
        planned = {f["id"]: f["path"] for f in todo}

    # 2. Group by album folder; every file in a folder must be one album.
    folders = {}
    for f in todo:
        parts = rel_parts(planned[f["id"]], apath)
        key = parts[0] if len(parts) > 1 else None
        folders.setdefault(key, set()).add(f["albumId"])
    moved = problems = 0
    for folder, album_ids in sorted(folders.items(), key=lambda x: str(x[0])):
        if folder is None:
            log(f"  {artist['artistName']}: {len(album_ids)} album(s) of tracks still loose in the artist folder")
            problems += 1
            continue
        if len(album_ids) != 1:
            log(f"  {artist['artistName']}/{folder}: holds {len(album_ids)} albums, left alone")
            problems += 1
            continue
        album = albums.get(next(iter(album_ids)))
        cat = category(album) if album else "Other"
        src, dst = os.path.join(apath, folder), os.path.join(apath, cat, folder)
        log(f"  {artist['artistName']}: {folder}  ->  {cat}/")
        if apply:
            problems += merge_move(src, dst, log)
        moved += 1

    # 3. Lidarr re-matches the moved files by their tags.
    if apply and moved:
        status = run_command({"name": "RescanFolders", "folders": [apath],
                              "artistIds": [artist["id"]], "addNewArtists": False})
        if status != "completed":
            log(f"  {artist['artistName']}: rescan {status}")
            problems += 1
    return len(todo), moved, problems


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--apply", action="store_true", help="actually move files (default: dry run)")
    ap.add_argument("--artist", help="only this artist (exact Lidarr name)")
    ap.add_argument("--quiet", action="store_true", help="only print when something changes")
    a = ap.parse_args()
    if not API_KEY:
        print("LIDARR_API_KEY not set", file=sys.stderr)
        return 1

    # One run at a time. systemd never overlaps its own runs, but a manual
    # sweep plus a timer run would both queue RenameFiles and race to move
    # the same folders. The lock lives in the library root because that is
    # the one path every run (container or host) shares; flock works
    # across the bind mount since it is the same inode.
    if a.apply:
        lock = open(os.path.join(LOCK_DIR, ".lidarr-filer.lock"), "a")
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            if not a.quiet:
                print("another filer run holds the lock; nothing done")
            return 0

    lines = []
    log = lines.append
    artists = [x for x in api("GET", "artist") if not a.artist or x["artistName"] == a.artist]
    files = folders = problems = 0
    for artist in sorted(artists, key=lambda x: x["artistName"].lower()):
        if not os.path.isdir(artist["path"]):
            continue
        try:
            n, m, p = file_artist(artist, a.apply, log)
        except Exception as e:  # one artist must not stop the rest
            log(f"  {artist['artistName']}: {type(e).__name__}: {e}")
            n, m, p = 0, 0, 1
        files, folders, problems = files + n, folders + m, problems + p
    if lines or not a.quiet:
        print("\n".join(lines))
        verb = "filed" if a.apply else "would file"
        print(f"{verb} {folders} album folder(s) covering {files} track file(s); problems: {problems}")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
