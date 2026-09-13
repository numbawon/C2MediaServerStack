#!/usr/bin/env python3
"""Create or update the Tdarr "Shrink oversized video" flow and its libraries.

    scripts/tdarr-shrink-flow.py                      # flow only
    scripts/tdarr-shrink-flow.py --libraries test     # + a scratch library on test clips
    scripts/tdarr-shrink-flow.py --libraries movies,tv
    scripts/tdarr-shrink-flow.py --pause movies,tv    # stop processing, keep the library
    scripts/tdarr-shrink-flow.py --remove test

The decision and restore logic live in tdarr/flows/*.js and are pasted
into the flow's two Custom JS Function nodes, so the repo is the source of
truth: edit those files and re-run this. Editing the flow in the Tdarr UI
works too, but the next run of this script overwrites it.

Flow, top to bottom:

    Input File
    Begin Command
    shrink-decide.js         1 = encode, 2 = leave alone (ends)
    Execute                  NVENC encode into Tdarr's cache
    shrink-restore.js        re-inject Dolby Vision / HDR10+ (fails the flow
                             rather than trade a DV original for HDR10-only)
    Compare Duration         within 99.5-100.5% or fail
    Compare Size             5-85% of the original, else leave alone
                             (under 5% means something broke: fail)
    Replace Original File

Tdarr's API is only on the `edge` overlay, so calls go through a
throwaway curl container on that network, as elsewhere in this repo.
"""
import argparse
import json
import pathlib
import subprocess
import sys

REPO = pathlib.Path(__file__).resolve().parent.parent
FLOWS = REPO / "tdarr" / "flows"
API = "http://tdarr:8265/api/v2"
FLOW_ID = "shrinkOversized"

LIBRARIES = {
    # No hold: the clips are copies, nothing else is writing to them.
    "test": {"_id": "shrinkTest", "name": "Shrink test clips", "folder": "/media/.appdata/tdarr/test",
             "holdNewFiles": False},
    "movies": {"_id": "shrinkMovies", "name": "Movies", "folder": "/media/Movies"},
    "tv": {"_id": "shrinkTV", "name": "TV", "folder": "/media/TV"},
}


def api(path, payload):
    out = subprocess.run(
        ["docker", "run", "--rm", "-i", "--network", "edge", "curlimages/curl:latest",
         "-sf", "--max-time", "60", "-X", "POST", "-H", "Content-Type: application/json",
         "--data-binary", "@-", f"{API}/{path}"],
        input=json.dumps(payload), capture_output=True, text=True,
    )
    if out.returncode != 0:
        sys.exit(f"tdarr {path} failed (curl exit {out.returncode}): {out.stderr.strip()}")
    try:
        return json.loads(out.stdout) if out.stdout.strip() else None
    except json.JSONDecodeError:
        return out.stdout  # scan-files and friends answer in plain text


def crud(collection, mode, **kw):
    return api("cruddb", {"data": {"collection": collection, "mode": mode, **kw}})


def upsert(collection, doc):
    existing = crud(collection, "getById", docID=doc["_id"])
    if existing:
        crud(collection, "update", docID=doc["_id"], obj=doc)
        return "updated"
    crud(collection, "insert", docID=doc["_id"], obj=doc)
    return "created"


def node(nid, plugin, name, y, inputs=None, x=0):
    n = {"name": name, "sourceRepo": "Community", "pluginName": plugin, "version": "1.0.0",
         "id": nid, "position": {"x": x, "y": y}, "fpEnabled": True}
    if inputs:
        n["inputsDB"] = inputs
    return n


def edge(src, handle, dst):
    return {"source": src, "sourceHandle": str(handle), "target": dst, "targetHandle": None,
            "id": f"{src}-{handle}-{dst}"}


def build_flow():
    decide = (FLOWS / "shrink-decide.js").read_text()
    restore = (FLOWS / "shrink-restore.js").read_text()
    plugins = [
        node("input", "inputFile", "Input File", 0),
        node("start", "ffmpegCommandStart", "Begin Command", 120),
        node("decide", "customFunction", "Decide: oversized for its resolution?", 240, {"code": decide}),
        node("exec", "ffmpegCommandExecute", "Execute (NVENC)", 360),
        node("restore", "customFunction", "Restore Dolby Vision / HDR10+", 480, {"code": restore}),
        node("dur", "compareFileDurationRatio", "Duration unchanged?", 600,
             {"greaterThan": "99.5", "lessThan": "100.5"}),
        node("size", "compareFileSizeRatio", "Worth replacing? (5-85% of original)", 720,
             {"greaterThan": "5", "lessThan": "85"}),
        node("replace", "replaceOriginalFile", "Replace Original File", 840),
        node("fail", "failFlow", "Fail Flow", 720, x=400),
    ]
    edges = [
        edge("input", 1, "start"),
        edge("start", 1, "decide"),
        edge("decide", 1, "exec"),          # 2 = leave alone: no edge, flow ends
        edge("exec", 1, "restore"),
        edge("restore", 1, "dur"),
        edge("restore", 2, "fail"),
        edge("dur", 1, "size"),
        edge("dur", 2, "fail"),
        edge("dur", 3, "fail"),
        edge("size", 1, "replace"),
        edge("size", 2, "fail"),            # 3 = not enough saved: no edge, original kept
    ]
    return {
        "_id": FLOW_ID,
        "name": "Shrink oversized video",
        "description": "Re-encode video that is oversized for its resolution with NVENC HEVC, "
                       "keeping HDR10, Dolby Vision and HDR10+. Managed by scripts/tdarr-shrink-flow.py.",
        "tags": "",
        "flowPlugins": plugins,
        "flowEdges": edges,
    }


def library_doc(spec, template, enabled):
    doc = dict(template)
    for k in ("totalHealthCheckCount", "totalTranscodeCount", "sizeDiff", "scanFound"):
        doc.pop(k, None)
    doc.update({
        "priority": 0,
        "cache": "/temp",
        "output": ".",
        "foldersToIgnore": "",
        "containerFilter": "mkv,mp4,m4v,mov,avi,ts,m2ts,webm",
        "processLibrary": enabled,
        "processTranscodes": True,
        "processHealthChecks": False,
        "scanOnStart": False,
        # New imports are picked up by a periodic scan and held an hour so
        # Radarr/Sonarr/Bazarr are done with them first.
        "folderWatching": False,
        "scheduledScanFindNew": True,
        "holdNewFiles": True,
        "holdFor": 3600,
        "holdForDisplayUnit": "hours",
        "exifToolScan": False,
        "mediaInfoScan": True,
        "ffprobeShowData": False,
        "filterHardlinked": False,
        "pluginIDs": [],
        "flowId": FLOW_ID,
        "decisionMaker": {**template.get("decisionMaker", {}),
                          "settingsPlugin": False, "settingsFlows": True, "settingsVideo": False,
                          "settingsAudio": False},
    })
    doc.update(spec)
    return doc


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--libraries", default="", help="comma list of: " + ", ".join(LIBRARIES))
    ap.add_argument("--pause", default="", help="set these libraries to not process")
    ap.add_argument("--remove", default="", help="delete these libraries from Tdarr (files untouched)")
    a = ap.parse_args()
    pick = lambda s: [x for x in s.split(",") if x]

    print(f"flow {FLOW_ID}: {upsert('FlowsJSONDB', build_flow())}")

    libs = crud("LibrarySettingsJSONDB", "getAll") or []
    template = next((l for l in libs if l["_id"] not in {s["_id"] for s in LIBRARIES.values()}), libs[0] if libs else {})
    for key in pick(a.libraries):
        spec = LIBRARIES[key]
        print(f"library {spec['name']} -> {spec['folder']}: {upsert('LibrarySettingsJSONDB', library_doc(spec, template, True))}")
        api("scan-files", {"data": {"scanConfig": {"dbID": spec["_id"], "arrayOrPath": spec["folder"], "mode": "scanFindNew"}}})
        print("  scan started")
    for key in pick(a.pause):
        crud("LibrarySettingsJSONDB", "update", docID=LIBRARIES[key]["_id"], obj={"processLibrary": False})
        print(f"library {LIBRARIES[key]['name']}: paused")
    for key in pick(a.remove):
        lib_id = LIBRARIES[key]["_id"]
        files = [f["_id"] for f in crud("FileJSONDB", "getAll") or [] if f.get("DB") == lib_id]
        for fid in files:
            crud("FileJSONDB", "removeOne", docID=fid)
        crud("LibrarySettingsJSONDB", "removeOne", docID=lib_id)
        print(f"library {LIBRARIES[key]['name']}: removed from Tdarr with {len(files)} file entries (files on disk untouched)")


if __name__ == "__main__":
    main()
