#!/usr/bin/env python3
"""Export Authentik account state as Prometheus metrics.

WHY NOT AUTHENTIK'S OWN NOTIFICATION RULES

Authentik can do this natively: an Expression Policy on `model_created`
bound to a Notification Rule with a webhook transport. It is real time,
which this is not. It also bypasses Alertmanager entirely, which means no
grouping, no silencing, no routing, and a second delivery path to ntfy that
fails in its own way and that nothing else in this stack resembles. Its
config would live only in Authentik's database, joining the list of things
that cannot be rebuilt from this repo.

This polls instead, on a five minute timer, and feeds the same
textfile -> Prometheus -> Alertmanager -> alert-relay -> ntfy path every
other alert here uses. Five minutes late is an acceptable price for one
alerting pipeline instead of two.

Accounts are gated upstream by the Google OAuth consent screen's test-user
allowlist, so a new account means someone already allowlisted signed in for
the first time rather than a stranger arriving. Worth knowing, not alarming.

NOTE ON LABELS: usernames are email addresses here and they become
Prometheus label values, so they appear in metrics, alerts and Grafana.
That data is local to this host and never leaves it, but it is real
addresses rather than opaque ids.

Run by systemd/mediastack-authentik-watchdog.timer.
"""
import subprocess
import sys
import time

TEXTFILE_VOLUME = "node_exporter_textfile"
METRIC_FILE = "authentik_watchdog.prom"
PG_FILTER = "mediastack_postgres."

# System principals, not people. AnonymousUser is Authentik's unauthenticated
# stand-in and ak-outpost-* is the embedded outpost's service account; both
# would otherwise look like accounts that joined.
EXCLUDE_SQL = "username <> 'AnonymousUser' AND username NOT LIKE 'ak-outpost-%'"

# The group join table is authentik_core_user_groups. Note that
# authentik_core_user_ak_groups ALSO exists in this database, but only in the
# `template` schema, so a query naming it fails with "relation does not
# exist" while looking entirely plausible in a table listing.


def sh(cmd):
    return subprocess.run(cmd, capture_output=True, text=True)


def pg_container():
    r = sh(["docker", "ps", "--filter", "name=" + PG_FILTER, "--format", "{{.Names}}"])
    names = [n for n in r.stdout.split() if n]
    return names[0] if names else None


def esc(v):
    return str(v).replace("\\", r"\\").replace('"', r"\"").replace("\n", " ")


def main():
    started = time.time()
    lines = []
    ok = 1

    container = pg_container()
    users = []
    if not container:
        ok = 0
        print("postgres container not found", file=sys.stderr)
    else:
        q = ("SELECT username, extract(epoch from date_joined)::bigint, "
             "coalesce(extract(epoch from last_login)::bigint, 0), "
             "CASE WHEN is_active THEN 1 ELSE 0 END, "
             "(SELECT count(*) FROM authentik_core_user_groups g "
             " WHERE g.user_id = u.id) "
             "FROM authentik_core_user u WHERE " + EXCLUDE_SQL + " ORDER BY date_joined")
        r = sh(["docker", "exec", container, "psql", "-U", "authentik", "-d", "authentik",
                "-tAF\t", "-c", q])
        if r.returncode != 0:
            ok = 0
            print("query failed: " + r.stderr.strip()[:200], file=sys.stderr)
        else:
            for line in r.stdout.splitlines():
                parts = line.split("\t")
                if len(parts) == 5:
                    users.append(parts)

    header = [
        "# HELP mediastack_authentik_users_total Non-system Authentik accounts.",
        "# TYPE mediastack_authentik_users_total gauge",
        "# HELP mediastack_authentik_user_created_timestamp_seconds When each account was created.",
        "# TYPE mediastack_authentik_user_created_timestamp_seconds gauge",
        "# HELP mediastack_authentik_user_last_login_timestamp_seconds Last login per account, 0 if never.",
        "# TYPE mediastack_authentik_user_last_login_timestamp_seconds gauge",
        "# HELP mediastack_authentik_user_groups Group bindings per account. Zero means no bindings at all, so domain-level fallthrough.",
        "# TYPE mediastack_authentik_user_groups gauge",
        "# HELP mediastack_authentik_watchdog_success Whether the last run read the database.",
        "# TYPE mediastack_authentik_watchdog_success gauge",
        "# HELP mediastack_authentik_watchdog_last_run_timestamp_seconds Unix time of the last run.",
        "# TYPE mediastack_authentik_watchdog_last_run_timestamp_seconds gauge",
    ]

    for username, created, last_login, active, groups in users:
        lab = 'username="%s"' % esc(username)
        lines.append("mediastack_authentik_user_created_timestamp_seconds{%s} %s" % (lab, created))
        lines.append("mediastack_authentik_user_last_login_timestamp_seconds{%s} %s" % (lab, last_login))
        lines.append("mediastack_authentik_user_groups{%s} %s" % (lab, groups))
        lines.append("mediastack_authentik_user_active{%s} %s" % (lab, active))

    lines.append("mediastack_authentik_users_total %d" % len(users))
    lines.append("mediastack_authentik_watchdog_success %d" % ok)
    lines.append("mediastack_authentik_watchdog_last_run_timestamp_seconds %d" % int(started))

    body = "\n".join(header + lines) + "\n"
    p = subprocess.run(
        ["docker", "run", "--rm", "-i", "-v", "%s:/t" % TEXTFILE_VOLUME, "alpine:latest",
         "sh", "-c", "cat > /t/%s.tmp && mv /t/%s.tmp /t/%s" % (METRIC_FILE, METRIC_FILE, METRIC_FILE)],
        input=body, text=True, capture_output=True)
    if p.returncode != 0:
        print("failed writing metrics: %s" % p.stderr.strip(), file=sys.stderr)
        return 1

    for username, created, _ll, _a, groups in users:
        age = (started - int(created)) / 86400.0
        print("  %-28s joined %5.1fd ago, %s group binding(s)" % (username, age, groups))
    print("%d account(s), success=%d" % (len(users), ok))
    return 0


if __name__ == "__main__":
    sys.exit(main())
