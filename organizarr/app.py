"""
Organizarr — a small config hub for the *arr apps in this stack. Not a
clone of every app's settings UI: it covers the fields that were
actually painful to keep straight across apps by hand this project
(auth method, download-client host/port, Prowlarr's app/indexer sync)
via each app's own real API, not by touching config files directly.

API keys are never sent to the browser -- read once at startup from
each app's own config volume (mounted read-only), kept server-side, and
attached to outbound requests here.

Auth: this container has no login of its own. It expects to sit behind
the same Authentik forwardAuth gate as everything else in the stack --
see the README note about binding it to an Admins-only Authentik
application before exposing it, same as Portainer/Pi-hole/Traefik's
dashboard. Anyone who reaches this page can change any app's
authentication settings and download-client credentials.
"""
import configparser
import re
from pathlib import Path
from typing import Any

import httpx
import yaml
from fastapi import FastAPI, HTTPException
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles

app = FastAPI(title="Organizarr")

# ---------------------------------------------------------------------
# App registry. "servarr" apps share one settings-provider API shape
# (config/host is a flat object; downloadclient/indexer/applications
# are self-describing {fields: [...]} schemas) -- everything below
# leans on that instead of hand-writing a client per app.
# ---------------------------------------------------------------------
APPS: dict[str, dict[str, Any]] = {
    "sonarr":        {"kind": "servarr",  "base": "http://vpn-client:8989",  "api": "v3", "config": "/data/sonarr/config.xml"},
    "radarr":        {"kind": "servarr",  "base": "http://vpn-client:7878",  "api": "v3", "config": "/data/radarr/config.xml"},
    "lidarr":        {"kind": "servarr",  "base": "http://lidarr:8686",      "api": "v1", "config": "/data/lidarr/config.xml"},
    "prowlarr":      {"kind": "prowlarr", "base": "http://prowlarr:9696",    "api": "v1", "config": "/data/prowlarr/config.xml"},
    "bazarr":        {"kind": "status",   "base": "http://bazarr:6767",     "config": "/data/bazarr/config/config.yaml"},
    "lazylibrarian": {"kind": "status",   "base": "http://vpn-client:5299", "config": "/data/lazylibrarian/config.ini"},
}

# Host-settings fields this UI will show/edit -- deliberately not the
# full config/host object, which also carries the admin password hash.
# Nothing outside this list is ever read or written through /host.
HOST_FIELDS = ["authenticationMethod", "authenticationRequired", "port", "urlBase", "branch"]


def _read_api_key(path: str) -> str | None:
    p = Path(path)
    if not p.exists():
        return None
    if p.suffix == ".xml":
        m = re.search(r"<ApiKey>([^<]+)</ApiKey>", p.read_text())
        return m.group(1) if m else None
    if p.suffix in (".yaml", ".yml"):
        data = yaml.safe_load(p.read_text()) or {}
        return (data.get("auth") or {}).get("apikey") or None
    if p.suffix == ".ini":
        cp = configparser.ConfigParser()
        cp.read(p)
        for section in cp.sections():
            if cp.has_option(section, "api_key"):
                return cp.get(section, "api_key")
        # LazyLibrarian's config.ini has no [section] header on some keys
        text = p.read_text()
        m = re.search(r"^api_key\s*=\s*(\S+)", text, re.MULTILINE)
        return m.group(1) if m else None
    return None


for name, cfg in APPS.items():
    cfg["api_key"] = _read_api_key(cfg["config"])


def _client(name: str) -> httpx.AsyncClient:
    cfg = APPS[name]
    if not cfg.get("api_key"):
        raise HTTPException(503, f"{name}: no API key found (is its config volume mounted / has it booted yet?)")
    headers = {"X-Api-Key": cfg["api_key"]}
    # follow_redirects handles the urlBase-prefix 307 these apps issue
    # (see docker-stack.yml history for why some carry a urlBase) --
    # httpx preserves method+body across 307/308, so PUT/POST land
    # correctly without hardcoding each app's prefix.
    return httpx.AsyncClient(base_url=cfg["base"], headers=headers, follow_redirects=True, timeout=15)


async def _servarr_get(name: str, path: str) -> Any:
    api = APPS[name]["api"]
    async with _client(name) as c:
        r = await c.get(f"/api/{api}{path}")
        r.raise_for_status()
        return r.json()


async def _servarr_put(name: str, path: str, body: Any) -> Any:
    api = APPS[name]["api"]
    async with _client(name) as c:
        r = await c.put(f"/api/{api}{path}", json=body)
        r.raise_for_status()
        return r.json()


async def _servarr_post(name: str, path: str, body: Any) -> Any:
    api = APPS[name]["api"]
    async with _client(name) as c:
        r = await c.post(f"/api/{api}{path}", json=body)
        r.raise_for_status()
        return r.json()


# ---------------------------------------------------------------------
# Status -- every app, reachable or not, shown on one page.
# ---------------------------------------------------------------------
@app.get("/api/status")
async def status():
    out = []
    for name, cfg in APPS.items():
        entry = {"name": name, "kind": cfg["kind"], "reachable": False, "version": None, "error": None}
        if not cfg.get("api_key"):
            entry["error"] = "no API key found"
            out.append(entry)
            continue
        try:
            if cfg["kind"] in ("servarr", "prowlarr"):
                data = await _servarr_get(name, "/system/status")
                entry["reachable"] = True
                entry["version"] = data.get("version")
            else:
                async with _client(name) as c:
                    r = await c.get("/")
                    entry["reachable"] = r.status_code < 500
        except Exception as e:  # noqa: BLE001 -- surfacing to the UI is the point
            entry["error"] = str(e)
        out.append(entry)
    return out


# ---------------------------------------------------------------------
# Host/security settings -- Sonarr/Radarr/Lidarr only (Prowlarr has no
# forms auth to toggle).
# ---------------------------------------------------------------------
@app.get("/api/{app_name}/host")
async def get_host(app_name: str):
    if app_name not in ("sonarr", "radarr", "lidarr"):
        raise HTTPException(404, "not a servarr app with host settings")
    data = await _servarr_get(app_name, "/config/host")
    return {k: data.get(k) for k in HOST_FIELDS}


@app.post("/api/{app_name}/host")
async def set_host(app_name: str, changes: dict[str, Any]):
    if app_name not in ("sonarr", "radarr", "lidarr"):
        raise HTTPException(404, "not a servarr app with host settings")
    bad = set(changes) - set(HOST_FIELDS)
    if bad:
        raise HTTPException(400, f"not editable here: {sorted(bad)}")
    current = await _servarr_get(app_name, "/config/host")
    current.update(changes)
    return await _servarr_put(app_name, "/config/host/1", current)


# ---------------------------------------------------------------------
# Download clients -- Sonarr/Radarr/Lidarr. Passthrough of the schema
# shape (each provider type self-describes its own fields), but a
# blank password/apiKey field on save means "leave unchanged", never
# "clear it" -- these apps store real credentials here.
# ---------------------------------------------------------------------
@app.get("/api/{app_name}/downloadclients")
async def list_download_clients(app_name: str):
    if app_name not in ("sonarr", "radarr", "lidarr"):
        raise HTTPException(404, "not a servarr app")
    return await _servarr_get(app_name, "/downloadclient")


@app.put("/api/{app_name}/downloadclients/{client_id}")
async def update_download_client(app_name: str, client_id: int, body: dict[str, Any]):
    if app_name not in ("sonarr", "radarr", "lidarr"):
        raise HTTPException(404, "not a servarr app")
    current = await _servarr_get(app_name, f"/downloadclient/{client_id}")
    incoming_by_name = {f["name"]: f for f in body.get("fields", [])}
    for f in current["fields"]:
        new = incoming_by_name.get(f["name"])
        if new is None:
            continue
        if f.get("privacy") in ("password", "apiKey") and new.get("value") in (None, ""):
            continue  # blank privacy field on the wire == "unchanged"
        f["value"] = new.get("value")
    return await _servarr_put(app_name, f"/downloadclient/{client_id}", current)


# ---------------------------------------------------------------------
# Prowlarr -- applications (sync targets) and indexers.
# ---------------------------------------------------------------------
@app.get("/api/prowlarr/applications")
async def list_applications():
    return await _servarr_get("prowlarr", "/applications")


@app.get("/api/prowlarr/applications/schema")
async def application_schema():
    return await _servarr_get("prowlarr", "/applications/schema")


@app.post("/api/prowlarr/applications")
async def create_application(body: dict[str, Any]):
    return await _servarr_post("prowlarr", "/applications", body)


@app.put("/api/prowlarr/applications/{app_id}")
async def update_application(app_id: int, body: dict[str, Any]):
    return await _servarr_put("prowlarr", f"/applications/{app_id}", body)


@app.get("/api/prowlarr/indexers")
async def list_indexers():
    return await _servarr_get("prowlarr", "/indexer")


@app.get("/api/prowlarr/indexers/schema")
async def indexer_schema():
    return await _servarr_get("prowlarr", "/indexer/schema")


@app.post("/api/prowlarr/indexers")
async def create_indexer(body: dict[str, Any]):
    return await _servarr_post("prowlarr", "/indexer", body)


@app.put("/api/prowlarr/indexers/{indexer_id}")
async def update_indexer(indexer_id: int, body: dict[str, Any]):
    return await _servarr_put("prowlarr", f"/indexer/{indexer_id}", body)


app.mount("/", StaticFiles(directory="static", html=True), name="static")
