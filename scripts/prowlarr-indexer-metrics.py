#!/usr/bin/env python3
"""Export real Prowlarr query outcomes per indexer, attributed to its solver.

WHY THIS REPLACES THE SYNTHETIC PROBE AS THE PRIMARY SIGNAL

This replaced scripts/solver-probe.py, which asked both Cloudflare solvers
for the same URLs and compared them. That probe was deleted along with
FlareSolverr on 2026-09-06. It was a fair comparison and it measured the
wrong thing three ways:

  - It fetches homepages. Prowlarr fetches SEARCH pages with parameters and
    reuses sessions. A solver can pass one and fail the other.
  - It only targets 1337x mirrors, so it largely measures that one site's
    Cloudflare configuration rather than solver capability.
  - It generates load. Ten browser sessions every 30 minutes is ~96 requests
    per day per target from one address, which is itself the pattern that
    gets an IP blocked. A probe that causes the failure it measures is worse
    than no probe.

Prowlarr already records the ground truth: every RSS poll and every search,
with a success flag, a timestamp and an elapsed time, per indexer. Real
traffic, no extra load, no risk of provoking a block. This reads that.

The solver is attributed through the indexer's tag, so an indexer tagged
`byparr` contributes to byparr's numbers. That made a genuine A/B possible
on the SAME site over time rather than comparing different sites. ByParr is
now the only solver, so this reads as a per-indexer success rate; the
attribution stays because it is how a second solver would be evaluated if
one is ever added.

Read-only against Prowlarr's API.

Run by systemd/mediastack-prowlarr-metrics.timer.
"""
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from collections import defaultdict
from datetime import datetime, timedelta, timezone

OUT_DIR = os.environ.get("PROWLARR_METRICS_OUT", "/textfile")
METRIC_FILE = "prowlarr_indexers.prom"
BASE = os.environ.get("PROWLARR_URL", "http://prowlarr:9696")
API_KEY = os.environ.get("PROWLARR_API_KEY", "")
# How far back to summarise. Long enough to be statistically meaningful,
# short enough that a solver change shows up within a day.
WINDOW_HOURS = int(os.environ.get("PROWLARR_WINDOW_HOURS", "24"))
# Safety rail: history is 15k+ records and grows. Stop paging once past the
# window rather than pulling everything on every run.
MAX_PAGES = int(os.environ.get("PROWLARR_MAX_PAGES", "40"))
PAGE_SIZE = 250


def esc(v):
    return str(v).replace("\\", r"\\").replace('"', r"\"").replace("\n", " ")


def api(path):
    req = urllib.request.Request(BASE.rstrip("/") + "/api/v1/" + path,
                                 headers={"X-Api-Key": API_KEY})
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.loads(r.read().decode())


def main():
    started = time.time()
    if not API_KEY:
        print("PROWLARR_API_KEY not set", file=sys.stderr)
        return 1

    # indexer id -> (name, solver) via tag labels
    tags = {t["id"]: t["label"] for t in api("tag")}
    # The literal tag strings, not the proxy's display name. These differed
    # once: FlareSolverr's tag was `flare` while its proxy was named
    # "FlareSolverr", so matching on display names attributed those indexers
    # to "none" and the numbers read as though nothing used it. FlareSolverr
    # was removed on 2026-09-06, but the old tags stay mapped so history
    # from before then still attributes correctly rather than vanishing
    # into "none".
    solver_aliases = {"byparr": "byparr", "flare": "flaresolverr",
                      "flaresolverr": "flaresolverr", "cloudflare": "flaresolverr"}
    indexers = {}
    for i in api("indexer"):
        labels = [tags.get(t, "") for t in (i.get("tags") or [])]
        solver = next((solver_aliases[l] for l in labels
                       if l in solver_aliases), "none")
        indexers[i["id"]] = (i.get("name", str(i["id"])), solver)

    cutoff = datetime.now(timezone.utc) - timedelta(hours=WINDOW_HOURS)
    counts = defaultdict(int)
    elapsed = defaultdict(list)
    scanned = 0
    reached_cutoff = False

    for page in range(1, MAX_PAGES + 1):
        q = urllib.parse.urlencode({"page": page, "pageSize": PAGE_SIZE,
                                    "sortKey": "date", "sortDirection": "descending"})
        try:
            d = api("history?" + q)
        except (urllib.error.URLError, OSError, ValueError) as e:
            print("history page %d failed: %s" % (page, e), file=sys.stderr)
            break
        recs = d.get("records") or []
        if not recs:
            break
        for r in recs:
            scanned += 1
            try:
                when = datetime.fromisoformat(r["date"].replace("Z", "+00:00"))
            except (KeyError, ValueError):
                continue
            if when < cutoff:
                reached_cutoff = True
                break
            iid = r.get("indexerId")
            if iid not in indexers:
                continue
            name, solver = indexers[iid]
            event = r.get("eventType", "unknown")
            # Only query-shaped events say anything about a solver. Grabs are
            # a different operation and would inflate the success rate.
            if event not in ("indexerQuery", "indexerRss"):
                continue
            result = "success" if r.get("successful") else "failure"
            counts[(name, solver, event, result)] += 1
            try:
                ms = float((r.get("data") or {}).get("elapsedTime"))
                elapsed[(name, solver)].append(ms)
            except (TypeError, ValueError):
                pass
        if reached_cutoff:
            break

    lines = []
    for (name, solver, event, result), n in sorted(counts.items()):
        lines.append('mediastack_prowlarr_queries{indexer="%s",solver="%s",event="%s",result="%s"} %d'
                     % (esc(name), esc(solver), esc(event), result, n))
    for (name, solver), vals in sorted(elapsed.items()):
        if vals:
            lines.append('mediastack_prowlarr_query_elapsed_ms{indexer="%s",solver="%s"} %.0f'
                         % (esc(name), esc(solver), sum(vals) / len(vals)))

    header = [
        "# HELP mediastack_prowlarr_queries Real Prowlarr queries in the window, by indexer, solver and outcome.",
        "# TYPE mediastack_prowlarr_queries gauge",
        "# HELP mediastack_prowlarr_query_elapsed_ms Mean elapsed time Prowlarr recorded per indexer.",
        "# TYPE mediastack_prowlarr_query_elapsed_ms gauge",
        "# HELP mediastack_prowlarr_metrics_window_hours Window these counts cover.",
        "# TYPE mediastack_prowlarr_metrics_window_hours gauge",
        "# HELP mediastack_prowlarr_metrics_records_scanned History records read on the last run.",
        "# TYPE mediastack_prowlarr_metrics_records_scanned gauge",
        "# HELP mediastack_prowlarr_metrics_window_complete Whether paging reached the window edge rather than the page cap.",
        "# TYPE mediastack_prowlarr_metrics_window_complete gauge",
        "# HELP mediastack_prowlarr_metrics_last_run_timestamp_seconds Unix time of the last run.",
        "# TYPE mediastack_prowlarr_metrics_last_run_timestamp_seconds gauge",
    ]
    lines.append("mediastack_prowlarr_metrics_window_hours %d" % WINDOW_HOURS)
    lines.append("mediastack_prowlarr_metrics_records_scanned %d" % scanned)
    # If this is 0 the counts are truncated and the rates are wrong; alert on it
    # rather than quietly reporting a partial window as if it were whole.
    lines.append("mediastack_prowlarr_metrics_window_complete %d" % (1 if reached_cutoff else 0))
    lines.append("mediastack_prowlarr_metrics_last_run_timestamp_seconds %d" % int(started))

    out = os.path.join(OUT_DIR, METRIC_FILE)
    try:
        with open(out + ".tmp", "w") as fh:
            fh.write("\n".join(header + lines) + "\n")
        os.replace(out + ".tmp", out)
    except OSError as e:
        print("failed writing %s: %s" % (out, e), file=sys.stderr)
        return 1

    totals = defaultdict(lambda: [0, 0])
    for (name, solver, _e, result), n in counts.items():
        totals[(name, solver)][0 if result == "success" else 1] += n
    for (name, solver), (ok, bad) in sorted(totals.items()):
        tot = ok + bad
        print("  %-22s solver=%-13s %4d/%-4d  %.1f%%"
              % (name[:20], solver, ok, tot, 100.0 * ok / tot if tot else 0.0))
    print("  scanned %d records, window %dh, complete=%s"
          % (scanned, WINDOW_HOURS, reached_cutoff))
    return 0


if __name__ == "__main__":
    sys.exit(main())
