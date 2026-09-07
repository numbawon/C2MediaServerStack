#!/usr/bin/env python3
"""Check the media trees against the apps that index them, and emit metrics.

WHY THIS EXISTS

Every media failure this stack has actually hit was silent. A PinePods import
that lands zero episodes returns a 500 the UI does not surface. Six .m4a files
imported with durations of 0 and no artwork at all, and nothing said so. 856
episode titles sat stale in the database for days after their files were
retagged, because an import only ever inserts NEW episodes and will never
correct an existing row. In each case the container was up, the mounts were
fine, and no log line mentioned it.

Nothing here uses an LLM, deliberately. These are exact comparisons between
what is on disk and what the database says, and a language model would only
make them less reliable. scripts/ai-digest.py reads the metrics this writes
and does the part that genuinely needs judgement: saying which of them matter
tonight. If that script never runs, these checks and their alerts are
unaffected.

Follows scripts/verify-backups.sh: write .prom files into the node-exporter
textfile volume, let Prometheus alert on them, so a job that runs on a timer
becomes something continuously alertable.

Run by systemd/mediastack-media-watchdog.timer.
"""
import json
import os
import subprocess
import sys
import time

TEXTFILE_VOLUME = "node_exporter_textfile"
METRIC_FILE = "media_watchdog.prom"
PG_FILTER = "mediastack_pinepods-postgres"

# PinePods stores this prefix on every local episode's URL.
LOCAL_PREFIX = "local:///opt/pinepods/local-media/"

AUDIO_EXT = (".mp3", ".m4a", ".m4b", ".ogg", ".flac", ".opus", ".wav")

# Directories under the podcast root that are not podcasts. _artwork is
# PinePods' own extracted cover cache, one file per episode.
NOT_A_PODCAST = {"_artwork"}


def sh(cmd, **kw):
    return subprocess.run(cmd, shell=isinstance(cmd, str), capture_output=True,
                          text=True, **kw)


def pg_container():
    r = sh(["docker", "ps", "--filter", "name=" + PG_FILTER, "--format", "{{.Names}}"])
    names = [n for n in r.stdout.split() if n]
    return names[0] if names else None


def psql(container, query):
    """Run a query and return rows as lists of strings.

    -tAF$'\\t' gives tuples-only, unaligned, tab-separated, which is the only
    shape that survives titles containing commas, quotes and newlines.
    """
    r = sh(["docker", "exec", container, "psql", "-U", "pinepods", "-d", "pinepods",
            "-tAF\t", "-c", query])
    if r.returncode != 0:
        raise RuntimeError("psql failed: " + r.stderr.strip()[:300])
    return [line.split("\t") for line in r.stdout.splitlines() if line]


def file_title(path):
    """Best-effort episode title from a file's tags, or None."""
    try:
        from mutagen import File as MFile
        f = MFile(path)
        if f is None or not f.tags:
            return None
        for key in ("TIT2", "\xa9nam", "title", "Title", "TITLE"):
            if key in f.tags:
                v = f.tags[key]
                v = v[0] if isinstance(v, list) and v else v
                return str(v)
    except Exception:
        pass
    return None


def has_comm(path):
    """Does this file carry an ID3 COMM frame?

    PinePods reads COMM as the episode description and keeps the frame's
    description-terminator NUL, which Postgres rejects, so one COMM frame
    anywhere in a folder fails that whole podcast's import. Files already
    imported are fine; this is about the NEXT import.
    """
    if not path.lower().endswith(".mp3"):
        return False
    try:
        from mutagen.id3 import ID3
        return bool(ID3(path).getall("COMM"))
    except Exception:
        return False


def audio_files(directory):
    try:
        names = os.listdir(directory)
    except OSError:
        return []
    return sorted(n for n in names
                  if not n.startswith(".") and n.lower().endswith(AUDIO_EXT))


def esc(v):
    return str(v).replace("\\", r"\\").replace('"', r"\"").replace("\n", " ")


def main():
    started = time.time()
    media = os.environ.get("COMMON_MEDIA", "/mnt/Media")
    podcast_root = os.path.join(media, "Podcasts")

    lines = []
    ok = 1
    problems = []

    def metric(name, value, **labels):
        if labels:
            lab = ",".join('%s="%s"' % (k, esc(v)) for k, v in sorted(labels.items()))
            lines.append("%s{%s} %s" % (name, lab, value))
        else:
            lines.append("%s %s" % (name, value))

    # -----------------------------------------------------------------
    # PinePods: disk versus database
    # -----------------------------------------------------------------
    container = pg_container()
    if not container:
        ok = 0
        problems.append({"check": "pinepods_db", "detail": "postgres container not found"})
    else:
        try:
            pods = psql(container,
                        'SELECT podcastid, podcastname FROM "Podcasts" ORDER BY podcastid;')
            eps = psql(container,
                       'SELECT p.podcastname, e.episodeurl, e.episodetitle, '
                       'coalesce(e.episodeduration,0), coalesce(e.episodeartwork,\'\') '
                       'FROM "Episodes" e JOIN "Podcasts" p USING(podcastid);')
        except Exception as exc:
            ok = 0
            problems.append({"check": "pinepods_db", "detail": str(exc)[:200]})
            pods, eps = [], []

        # Keyed by podcast NAME, but PinePods is multi-user and each
        # subscription is its own podcastid with its own episode rows. Two
        # accounts subscribed to one show therefore yield two Podcasts rows
        # and two full sets of Episodes. Collapsing on the episode URL keeps
        # the counts describing the show rather than the number of people
        # listening to it, which is what "does disk match the database"
        # actually asks.
        by_pod = {}
        for row in eps:
            if len(row) < 5:
                continue
            name, url, title, dur, art = row[0], row[1], row[2], row[3], row[4]
            d = by_pod.setdefault(name, {"eps": {}})
            d["eps"][url] = (title, dur, art)

        for d in by_pod.values():
            d["rows"] = [(u, t) for u, (t, _dur, _art) in d["eps"].items()]
            d["zero_dur"] = sum(1 for (_t, dur, _a) in d["eps"].values() if dur in ("", "0"))
            d["no_art"] = sum(1 for (_t, _d, art) in d["eps"].values() if art == "")

        db_names = {p[1] for p in pods if len(p) > 1}

        # Folders on disk that no app knows about.
        try:
            dirs = sorted(d for d in os.listdir(podcast_root)
                          if os.path.isdir(os.path.join(podcast_root, d))
                          and d not in NOT_A_PODCAST and not d.startswith("."))
        except OSError as exc:
            dirs = []
            ok = 0
            problems.append({"check": "podcast_root", "detail": str(exc)[:200]})

        for d in dirs:
            files = audio_files(os.path.join(podcast_root, d))
            imported = 1 if d in db_names else 0
            metric("mediastack_media_podcast_imported", imported, podcast=d)
            metric("mediastack_media_podcast_files_on_disk", len(files), podcast=d)
            if not imported and files:
                problems.append({"check": "not_imported", "podcast": d,
                                 "detail": "%d audio files on disk, no PinePods entry" % len(files)})

            # COMM frames block the NEXT import of this folder.
            comm = sum(1 for n in files if has_comm(os.path.join(podcast_root, d, n)))
            metric("mediastack_media_podcast_comm_frames", comm, podcast=d)
            if comm:
                problems.append({"check": "comm_frames", "podcast": d,
                                 "detail": "%d file(s) carry an ID3 COMM frame, which will fail "
                                           "the next import of this folder" % comm})

        # One emission per podcast NAME, not per Podcasts row. Emitting per
        # row produced two identical metric lines for every show more than
        # one account subscribes to, and node_exporter's textfile collector
        # rejects duplicate name+label pairs: node_textfile_scrape_error
        # went to 1 and the whole file stopped parsing.
        seen_names = set()
        for row in pods:
            if len(row) < 2:
                continue
            name = row[1]
            if name in seen_names:
                continue
            seen_names.add(name)
            d = by_pod.get(name, {"rows": [], "zero_dur": 0, "no_art": 0})
            n_db = len(d["rows"])
            metric("mediastack_media_podcast_episodes_in_db", n_db, podcast=name)
            metric("mediastack_media_podcast_zero_duration_episodes", d["zero_dur"], podcast=name)
            metric("mediastack_media_podcast_missing_artwork_episodes", d["no_art"], podcast=name)

            if n_db == 0:
                problems.append({"check": "empty_podcast", "podcast": name,
                                 "detail": "podcast row exists with zero episodes"})
            if d["zero_dur"]:
                problems.append({"check": "zero_duration", "podcast": name,
                                 "detail": "%d episode(s) have no duration" % d["zero_dur"]})
            if n_db and d["no_art"] == n_db:
                problems.append({"check": "no_artwork", "podcast": name,
                                 "detail": "no episode has artwork"})

            # Orphans and title drift, both file-by-file.
            orphans = drift = 0
            for url, title in d["rows"]:
                if not url.startswith(LOCAL_PREFIX):
                    continue
                path = os.path.join(media, "Podcasts", url[len(LOCAL_PREFIX):])
                if not os.path.exists(path):
                    orphans += 1
                    continue
                tag = file_title(path)
                if tag is not None and tag.strip() and tag.strip() != (title or "").strip():
                    drift += 1
            metric("mediastack_media_podcast_orphan_episodes", orphans, podcast=name)
            metric("mediastack_media_podcast_title_drift_episodes", drift, podcast=name)
            if orphans:
                problems.append({"check": "orphan_episodes", "podcast": name,
                                 "detail": "%d episode(s) point at a file that no longer exists" % orphans})
            if drift:
                problems.append({"check": "title_drift", "podcast": name,
                                 "detail": "%d episode title(s) no longer match the file's tag; "
                                           "an import will not fix these, the rows need updating" % drift})

    # -----------------------------------------------------------------
    # Ownership: anything running as root leaves files nobody else can fix
    # -----------------------------------------------------------------
    for tree in ("Podcasts", "Audiobooks", "Music", "TV", "Movies"):
        path = os.path.join(media, tree)
        if not os.path.isdir(path):
            continue
        r = sh(["find", path, "-uid", "0", "-print"])
        n = len([x for x in r.stdout.splitlines() if x])
        metric("mediastack_media_root_owned_files", n, tree=tree)
        if n:
            problems.append({"check": "root_owned", "tree": tree,
                             "detail": "%d root-owned path(s); an app is running as uid 0" % n})

    # -----------------------------------------------------------------
    # Emit
    # -----------------------------------------------------------------
    header = [
        "# HELP mediastack_media_podcast_imported Whether a podcast folder on disk has a PinePods entry.",
        "# TYPE mediastack_media_podcast_imported gauge",
        "# HELP mediastack_media_podcast_files_on_disk Audio files present in the podcast folder.",
        "# TYPE mediastack_media_podcast_files_on_disk gauge",
        "# HELP mediastack_media_podcast_episodes_in_db Episode rows PinePods holds for the podcast.",
        "# TYPE mediastack_media_podcast_episodes_in_db gauge",
        "# HELP mediastack_media_podcast_zero_duration_episodes Episodes whose duration is missing or zero.",
        "# TYPE mediastack_media_podcast_zero_duration_episodes gauge",
        "# HELP mediastack_media_podcast_missing_artwork_episodes Episodes with no artwork URL.",
        "# TYPE mediastack_media_podcast_missing_artwork_episodes gauge",
        "# HELP mediastack_media_podcast_orphan_episodes Episode rows pointing at a file that no longer exists.",
        "# TYPE mediastack_media_podcast_orphan_episodes gauge",
        "# HELP mediastack_media_podcast_title_drift_episodes Episodes whose stored title differs from the file tag.",
        "# TYPE mediastack_media_podcast_title_drift_episodes gauge",
        "# HELP mediastack_media_podcast_comm_frames Files carrying an ID3 COMM frame, which fails the next import.",
        "# TYPE mediastack_media_podcast_comm_frames gauge",
        "# HELP mediastack_media_root_owned_files Root-owned paths under a media tree.",
        "# TYPE mediastack_media_root_owned_files gauge",
        "# HELP mediastack_media_watchdog_problems Distinct problems found on the last run.",
        "# TYPE mediastack_media_watchdog_problems gauge",
        "# HELP mediastack_media_watchdog_success Whether the last run completed its checks.",
        "# TYPE mediastack_media_watchdog_success gauge",
        "# HELP mediastack_media_watchdog_last_run_timestamp_seconds Unix time of the last run.",
        "# TYPE mediastack_media_watchdog_last_run_timestamp_seconds gauge",
        "# HELP mediastack_media_watchdog_duration_seconds How long the last run took.",
        "# TYPE mediastack_media_watchdog_duration_seconds gauge",
    ]
    metric("mediastack_media_watchdog_problems", len(problems))
    metric("mediastack_media_watchdog_success", ok)
    metric("mediastack_media_watchdog_last_run_timestamp_seconds", int(started))
    metric("mediastack_media_watchdog_duration_seconds", round(time.time() - started, 2))

    body = "\n".join(header + lines) + "\n"

    # Write via a temp name and mv: node-exporter reads this directory
    # continuously and a half-written file parses as garbage metrics.
    p = subprocess.run(
        ["docker", "run", "--rm", "-i", "-v", "%s:/t" % TEXTFILE_VOLUME, "alpine:latest",
         "sh", "-c", "cat > /t/%s.tmp && mv /t/%s.tmp /t/%s" % (METRIC_FILE, METRIC_FILE, METRIC_FILE)],
        input=body, text=True, capture_output=True)
    if p.returncode != 0:
        print("failed writing metrics: %s" % p.stderr.strip(), file=sys.stderr)
        return 1

    # A findings file next to the metrics, for scripts/ai-digest.py. Metrics
    # carry the numbers; this carries the wording, which a digest needs.
    findings = {"timestamp": int(started), "ok": ok, "problems": problems}
    subprocess.run(
        ["docker", "run", "--rm", "-i", "-v", "%s:/t" % TEXTFILE_VOLUME, "alpine:latest",
         "sh", "-c", "cat > /t/media_findings.json.tmp && mv /t/media_findings.json.tmp /t/media_findings.json"],
        input=json.dumps(findings, indent=1), text=True, capture_output=True)

    for pr in problems:
        print("  %-16s %s: %s" % (pr["check"],
                                  pr.get("podcast") or pr.get("tree") or "-",
                                  pr["detail"]))
    print("%d problem(s), success=%d, %.1fs" % (len(problems), ok, time.time() - started))
    return 0


if __name__ == "__main__":
    sys.exit(main())
