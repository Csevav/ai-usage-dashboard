#!/usr/bin/env node

const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");

const root = path.resolve(__dirname, "..");
const argv = new Set(process.argv.slice(2));
const homeDir = process.env.AI_USAGE_DASHBOARD_HOME || path.join(os.homedir(), ".ai-usage-dashboard");
const claudeCommandsDir = path.join(os.homedir(), ".claude", "commands");

function ensureDir(dir) {
  fs.mkdirSync(dir, { recursive: true });
}

function copyFile(src, dest) {
  ensureDir(path.dirname(dest));
  fs.copyFileSync(src, dest);
}

function copyDashboard() {
  const rootFiles = ["build.sh", "build.ps1", "template.html"];
  const rootCompatFiles = ["dashboard_daemon.sh"];
  const scriptFiles = ["build_dashboard.py", "dashboard_daemon.py", "dashboard_server.py", "manage_daemon.py"];
  for (const name of rootFiles) {
    copyFile(path.join(root, name), path.join(homeDir, name));
  }
  for (const name of rootCompatFiles) {
    copyFile(path.join(root, "scripts", name), path.join(homeDir, name));
  }
  for (const name of scriptFiles) {
    copyFile(path.join(root, "scripts", name), path.join(homeDir, "scripts", name));
  }
  console.log(`Dashboard files installed to ${homeDir}`);
}

function copyCommand() {
  ensureDir(claudeCommandsDir);
  copyFile(path.join(root, "commands", "ai-usage.md"), path.join(claudeCommandsDir, "ai-usage.md"));
  console.log(`Claude Code slash command installed to ${path.join(claudeCommandsDir, "ai-usage.md")}`);
}

if (argv.has("--dashboard")) {
  copyDashboard();
} else if (argv.has("--command")) {
  copyCommand();
} else {
  copyDashboard();
  copyCommand();
}
