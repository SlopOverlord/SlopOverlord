---
layout: doc
title: Install
---

# Install

Three ways to get Sloppy running: with Homebrew, from the source installer, or with Docker Compose.

## Homebrew

[Install Homebrew](https://brew.sh) if you do not already have it. The Sloppy tap files live in this repository ([`Casks/sloppy.rb`](https://github.com/TeamSloppy/Sloppy/blob/main/Casks/sloppy.rb) and [`Formula/sloppy.rb`](https://github.com/TeamSloppy/Sloppy/blob/main/Formula/sloppy.rb)); add the tap once, then install the cask or formula below.

### macOS (Cask)

```bash
brew tap teamsloppy/sloppy https://github.com/TeamSloppy/Sloppy
brew install --cask teamsloppy/sloppy/sloppy
```

This installs the `sloppy` binary and copies the Dashboard bundle to `~/.local/share/sloppy/dashboard`, matching the layout used by the source installer. Install `sloppy-node` separately when you need a standalone local computer-control executor.

::: tip macOS architecture

Each release updates the cask to a single macOS tarball from [GitHub Releases](https://github.com/TeamSloppy/Sloppy/releases). If that build does not match your Mac, use the [source installer](#source-installer) or download the matching `Sloppy-macos-*.tar.gz` asset manually.

:::

### Linux (Formula)

The Homebrew formula ships a **Linux x86_64** tarball.

```bash
brew tap teamsloppy/sloppy https://github.com/TeamSloppy/Sloppy
brew install teamsloppy/sloppy/sloppy
```

### Verify, upgrade, and uninstall

```bash
sloppy --version
```

```bash
brew upgrade --cask teamsloppy/sloppy/sloppy   # macOS
brew upgrade teamsloppy/sloppy/sloppy           # Linux
```

```bash
brew uninstall --cask teamsloppy/sloppy/sloppy   # macOS
brew uninstall teamsloppy/sloppy/sloppy         # Linux
```

## Terminal

### Prerequisites

| Dependency | Notes |
| --- | --- |
| Swift 6 toolchain | macOS 14+ or Linux |
| `sqlite3` | Runtime dependency |
| Node.js + npm | For Dashboard |

On Ubuntu/Debian install SQLite headers first:

```bash
sudo apt-get update && sudo apt-get install -y libsqlite3-dev
```

### Source installer

From a local checkout:

```bash
git clone https://github.com/TeamSloppy/Sloppy.git
cd Sloppy
bash scripts/install.sh
```

Or bootstrap from GitHub without cloning first:

```bash
curl -fsSL https://sloppy.team/install.sh | bash
```

The installer will:

- build `sloppy` in release mode
- build the Dashboard bundle by default
- install the `sloppy` symlink into `~/.local/bin`

Useful modes:

```bash
bash scripts/install.sh --server-only
bash scripts/install.sh --bundle --no-prompt
bash scripts/install.sh --release
bash scripts/install.sh --dry-run
curl -fsSL https://sloppy.team/install.sh | bash -s -- --server-only
```

If you want the script to clone or update Sloppy for you instead of running from a checkout:

```bash
bash scripts/install.sh --dir ~/.local/share/sloppy/source
curl -fsSL https://sloppy.team/install.sh | bash -s -- --dir ~/.local/share/sloppy/source
```

Verify the installation and check connectivity:

```bash
sloppy --version
```

### Standalone SloppyNode

`sloppy` can use computer-control tools in-process. For a separate node executable, install `sloppy-node`:

```bash
bash scripts/install-sloppy-node.sh
```

On Windows:

```powershell
powershell -ExecutionPolicy Bypass -File scripts/install-sloppy-node.ps1
```

For permissions, protocol details, and client helper notes, see [SloppyNode](/guides/sloppy-node).

Then open the terminal UI for local project chat:

```bash
sloppy
```

Or start the server and Dashboard:

```bash
sloppy run
sloppy status
```

If `sloppy` is not in `PATH`, add `~/.local/bin` to your shell profile.

## Run as a background service

Once `sloppy` is in your `PATH`, you can install it as a persistent background service that starts automatically on login and restarts if it crashes.

```bash
sloppy service install
```

That's it. The server is now running in the background and will start again on every login.

To verify:

```bash
sloppy service status
sloppy status
```

To follow the live log:

```bash
sloppy service logs
```

To stop or remove the service:

```bash
sloppy service stop        # stop now, keep registered
sloppy service uninstall   # stop + remove entirely
```

::: tip Custom config path

If your `sloppy.json` is not in the default location (`~/.sloppy/sloppy.json`), pass it at install time:

```bash
sloppy service install --config-path /path/to/sloppy.json
```

The path is embedded in the service definition so every restart picks it up automatically.

:::

::: details Platform notes

**macOS** — registers a LaunchAgent at `~/Library/LaunchAgents/com.sloppy.server.plist`. The OS uses `KeepAlive` to restart the process if it exits. Logs go to `~/.sloppy/logs/service.log`.

**Linux** — creates a systemd user unit at `~/.config/systemd/user/sloppy.service` and enables it with `systemctl --user`. Logs are available via `journalctl --user -u sloppy.service`.

:::

### Uninstall

To remove installed binaries and dashboard assets:

```bash
bash scripts/uninstall.sh
```

To also remove the source checkout used for source installs:

```bash
bash scripts/uninstall.sh --remove-source-checkout
```

Preview removals without deleting anything:

```bash
bash scripts/uninstall.sh --dry-run
```

For details see [Build From Terminal](/guides/build-from-terminal), [Terminal UI](/guides/tui), and the [CLI Reference](/guides/cli).

## Docker

### Prerequisites

| Dependency | Notes |
| --- | --- |
| Docker | Engine + CLI |
| Docker Compose | v2 plugin |

### Quick start

```bash
git clone https://github.com/TeamSloppy/Sloppy.git
cd Sloppy
docker compose -f utils/docker/docker-compose.yml up --build
```

| Service | URL |
| --- | --- |
| `sloppy` | `http://localhost:25101` |
| `dashboard` | `http://localhost:25102` |

For details see [Build With Docker](/guides/build-with-docker).

## Environment variables

Create a `.env` in the repository root to configure API keys:

```bash
OPENAI_API_KEY=your_key
GEMINI_API_KEY=your_key
ANTHROPIC_API_KEY=your_key
SLOPPY_CA_CERTS=/path/to/extra-ca.pem
BRAVE_API_KEY=your_key
PERPLEXITY_API_KEY=your_key
```

Environment values take precedence over empty `sloppy.json` keys but are overridden when a config key is explicitly set. See [Model Providers](/guides/models) for provider-specific setup.
