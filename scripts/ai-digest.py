#!/usr/bin/env python3
"""Summarise what the stack is complaining about, and push it to ntfy.

WHERE THE LLM SITS, AND WHY IT SITS THERE

It does not detect anything. Every fact in the digest comes from
scripts/media-watchdog.py's findings file and Prometheus' firing alerts,
both of which are exact and both of which alert on their own regardless of
whether this script ever runs. The model's only job is to read that list and
say which parts matter and what they mean together, which is the one part of
this that is actually judgement rather than comparison.

That split is deliberate and worth keeping. A language model asked "is this
podcast missing episodes" is strictly worse than a COUNT(*), and it fails in
a way you cannot alert on. Asked "here are nine findings, which is the one
that will bite first", it is genuinely useful.

So the failure mode is bounded: if Ollama is down, the model is slow, or it
returns nonsense, the digest falls back to the plain deterministic summary
and still goes out. It never suppresses a finding, and it is never the reason
you learn about something late.

BACKEND

Defaults to the local Ollama on 127.0.0.1:11434 with hermes3:8b, Nous
Research's Hermes 3 running on this machine's GPU, so nothing leaves the
network. The endpoint is an ordinary OpenAI-compatible /chat/completions, so
pointing AI_DIGEST_BASE_URL at any hosted provider plus AI_DIGEST_API_KEY_FILE
is a config change rather than a code change. Note that doing so sends podcast
names, alert text and hostnames to that provider.

Run by systemd/mediastack-ai-digest.timer.
"""
import json
import os
import subprocess
import sys
import urllib.error
import urllib.request

TEXTFILE_VOLUME = "node_exporter_textfile"
BASE_URL = os.environ.get("AI_DIGEST_BASE_URL", "http://127.0.0.1:11434/v1")
MODEL = os.environ.get("AI_DIGEST_MODEL", "hermes3:8b-llama3.1-q4_K_M")
KEY_FILE = os.environ.get("AI_DIGEST_API_KEY_FILE", "")
TIMEOUT = int(os.environ.get("AI_DIGEST_TIMEOUT", "240"))
NTFY_TOPIC = os.environ.get("NTFY_TOPIC", "alerts")
# Push even when everything is clean. Off by default: a digest that arrives
# every night saying "all good" stops being read within a week.
ALWAYS_PUSH = os.environ.get("AI_DIGEST_ALWAYS_PUSH", "0") == "1"

# Alerts that are effectively always firing and are not a problem to act on
# tonight. ImageUpdateAvailable fires once per image with an update, which is
# permanently six or seven of them, and Watchdog fires forever by design as
# the dead-man switch. Left in, they would be the entire digest every night
# and the digest would stop being read. They are still counted and still
# alert normally through Alertmanager; they just do not get a nightly essay.
CHRONIC_ALERTS = set(
    os.environ.get("AI_DIGEST_CHRONIC", "ImageUpdateAvailable,Watchdog,DiunUpdateAvailable")
    .split(","))

SYSTEM_PROMPT = """You summarise findings from a self-hosted media server for its owner.

Rules, all of them absolute:
- Use ONLY the findings given to you. Never invent a problem, a number, a
  service name or a cause that is not in the input.
- If you are unsure what something means, say what it says rather than
  guessing at a cause.
- Lead with whatever is most likely to actually break something or lose data.
- Be specific and short. Name the podcast, service or file count involved.
- No preamble, no sign-off, no bullet symbols, no markdown headers.
- At most 6 short lines, each one a complete thought.
- Plain sentences. Do not use em-dashes.

The reader is technical and runs this machine. Tell them what is wrong and
what it means, not what a monitoring system is."""


def sh(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, **kw)


def read_from_volume(filename):
    r = sh(["docker", "run", "--rm", "-v", "%s:/t:ro" % TEXTFILE_VOLUME,
            "alpine:latest", "sh", "-c", "cat /t/%s 2>/dev/null || true" % filename])
    return r.stdout.strip()


def container(name_filter):
    r = sh(["docker", "ps", "--filter", "name=" + name_filter, "--format", "{{.Names}}"])
    names = [n for n in r.stdout.split() if n]
    return names[0] if names else None


def firing_alerts():
    """Alerts Prometheus currently has firing.

    Prometheus is only on the internal overlay, so this asks it from inside
    its own container rather than attaching a helper to that network.
    """
    c = container("mediastack_prometheus.")
    if not c:
        return [], []
    r = sh(["docker", "exec", c, "wget", "-qO-", "http://localhost:9090/api/v1/alerts"])
    if r.returncode != 0:
        return [], []
    try:
        data = json.loads(r.stdout)
    except ValueError:
        return [], []
    out, chronic = [], []
    for a in data.get("data", {}).get("alerts", []):
        if a.get("state") != "firing":
            continue
        lab = a.get("labels", {})
        ann = a.get("annotations", {})
        row = {
            "alert": lab.get("alertname", "?"),
            "severity": lab.get("severity", "?"),
            "summary": ann.get("summary", ""),
        }
        (chronic if row["alert"] in CHRONIC_ALERTS else out).append(row)
    return out, chronic


def media_findings():
    raw = read_from_volume("media_findings.json")
    if not raw:
        return None
    try:
        return json.loads(raw)
    except ValueError:
        return None


def plain_summary(findings, alerts, chronic):
    """The digest that goes out if the model is unavailable or unusable.

    Deliberately dull and complete. This is the floor: whatever else happens,
    the owner gets this.
    """
    lines = []
    crit = [a for a in alerts if a["severity"] == "critical"]
    warn = [a for a in alerts if a["severity"] == "warning"]
    info = [a for a in alerts if a["severity"] not in ("critical", "warning")]

    if crit:
        lines.append("CRITICAL: " + "; ".join(a["summary"] or a["alert"] for a in crit[:3]))
    if warn:
        lines.append("Warnings: " + "; ".join(a["summary"] or a["alert"] for a in warn[:3]))
    if info:
        lines.append("Info: %d lower-severity alert(s)." % len(info))
    if chronic:
        names = sorted({a["alert"] for a in chronic})
        lines.append("Ongoing (not new): %d x %s." % (len(chronic), ", ".join(names)))

    if findings is None:
        lines.append("Media watchdog has not written findings yet.")
    elif not findings.get("ok", 1):
        lines.append("Media watchdog did not complete its checks.")
    else:
        probs = findings.get("problems", [])
        if probs:
            for p in probs[:4]:
                where = p.get("podcast") or p.get("tree") or ""
                lines.append(("%s: %s" % (where, p["detail"])) if where else p["detail"])
            if len(probs) > 4:
                lines.append("...and %d more media finding(s)." % (len(probs) - 4))
        else:
            lines.append("Media library checks clean.")

    return "\n".join(lines) if lines else "Nothing to report."


def ask_model(findings, alerts, chronic):
    """Returns the model's digest, or None if anything at all goes wrong."""
    facts = {
        "firing_alerts": alerts,
        "ongoing_background_alerts": {
            "count": len(chronic),
            "names": sorted({a["alert"] for a in chronic}),
            "note": "always firing, mention in at most one short line, never itemise",
        },
        "media_watchdog": findings if findings else {"note": "no findings file yet"},
    }
    body = {
        "model": MODEL,
        "messages": [
            {"role": "system", "content": SYSTEM_PROMPT},
            {"role": "user", "content":
                "Findings as JSON:\n\n" + json.dumps(facts, indent=1) +
                "\n\nWrite the digest."},
        ],
        "temperature": 0.2,
        "max_tokens": 400,
        "stream": False,
    }
    headers = {"Content-Type": "application/json"}
    if KEY_FILE and os.path.exists(KEY_FILE):
        with open(KEY_FILE) as fh:
            headers["Authorization"] = "Bearer " + fh.read().strip()

    req = urllib.request.Request(
        BASE_URL.rstrip("/") + "/chat/completions",
        data=json.dumps(body).encode(), headers=headers, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
            data = json.loads(resp.read().decode())
        text = data["choices"][0]["message"]["content"].strip()
    except (urllib.error.URLError, OSError, ValueError, KeyError, IndexError) as exc:
        print("model unavailable (%s), using the plain summary" % type(exc).__name__,
              file=sys.stderr)
        return None

    # Reasoning models emit a think block; keep only what follows it.
    if "</think>" in text:
        text = text.split("</think>", 1)[1].strip()
    if not text:
        return None
    # An answer far longer than asked for means it ignored the instructions,
    # and a wall of text in a push notification is worse than the plain one.
    if len(text) > 1200:
        print("model answer too long (%d chars), using the plain summary" % len(text),
              file=sys.stderr)
        return None
    return text


def push(title, message, priority, tags):
    """Publish via ntfy, reusing alert-relay's token rather than a second copy."""
    relay = container("mediastack_alert-relay")
    if not relay:
        print("alert-relay container not found, cannot read the ntfy token", file=sys.stderr)
        return False
    r = sh(["docker", "exec", relay, "cat", "/run/secrets/ntfy_relay_token"])
    if r.returncode != 0:
        print("could not read the ntfy token", file=sys.stderr)
        return False
    token = r.stdout.strip()

    p = subprocess.run(
        ["docker", "run", "--rm", "-i", "--network", "edge", "curlimages/curl:latest",
         "-s", "-o", "/dev/null", "-w", "%{http_code}",
         "-H", "Authorization: Bearer " + token,
         "-H", "Title: " + title,
         "-H", "Priority: " + priority,
         "-H", "Tags: " + tags,
         "--data-binary", "@-",
         "http://ntfy:80/" + NTFY_TOPIC],
        input=message, text=True, capture_output=True)
    code = p.stdout.strip()
    if code != "200":
        print("ntfy publish returned %s" % (code or p.stderr.strip()[:120]), file=sys.stderr)
        return False
    return True


def main():
    findings = media_findings()
    alerts, chronic = firing_alerts()

    n_media = len(findings.get("problems", [])) if findings else 0
    watchdog_broken = findings is not None and not findings.get("ok", 1)
    quiet = not alerts and not n_media and not watchdog_broken

    if quiet and not ALWAYS_PUSH:
        print("nothing firing and no media findings; no digest sent")
        return 0

    plain = plain_summary(findings, alerts, chronic)
    smart = ask_model(findings, alerts, chronic)
    message = smart or plain
    if smart:
        # The facts, underneath the interpretation, so the push is still
        # useful if the model phrased something oddly.
        message = smart + "\n\n---\n" + plain

    crit = any(a["severity"] == "critical" for a in alerts)
    priority = "high" if crit else ("default" if (alerts or n_media) else "low")
    tags = "rotating_light" if crit else ("warning" if alerts else "mag")
    title = "Stack digest: %d alert(s), %d media finding(s)" % (len(alerts), n_media)

    print(message)
    ok = push(title, message, priority, tags)
    print("\npushed=%s model=%s" % (ok, "yes" if smart else "no (plain summary)"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
