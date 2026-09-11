FROM rust:alpine AS api-builder

ARG PINEPODS_COMMIT=09c3dcd459bf8e1b8732f26cfa42b3e99064f4ae

RUN apk add --no-cache musl-dev openssl-dev openssl-libs-static patch wget

WORKDIR /src
RUN wget -qO- "https://github.com/madeofpendletonwool/PinePods/archive/${PINEPODS_COMMIT}.tar.gz" \
    | tar -xz --strip-components=1

COPY subscription-null.patch /tmp/subscription-null.patch
RUN patch -p1 < /tmp/subscription-null.patch

WORKDIR /src/rust-api
ENV OPENSSL_STATIC=1
ENV OPENSSL_LIB_DIR=/usr/lib
ENV OPENSSL_INCLUDE_DIR=/usr/include
RUN cargo build --release && strip target/release/pinepods-api

RUN rustup target add wasm32-unknown-unknown \
    && cargo install trunk --version 0.21.14 --locked
WORKDIR /src/web
RUN RUSTFLAGS='--cfg=web_sys_unstable_apis --cfg getrandom_backend="wasm_js"' \
    trunk build --features server_build

# Hash every python app file at the pinned commit. The final stage diffs
# this against what the base image actually ships, so a mismatch between
# the two halves of this image becomes a build failure instead of a
# runtime mystery.
WORKDIR /src
RUN for d in database_functions startup clients; do \
        [ -d "$d" ] && find "$d" -type f -exec sha256sum {} + ; \
    done | sort -k2 > /tmp/src-manifest.txt

FROM madeofpendletonwool/pinepods@sha256:ebc258bb0c62cdb69e5fb726b247c885dac19b50d06fed68fa8d37197b88ace4

COPY --from=api-builder /src/rust-api/target/release/pinepods-api /usr/local/bin/pinepods-api
COPY --from=api-builder /src/web/dist/ /var/www/html/

# The migrations have to come from the same commit as the API, not from
# the base image. The base is a release image and lags the pinned commit:
# 0.9.0 was cut 2026-06-26, this commit is 2026-09-09, and the twelve
# migrations 048-059 landed in between. Taking only the binary meant a
# Rust API new enough to SELECT AutoQueue against a schema whose migration
# set stopped at 047, so every scheduled podcast refresh died on
# `column "autoqueue" does not exist` and no new episodes appeared in the
# UI or on disk. Nothing logged it as a failure: startup reported "All
# migrations registered" and "No pending migrations to apply", both true
# and both describing the wrong migration set.
#
# Only migration_definitions.py actually differs (211911 vs 258094 bytes);
# migrate.py, migrations.py and validate_database.py are identical, and
# startup imports them by module name, so replacing the directory as a
# unit keeps it internally consistent.
COPY --from=api-builder /src/database_functions/ /pinepods/database_functions/

# --- drift guard ---------------------------------------------------
# This image is two halves: application code from PINEPODS_COMMIT, and a
# runtime (nginx, horust, python deps) from the base image. Bumping the
# commit upgrades only the first half. That is how a September API ended
# up querying a June schema: twelve migrations, 048-059, were never even
# registered, startup cheerfully logged "All migrations registered" and
# "No pending migrations to apply" -- both true of the wrong set -- and
# podcast refresh then failed every 30 minutes on a column that did not
# exist.
#
# So: compare every python app file in the base image against the same
# file at the pinned commit. Anything that differs must be listed in
# base-divergence.allow with a reason. The comparison is exact in both
# directions, so a newly drifting file fails the build AND a file that
# stops drifting fails it too, which keeps the allow list honest rather
# than letting it rot into a pile of stale exemptions.
# yt-dlp self-updates at runtime now that migration 059 turned on yt-dlp
# management, and it could not: the binary and /usr/local/bin are both
# root-owned while the app runs as PUID/PGID, so every scheduler tick
# logged "Unable to write to /usr/local/bin/yt-dlp" and kept the old copy.
#
# It needs the DIRECTORY writable, not just the file: the updater writes
# <path>.new and renames over the original. Making /usr/local/bin writable
# would let the app replace any binary in it, pinepods-api included, so
# yt-dlp gets its own directory and a symlink keeps it on PATH. It is a
# PyInstaller one-file build, so it resolves the symlink and updates the
# real path in the writable directory.
#
# 1000:1000 matches COMMON_PUID/COMMON_PGID. If those change, the update
# fails exactly as before: a warning, and the existing binary is kept.
RUN mkdir -p /opt/yt-dlp \
 && mv /usr/local/bin/yt-dlp /opt/yt-dlp/yt-dlp \
 && ln -s /opt/yt-dlp/yt-dlp /usr/local/bin/yt-dlp \
 && chown -R 1000:1000 /opt/yt-dlp

COPY --from=api-builder /tmp/src-manifest.txt /tmp/src-manifest.txt
COPY base-divergence.allow /tmp/base-divergence.allow
RUN set -eu; \
    grep -vE '^\s*(#|$)' /tmp/base-divergence.allow | sort -u > /tmp/allowed; \
    : > /tmp/diverged; \
    while read -r want path; do \
        have="$(sha256sum "/pinepods/$path" 2>/dev/null | cut -d' ' -f1 || true)"; \
        [ "$have" = "$want" ] || echo "$path" >> /tmp/diverged; \
    done < /tmp/src-manifest.txt; \
    sort -u /tmp/diverged -o /tmp/diverged; \
    if ! diff -q /tmp/allowed /tmp/diverged >/dev/null 2>&1; then \
        echo "=========================================================="; \
        echo "PinePods image drift guard FAILED."; \
        echo ""; \
        echo "Files differing from PINEPODS_COMMIT but NOT allow-listed:"; \
        comm -13 /tmp/allowed /tmp/diverged | sed 's/^/  + /'; \
        echo "Allow-listed but no longer differing (remove these):"; \
        comm -23 /tmp/allowed /tmp/diverged | sed 's/^/  - /'; \
        echo ""; \
        echo "Fix by adding a COPY --from=api-builder for the file, or by"; \
        echo "updating pinepods/base-divergence.allow with the reason."; \
        echo "=========================================================="; \
        exit 1; \
    fi; \
    echo "drift guard: base-image divergence matches the allow list"

