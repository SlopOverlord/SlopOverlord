#!/usr/bin/env node
/**
 * Runs `docker compose up` from the repo root. Used by VS Code launch config
 * so that stopping the debug session stops the containers.
 */
const { spawn } = require("child_process");
const path = require("path");

const repoRoot = path.resolve(__dirname, "../../..");
const child = spawn(
  "docker",
  ["compose", "-f", "utils/docker/docker-compose.yml", "up"],
  {
    cwd: repoRoot,
    stdio: "inherit",
    shell: true,
  }
);

function shutdown() {
  child.kill("SIGTERM");
}

process.on("SIGINT", shutdown);
process.on("SIGTERM", shutdown);
child.on("exit", (code) => process.exit(code ?? 0));
