param(
  [Parameter(Mandatory = $true)]
  [string]$Edl,

  [Parameter(Mandatory = $true)]
  [string]$OutDir,

  [string]$GsapPath,

  [string]$CacheDir,

  [double]$ClipPreloadSec = 0.08,

  [switch]$NoCache,

  [switch]$PreserveTrackIndex,

  [switch]$Force
)

$ErrorActionPreference = "Stop"

function Escape-Html([string]$Text) {
  if ($null -eq $Text) { return "" }
  return $Text.Replace("&", "&amp;").Replace("<", "&lt;").Replace(">", "&gt;").Replace('"', "&quot;")
}

function To-JsonLiteral($Value) {
  if ($null -eq $Value) { return "[]" }
  if ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [string])) {
    $items = New-Object System.Collections.Generic.List[object]
    foreach ($item in $Value) { $items.Add($item) }
    return (ConvertTo-Json -InputObject $items.ToArray() -Compress)
  }
  return ($Value | ConvertTo-Json -Compress)
}

function Get-CacheKey([string]$Text) {
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    return (($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString("x2") }) -join "")
  } finally {
    $sha.Dispose()
  }
}

if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) {
  throw "ffmpeg was not found on PATH."
}

$validator = Join-Path $PSScriptRoot "Validate-Edl.ps1"
if (Test-Path -LiteralPath $validator) {
  & $validator -Edl $Edl
}

$edlPath = Resolve-Path -LiteralPath $Edl
$config = Get-Content -LiteralPath $edlPath -Raw | ConvertFrom-Json
$project = $config.project
$audio = if ($config.audio) { $config.audio } elseif ($config.music) { $config.music } else { $null }
$shots = @($config.shots)

if ($shots.Count -eq 0) {
  throw "EDL has no shots."
}

if ((Test-Path -LiteralPath $OutDir) -and -not $Force) {
  throw "OutDir already exists. Use -Force to overwrite generated files: $OutDir"
}

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $OutDir "media") | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $OutDir "renders") | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $OutDir "snapshots") | Out-Null
if (-not $CacheDir) {
  $CacheDir = Join-Path (Split-Path -Parent $OutDir) ".shot-cache"
}
if (-not $NoCache) {
  New-Item -ItemType Directory -Force -Path $CacheDir | Out-Null
}

$width = [int]$project.width
$height = [int]$project.height
$fps = [int]$project.fps
$duration = [double]$project.duration
$audioOut = Join-Path $OutDir "media\music.mp3"
$audioStart = [double]$audio.start
$audioDuration = [double]$audio.duration
$audioVolume = if ($audio.volume -ne $null) { [double]$audio.volume } else { 1.0 }
$fadeIn = if ($audio.fadeIn -ne $null) { [double]$audio.fadeIn } else { 0.2 }
$fadeOut = if ($audio.fadeOut -ne $null) { [double]$audio.fadeOut } else { 0.8 }
$fadeOutStart = [Math]::Max(0, $audioDuration - $fadeOut)

ffmpeg -hide_banner -y -ss $audioStart -t $audioDuration -i $audio.path -vn `
  -af "volume=${audioVolume},afade=t=in:st=0:d=${fadeIn},afade=t=out:st=${fadeOutStart}:d=${fadeOut}" `
  -c:a libmp3lame -b:a 192k $audioOut
if ($LASTEXITCODE -ne 0) { throw "Audio extraction failed." }

$videoTags = New-Object System.Collections.Generic.List[string]
$cutTimes = New-Object System.Collections.Generic.List[double]

for ($i = 0; $i -lt $shots.Count; $i++) {
  $shot = $shots[$i]
  $id = if ($shot.id) { [string]$shot.id } else { "shot-{0:D2}" -f ($i + 1) }
  $shotFile = "shot-{0:D2}.mp4" -f ($i + 1)
  $shotOut = Join-Path $OutDir ("media\" + $shotFile)
  $srcStart = [double]$shot.sourceStart
  $shotDuration = [double]$shot.duration
  $timelineStart = [double]$shot.timelineStart
  $preload = if ($i -gt 0) { [Math]::Min($ClipPreloadSec, [Math]::Max(0, $srcStart)) } else { 0 }
  $extractStart = [Math]::Max(0, $srcStart - $preload)
  $extractDuration = $shotDuration + $preload + 0.05
  $clipStart = [Math]::Max(0, $timelineStart - $preload)
  $clipDuration = $shotDuration + $preload
  $trackIndex = if ($PreserveTrackIndex -and $shot.trackIndex -ne $null) { [int]$shot.trackIndex } else { $i % 2 }

  $vf = "scale=${width}:${height}:force_original_aspect_ratio=increase,crop=${width}:${height},format=yuv420p,fps=$fps"
  $cacheKey = Get-CacheKey ("beat|{0}|{1:F3}|{2:F3}|{3}|{4}|{5}|crf20|{6}" -f [string]$shot.source, $extractStart, $extractDuration, $width, $height, $fps, $vf)
  $cacheFile = if ($NoCache) { $null } else { Join-Path $CacheDir ($cacheKey + ".mp4") }
  if ($cacheFile -and (Test-Path -LiteralPath $cacheFile -PathType Leaf)) {
    Copy-Item -LiteralPath $cacheFile -Destination $shotOut -Force
  } else {
    ffmpeg -hide_banner -y -ss $extractStart -t $extractDuration -i $shot.source -an `
      -vf $vf -c:v libx264 -preset veryfast -crf 20 -g $fps -keyint_min $fps -sc_threshold 0 -movflags +faststart $shotOut
    if ($LASTEXITCODE -ne 0) { throw "Shot extraction failed: $id" }
    if ($cacheFile) {
      Copy-Item -LiteralPath $shotOut -Destination $cacheFile -Force
    }
  }

  if ($timelineStart -gt 0) { $cutTimes.Add($timelineStart) }
  $videoTags.Add("      <video id=""$id"" class=""clip video-shot"" data-start=""$clipStart"" data-visible-start=""$timelineStart"" data-duration=""$clipDuration"" data-visible-duration=""$shotDuration"" data-track-index=""$trackIndex"" src=""./media/$shotFile"" muted playsinline preload=""auto""></video>")
}

$templatePath = Join-Path $PSScriptRoot "..\templates\hyperframes\index.template.html"
$template = Get-Content -LiteralPath $templatePath -Raw
$flashColors = if ($config.style.flashColors) { @($config.style.flashColors) } else { @("#f7f0cf", "#93ffd4", "#fff0b4", "#ffd28b") }

$html = $template `
  -replace "{{WIDTH}}", [string]$width `
  -replace "{{HEIGHT}}", [string]$height `
  -replace "{{DURATION}}", [string]$duration `
  -replace "{{VIDEO_CLIPS}}", ($videoTags -join "`n") `
  -replace "{{KICKER}}", (Escape-Html $project.kicker) `
  -replace "{{TITLE}}", (Escape-Html $project.title) `
  -replace "{{CUT_TIMES}}", (To-JsonLiteral $cutTimes) `
  -replace "{{FLASH_COLORS}}", (To-JsonLiteral $flashColors) `
  -replace "{{FINAL_VIGNETTE_START}}", ([string]([Math]::Max(0, $duration - 3.3))) `
  -replace "{{FINAL_TITLE_START}}", ([string]([Math]::Max(0, $duration - 3.6))) `
  -replace "{{FINAL_TITLE_END}}", ([string]([Math]::Max(0, $duration - 0.92)))

Set-Content -LiteralPath (Join-Path $OutDir "index.html") -Value $html -Encoding utf8

$resolvedGsap = $GsapPath
if (-not $resolvedGsap -and $config.assets.gsap) {
  $resolvedGsap = [string]$config.assets.gsap
}
if ($resolvedGsap -and (Test-Path -LiteralPath $resolvedGsap)) {
  Copy-Item -LiteralPath $resolvedGsap -Destination (Join-Path $OutDir "gsap.min.js") -Force
} else {
  Write-Warning "No local gsap.min.js was copied. Provide -GsapPath or set assets.gsap in the EDL before rendering."
}

Copy-Item -LiteralPath $edlPath -Destination (Join-Path $OutDir "edl.json") -Force
Write-Host "Created video mix project: $OutDir"
