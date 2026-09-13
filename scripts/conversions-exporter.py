#!/usr/bin/env python3
"""Tdarr + GPU metrics for the Media Conversions dashboard.

Writes <textfile>/conversions.prom for node_exporter's textfile collector.
Run every minute by mediastack-conversions-exporter.timer, inside a
container on `edge` (Tdarr publishes no port and the overlay is not
reachable from the host) with `--gpus all`, which is what puts a working
nvidia-smi inside it.

Every Tdarr call here is small: the one-document statistics record, the
library settings, the node list, and status-table queries with pageSize
1 (just the count) or a short page of recent jobs. It never pulls the
whole file database, which with ffprobe data is tens of megabytes.
"""
import json
import os
import subprocess
import sys
import time
import urllib.request

TDARR = os.environ.get("TDARR_URL", "http://tdarr:8265").rstrip("/")
OUT_DIR = os.environ.get("CONVERSIONS_METRICS_OUT", "/textfile")
METRIC_FILE = "conversions.prom"
RECENT = 15
STATUSES = ("Queued", "Hold", "Processing", "Transcode success", "Not required", "Transcode error")
GB = 1e9


def post(path, payload):
    req = urllib.request.Request(f"{TDARR}/api/v2/{path}", data=json.dumps({"data": payload}).encode(),
                                 headers={"Content-Type": "application/json"}, method="POST")
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.loads(r.read().decode())


def get(path):
    with urllib.request.urlopen(f"{TDARR}/api/v2/{path}", timeout=60) as r:
        return json.loads(r.read().decode())


def table(name, filters=(), sorts=(), size=1):
    return post("client/status-tables", {"start": 0, "pageSize": size, "filters": list(filters),
                                         "sorts": list(sorts), "opts": {"table": name}})


def esc(v):
    return str(v).replace("\\", r"\\").replace('"', r"\"").replace("\n", " ")


def lbl(**kv):
    return "{" + ",".join(f'{k}="{esc(v)}"' for k, v in kv.items()) + "}"


class Metrics:
    """Collects samples per metric so each family is written contiguously,
    with one TYPE line, as the text exposition format requires."""

    def __init__(self):
        self.families = {}

    def add(self, metric, value, mtype="gauge", **labels):
        fam = self.families.setdefault(metric, (mtype, []))
        fam[1].append(f"{metric}{lbl(**labels) if labels else ''} {value}")

    def render(self):
        lines = []
        for name, (mtype, samples) in self.families.items():
            lines.append(f"# TYPE {name} {mtype}")
            lines.extend(samples)
        return "\n".join(lines) + "\n"


def eta_seconds(eta):
    """Tdarr reports ETA as 'H:MM:SS' or 'Calc...'."""
    try:
        parts = [int(p) for p in str(eta).split(":")]
    except ValueError:
        return None
    secs = 0
    for p in parts:
        secs = secs * 60 + p
    return secs


def tdarr_metrics(m):
    stats = post("cruddb", {"collection": "StatisticsJSONDB", "mode": "getById", "docID": "statistics"})
    m.add("mediastack_tdarr_saved_bytes", f"{float(stats.get('sizeDiff') or 0) * GB:.0f}")
    m.add("mediastack_tdarr_transcodes_total", int(stats.get("totalTranscodeCount") or 0), "counter")

    libs = post("cruddb", {"collection": "LibrarySettingsJSONDB", "mode": "getAll"})
    names = {lib["_id"]: lib.get("name", lib["_id"]) for lib in libs}
    for lib in libs:
        name = names[lib["_id"]]
        m.add("mediastack_tdarr_library_enabled", int(bool(lib.get("processLibrary"))), library=name)
        m.add("mediastack_tdarr_library_saved_bytes", f"{float(lib.get('sizeDiff') or 0) * GB:.0f}", library=name)
        m.add("mediastack_tdarr_library_transcodes_total", int(lib.get("totalTranscodeCount") or 0), "counter", library=name)
        for st in STATUSES:
            tbl = "table1" if st in ("Queued", "Hold", "Processing") else ("table3" if st == "Transcode error" else "table2")
            n = table(tbl, filters=[{"id": "DB", "value": lib["_id"]},
                                    {"id": "TranscodeDecisionMaker", "value": st}])["totalCount"]
            m.add("mediastack_tdarr_library_files", n, library=name, status=st)

    # Latest real transcodes, newest first, with before/after sizes.
    recent = table("table2", filters=[{"id": "TranscodeDecisionMaker", "value": "Transcode success"}],
                   sorts=[{"id": "lastTranscodeDate", "desc": True}], size=RECENT)["array"]
    for r in recent:
        lab = dict(file=os.path.basename(r["_id"]), library=names.get(r.get("DB"), r.get("DB")),
                   resolution=r.get("video_resolution", ""))
        m.add("mediastack_tdarr_recent_transcode_old_bytes", f"{float(r.get('oldSize') or 0) * GB:.0f}", **lab)
        m.add("mediastack_tdarr_recent_transcode_new_bytes", f"{float(r.get('newSize') or 0) * GB:.0f}", **lab)
        m.add("mediastack_tdarr_recent_transcode_time_seconds", f"{int(r.get('lastTranscodeDate') or 0) / 1000:.0f}", **lab)

    errors = table("table3", size=RECENT)
    m.add("mediastack_tdarr_errors", errors["totalCount"])
    for r in errors["array"]:
        m.add("mediastack_tdarr_error_info", 1, file=os.path.basename(r["_id"]),
              library=names.get(r.get("DB"), r.get("DB")))

    # Live workers.
    active = 0
    for node in get("get-nodes").values():
        nn = node.get("nodeName", "")
        for kind, n in (node.get("workerLimits") or {}).items():
            m.add("mediastack_tdarr_worker_limit", n, node=nn, type=kind)
        m.add("mediastack_tdarr_node_paused", int(bool(node.get("nodePaused"))), node=nn)
        for w in (node.get("workers") or {}).values():
            active += 1
            lab = dict(node=nn, type=w.get("workerType", ""), file=os.path.basename(w.get("file") or ""),
                       step=w.get("status", ""))
            m.add("mediastack_tdarr_worker_percent", f"{float(w.get('percentage') or 0):.2f}", **lab)
            m.add("mediastack_tdarr_worker_fps", f"{float(w.get('fps') or 0):.1f}", **lab)
            eta = eta_seconds(w.get("ETA"))
            if eta is not None:
                m.add("mediastack_tdarr_worker_eta_seconds", eta, **lab)
    m.add("mediastack_tdarr_workers_active", active)


GPU_FIELDS = ("index", "name", "utilization.gpu", "utilization.encoder", "utilization.decoder",
              "memory.used", "memory.total", "encoder.stats.sessionCount", "encoder.stats.averageFps",
              "temperature.gpu", "power.draw")
MIB = 1024 * 1024


def gpu_metrics(m):
    res = subprocess.run(["nvidia-smi", f"--query-gpu={','.join(GPU_FIELDS)}", "--format=csv,noheader,nounits"],
                         capture_output=True, text=True, timeout=30)
    if res.returncode != 0:
        m.add("mediastack_gpu_up", 0)
        return
    m.add("mediastack_gpu_up", 1)

    def num(x):
        try:
            return float(x)
        except ValueError:
            return None

    for line in res.stdout.strip().splitlines():
        v = dict(zip(GPU_FIELDS, [x.strip() for x in line.split(",")]))
        g = dict(gpu=v["index"], name=v["name"])
        for engine in ("gpu", "encoder", "decoder"):
            n = num(v[f"utilization.{engine}"])
            if n is not None:
                m.add("mediastack_gpu_utilization_percent", n, **g, engine=engine)
        for key, metric, scale in (("memory.used", "mediastack_gpu_memory_used_bytes", MIB),
                                   ("memory.total", "mediastack_gpu_memory_total_bytes", MIB),
                                   ("encoder.stats.sessionCount", "mediastack_gpu_encoder_sessions", 1),
                                   ("encoder.stats.averageFps", "mediastack_gpu_encoder_fps", 1),
                                   ("temperature.gpu", "mediastack_gpu_temperature_celsius", 1),
                                   ("power.draw", "mediastack_gpu_power_watts", 1)):
            n = num(v[key])
            if n is not None:
                m.add(metric, f"{n * scale:.0f}" if scale != 1 else n, **g)


def main():
    started = time.time()
    m = Metrics()
    ok = 1
    try:
        tdarr_metrics(m)
    except Exception as e:  # still write GPU metrics and the up flag
        print(f"tdarr: {e}", file=sys.stderr)
        ok = 0
    m.add("mediastack_tdarr_up", ok)
    try:
        gpu_metrics(m)
    except Exception as e:
        print(f"gpu: {e}", file=sys.stderr)
        m.add("mediastack_gpu_up", 0)
    m.add("mediastack_conversions_exporter_last_run_timestamp_seconds", f"{time.time():.0f}")
    m.add("mediastack_conversions_exporter_duration_seconds", f"{time.time() - started:.2f}")
    tmp = os.path.join(OUT_DIR, METRIC_FILE + ".tmp")
    with open(tmp, "w") as f:
        f.write(m.render())
    os.replace(tmp, os.path.join(OUT_DIR, METRIC_FILE))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
