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

$pythonCandidates = @(
    "python",
    "py",
    (Join-Path $env:LOCALAPPDATA "Programs\Python\Python314\python.exe"),
    (Join-Path $env:LOCALAPPDATA "Programs\Python\Python313\python.exe"),
    (Join-Path $env:LOCALAPPDATA "Programs\Python\Python312\python.exe"),
    (Join-Path $env:LOCALAPPDATA "Programs\Python\Python311\python.exe")
)

$pythonCommand = $null
foreach ($candidate in $pythonCandidates) {
    if (-not $candidate) {
        continue
    }

    $command = Get-Command $candidate -ErrorAction SilentlyContinue
    if ($command -and $command.CommandType -eq "Application") {
        $pythonCommand = $command.Source
        break
    }

    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
        $pythonCommand = $candidate
        break
    }
}

if (-not $pythonCommand) {
    throw "Python executable not found. Install Python or update Update-CodexDailyCandidates.ps1 with its full path."
}

& $pythonCommand @args
