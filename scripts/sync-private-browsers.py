#!/usr/bin/env python3
"""Give every member of the Authentik `Browser` group a private browser.

    scripts/sync-private-browsers.py                 render + show the plan
    scripts/sync-private-browsers.py --apply         ...and push it to the node
    scripts/sync-private-browsers.py --ensure-group  create the group if missing

What exists once this has run, per person: one Firefox container (KasmVNC, in
a browser tab) with its own profile volume, so bookmarks, logins and
downloads are theirs alone. All of them sit on an internal Docker network
with no route out; the only exit is a filtering proxy that forwards to the
existing VPN container. See nuc-nodes/C2-Swarm-01/browser/ for the pieces
and why each is shaped the way it is.

Why this is a generator and not a static compose file: who has a browser is
whoever is in the Authentik group today, and the output carries usernames
(often email addresses) and the VPN proxy password. None of that belongs in a
public repo, so everything rendered lands in .generated/browser/, which is
git-ignored, and goes straight to the node.

Removing someone from the group removes their container on the next --apply,
but NEVER their profile volume: their data stays until you delete the volume
by hand.

Settings come from .env: COMMON_DOMAIN, COMMON_TZ, and BROWSER_NODE_SSH, the
user@host of the node that runs the browsers.
"""
import argparse
import hashlib
import os
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "nuc-nodes/C2-Swarm-01/browser"
OUT = ROOT / ".generated/browser"
GROUP = "Browser"
REMOTE_DIR = "browser"  # relative to the node user's home
USERNAME_OK = re.compile(r"^[A-Za-z0-9._@+-]{1,64}$")
SECRET_OK = re.compile(r"^[A-Za-z0-9._~+=-]{1,128}$")


def load_env():
    env = dict(os.environ)
    path = ROOT / ".env"
    if path.exists():
        for line in path.read_text().splitlines():
            m = re.match(r'^\s*([A-Z][A-Z0-9_]*)=(.*)$', line)
            if m and m.group(1) not in env:
                env[m.group(1)] = m.group(2).strip().strip('"').strip("'")
    return env


def authentik(code):
    """Run a snippet in Authentik's own shell and return the RES lines."""
    worker = subprocess.run(
        ["docker", "ps", "-q", "-f", "name=mediastack_authentik-worker"],
        capture_output=True, text=True).stdout.split()
    if not worker:
        sys.exit("authentik worker container is not running")
    res = subprocess.run(["docker", "exec", "-i", worker[0], "ak", "shell"],
                         input=code, capture_output=True, text=True)
    return [l[4:] for l in res.stdout.splitlines() if l.startswith("RES ")]


def group_members():
    lines = authentik(
        "from authentik.core.models import Group\n"
        f"g = Group.objects.filter(name='{GROUP}').first()\n"
        "print('RES missing' if g is None else 'RES ok')\n"
        "if g is not None:\n"
        "    for u in g.users.filter(is_active=True).order_by('username'):\n"
        "        print('RES user ' + u.username)\n")
    if lines and lines[0] == "missing":
        sys.exit(f"Authentik has no group named {GROUP!r}. "
                 "Run again with --ensure-group, then add people to it.")
    return [l[5:] for l in lines if l.startswith("user ")]


def ensure_group():
    out = authentik(
        "from authentik.core.models import Group\n"
        f"g, made = Group.objects.get_or_create(name='{GROUP}')\n"
        "print('RES ' + ('created' if made else 'exists'))\n")
    print(f"group {GROUP!r}: {out[0] if out else 'unknown'}")


def make_slugs(usernames):
    """Stable, readable, unique container names from usernames."""
    slugs, used = {}, set()
    for u in usernames:
        if not USERNAME_OK.match(u):
            print(f"  skipping {u!r}: unusual characters in the username", file=sys.stderr)
            continue
        base = re.sub(r"[^a-z0-9]+", "-", u.split("@")[0].lower()).strip("-")[:24] or "user"
        slug = base
        if slug in used:
            slug = f"{base}-{hashlib.sha1(u.encode()).hexdigest()[:6]}"
        used.add(slug)
        slugs[u] = slug
    return slugs


def read_secret(name):
    p = ROOT / "secrets" / name
    if not p.exists():
        sys.exit(f"missing {p}: the VPN proxy credentials live there")
    v = p.read_text().strip()
    if not SECRET_OK.match(v):
        sys.exit(f"{name} has characters Squid's login= cannot take unescaped; "
                 "rotate it to letters/digits first")
    return v


def render_compose(slugs, tz, policy_hash):
    users = ""
    volumes = ""
    for slug in slugs.values():
        users += f"""
  browser-{slug}:
    image: lscr.io/linuxserver/firefox:latest
    container_name: browser-{slug}
    environment:
      - TZ={tz}
      # The policy and the respawn script are read once, at container start.
      # This changes whenever either does, which makes `compose up` recreate
      # the container so the new version is live.
      - POLICY_HASH={policy_hash}
      # No CUSTOM_USER/PASSWORD: the gate in front does the authenticating
      # and this container is on a network nothing else can reach.
    volumes:
      - {slug}_config:/config
      # Proxy locked to the filtering egress, DoH and WebRTC off, about:config
      # blocked: the user cannot point the browser anywhere else.
      - ./firefox-policies.json:/usr/lib/firefox/distribution/policies.json:ro
      # Directory mount (see squid/gate above): keeps Firefox running after
      # its last tab is closed. Scripts here run at container start.
      - ./init:/custom-cont-init.d:ro
    shm_size: 1gb
    mem_limit: 3g
    cpus: 2
    pids_limit: 768
    networks: [browsers]
    restart: unless-stopped
"""
        volumes += f"  {slug}_config:\n"
    return f"""# GENERATED by scripts/sync-private-browsers.py: do not edit, do not commit.
name: browser

x-logging: &logging
  driver: json-file
  options:
    max-size: "10m"
    max-file: "3"

services:
  browser-egress:
    logging: *logging
    image: ubuntu/squid:latest
    container_name: browser-egress
    # Directory mounts, never single files: a file replaced on the host gets a
    # new inode and a running container keeps seeing the old one.
    volumes:
      - ./squid:/etc/squid-local:ro
    command: ["-f", "/etc/squid-local/squid.conf", "-NYC"]
    networks: [browsers, edge]
    restart: unless-stopped

  browser-gate:
    logging: *logging
    image: nginx:alpine
    container_name: browser-gate
    volumes:
      - ./gate:/etc/nginx/conf.d:ro
    networks: [browsers, edge]
    restart: unless-stopped
{users}
networks:
  # No gateway, no route out: containers here can only talk to each other.
  browsers:
    driver: bridge
    internal: true
  edge:
    external: true

volumes:
{volumes if volumes else "  {}"}"""


def render(slugs, env):
    for d in (OUT, OUT / "gate", OUT / "squid"):
        d.mkdir(parents=True, exist_ok=True)
    os.chmod(OUT, 0o700)
    (OUT / "gate/gate.conf").write_text((SRC / "gate.conf").read_text())
    (OUT / "squid/squid.conf").write_text((SRC / "squid.conf").read_text())
    (OUT / "init").mkdir(exist_ok=True)
    respawn = (SRC / "10-firefox-respawn.sh").read_text()
    (OUT / "init/10-firefox-respawn.sh").write_text(respawn)
    os.chmod(OUT / "init/10-firefox-respawn.sh", 0o755)
    policy = (SRC / "firefox-policies.json").read_text()
    (OUT / "firefox-policies.json").write_text(policy)
    user, pw = read_secret("httpproxy_user.txt"), read_secret("httpproxy_password.txt")
    peer = OUT / "squid/squid-peer.conf"
    peer.write_text(f"cache_peer vpn-client parent 8888 0 no-query no-digest "
                    f"name=vpn login={user}:{pw} connect-timeout=10\n")
    os.chmod(peer, 0o600)  # it holds the proxy password
    (OUT / "gate/users.map").write_text("".join(f'"{u}" browser-{s};\n' for u, s in slugs.items()))
    # Both are read once at container start, so a change to either must
    # recreate the containers.
    policy_hash = hashlib.sha1((policy + respawn).encode()).hexdigest()[:12]
    (OUT / "docker-compose.yml").write_text(
        render_compose(slugs, env.get("COMMON_TZ", "UTC"), policy_hash))


def ssh(node, cmd, stdin=None):
    return subprocess.run(["ssh", "-o", "BatchMode=yes", node, cmd],
                          input=stdin, capture_output=True, text=True)


def push(node, rel, in_place=False):
    """Send one file. Directory-mounted files are replaced atomically (the
    mount sees directory entries, so a new inode is fine). A file mounted
    DIRECTLY into a container (the Firefox policy) must keep its inode, so it
    is overwritten in place instead; a rename would leave containers reading
    the old file."""
    mode = "600" if rel.endswith("squid-peer.conf") else ("755" if rel.endswith(".sh") else "644")
    dest = f"{REMOTE_DIR}/{rel}"
    if in_place:
        cmd = f"mkdir -p $(dirname {dest}) && cat > {dest} && chmod {mode} {dest}"
    else:
        cmd = (f"mkdir -p $(dirname {dest}) && cat > {dest}.new && chmod {mode} {dest}.new "
               f"&& mv {dest}.new {dest}")
    r = ssh(node, cmd, (OUT / rel).read_text())
    if r.returncode:
        sys.exit(f"pushing {rel} failed: {r.stderr.strip()}")


def apply(env):
    node = env.get("BROWSER_NODE_SSH")
    if not node:
        sys.exit("set BROWSER_NODE_SSH=user@host in .env (the node that runs the browsers)")
    r = ssh(node, f"mkdir -p {REMOTE_DIR} && chmod 700 {REMOTE_DIR}")
    if r.returncode:
        sys.exit(f"cannot reach {node}: {r.stderr.strip()}")
    # Old single-file layout from the first version, now unused.
    ssh(node, f"cd {REMOTE_DIR} && rm -f gate.conf users.map squid.conf squid-peer.conf")
    for rel in ("gate/gate.conf", "gate/users.map", "squid/squid.conf", "squid/squid-peer.conf",
                "init/10-firefox-respawn.sh", "docker-compose.yml"):
        push(node, rel)
    push(node, "firefox-policies.json", in_place=True)
    r = ssh(node, f"cd {REMOTE_DIR} && docker compose up -d --remove-orphans")
    print(r.stdout + r.stderr)
    if r.returncode:
        sys.exit("docker compose up failed")
    # Directory mounts show the new files already; these make nginx and Squid
    # re-read them without dropping existing sessions.
    ssh(node, "docker exec browser-gate nginx -s reload; docker exec browser-egress squid -k reconfigure")
    print("applied.")


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--apply", action="store_true", help="push to the node and (re)start")
    ap.add_argument("--ensure-group", action="store_true", help=f"create the {GROUP!r} group if absent")
    args = ap.parse_args()
    env = load_env()
    if args.ensure_group:
        ensure_group()
    slugs = make_slugs(group_members())
    print(f"{len(slugs)} member(s) in {GROUP!r}:")
    for u, s in slugs.items():
        print(f"  {u}  ->  browser-{s}")
    render(slugs, env)
    print(f"rendered to {OUT.relative_to(ROOT)}/ (git-ignored)")
    if args.apply:
        apply(env)
    else:
        print("dry run: nothing pushed. Re-run with --apply to deploy.")


if __name__ == "__main__":
    main()
