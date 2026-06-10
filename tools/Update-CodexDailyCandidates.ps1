param(
    [string]$Date = (Get-Date -Format 'yyyy-MM-dd'),
    [switch]$DryRun
)

$scriptPath = Join-Path $PSScriptRoot "codex_light_auto.py"

if (-not (Test-Path -LiteralPath $scriptPath)) {
    throw "Missing script: $scriptPath"
}

$args = @($scriptPath, "--date", $Date)
if ($DryRun) {
    $args += "--dry-run"
}

python @args
