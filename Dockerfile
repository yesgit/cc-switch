# cc-switch Docker image
# Multi-stage: build on ubuntu:22.04, then produce a thin runtime image.
#
# Build:
#   docker build -t cc-switch .
#
# Run (X11):
#   docker run --rm --net=host --ipc=host \
#     -e DISPLAY -v /tmp/.X11-unix:/tmp/.X11-unix \
#     -v $HOME:$HOME -w $HOME \
#     ghcr.io/yesgit/cc-switch
#
# Run (Wayland):
#   docker run --rm --net=host --ipc=host \
#     -e XDG_RUNTIME_DIR=/tmp \
#     -e WAYLAND_DISPLAY=$WAYLAND_DISPLAY \
#     -v $XDG_RUNTIME_DIR/$WAYLAND_DISPLAY:/tmp/$WAYLAND_DISPLAY \
#     -v $HOME:$HOME -w $HOME \
#     ghcr.io/yesgit/cc-switch

# ── Stage 1: Build ──
FROM ubuntu:22.04 AS builder

ENV DEBIAN_FRONTEND=noninteractive \
    PATH="/root/.cargo/bin:$PATH"

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl \
    && update-ca-certificates --fresh \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential pkg-config wget file patchelf \
    libssl-dev libgtk-3-dev librsvg2-dev libayatana-appindicator3-dev \
    libwebkit2gtk-4.1-dev libsoup-3.0-dev \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
    | sh -s -- -y --profile minimal --default-toolchain 1.95

RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y nodejs \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

RUN npm install -g pnpm@10.12.3

WORKDIR /build
COPY . .

SHELL ["/bin/bash", "-eo", "pipefail", "-c"]

RUN node -v && pnpm -v && rustc -V

RUN pnpm install --frozen-lockfile \
    && sed -i 's/"createUpdaterArtifacts": true/"createUpdaterArtifacts": false/' src-tauri/tauri.conf.json \
    && sed -i 's|"pubkey": ".*"|"pubkey": ""|' src-tauri/tauri.conf.json \
    && pnpm tauri build --bundles deb

# ── Stage 2: Runtime ──
FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    fonts-noto-cjk \
    libgtk-3-0 librsvg2-2 libayatana-appindicator3-1 \
    libwebkit2gtk-4.1-0 libjavascriptcoregtk-4.1-0 \
    libsoup-3.0-0 libenchant-2-2 libsecret-1-0 libnotify4 \
    libgstreamer1.0-0 libgstreamer-plugins-base1.0-0 \
    libegl1 libgles2 libgl1 \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

COPY --from=builder /build/src-tauri/target/release/cc-switch /usr/local/bin/cc-switch

ENTRYPOINT ["cc-switch"]
