#!/usr/bin/env python3
"""One-off normalizer for the music library layout.

    music-normalize.py plan  > plan.tsv     # compute every move, change nothing
    music-normalize.py apply plan.tsv        # do them, write an undo log
    music-normalize.py undo  undo.tsv        # reverse an apply

Target layout, the one most of the library already used (2,079 album
folders vs 359, and "NN - Title" as the commonest track name):

    Artist/<Category>/<Year> - <Album>/<NN> - <Title>.<ext>

What it does:
  - merges alias artist folders into the real one (MERGE below) and
    collaboration folders ("A & B", "A, B", "A f. B") into the first-named
    artist;
  - files album folders sitting directly under an artist into a category
    (Lidarr's album types when Lidarr knows the album, else the folder
    name: Live/Unplugged -> Live, Remix -> Remixes, Greatest Hits/Best
    Of/Essentials -> Compilations, EP/Single -> Singles & EPs, Demo ->
    Other, else Albums);
  - renames "Artist - Year - Album" folders to "Year - Album", and adds
    the year from the tags to folders that lack one;
  - renames tracks to "NN - Title" from their current names ("01. X",
    "Artist - Album - 01 - X", "01 X", scene "01-artist-x-grp"), using the
    tag's title only to restore capitalisation of a scene name, and the
    tag's track number only when the name has none;
  - moves sidecars (.lrc/.txt with the same stem) along with their track.

It never overwrites: a destination that exists is reported and skipped.
Categories, containers (Various Artists, Soundtracks, ...) and anything
it cannot parse are left where they are and reported.
"""
import csv, json, os, re, subprocess, sys, unicodedata
from collections import Counter, defaultdict

ROOT = os.environ.get("MUSIC_ROOT", "/mnt/Media/Music")
CATS = ("Albums", "Singles & EPs", "Live", "Compilations", "Remixes", "Other")
AUD = (".flac", ".mp3", ".m4a", ".ogg", ".opus", ".wav", ".aac", ".alac", ".wma", ".ape", ".wv")
SIDE = (".lrc", ".txt")
# Containers, not artists: left alone.
CONTAINERS = {"Various Artists", "VA", "Soundtracks", "Original Soundtrack", "Non-Album",
              "Radio Show - A State Of Trance", "EVE Online Soundtrack", "Cyberpunk 2077 OST",
              "Erotic Massage Lounge - Sexy Chillout Obsession Music for Intimate Moments and Relaxation (2017)",
              "Hybrid Theory"}
# Alias -> real artist folder (decided by reading tags, 2026-09-13).
MERGE = {
    "IRON MAIDEN": "Iron Maiden", "System of A Down": "System of a Down", "Killers": "The Killers",
    "Bowie": "David Bowie", "Weezer-Death to False Metal": "Weezer", "Mister Hahn": "Mr. Hahn",
    "Ralph": "DJ Ralph", "What If (CD Single) Belgium": "Coldplay", "AlbumArtist": "Jay-Z",
}
COLLAB_SPLIT = re.compile(r"\s*(?:&|,| and | And | f\. | feat\.? | ft\. |\+| - | vs\.? | x )\s*")


def lidarr_artists():
    p = os.environ.get("LIDARR_ARTISTS_JSON")
    return {os.path.basename(a["path"]) for a in json.load(open(p))} if p else set()


def tags(path):
    out = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format_tags", "-of", "json", path],
                         capture_output=True, text=True).stdout
    try:
        return {k.lower(): v for k, v in json.loads(out).get("format", {}).get("tags", {}).items()}
    except Exception:
        return {}


def clean(name):
    name = name.replace("/", "-").replace("\\", "-").replace(":", " -").replace("?", "").replace("*", "")
    name = name.replace('"', "'").replace("<", "").replace(">", "").replace("|", "-")
    return re.sub(r"\s+", " ", name).strip().rstrip(".")


def norm(s):
    s = unicodedata.normalize("NFKD", s).encode("ascii", "ignore").decode().lower()
    return re.sub(r"[^a-z0-9]", "", s)


def smart_title(s):
    return " ".join(w[:1].upper() + w[1:] for w in s.split(" "))


YEAR_RE = re.compile(r"^(\d{4}[a-z]?)\s*[-–]\s*(.+)$")


def album_folder(name, artist_names, files):
    """-> 'Year - Album' (or the original name when no year can be found)."""
    n = name
    for a in artist_names:
        for sep in (" - ", " – "):
            if n.lower().startswith(a.lower() + sep):
                n = n[len(a) + len(sep):]
    m = YEAR_RE.match(n)
    if m:
        return clean(f"{m.group(1)} - {m.group(2)}"), None
    years = Counter()
    for f in files[:12]:
        t = tags(f)
        y = re.match(r"(\d{4})", t.get("originaldate") or t.get("original_year") or t.get("date") or t.get("year") or "")
        if y:
            years[y.group(1)] += 1
    if years:
        return clean(f"{years.most_common(1)[0][0]} - {n}"), None
    return clean(n), "no year in name or tags"


TRACK_PATTERNS = [
    re.compile(r"^(?P<n>\d{1,2}-\d{2}) - (?P<t>.+)$"),                       # 01-03 - Title (multi-disc)
    re.compile(r"^(?P<n>\d{1,2}-\d{2})\.?\s+(?P<t>[^-].*)$"),                # 1-06. Title / 1-06 Title
    re.compile(r"^(?P<n>\d{2,3}) - (?P<t>.+)$"),                            # 01 - Title
    re.compile(r"^(?P<n>\d{1,3})\.\s*(?P<t>.+)$"),                          # 01. Title
    re.compile(r"^.+? [-–] .+? [-–] (?P<n>\d{1,2}(?:-\d{2})?) [-–] (?P<t>.+)$"),  # Artist - Album - 01 - Title
    re.compile(r"^(?P<n>\d{1,3})[-_](?P<scene>[a-z0-9_()'.,&!+]+-[a-z0-9_()'.,&!+]+(?:-[a-z0-9_()'.,&!+]+)?)$"),  # 01-artist-title-grp
    re.compile(r"^(?P<n>\d{1,3})-(?P<t>[^-\d\s].*)$"),                     # 09-Title
    re.compile(r"^(?P<n>\d{1,3})\s+(?P<t>[^-\d].*)$"),                      # 01 Title
]


def strip_prefixes(title, artist_names, album):
    """'Sting - The Complete Chicago Sessions (Disc 1) - If' -> 'If'."""
    changed = True
    while changed:
        changed = False
        for a in artist_names:
            for sep in (" - ", " – "):
                if title.lower().startswith(a.lower() + sep):
                    title, changed = title[len(a) + len(sep):], True
        parts = re.split(r"\s+[-–]\s+", title, maxsplit=1)
        if album and len(parts) == 2 and (norm(parts[0]).startswith(norm(album)) or norm(album).startswith(norm(parts[0]))) and len(norm(parts[0])) >= 4:
            title, changed = parts[1], True
    return title.strip()


def track_name(fname, artist_names, path, album="", oneoff=False):
    """-> ('NN - Title.ext', note). One-off tracks (singles sitting straight in a
    category folder) and tracks numbered 00 or not at all get just 'Title.ext'."""
    stem, ext = os.path.splitext(fname)
    for pat in TRACK_PATTERNS:
        m = pat.match(stem)
        if not m:
            continue
        num = m.group("n")
        if "scene" in m.groupdict() and m.group("scene"):
            parts = m.group("scene").split("-")
            if len(parts) >= 2 and norm(parts[0].replace("_", " ")) in {norm(a) for a in artist_names}:
                parts = parts[1:]
            if len(parts) >= 2:
                parts = parts[:-1]                                           # drop release-group suffix
            title = " ".join(parts).replace("_", " ")
            tt = tags(path).get("title", "")
            title = tt if tt and norm(tt) == norm(title) else smart_title(title)
        else:
            title = m.group("t")
        title = strip_prefixes(title, artist_names, album)
        if oneoff or re.fullmatch(r"0+", num):
            return clean(title) + ext.lower(), None
        if "-" in num:
            d, t = num.split("-")
            num = f"{int(d):02d}-{t}"
        else:
            num = f"{int(num):02d}"
        return clean(f"{num} - {title}") + ext.lower(), None
    t = tags(path)
    tn = re.match(r"(\d+)", t.get("track", ""))
    title = strip_prefixes(re.sub(r"^[A-Da-d]\d{1,2}\.?\s+", "", stem), artist_names, album)  # vinyl: A2. Title
    if tn and int(tn.group(1)) > 0 and not oneoff:
        return clean(f"{int(tn.group(1)):02d} - {title}") + ext.lower(), None
    return clean(title) + ext.lower(), None


def category_for(folder):
    f = folder.lower()
    if re.search(r"\blive\b|unplugged|\bconcert\b|\btour\b|\d{2}[-.]\d{2}[-.]\d{2,4}", f):
        return "Live"
    if re.search(r"remix|\brmx\b|\bmixes\b", f):
        return "Remixes"
    if re.search(r"greatest hits|best of|essentials|anthology|collection|\bhits\b|compilation", f):
        return "Compilations"
    if re.search(r"\bep\b|single|\bcds\b", f):
        return "Singles & EPs"
    if re.search(r"\bdemo", f):
        return "Other"
    return "Albums"


def plan(out):
    lid = lidarr_artists()
    w = csv.writer(out, delimiter="\t", lineterminator="\n")
    notes = []
    for a in sorted(os.listdir(ROOT)):
        ap = os.path.join(ROOT, a)
        if not os.path.isdir(ap) or a.startswith(".") or a in CONTAINERS:
            continue
        target = MERGE.get(a)
        if not target and a not in lid:
            parts = [p for p in COLLAB_SPLIT.split(a) if p]
            if len(parts) > 1:
                target = parts[0].strip()
        target = target or a
        names = sorted({a, target, *[p for p in COLLAB_SPLIT.split(a) if p]}, key=len, reverse=True)
        for entry in sorted(os.listdir(ap)):
            ep = os.path.join(ap, entry)
            if os.path.isfile(ep):
                if entry.lower().endswith(AUD):
                    notes.append(f"loose track left: {a}/{entry}")
                continue
            if entry in CATS:
                cat, albums = entry, [(d, os.path.join(ep, d)) for d in sorted(os.listdir(ep)) if os.path.isdir(os.path.join(ep, d))]
                # one-off tracks directly inside a category folder: keep them
                # there, named by title alone
                for f in sorted(os.listdir(ep)):
                    if f.lower().endswith(AUD):
                        nf, _ = track_name(f, names, os.path.join(ep, f), oneoff=True)
                        dst = os.path.join(ROOT, target, entry, nf)
                        if dst != os.path.join(ep, f):
                            w.writerow([os.path.join(ep, f), dst])
            else:
                cat, albums = category_for(entry), [(entry, ep)]
            for alb, albp in albums:
                files = []
                for r, _, fs in os.walk(albp):
                    files += [os.path.join(r, f) for f in fs if f.lower().endswith(AUD)]
                if not files:
                    continue
                newalb, why = album_folder(alb, names, sorted(files))
                if why:
                    notes.append(f"{why}: {a}/{cat}/{alb}")
                for r, _, fs in os.walk(albp):
                    rel = os.path.relpath(r, albp)
                    stems = {}
                    for f in sorted(fs):
                        src = os.path.join(r, f)
                        if f.lower().endswith(AUD):
                            nf, why = track_name(f, names, src, YEAR_RE.sub(r"\2", newalb))
                            if why:
                                notes.append(f"{why}: {a}/{cat}/{alb}/{f}")
                            stems[os.path.splitext(f)[0]] = os.path.splitext(nf)[0]
                        else:
                            nf = f
                        dst = os.path.normpath(os.path.join(ROOT, target, cat, newalb, rel, nf))
                        if dst != src:
                            w.writerow([src, dst])
                    # sidecars follow their track's new stem
                    for f in fs:
                        s, e = os.path.splitext(f)
                        if e.lower() in SIDE and s in stems and stems[s] != s:
                            w.writerow([os.path.join(r, f),
                                        os.path.normpath(os.path.join(ROOT, target, cat, newalb, rel, stems[s] + e))])
    for n in notes:
        print(n, file=sys.stderr)


def apply(planfile):
    rows, seen = [], {}
    for src, dst in csv.reader(open(planfile), delimiter="\t"):
        rows.append((src, dst))
    undo_path = os.path.join(os.path.dirname(os.path.abspath(planfile)), "undo-" + os.path.basename(planfile))
    moved = skipped = 0
    touched = set()
    with open(undo_path, "w") as undo:
        uw = csv.writer(undo, delimiter="\t", lineterminator="\n")
        for src, dst in rows:
            if src == dst or not os.path.exists(src):
                continue
            if os.path.exists(dst) or dst in seen:
                print(f"kept both (destination exists): {dst}", file=sys.stderr)
                skipped += 1
                continue
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            os.rename(src, dst)
            seen[dst] = src
            uw.writerow([dst, src])
            undo.flush()
            moved += 1
            touched.add(os.path.dirname(src))
    # remove directories this run emptied (only those; never pre-existing empty ones)
    removed = 0
    for d in sorted(touched, key=len, reverse=True):
        while d.startswith(ROOT + os.sep) and d != ROOT and os.path.isdir(d) and not os.listdir(d):
            os.rmdir(d)
            removed += 1
            d = os.path.dirname(d)
    print(f"moved {moved}, skipped {skipped}, removed {removed} emptied folders; undo log {undo_path}")


def undo(undofile):
    rows = list(csv.reader(open(undofile), delimiter="\t"))
    n = 0
    for cur, orig in reversed(rows):
        if os.path.exists(cur) and not os.path.exists(orig):
            os.makedirs(os.path.dirname(orig), exist_ok=True)
            os.rename(cur, orig)
            n += 1
    print(f"restored {n} of {len(rows)}")


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "plan"
    if cmd == "plan":
        plan(sys.stdout)
    elif cmd == "apply":
        apply(sys.argv[2])
    elif cmd == "undo":
        undo(sys.argv[2])
