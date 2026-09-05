"""Extract embedded cover art from M4A/M4B files into PinePods' _artwork dir.

PinePods does this itself for MP3s, but silently skips MP4-container files:
Heist's six .m4a files each carry a ~58 KB cover and all six imported with no
artwork at all (the same blind spot that left their durations at 0). This
writes the covers using PinePods' own convention, a UUID-named file under
_artwork served as /api/local-media/_artwork/<uuid>.<ext>, and prints a TSV of
filename -> artwork URL for the database update.

Usage: extract_covers.py <podcast_dir> <artwork_dir> <out.tsv>
"""
import sys, os, uuid
from mutagen.mp4 import MP4, AtomDataType

podcast_dir, artwork_dir, out_path = sys.argv[1], sys.argv[2], sys.argv[3]
os.makedirs(artwork_dir, exist_ok=True)

rows = []
for name in sorted(os.listdir(podcast_dir)):
    if name.startswith(".") or not name.lower().endswith((".m4a", ".m4b", ".mp4")):
        continue
    path = os.path.join(podcast_dir, name)
    tags = MP4(path).tags
    covers = tags.get("covr") if tags else None
    if not covers:
        print("  no cover: %s" % name[:55])
        continue

    cover = covers[0]
    ext = "png" if cover.imageformat == AtomDataType.PNG else "jpg"
    fname = "%s.%s" % (uuid.uuid4(), ext)
    dest = os.path.join(artwork_dir, fname)
    with open(dest, "wb") as fh:
        fh.write(bytes(cover))
    os.chmod(dest, 0o644)

    url = "/api/local-media/_artwork/%s" % fname
    rows.append((name, url))
    print("  %-46s -> %s (%d bytes)" % (name[:44], fname, len(bytes(cover))))

with open(out_path, "w") as fh:
    for name, url in rows:
        fh.write("%s\t%s\n" % (name.replace("\\", "\\\\"), url))

print("extracted %d cover(s)" % len(rows))
