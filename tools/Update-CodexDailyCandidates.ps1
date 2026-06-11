param(
    [string]$Date = (Get-Date -Format 'yyyy-MM-dd'),
    [switch]$DryRun,
    [string]$SessionsRoot = 'C:\Users\33055\.codex\sessions',
    [string]$SessionIndex = 'C:\Users\33055\.codex\session_index.jsonl',
    [string]$VaultRoot = '',
    [int]$MinScore = 6,
    [int]$MaxItems = 12
)

[Console]::InputEncoding = [System.Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $VaultRoot) {
    $VaultRoot = Split-Path -Parent $ScriptRoot
}

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$AutoSectionStart = '<!-- codex-auto:start -->'
$AutoSectionEnd = '<!-- codex-auto:end -->'
$FallbackThreadName = 'Untitled thread'
$FallbackTitle = 'Candidate note'
$DefaultCategory = 'Workflow'
$CategoryOrder = @('Config', 'Issue', 'Workflow', 'Research')
$TitleMap = @{
    Config = 'Configuration candidates'
    Issue = 'Issue candidates'
    Workflow = 'Workflow candidates'
    Research = 'Research candidates'
}
$TrivialUserMessages = @('continue', 'ok', 'okay', 'yes', 'thanks', 'thank you', 'hi', 'hello')
$SkipSessionSources = @('guardian')
$SkipModelProviders = @('codex-auto-review')

$CategoryKeywords = [ordered]@{
    Config = [ordered]@{
        'config' = 3
        'base_url' = 4
        'api key' = 4
        'gateway' = 3
        'model' = 2
        'default' = 2
        'global' = 2
        'auth' = 3
        'provider' = 3
        'env' = 2
        'environment variable' = 3
        'agents.md' = 2
    }
    Issue = [ordered]@{
        'error' = 4
        'fail' = 3
        'cannot' = 3
        'unable' = 3
        'diagnose' = 3
        'debug' = 3
        'fix' = 4
        'recover' = 3
        '403' = 4
        '404' = 4
        '202' = 3
        '500' = 3
        'timeout' = 3
        'problem' = 2
        'bug' = 3
    }
    Workflow = [ordered]@{
        'workflow' = 4
        'steps' = 3
        'automation' = 3
        'script' = 3
        'template' = 2
        'daily' = 2
        'obsidian' = 3
        'codex' = 2
        'process' = 3
    }
    Research = [ordered]@{
        'research' = 3
        'knowledge base' = 4
        'paper' = 3
        'thesis' = 3
        'plan' = 2
        'compare' = 2
        'approach' = 2
        'wiki' = 3
    }
}

function Convert-JsonLine {
    param([string]$Line)

    try {
        return $Line | ConvertFrom-Json -Depth 100
    }
    catch {
        return $null
    }
}

function Get-ThreadNames {
    param([string]$IndexPath)

    $threadNames = @{}
    if (-not (Test-Path -LiteralPath $IndexPath -PathType Leaf)) {
        return $threadNames
    }

    foreach ($line in [System.IO.File]::ReadLines($IndexPath)) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }
        $payload = Convert-JsonLine -Line $line
        if (-not $payload -or -not $payload.id) {
            continue
        }

        $threadNames[[string]$payload.id] = if ($payload.thread_name) { [string]$payload.thread_name } else { $FallbackThreadName }
    }

    return $threadNames
}

function Get-SessionFiles {
    param(
        [string]$RootPath,
        [string]$TargetDate
    )

    try {
        $parsedDate = [datetime]::ParseExact($TargetDate, 'yyyy-MM-dd', $null)
    }
    catch {
        throw "Invalid -Date value '$TargetDate'. Expected YYYY-MM-DD."
    }

    $datedDir = Join-Path $RootPath ('{0:0000}\{1:00}\{2:00}' -f $parsedDate.Year, $parsedDate.Month, $parsedDate.Day)
    if (-not (Test-Path -LiteralPath $datedDir -PathType Container)) {
        return @()
    }

    return Get-ChildItem -LiteralPath $datedDir -Filter '*.jsonl' | Sort-Object FullName
}

function Get-FileLines {
    param([string]$Path)

    $fileStream = $null
    $streamReader = $null

    try {
        $fileStream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $streamReader = [System.IO.StreamReader]::new($fileStream, [System.Text.Encoding]::UTF8, $true)
        while (-not $streamReader.EndOfStream) {
            $line = $streamReader.ReadLine()
            if ($null -ne $line) {
                $line
            }
        }
    }
    catch [System.IO.IOException] {
        Write-Warning ("Skipping locked session file: {0}" -f $Path)
    }
    finally {
        if ($streamReader) {
            $streamReader.Dispose()
        }
        elseif ($fileStream) {
            $fileStream.Dispose()
        }
    }
}

function Sanitize-Text {
    param([AllowNull()][string]$Text)

    if ($null -eq $Text) {
        return ''
    }

    $value = [string]$Text
    $value = [regex]::Replace($value, 'sk-[A-Za-z0-9_-]{8,}', 'sk-***')
    $value = [regex]::Replace($value, 'Bearer\s+[A-Za-z0-9._-]{16,}', 'Bearer ***')
    $value = [regex]::Replace($value, 'https?://[^\s)]+', {
        param($match)
        if ($match.Value.Length -gt 80) { return $match.Value.Substring(0, 80) }
        return $match.Value
    })
    $value = [regex]::Replace($value, '\[([^\]]+)\]\([^)]+\)', '$1')
    $value = $value.Replace("`r", '')
    return $value.Trim()
}

function Get-CleanText {
    param([AllowNull()][string]$Text)

    $value = Sanitize-Text -Text $Text
    $value = [regex]::Replace($value, '```.*?```', ' ', [System.Text.RegularExpressions.RegexOptions]::Singleline)
    $value = [regex]::Replace($value, '`([^`]+)`', '$1')
    $value = [regex]::Replace($value, '\s+', ' ')
    return $value.Trim()
}

function Test-TrivialUserMessage {
    param([AllowNull()][string]$Text)

    $normalized = (Get-CleanText -Text $Text).ToLowerInvariant().Trim(' ', '.', ',', '!', '?')
    if ([string]::IsNullOrWhiteSpace($normalized)) {
        return $true
    }
    if ($TrivialUserMessages -contains $normalized) {
        return $true
    }
    if ($normalized.Length -le 2) {
        return $true
    }
    return [regex]::IsMatch($normalized, '^[\d.\s:-]+$')
}

function Get-SummaryText {
    param(
        [AllowNull()][string]$Text,
        [int]$Limit = 110
    )

    $cleaned = Sanitize-Text -Text $Text
    $paragraphs = [regex]::Split($cleaned, '\n\s*\n') | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    $preferred = ''

    foreach ($paragraph in $paragraphs) {
        $current = Get-CleanText -Text $paragraph
        if ($current.Length -ge 20 -and -not $current.Contains('if you want')) {
            $preferred = $current
            break
        }
    }

    if (-not $preferred) {
        $preferred = Get-CleanText -Text $cleaned
    }

    if ($preferred.Length -gt $Limit) {
        return $preferred.Substring(0, $Limit).TrimEnd() + '...'
    }
    return $preferred
}

function Get-DisplayTitle {
    param(
        [AllowNull()][string]$UserText,
        [AllowNull()][string]$AgentText,
        [AllowNull()][string]$ThreadName
    )

    foreach ($rawLine in ([string]$UserText -split "`n")) {
        $line = (Get-CleanText -Text $rawLine).TrimStart('-', '*', '1', '2', '3', '4', '5', '6', '7', '8', '9', '0', '.', ' ')
        $line = [regex]::Replace($line, 'https?://\S+', '').Trim()
        if ([string]::IsNullOrWhiteSpace($line) -or $line.Length -lt 4) {
            continue
        }
        if ($line.StartsWith('# Files mentioned by the user')) {
            continue
        }
        if ($line.ToLowerInvariant().StartsWith('sk-')) {
            continue
        }
        if ([regex]::IsMatch($line, '^[A-Z]:\\')) {
            continue
        }
        if ([regex]::IsMatch($line, '^[A-Za-z0-9._-]+$')) {
            continue
        }
        if ($line.Length -gt 36) {
            return $line.Substring(0, 36).TrimEnd() + '...'
        }
        return $line
    }

    $summary = Get-SummaryText -Text $AgentText -Limit 36
    if ($summary) {
        return $summary
    }

    $thread = Get-CleanText -Text $ThreadName
    if ($thread) {
        if ($thread.Length -gt 36) {
            return $thread.Substring(0, 36)
        }
        return $thread
    }

    return $FallbackTitle
}

function Get-CategoryInfo {
    param([string]$Text)

    $lowered = $Text.ToLowerInvariant()
    $bestCategory = $DefaultCategory
    $bestScore = 0

    foreach ($category in $CategoryKeywords.Keys) {
        $score = 0
        foreach ($keyword in $CategoryKeywords[$category].Keys) {
            if ($lowered.Contains($keyword.ToLowerInvariant())) {
                $score += [int]$CategoryKeywords[$category][$keyword]
            }
        }
        if ($score -gt $bestScore) {
            $bestCategory = $category
            $bestScore = $score
        }
    }

    return @{
        Category = $bestCategory
        Score = $bestScore
    }
}

function Get-ExchangeScore {
    param(
        [AllowNull()][string]$UserText,
        [AllowNull()][string]$AgentText
    )

    $combined = (Get-CleanText -Text ($UserText + "`n" + $AgentText)).ToLowerInvariant()
    $agentLength = (Get-CleanText -Text $AgentText).Length
    $score = 0

    if ($agentLength -ge 80) { $score += 3 }
    if ($agentLength -ge 180) { $score += 2 }
    if (($AgentText -like '*```*') -or ($AgentText -like '*`*')) { $score += 2 }
    if ([regex]::IsMatch([string]$AgentText, '[A-Z]:\\')) { $score += 2 }

    foreach ($token in @('config', 'fix', 'workflow', 'install', 'issue', 'knowledge base', 'gateway', 'model', 'script', 'obsidian', 'codex')) {
        if ($combined.Contains($token)) {
            $score += 3
            break
        }
    }

    if ([regex]::IsMatch($combined, '\b(403|404|202|500)\b')) { $score += 2 }
    if (Test-TrivialUserMessage -Text $UserText) { $score -= 3 }
    if ((Get-CleanText -Text $UserText).Length -le 6) { $score -= 1 }

    return $score
}

function Convert-ToLocalTimeText {
    param([AllowNull()][string]$Timestamp)

    if ([string]::IsNullOrWhiteSpace($Timestamp)) {
        return '00:00'
    }

    try {
        return ([datetimeoffset]::Parse($Timestamp).ToLocalTime()).ToString('HH:mm')
    }
    catch {
        return '00:00'
    }
}

function Test-SkippableSessionMeta {
    param($Payload)

    if (-not $Payload) {
        return $false
    }

    $sourceOther = ''
    $provider = ''

    if ($Payload.source -and $Payload.source.subagent -and $Payload.source.subagent.other) {
        $sourceOther = [string]$Payload.source.subagent.other
    }
    if ($Payload.model_provider) {
        $provider = [string]$Payload.model_provider
    }

    if ($sourceOther -and ($SkipSessionSources -contains $sourceOther)) {
        return $true
    }
    if ($provider -and ($SkipModelProviders -contains $provider)) {
        return $true
    }
    return $false
}

function Get-ExchangeObjects {
    param(
        [string]$SessionFile,
        [hashtable]$ThreadNames,
        [int]$MinimumScore
    )

    $sessionId = ''
    $threadName = $FallbackThreadName
    $sessionTopic = ''
    $currentTurnId = ''
    $pending = @{}
    $exchanges = New-Object System.Collections.Generic.List[object]
    $skipSession = $false

    foreach ($line in (Get-FileLines -Path $SessionFile)) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }

        $record = Convert-JsonLine -Line $line
        if (-not $record) {
            continue
        }

        $recordType = [string]$record.type
        if ($recordType -eq 'session_meta') {
            $sessionId = [string]$record.payload.id
            if ($sessionId -and $ThreadNames.ContainsKey($sessionId)) {
                $threadName = [string]$ThreadNames[$sessionId]
            }
            $skipSession = Test-SkippableSessionMeta -Payload $record.payload
            continue
        }

        if ($skipSession) {
            continue
        }

        if ($recordType -eq 'turn_context') {
            $currentTurnId = [string]$record.payload.turn_id
            if ($currentTurnId -and -not $pending.ContainsKey($currentTurnId)) {
                $pending[$currentTurnId] = @{}
            }
            continue
        }

        if ($recordType -ne 'event_msg') {
            continue
        }

        $payload = $record.payload
        $eventType = [string]$payload.type

        if ($eventType -eq 'user_message') {
            if ($currentTurnId) {
                if (-not $pending.ContainsKey($currentTurnId)) {
                    $pending[$currentTurnId] = @{}
                }
                $pending[$currentTurnId]['user_text'] = [string]$payload.message
                if (-not $sessionTopic -and -not (Test-TrivialUserMessage -Text $pending[$currentTurnId]['user_text'])) {
                    $sessionTopic = Get-DisplayTitle -UserText $pending[$currentTurnId]['user_text'] -AgentText '' -ThreadName ''
                }
            }
            continue
        }

        if ($eventType -ne 'task_complete') {
            continue
        }

        $turnId = [string]$payload.turn_id
        if (-not $turnId -or -not $pending.ContainsKey($turnId)) {
            continue
        }

        $entry = $pending[$turnId]
        $userText = if ($entry.ContainsKey('user_text')) { [string]$entry['user_text'] } else { '' }
        $agentText = if ($payload.last_agent_message) { [string]$payload.last_agent_message } else { '' }
        if (-not $userText -or -not $agentText) {
            continue
        }

        $score = Get-ExchangeScore -UserText $userText -AgentText $agentText
        $categoryInfo = Get-CategoryInfo -Text ($userText + "`n" + $agentText)
        $totalScore = $score + [int]$categoryInfo.Score
        if ($totalScore -lt $MinimumScore) {
            continue
        }

        $displayThreadName = $threadName
        if ($displayThreadName -eq $FallbackThreadName -and $sessionTopic) {
            $displayThreadName = $sessionTopic
        }

        $exchanges.Add([pscustomobject]@{
            SessionId = if ($sessionId) { $sessionId } else { [System.IO.Path]::GetFileNameWithoutExtension($SessionFile) }
            ThreadName = $displayThreadName
            TurnId = $turnId
            TimestampUtc = [string]$record.timestamp
            LocalTime = Convert-ToLocalTimeText -Timestamp ([string]$record.timestamp)
            UserText = Sanitize-Text -Text $userText
            AgentText = Sanitize-Text -Text $agentText
            Score = $totalScore
            Category = [string]$categoryInfo.Category
            Title = Get-DisplayTitle -UserText $userText -AgentText $agentText -ThreadName $threadName
            Summary = Get-SummaryText -Text $agentText
        })
    }

    return $exchanges
}

function Ensure-DailyNote {
    param(
        [string]$NotePath,
        [string]$TargetDate
    )

    if (Test-Path -LiteralPath $NotePath -PathType Leaf) {
        return
    }

    $content = @(
        "# $TargetDate - Pending",
        '',
        '## Worth keeping today',
        '',
        '- ',
        '',
        '## Move to config center',
        '',
        '- ',
        '',
        '## Move to issue fixes',
        '',
        '- ',
        '',
        '## Move to workflows',
        '',
        '- ',
        '',
        '## Move to research topics',
        '',
        '- ',
        ''
    ) -join "`n"

    $parent = Split-Path -Parent $NotePath
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    [System.IO.File]::WriteAllText($NotePath, $content, [System.Text.UTF8Encoding]::new($false))
}

function Get-DailyNotesDirectory {
    param([string]$VaultPath)

    $inboxDir = Get-ChildItem -LiteralPath $VaultPath -Directory |
        Where-Object { $_.Name -like '00-*' } |
        ForEach-Object {
            [pscustomobject]@{
                Directory = $_
                NoteCount = @(
                    Get-ChildItem -LiteralPath $_.FullName -Recurse -Filter '20??-??-?? - *.md' -ErrorAction SilentlyContinue
                ).Count
            }
        } |
        Sort-Object @{ Expression = 'NoteCount'; Descending = $true }, @{ Expression = { $_.Directory.Name } } |
        Select-Object -First 1

    if (-not $inboxDir) {
        throw "Could not find inbox directory under '$VaultPath'."
    }

    $inboxPath = $inboxDir.Directory.FullName
    $dailyDir = Get-ChildItem -LiteralPath $inboxPath -Directory |
        Where-Object {
            $_.Name -like '*record*' -or
            (Get-ChildItem -LiteralPath $_.FullName -Filter '20??-??-?? - *.md' -ErrorAction SilentlyContinue | Select-Object -First 1)
        } |
        ForEach-Object {
            [pscustomobject]@{
                Directory = $_
                NoteCount = @(
                    Get-ChildItem -LiteralPath $_.FullName -Filter '20??-??-?? - *.md' -ErrorAction SilentlyContinue
                ).Count
            }
        } |
        Sort-Object @{ Expression = 'NoteCount'; Descending = $true }, @{ Expression = { $_.Directory.Name } } |
        ForEach-Object { $_.Directory } |
        Select-Object -First 1

    if (-not $dailyDir) {
        $dailyDir = Join-Path $inboxPath 'DailyRecords'
    }
    else {
        $dailyDir = $dailyDir.FullName
    }

    return $dailyDir
}

function Get-DailyNotePath {
    param(
        [string]$DailyNotesDirectory,
        [string]$TargetDate
    )

    $existing = Get-ChildItem -LiteralPath $DailyNotesDirectory -Filter ($TargetDate + ' - *.md') -ErrorAction SilentlyContinue |
        Sort-Object Name |
        Select-Object -First 1

    if ($existing) {
        return $existing.FullName
    }

    $template = Get-ChildItem -LiteralPath $DailyNotesDirectory -Filter '20??-??-?? - *.md' -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending |
        Select-Object -First 1

    if ($template) {
        $suffix = $template.Name.Substring(10)
        return (Join-Path $DailyNotesDirectory ($TargetDate + $suffix))
    }

    return (Join-Path $DailyNotesDirectory ($TargetDate + ' - Pending.md'))
}

function Build-AutoSection {
    param([object[]]$Exchanges)

    $generatedAt = Get-Date -Format 'yyyy-MM-dd HH:mm'
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add($AutoSectionStart)
    $lines.Add('## Auto candidates')
    $lines.Add('')
    $lines.Add("_Updated: ${generatedAt}_")
    $lines.Add('_This section is overwritten by the script on each run._')
    $lines.Add('')

    if (-not $Exchanges -or $Exchanges.Count -eq 0) {
        $lines.Add('- No candidates cleared the score threshold today.')
        $lines.Add('')
        $lines.Add($AutoSectionEnd)
        return ($lines -join "`n")
    }

    foreach ($category in $CategoryOrder) {
        $items = $Exchanges | Where-Object { $_.Category -eq $category }
        if (-not $items) {
            continue
        }
        $lines.Add("### $($TitleMap[$category])")
        $lines.Add('')
        foreach ($item in $items) {
            $threadName = Get-CleanText -Text $item.ThreadName
            $lines.Add("- ``$($item.LocalTime)`` $($item.Title): $($item.Summary) Thread: $threadName.")
        }
        $lines.Add('')
    }

    $lines.Add($AutoSectionEnd)
    return ($lines -join "`n")
}

function Upsert-AutoSection {
    param(
        [string]$NotePath,
        [string]$AutoSection
    )

    $content = [System.IO.File]::ReadAllText($NotePath, [System.Text.Encoding]::UTF8)
    $pattern = [regex]::Escape($AutoSectionStart) + '.*?' + [regex]::Escape($AutoSectionEnd)

    if ([regex]::IsMatch($content, $pattern, [System.Text.RegularExpressions.RegexOptions]::Singleline)) {
        $updated = [regex]::Replace(
            $content,
            $pattern,
            [System.Text.RegularExpressions.MatchEvaluator]{ param($match) $AutoSection },
            [System.Text.RegularExpressions.RegexOptions]::Singleline
        )
    }
    else {
        $updated = $content.TrimEnd() + "`n`n" + $AutoSection + "`n"
    }

    [System.IO.File]::WriteAllText($NotePath, $updated, [System.Text.UTF8Encoding]::new($false))
}

$threadNames = Get-ThreadNames -IndexPath $SessionIndex
$allExchanges = New-Object System.Collections.Generic.List[object]

foreach ($sessionFile in (Get-SessionFiles -RootPath $SessionsRoot -TargetDate $Date)) {
    foreach ($exchange in (Get-ExchangeObjects -SessionFile $sessionFile.FullName -ThreadNames $threadNames -MinimumScore $MinScore)) {
        $allExchanges.Add($exchange)
    }
}

$selectedExchanges = @(
    $allExchanges |
        Sort-Object @{ Expression = 'Score'; Descending = $true }, @{ Expression = 'LocalTime'; Descending = $true } |
        Select-Object -First $MaxItems
)

$autoSection = Build-AutoSection -Exchanges $selectedExchanges
if ($DryRun) {
    Write-Output $autoSection
    return
}

$dailyNotesDirectory = Get-DailyNotesDirectory -VaultPath $VaultRoot
$notePath = Get-DailyNotePath -DailyNotesDirectory $dailyNotesDirectory -TargetDate $Date
Ensure-DailyNote -NotePath $notePath -TargetDate $Date
Upsert-AutoSection -NotePath $notePath -AutoSection $autoSection
Write-Output ('Wrote {0} candidate items to: {1}' -f $selectedExchanges.Count, $notePath)
