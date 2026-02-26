# syntax=docker/dockerfile:1.7
FROM swift:6.2-jammy AS builder
RUN apt-get update && apt-get install -y libsqlite3-dev && rm -rf /var/lib/apt/lists/*
WORKDIR /workspace
ARG SWIFT_BUILD_CONFIGURATION=release
COPY Package.swift ./
COPY Package.resolved ./
RUN --mount=type=cache,id=slopoverlord-swiftpm,target=/root/.swiftpm \
    --mount=type=cache,id=slopoverlord-swift-cache,target=/root/.cache \
    swift package resolve
COPY Sources ./Sources
COPY Tests ./Tests
RUN --mount=type=cache,id=slopoverlord-swiftpm,target=/root/.swiftpm \
    --mount=type=cache,id=slopoverlord-swift-cache,target=/root/.cache \
    --mount=type=cache,id=slopoverlord-core-build,target=/workspace/.build \
    set -eux; \
    swift build -c "${SWIFT_BUILD_CONFIGURATION}" --product Core; \
    mkdir -p /artifacts; \
    mkdir -p /artifacts/SlopOverlord_Core.resources; \
    mkdir -p /artifacts/SlopOverlord_Core.bundle; \
    CORE_BIN="$(find .build -type f -path "*/${SWIFT_BUILD_CONFIGURATION}/Core" | head -n 1)"; \
    cp "$CORE_BIN" /artifacts/slopoverlord-core; \
    RESOURCE_DIR="$(find .build -type d \( -name 'SlopOverlord_Core.resources' -o -name 'SlopOverlord_Core.bundle' \) | head -n 1 || true)"; \
    if [ -n "${RESOURCE_DIR}" ]; then \
      cp -R "$RESOURCE_DIR"/. "/artifacts/$(basename "$RESOURCE_DIR")"; \
    fi

FROM swift:6.2-jammy
WORKDIR /usr/lib/slopoverlord
RUN mkdir -p /etc/slopoverlord /var/lib/slopoverlord
COPY --from=builder /artifacts/slopoverlord-core /usr/bin/slopoverlord-core
COPY --from=builder /artifacts/SlopOverlord_Core.resources /usr/lib/slopoverlord/SlopOverlord_Core.resources
COPY --from=builder /artifacts/SlopOverlord_Core.bundle /usr/lib/slopoverlord/SlopOverlord_Core.bundle
COPY slopoverlord.config.json /etc/slopoverlord/slopoverlord.config.json
EXPOSE 25101
CMD ["/usr/bin/slopoverlord-core", "--config-path", "/etc/slopoverlord/slopoverlord.config.json"]
