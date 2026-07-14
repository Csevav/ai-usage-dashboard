#!/usr/bin/env node

const { spawnSync } = require("node:child_process");
const os = require("node:os");
const path = require("node:path");

const root = path.resolve(__dirname, "..");
const homeDir = process.env.AI_USAGE_DASHBOARD_HOME || path.join(os.homedir(), ".ai-usage-dashboard");
const script = path.join(root, "scripts", "build_dashboard.py");
const args = [script, "--source-dir", root, "--home", homeDir, ...process.argv.slice(2)];

const candidates = process.platform === "win32"
  ? [["py", ["-3", ...args]], ["python", args], ["python3", args]]
  : [["python3", args], ["python", args]];

let lastError = null;
for (const [command, commandArgs] of candidates) {
  const result = spawnSync(command, commandArgs, { stdio: "inherit" });
  if (!result.error) {
    process.exit(result.status ?? 0);
  }
  lastError = result.error;
}

console.error(`Failed to start AI Usage Dashboard: ${lastError ? lastError.message : "no Python runtime found"}`);
process.exit(1);
