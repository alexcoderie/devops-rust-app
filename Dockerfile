FROM lukemathwalker/cargo-chef:latest-rust-1 AS chef
WORKDIR /app

COPY rust-toolchain.toml .
RUN rustup toolchain install

FROM chef AS planner
COPY . .
RUN cargo chef prepare --recipe-path recipe.json

FROM chef AS builder
COPY --from=planner /app/recipe.json recipe.json
# Build dependencies - this is the caching Docker layer!
RUN cargo chef cook --release --locked --recipe-path recipe.json
# Build application
COPY . .
RUN cargo build --release --locked --bin my-app

# We do not need the Rust toolchain to run the binary!
FROM debian:bookworm-slim AS runtime
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --system --uid 10001 --no-create-home app
WORKDIR /app
COPY --from=builder /app/target/release/my-app /usr/local/bin/my-app
USER app
ENTRYPOINT ["/usr/local/bin/my-app"]
