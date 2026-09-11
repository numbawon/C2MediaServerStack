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

FROM madeofpendletonwool/pinepods@sha256:ebc258bb0c62cdb69e5fb726b247c885dac19b50d06fed68fa8d37197b88ace4

COPY --from=api-builder /src/rust-api/target/release/pinepods-api /usr/local/bin/pinepods-api
COPY --from=api-builder /src/web/dist/ /var/www/html/
