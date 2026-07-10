# Multi-stage Docker build for cc-switch
# Produces a self-contained AppImage that bundles all required system libraries.
#
# Stage 1: Build on Ubuntu 22.04 (has libsoup-3.0-dev required by Tauri v2 → WRY)
# Stage 2: Package AppImage on Ubuntu 22.04 (bundles runtime libraries into AppImage)
#
# The resulting AppImage is self-contained and includes libsoup-3.0, libwebkit2gtk-4.1,
# and all other runtime dependencies. Compatibility with Ubuntu 20.04 depends on whether
# the bundled libraries use GLIBC symbols ≤ 2.31 — testing required.
#
# Usage:
#   docker build -t cc-switch .
#   docker run --rm -v $(pwd)/out:/out cc-switch
#   # AppImage will be at ./out/CC-Switch-*.AppImage

# ── Stage 1: Build ────────────────────────────────────────────────
FROM ubuntu:22.04 AS builder

ENV DEBIAN_FRONTEND=noninteractive \
    PATH="/root/.cargo/bin:$PATH"

# Step 1: SSL certs FIRST (before any curl/https operations)
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl \
    && update-ca-certificates --fresh \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Step 2: Build deps (libsoup-3.0-dev REQUIRED by Tauri v2 → WRY)
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential pkg-config wget file patchelf \
    libssl-dev libgtk-3-dev librsvg2-dev libayatana-appindicator3-dev \
    libwebkit2gtk-4.1-dev libsoup-3.0-dev \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Step 3: Rust toolchain (match rust-toolchain.toml)
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
    | sh -s -- -y --profile minimal --default-toolchain 1.95

# Step 4: Node.js 22 (match .node-version)
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y nodejs \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Step 5: pnpm (match CI version, npm -g is more reliable than corepack in Docker)
RUN npm install -g pnpm@10.12.3

WORKDIR /build
COPY . .

# Use bash explicitly (ubuntu:22.04 default /bin/sh is dash)
SHELL ["/bin/bash", "-eo", "pipefail", "-c"]

# Verify toolchain versions
RUN node --version \
    && npm --version \
    && pnpm --version \
    && rustc --version \
    && cargo --version

# Install frontend dependencies
RUN pnpm install --frozen-lockfile

# Disable updater signing in Docker (we don't have the private key)
# Tauri will try to sign if pubkey is present; clear it to skip
RUN sed -i 's/"createUpdaterArtifacts": true/"createUpdaterArtifacts": false/' src-tauri/tauri.conf.json \
    && sed -i 's|"pubkey": ".*"|"pubkey": ""|' src-tauri/tauri.conf.json

# Build frontend (Vite) then Rust backend + .deb
# Produces: src-tauri/target/release/cc-switch (binary)
#           src-tauri/target/release/bundle/deb/*.deb (for desktop/icon assets)
RUN pnpm tauri build --bundles deb

# ── Stage 2: Package AppImage ─────────────────────────────────────
FROM ubuntu:22.04 AS packager

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8

# SSL certs first (for wget)
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates wget \
    && update-ca-certificates --fresh \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Runtime-only system deps (no -dev packages)
# These are the libraries that linuxdeploy will detect via ldd and bundle
RUN apt-get update && apt-get install -y --no-install-recommends \
    file patchelf \
    libgtk-3-0 librsvg2-2 libayatana-appindicator3-1 \
    libwebkit2gtk-4.1-0 libjavascriptcoregtk-4.1-0 \
    libsoup-3.0-0 libenchant-2-2 libsecret-1-0 libnotify4 \
    libgstreamer1.0-0 libgstreamer-plugins-base1.0-0 \
    libegl1 libgles2 libgl1 libglib2.0-0 \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# linuxdeploy (self-contained AppImage, extracted to avoid FUSE requirement)
RUN wget -q -O /tmp/linuxdeploy.AppImage \
    "https://github.com/linuxdeploy/linuxdeploy/releases/download/continuous/linuxdeploy-x86_64.AppImage" \
    && chmod +x /tmp/linuxdeploy.AppImage \
    && /tmp/linuxdeploy.AppImage --appimage-extract \
    && mv squashfs-root /opt/linuxdeploy \
    && rm /tmp/linuxdeploy.AppImage

WORKDIR /app

# Copy compiled binary from builder
COPY --from=builder /build/src-tauri/target/release/cc-switch /app/usr/bin/cc-switch

# Copy .deb package from builder to extract desktop/icon assets
COPY --from=builder /build/src-tauri/target/release/bundle/deb/ /tmp/deb/

# Extract .deb assets: desktop file, icons
RUN cd /tmp/deb && DEB=$(ls *.deb | head -1) \
    && mkdir -p /tmp/deb-extract \
    && dpkg-deb -x "$DEB" /tmp/deb-extract \
    && mkdir -p /app/usr/share \
    && if [ -d /tmp/deb-extract/usr/share/applications ]; then cp -a /tmp/deb-extract/usr/share/applications /app/usr/share/; fi \
    && if [ -d /tmp/deb-extract/usr/share/icons ]; then cp -a /tmp/deb-extract/usr/share/icons /app/usr/share/; fi \
    && if [ -d /tmp/deb-extract/usr/lib/systemd ]; then cp -a /tmp/deb-extract/usr/lib/systemd /app/usr/lib/; fi \
    && rm -rf /tmp/deb /tmp/deb-extract

# Verify essential files
RUN test -f /app/usr/bin/cc-switch || (echo "ERROR: binary missing" >&2 && exit 1) \
    && ls /app/usr/share/applications/*.desktop >/dev/null 2>&1 \
        || (echo "ERROR: desktop file missing" >&2 && exit 1) \
    && find /app/usr/share/icons -name "*.png" | grep -q . \
        || (echo "WARNING: no icon found" >&2)

# AppRun symlink (required by AppImage spec)
RUN ln -sf usr/bin/cc-switch /app/AppRun

# Bundle libraries and create AppImage
# linuxdeploy runs ldd on the binary, finds all .so deps from the system (Ubuntu 22.04),
# and bundles them into the AppImage. This includes libsoup-3.0, libwebkit2gtk-4.1, etc.
RUN cd /app \
    && DESKTOP=$(ls usr/share/applications/*.desktop | head -1) \
    && ICON=$(find usr/share/icons -name "*.png" | head -1) \
    && /opt/linuxdeploy/AppRun \
        --appdir /app \
        --executable /app/usr/bin/cc-switch \
        --desktop-file "/app/$DESKTOP" \
        --icon-file "/app/$ICON" \
        --output appimage \
    && echo "=== AppImage created ===" \
    && ls -la /app/*.AppImage \
    && echo "=== Bundled libraries ===" \
    && ls /app/usr/lib/ 2>/dev/null | head -20 || echo "(none)"

# VOLUME + CMD: run container to extract AppImage to host
VOLUME /out
CMD ["sh", "-c", "chmod +x /app/*.AppImage && cp /app/*.AppImage /out/ && echo 'AppImage copied to /out/' && ls -la /out/"]
