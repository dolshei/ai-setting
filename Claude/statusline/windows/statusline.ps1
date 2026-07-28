$input_json = $input | Out-String | ConvertFrom-Json

$parts = New-Object System.Collections.Generic.List[string]

# [char]27 rather than `e so this also runs under Windows PowerShell 5.1.
# Always reference as ${esc} in strings: "$esc[..." would be parsed as an index.
$esc = [char]27
$reset = "${esc}[0m"

# Icon glyphs are built from their code points rather than pasted literally, so
# they survive regardless of how this file is saved (Windows PowerShell reads
# BOM-less files as the ANSI codepage). stdout must be UTF-8 too, or the emoji
# is transcoded to "?" on its way out.
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
$clock = [char]::ConvertFromUtf32(0x1F550)      # U+1F550 CLOCK FACE ONE OCLOCK
$branchIcon = [char]::ConvertFromUtf32(0x1F33F) # U+1F33F HERB (git branch)

function Format-Duration {
    param([double]$TotalSeconds)
    if ($TotalSeconds -lt 0) { $TotalSeconds = 0 }
    $totalMinutes = [math]::Floor($TotalSeconds / 60)
    $days = [math]::Floor($totalMinutes / 1440)
    $hours = [math]::Floor(($totalMinutes % 1440) / 60)
    $minutes = $totalMinutes % 60

    # Drop leading zero-valued units: "35m" instead of "0h 35m", "1h 30m"
    # instead of "0d 1h 30m". A zero unit is kept once a larger one is shown
    # (e.g. "1d 0h 5m") so the value never reads ambiguously.
    $segments = New-Object System.Collections.Generic.List[string]
    if ($days -gt 0) { $segments.Add("${days}d") }
    if ($days -gt 0 -or $hours -gt 0) { $segments.Add("${hours}h") }
    $segments.Add("${minutes}m")
    return [string]::Join(" ", $segments)
}

# Every percentage on the line shares one severity ramp, keyed on how much has
# been consumed. Thresholds are applied to the rounded value so the colour
# always matches the number actually printed (89.6 shows as 90%, red).
function Get-UsageColor {
    param([double]$Used)
    if ($Used -ge 90)     { return '38;5;196' }  # red
    elseif ($Used -ge 80) { return '38;5;208' }  # orange
    elseif ($Used -ge 60) { return '38;5;220' }  # yellow
    else                  { return '38;5;77'  }  # green
}

function Format-Usage {
    param([double]$Percent)
    $rounded = [math]::Round($Percent)
    return "${esc}[$(Get-UsageColor -Used $rounded)m${rounded}%${reset}"
}

# Remaining runs the other way, so it is coloured by its complement rather than
# by its own value -- 41% left is green, 10% left is red. Deriving the colour
# from (100 - remaining) keeps it an exact mirror of Format-Usage instead of a
# second threshold table that could drift out of sync.
function Format-Remaining {
    param([double]$Percent)
    $rounded = [math]::Round($Percent)
    return "${esc}[$(Get-UsageColor -Used (100 - $rounded))m${rounded}%${reset}"
}

# 1. Model name, colored per family. Matching is on the family substring rather
#    than the full name so it keeps working across version bumps ("Opus 5",
#    "Opus 4.1", ...). 256-color codes keep these hues distinct from the
#    effort ramp below, which sits right next to it on the line.
$modelColors = @(
    @{ Pattern = 'opus';   Code = '38;5;208' }  # orange
    @{ Pattern = 'sonnet'; Code = '38;5;75'  }  # blue
    @{ Pattern = 'haiku';  Code = '38;5;114' }  # green
    @{ Pattern = 'fable';  Code = '38;5;176' }  # purple
)
$modelName = [string]$input_json.model.display_name
if ($modelName) {
    $haystack = "$modelName $($input_json.model.id)".ToLower()
    $code = ($modelColors | Where-Object { $haystack -like "*$($_.Pattern)*" } | Select-Object -First 1).Code
    if ($code) {
        $parts.Add("${esc}[${code}m${modelName}${reset}")
    } else {
        $parts.Add($modelName)
    }
}

# 2. Current reasoning/thinking level
#    "effort.level" (low/medium/high/xhigh/max) is only present for models
#    that support a reasoning-effort setting; fall back to thinking.enabled
#    when effort isn't available. Shown bare (no label), colored on a
#    cool-to-hot ramp so the active level is recognizable at a glance.
$effortColors = @{
    'low'    = '32'  # green
    'medium' = '36'  # cyan
    'high'   = '33'  # yellow
    'xhigh'  = '95'  # bright magenta
    'max'    = '91'  # bright red
}
if ($input_json.effort.level) {
    $level = [string]$input_json.effort.level
    $code = $effortColors[$level.ToLower()]
    if ($code) {
        $parts.Add("${esc}[${code}m${level}${reset}")
    } else {
        $parts.Add($level)
    }
} elseif ($input_json.thinking.enabled) {
    $parts.Add("thinking: on")
}

# 3. Current working directory -- read here because the git lookup below needs
#    it, but appended at the end of the line (see below).
$cwd = $input_json.cwd

# 4. Git branch
#    The statusline JSON schema has no generic "current git branch" field,
#    so it is resolved by calling git directly (optional locks skipped).
if ($cwd) {
    try {
        $branch = git --no-optional-locks -C "$cwd" branch --show-current 2>$null
        if ($LASTEXITCODE -eq 0 -and $branch) {
            $parts.Add("$branchIcon $($branch.Trim())")
        }
    } catch {}
}

# 5. Elapsed time since session start, e.g. "1h 30m" / "1d 2h 32m"
#    The statusline JSON has no "session start time" field either, so this
#    is derived from the earliest "timestamp" entry in the session
#    transcript file (transcript_path).
$transcriptPath = $input_json.transcript_path
if ($transcriptPath -and (Test-Path -LiteralPath $transcriptPath)) {
    try {
        $startTime = $null
        Get-Content -LiteralPath $transcriptPath -TotalCount 20 | ForEach-Object {
            if (-not $startTime) {
                try {
                    $entry = $_ | ConvertFrom-Json
                    if ($entry.timestamp) {
                        $startTime = [DateTimeOffset]::Parse($entry.timestamp)
                    }
                } catch {}
            }
        }
        if ($startTime) {
            $elapsedSeconds = ([DateTimeOffset]::UtcNow - $startTime.ToUniversalTime()).TotalSeconds
            $parts.Add("$clock $(Format-Duration -TotalSeconds $elapsedSeconds)")
        }
    } catch {}
}

# 6. Pre-computed used percentage of the context window
$usedPct = $input_json.context_window.used_percentage
if ($null -ne $usedPct) {
    $parts.Add("ctx used: $(Format-Usage -Percent $usedPct)")
}

# 7. Pre-computed remaining percentage of the context window
$remainingPct = $input_json.context_window.remaining_percentage
if ($null -ne $remainingPct) {
    $parts.Add("ctx left: $(Format-Remaining -Percent $remainingPct)")
}

# 3 (continued). The working directory is the longest and most variable field,
# so it trails the fixed-width ones to keep the line's left side stable.
if ($cwd) {
    $parts.Add($cwd)
}

# 8 & 9. Rate limit usage and time to reset, rendered on their own second
#    line. Both windows are shown, 5-hour first then 7-day; either may be
#    absent from the payload, in which case it is simply skipped.
$rateParts = New-Object System.Collections.Generic.List[string]
$windows = @(
    @{ Label = "5h"; Data = $input_json.rate_limits.five_hour },
    @{ Label = "7d"; Data = $input_json.rate_limits.seven_day }
)
foreach ($window in $windows) {
    $data = $window.Data
    if (-not $data) { continue }
    $label = $window.Label
    if ($null -ne $data.used_percentage) {
        $rateParts.Add("$label used: $(Format-Usage -Percent $data.used_percentage)")
    }
    if ($data.resets_at) {
        $resetsAt = [DateTimeOffset]::FromUnixTimeSeconds([int64]$data.resets_at)
        $remainingSeconds = ($resetsAt - [DateTimeOffset]::UtcNow).TotalSeconds
        if ($remainingSeconds -gt 0) {
            $rateParts.Add("$label reset: $(Format-Duration -TotalSeconds $remainingSeconds)")
        }
    }
}

# Rate limits go on line 2. When they're absent (non-subscriber, or before the
# first API response) only line 1 is emitted -- no trailing blank line.
$lines = New-Object System.Collections.Generic.List[string]
if ($parts.Count -gt 0) { $lines.Add([string]::Join(" | ", $parts)) }
if ($rateParts.Count -gt 0) { $lines.Add([string]::Join(" | ", $rateParts)) }

Write-Host ([string]::Join("`n", $lines))