---
layout: doc
title: Git & Repositories
---

# Git & Repositories

Sloppy uses Git in two ways: **cloning project repositories** (code that agents work with) and **syncing your workspace** (backing up agent configuration to a remote repository). Both support private repositories via a Personal Access Token (PAT) or SSH.

## Private repositories

By default Sloppy can only clone public repositories. To work with private ones, connect your GitHub account using a Personal Access Token.

### Step 1. Create a token on GitHub

1. Open [github.com/settings/tokens/new](https://github.com/settings/tokens/new?scopes=repo&description=Sloppy)
2. In the **Note** field enter `Sloppy`
3. Under **Select scopes** check `repo` — this grants access to all private repositories in your account
4. Click **Generate token** and copy it (it is shown only once)

### Step 2. Connect the token in the Dashboard

1. Open Dashboard → **Settings → Providers**
2. Scroll down to the **GitHub Access** section
3. Paste the token into the **Personal Access Token** field and click **Connect**

Sloppy validates the token and displays your account name. After that, cloning private repositories works automatically.

### Alternative: environment variable

If you run Sloppy from the terminal or Docker, you can pass the token via an environment variable instead of saving it in the Dashboard:

```bash
GITHUB_TOKEN=ghp_your_token swift run sloppy
```

Or in Docker Compose:

```yaml
environment:
  - GITHUB_TOKEN=ghp_your_token
```

**Priority:** a token set in the Dashboard takes precedence over `GITHUB_TOKEN`.

### SSH repositories

If you use a URL in the `git@github.com:org/repo.git` format, Sloppy passes it directly to `git clone` — authentication happens through SSH keys configured on the host system. Sloppy does not manage SSH keys on its own.

Make sure the SSH agent is running and the key is added:

```bash
eval "$(ssh-agent -s)"
ssh-add ~/.ssh/id_ed25519
ssh -T git@github.com   # should return your account name
```

---

## Cloning a repository into a project

When creating a project you can specify a repository URL. Sloppy clones it into the project directory, giving agents access to the code through filesystem tools.

### Via the Dashboard

1. Open Dashboard → **Projects → New Project**
2. Select **Clone from GitHub** as the source
3. Paste the repository URL (HTTPS or SSH)
4. Click **Create**

Cloning runs in the background. The repository appears inside the project directory within the workspace.

### Via the API

```bash
curl -X POST http://localhost:25101/v1/projects \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer your-token" \
  -d '{
    "id": "my-project",
    "name": "My Project",
    "repoUrl": "https://github.com/org/private-repo"
  }'
```

### Where the code is stored

The cloned repository lives at:

```
.sloppy/projects/{project-id}/
```

The path is controlled by `workspace.basePath` and `workspace.name` in `sloppy.json`.

---

## Workspace Git Sync

Git Sync saves your agent configuration (instructions, settings, tool policies) to a remote repository. This lets you:

- Restore the workspace after a reset
- Transfer configuration between servers
- Keep a history of changes to your agents

::: warning
Git Sync only synchronizes **configuration** inside `.sloppy/` (`AGENTS.md`, `USER.md`, `FRIEND_REMINDER.md`, `config.json`, `tools.json`, etc.), **not** memory data (SQLite), sessions, or cloned project code.
:::

### Setup via the Dashboard

1. Open **Settings → Git Sync**
2. Enable **Enable Sync**
3. Fill in the fields:

| Field | Description |
| --- | --- |
| **Repository** | Repository URL for synchronization (HTTPS with token or SSH) |
| **Branch** | Target branch, defaults to `main` |
| **Auth Token** | GitHub PAT with `repo` scope (if the repository is private) |
| **Schedule** | `manual`, `daily`, or `weekdays` |
| **Sync Time** | Synchronization time in `HH:MM` format |
| **Conflict Strategy** | What to do on conflict: `remote_wins`, `local_wins`, or `manual` |

4. Click **Save Config**

### Configuration in `sloppy.json`

```json
{
  "gitSync": {
    "enabled": true,
    "repository": "https://github.com/org/sloppy-workspace",
    "branch": "main",
    "authToken": "ghp_your_token",
    "schedule": {
      "frequency": "daily",
      "time": "18:00"
    },
    "conflictStrategy": "remote_wins"
  }
}
```

| Field | Type | Default | Description |
| --- | --- | --- | --- |
| `enabled` | bool | `false` | Enable synchronization |
| `repository` | string | `""` | Repository URL |
| `branch` | string | `"main"` | Target branch |
| `authToken` | string | `""` | GitHub PAT for private repositories |
| `schedule.frequency` | string | `"daily"` | Schedule: `manual`, `daily`, `weekdays` |
| `schedule.time` | string | `"18:00"` | Synchronization time (UTC) |
| `conflictStrategy` | string | `"remote_wins"` | Conflict resolution strategy |

### Conflict resolution strategies

| Value | Behavior |
| --- | --- |
| `remote_wins` | Remote version overwrites local |
| `local_wins` | Local version overwrites remote |
| `manual` | Sync pauses; you resolve the conflict manually |

---

## FAQ

**Can I use multiple GitHub accounts?**

Sloppy stores one token for private repository access. If you need access to repositories across different accounts, use SSH with separate keys (configured via `~/.ssh/config`) or create a token from an organization that has access to all required repositories.

**Where is the token stored?**

A token entered through the Dashboard is saved in `.sloppy/auth/github.json` inside the workspace. The file is only accessible on the server where Sloppy is running.

**What happens if the token expires?**

Cloning private repositories fails. Sloppy logs show a `project.clone.failed` event with exit code 128. Update the token via **Settings → Providers → GitHub Access**.

**Can I use Git Sync and GitHub Access with different accounts?**

Yes. Git Sync uses the token from the `authToken` field in the `gitSync` config, while project cloning uses the token from **GitHub Access** (or `GITHUB_TOKEN`). These are independent settings.
