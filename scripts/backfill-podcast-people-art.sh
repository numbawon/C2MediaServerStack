#!/usr/bin/env bash
# Fill in PinePods host artwork that never got stored.
#
# WHY THIS EXISTS
#
# PinePods writes People.personimg ONCE, at subscribe time, from whatever
# the browser happened to have loaded. It is never refreshed and has no
# fallback, so subscribing from a page that had not yet fetched the
# artwork stores an empty string permanently. Meanwhile the Discover Hosts
# view queries the podpeople API live and always looks correct -- two
# sources of truth, one of them frozen.
#
# That is upstream's design to fix; the real answer is for the person page
# to treat personimg as a cache and fall back to the API. Until then this
# reconciles the two. Re-run it after subscribing to new people.
#
# Only fills EMPTY values. Anything already set is left alone.
#
# Hotlink protection is the reason each URL is checked with a Referer
# before being written: some upstream URLs (wikia/fandom, for one) return
# 200 to a plain fetch and 404 when embedded in a page, which would store
# a link that is broken everywhere it is used.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

DOMAIN="$(grep -E '^COMMON_DOMAIN=' .env | cut -d= -f2 | tr -d '"')"
PG="$(docker ps -qf name=mediastack_pinepods-postgres | head -1)"
[ -n "$PG" ] || { echo "pinepods-postgres not running" >&2; exit 1; }

KEY="$(docker exec "$PG" psql -U pinepods -d pinepods -tAc \
  'select apikey from "APIKeys" limit 1;' | tr -d '\r\n')"
[ -n "$KEY" ] || { echo "no PinePods API key found" >&2; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

docker run --rm --network edge -e K="$KEY" curlimages/curl:latest sh -c \
  'curl -s -m 60 -H "Api-Key: $K" "http://pinepods:8040/api/data/podpeople/discover?kind=top-hosts&limit=500"' \
  > "$TMP/hosts.json"

echo "==> hosts from the podpeople API: $(python3 -c "import json;print(len(json.load(open('$TMP/hosts.json'))))")"

python3 - "$TMP/hosts.json" "$TMP/backfill.sql" "$DOMAIN" <<'PY'
import json, sys, urllib.request, urllib.error
hosts, out, domain = sys.argv[1], sys.argv[2], sys.argv[3]
ua = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/140"
ok = skipped = 0
with open(out, "w") as f:
    f.write("begin;\n")
    for h in json.load(open(hosts)):
        name, img = h.get("name"), h.get("img")
        if not (name and img):
            continue
        # Embedded fetch, not a bare one: that is what the browser does.
        req = urllib.request.Request(img, headers={
            "Referer": "https://podcasts.%s/" % domain, "User-Agent": ua})
        try:
            with urllib.request.urlopen(req, timeout=20) as r:
                if r.status != 200:
                    raise ValueError(r.status)
        except Exception:
            print("    skip (not embeddable): %s" % name)
            skipped += 1
            continue
        f.write("update \"People\" set personimg='%s' "
                "where lower(trim(name))=lower(trim('%s')) "
                "and coalesce(personimg,'')='';\n"
                % (img.replace("'", "''"), name.replace("'", "''")))
        ok += 1
    f.write("commit;\n")
print("==> %d usable, %d skipped as not embeddable" % (ok, skipped))
PY

docker exec -i "$PG" psql -U pinepods -d pinepods -v ON_ERROR_STOP=1 < "$TMP/backfill.sql" >/dev/null
echo "==> applied. People rows still without artwork:"
docker exec "$PG" psql -U pinepods -d pinepods -tAc \
  "select name from \"People\" where coalesce(personimg,'')='' order by name;" | sed 's/^/    /'
