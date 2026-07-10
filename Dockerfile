# Docker build for cc-switch
# Builds the Rust binary + .deb package on Ubuntu 22.04.
# The .deb is then used by the GitHub Action to build a Flatpak bundle.
#
# Flatpak provides its own runtime (GNOME 46) with GLIBC 2.38, libsoup-3.0,
# webkit2gtk-4.1, etc. — so the resulting Flatpak works on Ubuntu 20.04+.
#
# Usage:
#   docker build -o out .
#   # .deb will be at out/*.deb

FROM ubuntu:22.04 AS builder

ENV DEBIAN_FRONTEND=noninteractive \
    PATH="/root/.cargo/bin:$PATH"

# ca-certificates FIRST (before any curl/https operations)
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl \
    && update-ca-certificates --fresh \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Build deps (libsoup-3.0-dev REQUIRED by Tauri v2 → WRY)
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential pkg-config wget file patchelf \
    libssl-dev libgtk-3-dev librsvg2-dev libayatana-appindicator3-dev \
    libwebkit2gtk-4.1-dev libsoup-3.0-dev \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Rust toolchain (match rust-toolchain.toml)
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
    | sh -s -- -y --profile minimal --default-toolchain 1.95

# Node.js 22 (match .node-version)
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y nodejs \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# pnpm
RUN npm install -g pnpm@10.12.3

WORKDIR /build
COPY . .

SHELL ["/bin/bash", "-eo", "pipefail", "-c"]

# Verify toolchain
RUN node -v && npm -v && pnpm -v && rustc -V && cargo -V

# Install deps + disable updater signing (no private key in Docker)
RUN pnpm install --frozen-lockfile \
    && sed -i 's/"createUpdaterArtifacts": true/"createUpdaterArtifacts": false/' src-tauri/tauri.conf.json \
    && sed -i 's|"pubkey": ".*"|"pubkey": ""|' src-tauri/tauri.conf.json

# Build
RUN pnpm tauri build --bundles deb \
    && cp src-tauri/target/release/bundle/deb/*.deb /tmp/cc-switch.deb

# Output stage: just the .deb with predictable name
FROM alpine:3.21
COPY --from=builder /tmp/cc-switch.deb /out/cc-switch.deb
CMD ["sh", "-c", "cp /out/cc-switch.deb /output/ 2>/dev/null || ls -la /out/"]
