#!/usr/bin/env python3
"""Scan stable files through clamd and expose Prometheus health metrics."""

import json
import os
import socket
import sqlite3
import struct
import threading
import time
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

CLAMD_HOST = os.environ.get("CLAMD_HOST", "clamav")
CLAMD_PORT = int(os.environ.get("CLAMD_PORT", "3310"))
SCAN_INTERVAL = int(os.environ.get("SCAN_INTERVAL", "300"))
MIN_FILE_AGE = int(os.environ.get("MIN_FILE_AGE", "120"))
MAX_FILE_BYTES = int(os.environ.get("MAX_FILE_BYTES", str(100 * 1024 * 1024)))
MAX_SCANS_PER_CYCLE = int(os.environ.get("MAX_SCANS_PER_CYCLE", "25"))
MAX_CYCLE_SECONDS = int(os.environ.get("MAX_CYCLE_SECONDS", "50"))
RESCAN_AFTER = int(os.environ.get("RESCAN_AFTER", str(30 * 24 * 60 * 60)))
CLAMD_TIMEOUT = int(os.environ.get("CLAMD_TIMEOUT", "10"))
PORT = int(os.environ.get("PORT", "9102"))
STATE_DB = os.environ.get("STATE_DB", "/state/scanner.db")
FORCE_RESCAN_FILE = Path(
    os.environ.get("FORCE_RESCAN_FILE", "/state/rescan.request")
)
EXPECTED_LARGE_MEDIA = {
    ".aac",
    ".avi",
    ".flac",
    ".m2ts",
    ".m4a",
    ".m4b",
    ".m4v",
    ".mkv",
    ".mov",
    ".mp3",
    ".mp4",
    ".mpeg",
    ".mpg",
    ".ogg",
    ".opus",
    ".ts",
    ".wav",
    ".webm",
}


def parse_roots(value):
    roots = []
    for item in value.split(","):
        name, separator, path = item.partition("=")
        if not separator or not name or not path:
            raise ValueError(f"invalid SCAN_ROOTS entry: {item!r}")
        roots.append((name, Path(path)))
    return roots


SCAN_ROOTS = parse_roots(
    os.environ.get(
        "SCAN_ROOTS",
        "completed=/scan/completed,uploads=/scan/uploads",
    )
)

metrics_lock = threading.Lock()
metrics = {
    "up": 0,
    "last_scan": 0,
    "duration": 0,
    "known": 0,
    "clean": 0,
    "infected": 0,
    "pending": 0,
    "queued": 0,
    "skipped": 0,
    "errors": 0,
    "inventory_errors": 0,
    "scanned_total": 0,
    "infected_total": 0,
    "errors_total": 0,
    "version": "",
}


class ClamdClient:
    def __init__(self, host, port, timeout=CLAMD_TIMEOUT):
        self.address = (host, port)
        self.timeout = timeout

    def command(self, command):
        with socket.create_connection(self.address, timeout=self.timeout) as sock:
            sock.sendall(b"z" + command.encode() + b"\0")
            return self._response(sock)

    def scan(self, path):
        with socket.create_connection(self.address, timeout=self.timeout) as sock:
            sock.sendall(b"zINSTREAM\0")
            with path.open("rb") as source:
                while chunk := source.read(1024 * 1024):
                    sock.sendall(struct.pack("!I", len(chunk)))
                    sock.sendall(chunk)
            sock.sendall(struct.pack("!I", 0))
            response = self._response(sock)

        if response.endswith(" OK"):
            return "clean", ""
        if response.endswith(" FOUND"):
            signature = response.removeprefix("stream: ").removesuffix(" FOUND")
            return "infected", signature
        raise RuntimeError(response)

    @staticmethod
    def _response(sock):
        chunks = []
        while True:
            chunk = sock.recv(4096)
            if not chunk:
                break
            chunks.append(chunk)
            if b"\0" in chunk:
                break
        return b"".join(chunks).rstrip(b"\0\n").decode("utf-8", "replace")


def connect_db():
    Path(STATE_DB).parent.mkdir(parents=True, exist_ok=True)
    db = sqlite3.connect(STATE_DB)
    db.execute(
        """
        CREATE TABLE IF NOT EXISTS files (
            path TEXT PRIMARY KEY,
            size INTEGER NOT NULL,
            mtime_ns INTEGER NOT NULL,
            status TEXT NOT NULL,
            detail TEXT NOT NULL,
            scanned_at REAL NOT NULL,
            seen_at INTEGER NOT NULL DEFAULT 0
        )
        """
    )
    columns = {row[1] for row in db.execute("PRAGMA table_info(files)")}
    if "seen_at" not in columns:
        db.execute("ALTER TABLE files ADD COLUMN seen_at INTEGER NOT NULL DEFAULT 0")
    db.commit()
    return db


def inventory():
    items = []
    errors = []
    successful_roots = set()
    for root_name, root in SCAN_ROOTS:
        if not root.is_dir():
            errors.append(f"{root_name}: scan root is unavailable: {root}")
            continue
        walk_errors = []
        root_failed = False
        for directory, _, filenames in os.walk(
            root,
            followlinks=False,
            onerror=lambda error: walk_errors.append(str(error)),
        ):
            for filename in filenames:
                path = Path(directory, filename)
                try:
                    if path.is_symlink():
                        continue
                    stat = path.stat()
                except OSError as error:
                    errors.append(f"{root_name}: cannot stat {path}: {error}")
                    root_failed = True
                    continue
                relative = path.relative_to(root)
                items.append((f"{root_name}/{relative}", path, stat))
        errors.extend(f"{root_name}: {error}" for error in walk_errors)
        if walk_errors:
            root_failed = True
        if not root_failed:
            successful_roots.add(root_name)
    return items, errors, successful_roots


def store(db, key, stat, status, detail, scanned_at, seen_at):
    db.execute(
        """
        INSERT INTO files(path, size, mtime_ns, status, detail, scanned_at, seen_at)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(path) DO UPDATE SET
            size=excluded.size,
            mtime_ns=excluded.mtime_ns,
            status=excluded.status,
            detail=excluded.detail,
            scanned_at=excluded.scanned_at,
            seen_at=excluded.seen_at
        """,
        (key, stat.st_size, stat.st_mtime_ns, status, detail, scanned_at, seen_at),
    )


def scan_cycle(db, client):
    started = time.time()
    cycle_scanned = 0
    cycle_infected = 0
    cycle_errors = 0
    cycle_id = time.time_ns()

    try:
        if client.command("PING") != "PONG":
            raise RuntimeError("clamd did not answer PONG")
        version = client.command("VERSION")
        clamd_up = 1
        with metrics_lock:
            metrics["up"] = 1
            metrics["version"] = version
    except (OSError, RuntimeError) as error:
        print(f"clamd unavailable: {error}", flush=True)
        with metrics_lock:
            metrics["up"] = 0
            metrics["errors_total"] += 1
        return

    now = time.time()
    rows = {
        row[0]: row[1:]
        for row in db.execute(
            "SELECT path, size, mtime_ns, status, scanned_at FROM files"
        )
    }

    queued = 0
    inventory_items, inventory_errors, successful_roots = inventory()
    for error in inventory_errors:
        print(f"inventory error: {error}", flush=True)
    cycle_errors += len(inventory_errors)
    items = sorted(inventory_items, key=lambda item: item[2].st_mtime, reverse=True)
    for key, path, stat in items:
        previous = rows.get(key)

        if now - stat.st_mtime < MIN_FILE_AGE:
            store(db, key, stat, "pending", "file is still settling", 0, cycle_id)
            continue
        if stat.st_size > MAX_FILE_BYTES:
            status = "media" if path.suffix.lower() in EXPECTED_LARGE_MEDIA else "skipped"
            store(db, key, stat, status, "file exceeds scan limit", 0, cycle_id)
            continue

        unchanged = (
            previous
            and previous[0] == stat.st_size
            and previous[1] == stat.st_mtime_ns
        )
        fresh = unchanged and previous[3] >= now - RESCAN_AFTER
        if fresh and previous[2] in ("clean", "infected"):
            db.execute("UPDATE files SET seen_at = ? WHERE path = ?", (cycle_id, key))
            continue
        if (
            cycle_scanned >= MAX_SCANS_PER_CYCLE
            or time.time() - started >= MAX_CYCLE_SECONDS
        ):
            queued += 1
            if previous:
                db.execute("UPDATE files SET seen_at = ? WHERE path = ?", (cycle_id, key))
            continue

        try:
            status, detail = client.scan(path)
            cycle_scanned += 1
            if status == "infected":
                cycle_infected += 1
                print(f"THREAT {key}: {detail}", flush=True)
            store(db, key, stat, status, detail, now, cycle_id)
        except (OSError, RuntimeError) as error:
            cycle_scanned += 1
            cycle_errors += 1
            store(db, key, stat, "error", str(error), now, cycle_id)
            print(f"scan error {key}: {error}", flush=True)

    for root_name in successful_roots:
        prefix = f"{root_name}/"
        db.execute(
            """
            DELETE FROM files
            WHERE substr(path, 1, length(?)) = ? AND seen_at != ?
            """,
            (prefix, prefix, cycle_id),
        )
    db.commit()

    counts = dict(
        db.execute("SELECT status, COUNT(*) FROM files GROUP BY status").fetchall()
    )
    with metrics_lock:
        metrics.update(
            {
                "up": clamd_up,
                "last_scan": time.time(),
                "duration": time.time() - started,
                "known": sum(counts.values()),
                "clean": counts.get("clean", 0),
                "infected": counts.get("infected", 0),
                "pending": counts.get("pending", 0),
                "queued": queued,
                "skipped": counts.get("skipped", 0),
                "errors": counts.get("error", 0),
                "inventory_errors": len(inventory_errors),
                "scanned_total": metrics["scanned_total"] + cycle_scanned,
                "infected_total": metrics["infected_total"] + cycle_infected,
                "errors_total": metrics["errors_total"] + cycle_errors,
                "version": version,
            }
        )


def scan_loop():
    db = connect_db()
    client = ClamdClient(CLAMD_HOST, CLAMD_PORT)
    while True:
        try:
            if FORCE_RESCAN_FILE.exists():
                db.execute("UPDATE files SET scanned_at = 0")
                db.commit()
                FORCE_RESCAN_FILE.unlink()
                print("forced full rescan requested", flush=True)
            scan_cycle(db, client)
        except sqlite3.Error as error:
            db.rollback()
            print(f"scanner database error: {error}", flush=True)
            with metrics_lock:
                metrics["up"] = 0
                metrics["errors_total"] += 1
        time.sleep(SCAN_INTERVAL)


def prometheus_escape(value):
    return value.replace("\\", "\\\\").replace("\n", "\\n").replace('"', '\\"')


def render_metrics():
    with metrics_lock:
        current = dict(metrics)

    definitions = (
        ("antivirus_up", "1 when clamd answered the latest scan cycle", "gauge", "up"),
        ("antivirus_last_scan_timestamp_seconds", "Last completed inventory scan", "gauge", "last_scan"),
        ("antivirus_scan_cycle_duration_seconds", "Duration of the latest scan cycle", "gauge", "duration"),
        ("antivirus_files_known", "Files tracked across scan roots", "gauge", "known"),
        ("antivirus_files_clean", "Tracked files last found clean", "gauge", "clean"),
        ("antivirus_files_infected", "Tracked files currently found infected", "gauge", "infected"),
        ("antivirus_files_pending", "Files waiting to become stable", "gauge", "pending"),
        ("antivirus_files_queued", "Files awaiting a future scan cycle", "gauge", "queued"),
        ("antivirus_files_skipped_oversize", "Files skipped because they exceed scan limit", "gauge", "skipped"),
        ("antivirus_files_error", "Files whose latest scan failed", "gauge", "errors"),
        ("antivirus_inventory_errors", "Unreadable or unavailable scan paths", "gauge", "inventory_errors"),
        ("antivirus_scanned_files_total", "Completed file scans", "counter", "scanned_total"),
        ("antivirus_infected_files_total", "Infected scan results", "counter", "infected_total"),
        ("antivirus_scan_errors_total", "Scanner or clamd errors", "counter", "errors_total"),
    )
    output = []
    for name, help_text, metric_type, key in definitions:
        output.extend(
            [
                f"# HELP {name} {help_text}",
                f"# TYPE {name} {metric_type}",
                f"{name} {current[key]}",
            ]
        )
    if current["version"]:
        output.extend(
            [
                "# HELP antivirus_clamd_info clamd engine and signature version",
                "# TYPE antivirus_clamd_info gauge",
                f'antivirus_clamd_info{{version="{prometheus_escape(current["version"])}"}} 1',
            ]
        )
    return "\n".join(output) + "\n"


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path not in ("/", "/metrics"):
            self.send_response(404)
            self.end_headers()
            return
        body = render_metrics().encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; version=0.0.4")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        pass


if __name__ == "__main__":
    print(
        json.dumps(
            {
                "event": "antivirus_start",
                "roots": [(name, str(path)) for name, path in SCAN_ROOTS],
                "max_file_bytes": MAX_FILE_BYTES,
                "scan_interval": SCAN_INTERVAL,
            }
        ),
        flush=True,
    )
    threading.Thread(target=scan_loop, daemon=True).start()
    HTTPServer(("", PORT), Handler).serve_forever()
