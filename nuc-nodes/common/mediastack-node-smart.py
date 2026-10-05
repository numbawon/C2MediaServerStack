#!/usr/bin/python3
"""The drives' own health report, as metrics.

The two NVMes in each node are a RAID1 mirror, which survives ONE disk dying
only if you notice the first one going. btrfs sees errors after they reach
the filesystem; the drive's SMART log sees wear, spare capacity and media
errors before that. This reads it with smartctl and writes Prometheus
textfile metrics, so a worn or failing disk is an alert instead of a
surprise.

Runs as root from mediastack-node-smart.timer. Needs smartmontools, which
arrives with the weekly update's full upgrade; until then it exits quietly
rather than failing, so the timer can be enabled before the package exists.
"""
import json
import os
import shutil
import subprocess
import sys
import time

TEXTFILE_DIR = os.environ.get(
    "TEXTFILE_DIR", "/var/lib/docker/volumes/node_exporter_textfile/_data")
SMARTCTL = os.environ.get("SMARTCTL", "smartctl")

# smartctl field -> (metric name, help). Fields come from the NVMe SMART
# health log as smartctl reports it in JSON.
FIELDS = {
    "critical_warning": ("critical_warning", "NVMe critical warning bitmask, 0 is healthy."),
    "temperature": ("temperature_celsius", "Composite drive temperature."),
    "available_spare": ("available_spare_percent", "Spare capacity left, percent."),
    "available_spare_threshold": ("available_spare_threshold_percent", "Spare level at which the drive warns."),
    "percentage_used": ("percentage_used", "Rated endurance consumed, percent (can exceed 100)."),
    "media_errors": ("media_errors_total", "Unrecovered data integrity errors."),
    "num_err_log_entries": ("error_log_entries_total", "Entries in the drive's error log."),
    "unsafe_shutdowns": ("unsafe_shutdowns_total", "Power losses without a clean shutdown."),
    "power_on_hours": ("power_on_hours", "Hours powered on."),
    "data_units_written": ("data_units_written_total", "Data written, in 512,000-byte units."),
}


def run_json(args):
    # smartctl's exit status is a bitmask that is non-zero for a drive that
    # merely has old error-log entries, so the JSON is trusted, not the status.
    proc = subprocess.run([SMARTCTL, "-j", *args], capture_output=True, text=True)
    return json.loads(proc.stdout or "{}")


def collect():
    devices = [d["name"] for d in run_json(["--scan"]).get("devices", [])
               if d.get("type") == "nvme"]
    series = {}  # metric -> list of (device, value)
    for dev in devices:
        data = run_json(["-a", dev])
        log = data.get("nvme_smart_health_information_log")
        if not log:
            continue
        name = os.path.basename(dev)
        model = data.get("model_name", "unknown")
        passed = data.get("smart_status", {}).get("passed")
        if passed is not None:
            series.setdefault("smart_passed", []).append((name, model, int(bool(passed))))
        for key, (metric, _help) in FIELDS.items():
            if key in log:
                series.setdefault(metric, []).append((name, model, log[key]))
    return series


def render(series):
    out = []
    helps = {m: h for m, h in FIELDS.values()}
    helps["smart_passed"] = "1 if the drive's overall SMART self-assessment passed."
    for metric, rows in series.items():
        full = f"mediastack_node_nvme_{metric}"
        out.append(f"# HELP {full} {helps[metric]}")
        out.append(f"# TYPE {full} gauge")
        for dev, model, value in rows:
            out.append(f'{full}{{device="{dev}",model="{model}"}} {value}')
    out.append("# TYPE mediastack_node_nvme_last_run_timestamp_seconds gauge")
    out.append(f"mediastack_node_nvme_last_run_timestamp_seconds {int(time.time())}")
    return "\n".join(out) + "\n"


def main():
    if shutil.which(SMARTCTL) is None:
        print("smartctl not installed yet, skipping (arrives with the next full upgrade)")
        return 0
    series = collect()
    if not series:
        print("no NVMe drives reported SMART data", file=sys.stderr)
        return 1
    body = render(series)
    if os.path.isdir(TEXTFILE_DIR):
        tmp = os.path.join(TEXTFILE_DIR, f".node_nvme.prom.{os.getpid()}")
        with open(tmp, "w") as fh:
            fh.write(body)
        os.replace(tmp, os.path.join(TEXTFILE_DIR, "node_nvme.prom"))
    print(f"nvme health written for {len({d for rows in series.values() for d, *_ in rows})} drive(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
