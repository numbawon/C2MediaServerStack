#!/usr/bin/env python3
"""Ask every Cloudflare solver for the same URLs, and export who succeeded.

WHY NOT JUST TAG SOME INDEXERS TO EACH SOLVER

That was the obvious approach and it does not answer the question. Tagging
splits indexers between solvers, so FlareSolverr ends up judged on one set
of sites and ByParr on another. Any difference in the resulting failure
counts is then a property of the sites, not of the solvers, and the sites
differ enormously in how hard they are. A solver handed only the easy half
looks perfect.

This asks BOTH solvers for the SAME list on the same schedule, so the only
variable is the solver. That is the comparison worth having, and it is
cheap: the targets are the indexer mirrors already in use.

WHAT SUCCESS MEANS HERE

The solver returned status "ok" AND the page came back 200. A solver that
answers cheerfully with a Cloudflare interstitial has not succeeded, and
counting it as success is how you end up trusting the wrong one.

Latency is recorded too. A solver that succeeds in 90 seconds is not
equivalent to one that succeeds in 8: Prowlarr's searches time out, and a
slow solve becomes a failed search anyway.

COST

Each probe drives a real browser. Two solvers times five targets is ten
browser sessions per run, which is why this runs every 30 minutes rather
than alongside the other collectors.

WHY THIS ONE RUNS INSIDE A CONTAINER

The solvers are only addressable on the `edge` overlay, which is not
attachable from the host, so unlike the other collectors this cannot run
directly under systemd. It runs in a throwaway python container joined to
`edge`, with the textfile volume mounted, and writes the .prom file itself
rather than shelling out to docker the way the host-side collectors do.

Run by systemd/mediastack-solver-probe.timer.
"""
import json
import os
import sys
import time
import urllib.error
import urllib.request

OUT_DIR = os.environ.get("SOLVER_PROBE_OUT", "/textfile")
METRIC_FILE = "solver_probe.prom"

# name -> URL of its /v1 endpoint. Both speak the FlareSolverr API, which is
# the only reason a single probe can drive them both.
SOLVERS = {
    "flaresolverr": "http://flaresolverr:8191/v1",
    "byparr": "http://byparr:8191/v1",
}

# The mirrors actually configured in Prowlarr's 1337x definition. Real
# targets rather than synthetic ones: a solver that handles a test page and
# fails the sites you use is not useful.
TARGETS = [
    "https://1337x.to/",
    "https://1337x.st/",
    "https://x1337x.ws/",
    "https://x1337x.eu/",
    "https://x1337x.cc/",
]

TIMEOUT_MS = int(os.environ.get("SOLVER_PROBE_TIMEOUT_MS", "60000"))


def esc(v):
    return str(v).replace("\\", r"\\").replace('"', r"\"").replace("\n", " ")


def probe(endpoint, url):
    """Returns (success, seconds, note)."""
    body = json.dumps({"cmd": "request.get", "url": url,
                       "maxTimeout": TIMEOUT_MS}).encode()
    req = urllib.request.Request(endpoint, data=body,
                                 headers={"Content-Type": "application/json"},
                                 method="POST")
    t0 = time.time()
    try:
        with urllib.request.urlopen(req, timeout=(TIMEOUT_MS / 1000.0) + 45) as r:
            d = json.loads(r.read().decode())
    except urllib.error.HTTPError as e:
        # FlareSolverr answers 500 with a JSON body explaining the block,
        # which is more useful than the status code alone.
        try:
            d = json.loads(e.read().decode())
        except Exception:
            return 0, time.time() - t0, "http %s" % e.code
    except Exception as e:
        return 0, time.time() - t0, type(e).__name__
    dt = time.time() - t0

    status = d.get("status")
    page = (d.get("solution") or {}).get("status")
    if status == "ok" and page == 200:
        return 1, dt, "ok"
    # A cheerful answer that is not actually the page is a failure.
    return 0, dt, (str(d.get("message")) or "status=%s page=%s" % (status, page))[:60]


def main():
    started = time.time()
    lines = []
    totals = {}

    for solver, endpoint in SOLVERS.items():
        ok = 0
        for url in TARGETS:
            success, secs, note = probe(endpoint, url)
            ok += success
            lab = 'solver="%s",target="%s"' % (esc(solver), esc(url))
            lines.append("mediastack_solver_probe_success{%s} %d" % (lab, success))
            lines.append("mediastack_solver_probe_seconds{%s} %.1f" % (lab, secs))
            print("  %-13s %-22s %-7s %5.1fs  %s"
                  % (solver, url, "ok" if success else "FAIL", secs, note))
        totals[solver] = ok
        lines.append('mediastack_solver_probe_targets_ok{solver="%s"} %d' % (esc(solver), ok))
        lines.append('mediastack_solver_probe_targets_total{solver="%s"} %d'
                     % (esc(solver), len(TARGETS)))

    header = [
        "# HELP mediastack_solver_probe_success Whether the solver returned the page, 1 or 0. Success means status ok AND page 200.",
        "# TYPE mediastack_solver_probe_success gauge",
        "# HELP mediastack_solver_probe_seconds How long the attempt took, successful or not.",
        "# TYPE mediastack_solver_probe_seconds gauge",
        "# HELP mediastack_solver_probe_targets_ok Targets this solver returned on the last run.",
        "# TYPE mediastack_solver_probe_targets_ok gauge",
        "# HELP mediastack_solver_probe_targets_total Targets attempted per solver.",
        "# TYPE mediastack_solver_probe_targets_total gauge",
        "# HELP mediastack_solver_probe_last_run_timestamp_seconds Unix time of the last run.",
        "# TYPE mediastack_solver_probe_last_run_timestamp_seconds gauge",
    ]
    lines.append("mediastack_solver_probe_last_run_timestamp_seconds %d" % int(started))

    body = "\n".join(header + lines) + "\n"
    # Write to a temp name and rename: node-exporter reads this directory
    # continuously and a half-written file parses as garbage metrics.
    out = os.path.join(OUT_DIR, METRIC_FILE)
    try:
        with open(out + ".tmp", "w") as fh:
            fh.write(body)
        os.replace(out + ".tmp", out)
    except OSError as e:
        print("failed writing %s: %s" % (out, e), file=sys.stderr)
        return 1

    print()
    for solver, ok in totals.items():
        print("  %-13s %d/%d targets" % (solver, ok, len(TARGETS)))
    print("  %.0fs total" % (time.time() - started))
    return 0


if __name__ == "__main__":
    sys.exit(main())
