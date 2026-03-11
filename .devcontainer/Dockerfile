# Dev container: Swift 6.2 + Node for building Core and Dashboard.
# Workspace is mounted by Dev Containers at /workspaces/Sloppy.
FROM swift:6.2-jammy

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    libsqlite3-dev \
    ca-certificates \
    curl \
    && rm -rf /var/lib/apt/lists/*

# Node 20 LTS for Dashboard
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y nodejs \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /workspaces/Sloppy

CMD ["sleep", "infinity"]
