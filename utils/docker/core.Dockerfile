FROM swift:6.2-jammy AS builder
RUN apt-get update && apt-get install -y libsqlite3-dev && rm -rf /var/lib/apt/lists/*
WORKDIR /workspace
COPY Package.swift ./
COPY Package.resolved ./
COPY Sources ./Sources
COPY Tests ./Tests
RUN swift build -c release --product Core
RUN set -eux; \
    mkdir -p /artifacts; \
    mkdir -p /artifacts/SlopOverlord_Core.resources; \
    mkdir -p /artifacts/SlopOverlord_Core.bundle; \
    CORE_BIN="$(find .build -type f -path '*/release/Core' | head -n 1)"; \
    cp "$CORE_BIN" /artifacts/Core; \
    RESOURCE_DIR="$(find .build -type d \( -name 'SlopOverlord_Core.resources' -o -name 'SlopOverlord_Core.bundle' \) | head -n 1 || true)"; \
    if [ -n "${RESOURCE_DIR}" ]; then \
      cp -R "$RESOURCE_DIR"/. "/artifacts/$(basename "$RESOURCE_DIR")"; \
    fi

FROM swift:6.2-jammy
WORKDIR /app
COPY --from=builder /artifacts/Core /app/Core
COPY --from=builder /artifacts/SlopOverlord_Core.resources /app/SlopOverlord_Core.resources
COPY --from=builder /artifacts/SlopOverlord_Core.bundle /app/SlopOverlord_Core.bundle
COPY slopoverlord.config.json /app/slopoverlord.config.json
EXPOSE 25101
CMD ["/app/Core"]
