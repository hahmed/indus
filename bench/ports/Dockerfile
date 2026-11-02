# One box for every AOT measurement: Go, Rust, GNU time. Indus binaries are
# mounted in; they need nothing from the image.
FROM rust:1-slim-bookworm
RUN apt-get update && apt-get install -y --no-install-recommends golang-go time && rm -rf /var/lib/apt/lists/*
WORKDIR /w
