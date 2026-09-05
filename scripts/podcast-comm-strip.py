"""Back up and remove ID3 COMM frames so PinePods can import the podcast.

WHY: PinePods reads COMM as the episode description, and its reader keeps the
frame's description-terminator NUL. Postgres rejects 0x00 in text, so a single
COMM frame anywhere in the directory fails the episode insert for the WHOLE
podcast ("invalid byte sequence for encoding UTF8: 0x00"). Verified against
both UTF-16 and UTF-8 COMM frames, so re-encoding is not a fix. Removing the
frame is.

Nothing is discarded: every frame is written to .comm-undo.json in the same
directory first, and --restore puts them back byte-for-byte. The text also
gets written into PinePods' own episodedescription column separately, so the
descriptions still show up in the app.

Usage:
  comm_strip.py <dir>            report only
  comm_strip.py <dir> --apply    back up, then strip
  comm_strip.py <dir> --restore  put the frames back from .comm-undo.json
"""
import sys, os, json
from mutagen.id3 import ID3, COMM

directory = sys.argv[1]
apply_changes = "--apply" in sys.argv
restore = "--restore" in sys.argv
undo_path = os.path.join(directory, ".comm-undo.json")

AUDIO = (".mp3", ".m4a", ".m4b")


def audio_files():
    for name in sorted(os.listdir(directory)):
        if not name.startswith(".") and name.lower().endswith(AUDIO):
            yield name


if restore:
    with open(undo_path) as fh:
        undo = json.load(fh)
    n = 0
    for name, frames in sorted(undo.items()):
        path = os.path.join(directory, name)
        if not os.path.exists(path):
            print("  MISSING, skipped: %s" % name)
            continue
        tags = ID3(path)
        tags.delall("COMM")
        for f in frames:
            tags.add(COMM(encoding=f["encoding"], lang=f["lang"],
                          desc=f["desc"], text=f["text"]))
        tags.save(path, v1=0, v2_version=4)
        n += 1
    print("restored COMM on %d files" % n)
    sys.exit(0)

undo = {}
for name in audio_files():
    path = os.path.join(directory, name)
    try:
        tags = ID3(path)
    except Exception:
        continue
    frames = tags.getall("COMM")
    if not frames:
        continue
    undo[name] = [{"encoding": int(f.encoding), "lang": f.lang, "desc": f.desc,
                   "text": [str(t) for t in f.text]} for f in frames]

print("  %d of %d files carry COMM" % (len(undo), sum(1 for _ in audio_files())))
if not apply_changes:
    print("  dry run, nothing written")
    sys.exit(0)

with open(undo_path, "w") as fh:
    json.dump(undo, fh, ensure_ascii=False, indent=1)
print("  backed up to %s" % os.path.basename(undo_path))

for name in undo:
    path = os.path.join(directory, name)
    tags = ID3(path)
    tags.delall("COMM")
    tags.save(path, v1=0, v2_version=4)
print("  stripped COMM from %d files" % len(undo))
