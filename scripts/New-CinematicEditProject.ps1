param(
  [Parameter(Mandatory = $true)]
  [string]$Edl,

  [Parameter(Mandatory = $true)]
  [string]$OutDir,

  [string]$GsapPath,

  [switch]$Force
)

$ErrorActionPreference = "Stop"

function Escape-Html([string]$Text) {
  if ($null -eq $Text) { return "" }
  return $Text.Replace("&", "&amp;").Replace("<", "&lt;").Replace(">", "&gt;").Replace('"', "&quot;")
}

if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) {
  throw "ffmpeg was not found on PATH."
}

$edlPath = Resolve-Path -LiteralPath $Edl
$config = Get-Content -LiteralPath $edlPath -Raw | ConvertFrom-Json
$project = $config.project
$music = $config.music
$shots = @($config.shots)
$dialogue = @($config.dialogue) | Where-Object { $null -ne $_ }
$captions = @($config.captions) | Where-Object { $null -ne $_ }

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

$width = [int]$project.width
$height = [int]$project.height
$fps = [int]$project.fps
$duration = [double]$project.duration
$musicVolume = if ($music.volume -ne $null) { [double]$music.volume } else { 0.42 }
$musicStart = [double]$music.start
$musicDuration = [double]$music.duration
$musicFadeIn = if ($music.fadeIn -ne $null) { [double]$music.fadeIn } else { 1.0 }
$musicFadeOut = if ($music.fadeOut -ne $null) { [double]$music.fadeOut } else { 2.0 }
$musicFadeOutStart = [Math]::Max(0, $musicDuration - $musicFadeOut)
$musicOut = Join-Path $OutDir "media\music.m4a"

ffmpeg -hide_banner -y -ss $musicStart -t $musicDuration -i $music.path -vn `
  -af "volume=${musicVolume},afade=t=in:st=0:d=${musicFadeIn},afade=t=out:st=${musicFadeOutStart}:d=${musicFadeOut}" `
  -c:a aac -b:a 192k $musicOut
if ($LASTEXITCODE -ne 0) { throw "Music extraction failed." }

$videoTags = New-Object System.Collections.Generic.List[string]
for ($i = 0; $i -lt $shots.Count; $i++) {
  $shot = $shots[$i]
  $id = if ($shot.id) { [string]$shot.id } else { "shot-{0:D2}" -f ($i + 1) }
  $shotFile = "shot-{0:D2}.mp4" -f ($i + 1)
  $shotOut = Join-Path $OutDir ("media\" + $shotFile)
  $srcStart = [double]$shot.sourceStart
  $shotDuration = [double]$shot.duration
  $timelineStart = [double]$shot.timelineStart

  $vf = "scale=${width}:${height}:force_original_aspect_ratio=increase,crop=${width}:${height},format=yuv420p,fps=$fps"
  ffmpeg -hide_banner -y -ss $srcStart -t ($shotDuration + 0.05) -i $shot.source -an `
    -vf $vf -c:v libx264 -preset veryfast -crf 19 -g $fps -keyint_min $fps -sc_threshold 0 -movflags +faststart $shotOut
  if ($LASTEXITCODE -ne 0) { throw "Shot extraction failed: $id" }

  $videoTags.Add("      <video id=""$id"" class=""clip video-shot"" data-start=""$timelineStart"" data-duration=""$shotDuration"" data-track-index=""0"" src=""./media/$shotFile"" muted playsinline preload=""auto""></video>")
}

$dialogueTags = New-Object System.Collections.Generic.List[string]
for ($i = 0; $i -lt $dialogue.Count; $i++) {
  $line = $dialogue[$i]
  $id = if ($line.id) { [string]$line.id } else { "dialogue-{0:D2}" -f ($i + 1) }
  $dialogueFile = "dialogue-{0:D2}.m4a" -f ($i + 1)
  $dialogueOut = Join-Path $OutDir ("media\" + $dialogueFile)
  $srcStart = [double]$line.sourceStart
  $lineDuration = [double]$line.duration
  $timelineStart = [double]$line.timelineStart
  $lineVolume = if ($line.volume -ne $null) { [double]$line.volume } else { 1.0 }
  $fadeIn = if ($line.fadeIn -ne $null) { [double]$line.fadeIn } else { 0.05 }
  $fadeOut = if ($line.fadeOut -ne $null) { [double]$line.fadeOut } else { 0.12 }
  $fadeOutStart = [Math]::Max(0, $lineDuration - $fadeOut)

  ffmpeg -hide_banner -y -ss $srcStart -t $lineDuration -i $line.source -vn `
    -af "volume=${lineVolume},afade=t=in:st=0:d=${fadeIn},afade=t=out:st=${fadeOutStart}:d=${fadeOut}" `
    -c:a aac -b:a 192k $dialogueOut
  if ($LASTEXITCODE -ne 0) { throw "Dialogue extraction failed: $id" }

  $track = 6 + $i
  $dialogueTags.Add("      <audio id=""$id"" class=""clip"" data-start=""$timelineStart"" data-duration=""$lineDuration"" data-track-index=""$track"" data-volume=""1"" src=""./media/$dialogueFile"" preload=""auto""></audio>")
}

$captionTags = New-Object System.Collections.Generic.List[string]
$captionSource = if ($captions.Count -gt 0) { $captions } else { $dialogue | Where-Object { $_.subtitle } }
for ($i = 0; $i -lt @($captionSource).Count; $i++) {
  $cue = @($captionSource)[$i]
  $id = if ($cue.id) { [string]$cue.id } else { "caption-{0:D2}" -f ($i + 1) }
  $cueStart = if ($cue.timelineStart -ne $null) { [double]$cue.timelineStart } else { [double]$cue.start }
  $cueDuration = [double]$cue.duration
  $text = if ($cue.text) { [string]$cue.text } else { [string]$cue.subtitle }
  $captionTags.Add("      <div id=""$id"" class=""clip subtitle-cue"" data-start=""$cueStart"" data-duration=""$cueDuration"" data-track-index=""3"">$(Escape-Html $text)</div>")
}

$templatePath = Join-Path $PSScriptRoot "..\templates\hyperframes\cinematic-character.template.html"
$template = Get-Content -LiteralPath $templatePath -Raw
$titleSize = [Math]::Round($width * 0.035)
$kickerSize = [Math]::Round($width * 0.012)
$subtitleSize = [Math]::Round($width * 0.019)
$titleOut = [Math]::Min(4.8, [Math]::Max(1.8, $duration * 0.12))

$html = $template `
  -replace "{{WIDTH}}", [string]$width `
  -replace "{{HEIGHT}}", [string]$height `
  -replace "{{DURATION}}", [string]$duration `
  -replace "{{VIDEO_CLIPS}}", ($videoTags -join "`n") `
  -replace "{{DIALOGUE_AUDIO}}", ($dialogueTags -join "`n") `
  -replace "{{CAPTIONS}}", ($captionTags -join "`n") `
  -replace "{{MUSIC_VOLUME}}", "1" `
  -replace "{{KICKER}}", (Escape-Html $project.kicker) `
  -replace "{{TITLE}}", (Escape-Html $project.title) `
  -replace "{{TITLE_OUT}}", [string]$titleOut `
  -replace "{{TITLE_SIZE}}", [string]$titleSize `
  -replace "{{KICKER_SIZE}}", [string]$kickerSize `
  -replace "{{SUBTITLE_SIZE}}", [string]$subtitleSize

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
Write-Host "Created cinematic character edit project: $OutDir"
