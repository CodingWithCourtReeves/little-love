FROM rust:1.88-bookworm AS builder
WORKDIR /build
COPY Cargo.toml Cargo.lock* ./
COPY crypto/Cargo.toml crypto/Cargo.toml
COPY crypto/src crypto/src
COPY server/Cargo.toml server/Cargo.toml
COPY server/src server/src
COPY server/migrations server/migrations
RUN cargo build --release -p littlelove-api

FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/*
COPY --from=builder /build/target/release/littlelove-api /usr/local/bin/littlelove-api
COPY --from=builder /build/server/migrations /app/migrations
WORKDIR /app
EXPOSE 7707
CMD ["/usr/local/bin/littlelove-api"]
