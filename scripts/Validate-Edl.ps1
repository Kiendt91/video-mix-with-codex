param(
  [Parameter(Mandatory = $true)]
  [string]$Edl
)

$ErrorActionPreference = "Stop"

function Test-Number($Value, [string]$Name, [switch]$AllowZero) {
  if ($null -eq $Value) { throw "$Name is required." }
  $number = [double]$Value
  if ($AllowZero) {
    if ($number -lt 0) { throw "$Name must be >= 0." }
  } elseif ($number -le 0) {
    throw "$Name must be > 0."
  }
  return $number
}

function Test-ReadableFile([string]$Path, [string]$Name) {
  if ([string]::IsNullOrWhiteSpace($Path)) { throw "$Name is required." }
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    throw "$Name does not exist: $Path"
  }
}

$edlPath = Resolve-Path -LiteralPath $Edl
$config = Get-Content -LiteralPath $edlPath -Raw | ConvertFrom-Json

if (-not $config.project) { throw "project is required." }
$audioConfig = if ($config.music) { $config.music } elseif ($config.audio) { $config.audio } else { $null }
if (-not $audioConfig) { throw "music or audio is required." }

$duration = Test-Number $config.project.duration "project.duration"
$width = Test-Number $config.project.width "project.width"
$height = Test-Number $config.project.height "project.height"
$fps = Test-Number $config.project.fps "project.fps"

if ($width -lt 16 -or $height -lt 16) { throw "project dimensions are too small." }
if ($fps -lt 1 -or $fps -gt 120) { throw "project.fps should be between 1 and 120." }

Test-ReadableFile ([string]$audioConfig.path) "music/audio.path"
$musicDuration = Test-Number $audioConfig.duration "music/audio.duration"
$musicStart = Test-Number $audioConfig.start "music/audio.start" -AllowZero
if ($musicStart + $musicDuration -lt $duration - 0.25) {
  Write-Warning "music range is shorter than project.duration by more than 0.25s."
}

$shots = @($config.shots) | Where-Object { $null -ne $_ }
if ($shots.Count -eq 0) { throw "shots must contain at least one shot." }

$ids = @{}
foreach ($shot in $shots) {
  $id = [string]$shot.id
  if ([string]::IsNullOrWhiteSpace($id)) { throw "Every shot must have an id." }
  if ($ids.ContainsKey($id)) { throw "Duplicate shot id: $id" }
  $ids[$id] = $true

  Test-ReadableFile ([string]$shot.source) "shot.source for $id"
  $sourceStart = Test-Number $shot.sourceStart "shot.sourceStart for $id" -AllowZero
  $shotDuration = Test-Number $shot.duration "shot.duration for $id"
  $timelineStart = Test-Number $shot.timelineStart "shot.timelineStart for $id" -AllowZero
  $trackIndex = if ($shot.trackIndex -ne $null) { $shot.trackIndex } else { 0 }
  [void](Test-Number $trackIndex "shot.trackIndex for $id" -AllowZero)

  if ($timelineStart + $shotDuration -gt $duration + 0.1) {
    throw "Shot $id ends after project.duration."
  }
  if ($sourceStart -lt 0) {
    throw "Shot $id has negative sourceStart."
  }
}

$dialogue = @($config.dialogue) | Where-Object { $null -ne $_ }
$dialogueIds = @{}
foreach ($line in $dialogue) {
  $id = [string]$line.id
  if ([string]::IsNullOrWhiteSpace($id)) { throw "Every dialogue line must have an id." }
  if ($dialogueIds.ContainsKey($id)) { throw "Duplicate dialogue id: $id" }
  $dialogueIds[$id] = $true

  Test-ReadableFile ([string]$line.source) "dialogue.source for $id"
  $lineDuration = Test-Number $line.duration "dialogue.duration for $id"
  $timelineStart = Test-Number $line.timelineStart "dialogue.timelineStart for $id" -AllowZero
  [void](Test-Number $line.sourceStart "dialogue.sourceStart for $id" -AllowZero)

  if ($timelineStart + $lineDuration -gt $duration + 0.1) {
    throw "Dialogue $id ends after project.duration."
  }
}

$captions = @($config.captions) | Where-Object { $null -ne $_ }
foreach ($caption in $captions) {
  $id = if ($caption.id) { [string]$caption.id } else { "(caption)" }
  $captionDuration = Test-Number $caption.duration "caption.duration for $id"
  $captionStart = if ($caption.timelineStart -ne $null) { $caption.timelineStart } else { $caption.start }
  $captionStart = Test-Number $captionStart "caption.timelineStart/start for $id" -AllowZero
  if ($captionStart + $captionDuration -gt $duration + 0.1) {
    throw "Caption $id ends after project.duration."
  }
}

[pscustomobject]@{
  Edl = $edlPath.Path
  Duration = $duration
  Shots = $shots.Count
  Dialogue = $dialogue.Count
  Captions = $captions.Count
  Width = $width
  Height = $height
  Fps = $fps
} | Format-List

Write-Host "EDL validation passed."
