---
layout: doc
title: Build With Docker
---

# Build With Docker

This guide covers the containerized workflow for running Sloppy with Docker Compose.

## What is included

The Docker assets live in `utils/docker/`:

- `utils/docker/core.Dockerfile` builds the `Core` executable in a Swift 6.2 image and packages it into an Ubuntu runtime image.
- `utils/docker/dashboard.Dockerfile` runs the React dashboard in a Node 20 container.
- `utils/docker/docker-compose.yml` starts the `core` and `dashboard` services together.
- `utils/docker/scripts/` contains thin wrappers around the Compose commands.

## Prerequisites

- Docker
- Docker Compose

Optional:

- `.env` in the repository root if you want to provide values such as `OPENAI_API_KEY`

## Build the containers

From the repository root:

```bash
docker compose -f utils/docker/docker-compose.yml build
```

Wrapper script:

```bash
./utils/docker/scripts/build.sh
```

## Start the stack

```bash
docker compose -f utils/docker/docker-compose.yml up
```

Wrapper script:

```bash
./utils/docker/scripts/up.sh
```

Start in detached mode:

```bash
docker compose -f utils/docker/docker-compose.yml up -d
```

## Stop the stack

```bash
docker compose -f utils/docker/docker-compose.yml down
```

Wrapper script:

```bash
./utils/docker/scripts/down.sh
```

## Service endpoints

| Service | URL | Notes |
| --- | --- | --- |
| `core` | `http://localhost:25101` | Exposes the Sloppy HTTP API |
| `dashboard` | `http://localhost:25102` | Runs the Vite development server in the container |

## Persistent data

The Compose stack defines a named volume:

| Volume | Purpose |
| --- | --- |
| `core_data` | Persists the workspace mounted at `/root/workspace` inside the `core` container |

## Environment variables

The Compose file loads the repository `.env` file and passes through `OPENAI_API_KEY` when present.

If you want OpenAI-backed flows in Docker, add this to `.env`:

```bash
OPENAI_API_KEY=your_key_here
```

## Build details

### Core image

- Uses `swift:6.2-jammy` as the build stage
- Installs `libsqlite3-dev`
- Builds the `Core` product
- Copies the binary and processed resources into a smaller Ubuntu runtime image

### Dashboard image

- Uses `node:20-alpine`
- Installs dashboard dependencies
- Runs `npm run dev -- --host 0.0.0.0 --port 25102`

## When to use Docker vs terminal builds

Use Docker when:

- You want a reproducible environment close to CI
- You want to avoid managing the host Swift toolchain manually
- You want `Core` and `Dashboard` launched together

Use direct terminal builds when:

- You need the fastest edit-run loop
- You are iterating on Swift or frontend code locally
- You want easier access to native debuggers and local tools
