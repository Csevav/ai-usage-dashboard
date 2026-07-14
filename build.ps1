Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$HomeDir = if ($env:AI_USAGE_DASHBOARD_HOME) { $env:AI_USAGE_DASHBOARD_HOME } else { Join-Path $HOME ".ai-usage-dashboard" }
$PythonArgs = @("$ScriptDir/scripts/build_dashboard.py", "--source-dir", $ScriptDir, "--home", $HomeDir) + $args

if (Get-Command py -ErrorAction SilentlyContinue) {
  & py -3 @PythonArgs
  exit $LASTEXITCODE
}

if (Get-Command python -ErrorAction SilentlyContinue) {
  & python @PythonArgs
  exit $LASTEXITCODE
}

if (Get-Command python3 -ErrorAction SilentlyContinue) {
  & python3 @PythonArgs
  exit $LASTEXITCODE
}

Write-Error "python3/python/py was not found. AI Usage Dashboard requires Python 3."
