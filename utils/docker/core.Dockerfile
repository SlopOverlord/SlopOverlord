# syntax=docker/dockerfile:1.7
FROM swift:6.2-jammy AS builder
RUN apt-get update && apt-get install -y libsqlite3-dev && rm -rf /var/lib/apt/lists/*
WORKDIR /workspace
ARG SWIFT_BUILD_CONFIGURATION=release
COPY Package.swift ./
COPY Package.resolved ./
COPY Vendor ./Vendor
RUN --mount=type=cache,id=sloppy-swiftpm,target=/root/.swiftpm \
    --mount=type=cache,id=sloppy-swift-cache,target=/root/.cache \
    swift package resolve
COPY Sources ./Sources
COPY Tests ./Tests
RUN --mount=type=cache,id=sloppy-swiftpm,target=/root/.swiftpm \
    --mount=type=cache,id=sloppy-swift-cache,target=/root/.cache \
    --mount=type=cache,id=sloppy-core-build,target=/workspace/.build \
    set -eux; \
    swift build -c "${SWIFT_BUILD_CONFIGURATION}" --product Core; \
    mkdir -p /artifacts; \
    mkdir -p /artifacts/Sloppy_Core.resources; \
    mkdir -p /artifacts/Sloppy_Core.bundle; \
    CORE_BIN="$(find .build -type f -path "*/${SWIFT_BUILD_CONFIGURATION}/Core" | head -n 1)"; \
    strip "$CORE_BIN" || true; \
    cp "$CORE_BIN" /artifacts/sloppy-core; \
    RESOURCE_DIR="$(find .build -type d \( -name 'Sloppy_Core.resources' -o -name 'Sloppy_Core.bundle' \) | head -n 1 || true)"; \
    if [ -n "${RESOURCE_DIR}" ]; then \
    cp -R "$RESOURCE_DIR"/. "/artifacts/$(basename "$RESOURCE_DIR")"; \
    fi

FROM ubuntu:22.04 AS runtime-base
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    tzdata \
    libsqlite3-0 \
    libcurl4 \
    libxml2 \
    libicu70 \
    libbsd0 \
    libedit2 \
    libncursesw6 \
    zlib1g \
    libgcc-s1 \
    libstdc++6 \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /root
RUN mkdir -p /root/workspace /etc/sloppy /var/lib/sloppy
COPY --from=builder /usr/lib/swift /usr/lib/swift
COPY --from=builder /artifacts/sloppy-core /usr/bin/sloppy-core
COPY --from=builder /artifacts/Sloppy_Core.resources /usr/bin/Sloppy_Core.resources
COPY --from=builder /artifacts/Sloppy_Core.bundle /usr/bin/Sloppy_Core.bundle

FROM runtime-base AS runtime-default

FROM runtime-base AS runtime-full
ARG CHROME_DEB_URL=https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb
RUN apt-get update && apt-get install -y --no-install-recommends \
    wget \
    gnupg \
    fonts-liberation \
    xdg-utils \
    libasound2 \
    libatk-bridge2.0-0 \
    libatk1.0-0 \
    libcups2 \
    libdrm2 \
    libgbm1 \
    libgtk-3-0 \
    libnspr4 \
    libnss3 \
    libu2f-udev \
    libvulkan1 \
    && wget -O /tmp/google-chrome.deb "${CHROME_DEB_URL}" \
    && apt-get install -y /tmp/google-chrome.deb \
    && ln -sf /usr/bin/google-chrome-stable /usr/bin/chromium \
    && rm -f /tmp/google-chrome.deb \
    && rm -rf /var/lib/apt/lists/*

EXPOSE 25101
CMD ["/usr/bin/sloppy-core"]
