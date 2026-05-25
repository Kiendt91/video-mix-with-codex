param(
  [Parameter(Mandatory = $true)]
  [string]$Edl,

  [Parameter(Mandatory = $true)]
  [string]$OutDir,

  [string]$GsapPath,

  [string]$CacheDir,

  [string]$Frei0rPath,

  [double]$ClipPreloadSec = 0.08,

  [switch]$NoCache,

  [switch]$RequireFrei0r,

  [switch]$PreserveTrackIndex,

  [switch]$Force
)

$ErrorActionPreference = "Stop"

function Escape-Html([string]$Text) {
  if ($null -eq $Text) { return "" }
  return $Text.Replace("&", "&amp;").Replace("<", "&lt;").Replace(">", "&gt;").Replace('"', "&quot;")
}

function Escape-Attribute([string]$Text) {
  if ($null -eq $Text) { return "" }
  return ($Text -replace "[^A-Za-z0-9_-]", "-").Trim("-")
}

function To-JsonLiteral($Value) {
  if ($null -eq $Value) { return "[]" }
  if ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [string])) {
    $items = New-Object System.Collections.Generic.List[object]
    foreach ($item in $Value) { $items.Add($item) }
    return (ConvertTo-Json -InputObject $items.ToArray() -Depth 20 -Compress)
  }
  return ($Value | ConvertTo-Json -Depth 20 -Compress)
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

$script:Frei0rProbeCache = @{}

function Test-Frei0rPlugin([string]$Name) {
  if ([string]::IsNullOrWhiteSpace($Name)) { return $false }
  if ($script:Frei0rProbeCache.ContainsKey($Name)) { return $script:Frei0rProbeCache[$Name] }

  $oldErrorActionPreference = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  try {
    & ffmpeg -hide_banner -loglevel error -f lavfi -i "testsrc2=s=160x90:d=0.05" -vf "frei0r=$Name" -frames:v 1 -f null - 2>&1 | Out-Null
    $ok = $LASTEXITCODE -eq 0
  } finally {
    $ErrorActionPreference = $oldErrorActionPreference
  }
  $script:Frei0rProbeCache[$Name] = $ok
  return $ok
}

function Get-EffectValue($Effect, [string]$Name, $Default) {
  if ($Effect.params -and $Effect.params.$Name -ne $null) { return $Effect.params.$Name }
  if ($Effect.$Name -ne $null) { return $Effect.$Name }
  return $Default
}

function ConvertTo-FilterNumber($Value) {
  if ($Value -is [string]) { return $Value }
  return ([double]$Value).ToString("0.########", [System.Globalization.CultureInfo]::InvariantCulture)
}

function Get-ObjectPropertyValue($Object, [string]$Name, $Default) {
  if ($null -eq $Object) { return $Default }
  if ($Object.PSObject.Properties.Name -contains $Name -and $null -ne $Object.$Name) {
    return $Object.$Name
  }
  return $Default
}

function Get-StyleMode($Config) {
  if ($Config.style -and $Config.style.mode) { return [string]$Config.style.mode }

  $projectName = "{0} {1} {2}" -f $Config.project.name, $Config.project.title, $Config.project.kicker
  if ($projectName -match "(?i)star\s*wars|space|dogfight|battle|trailer") {
    return "space_battle_trailer"
  }
  if ([int]$Config.project.height -gt [int]$Config.project.width) {
    return "anime_game_lyric"
  }
  return "default"
}

function New-LinearReframeExpression($Keyframes, [string]$PropertyName, [string]$DefaultExpression) {
  $points = @(
    @($Keyframes) |
      Where-Object {
        $null -ne $_ -and
        $_.PSObject.Properties.Name -contains "t" -and
        $_.PSObject.Properties.Name -contains $PropertyName -and
        $null -ne $_.t -and
        $null -ne $_.$PropertyName
      } |
      Sort-Object { [double]$_.t }
  )

  if ($points.Count -eq 0) { return $DefaultExpression }
  if ($points.Count -eq 1) { return ConvertTo-FilterNumber $points[0].$PropertyName }

  $lastPoint = $points[$points.Count - 1]
  $expression = ConvertTo-FilterNumber $lastPoint.$PropertyName

  for ($i = $points.Count - 2; $i -ge 0; $i--) {
    $current = $points[$i]
    $next = $points[$i + 1]
    $t0 = ConvertTo-FilterNumber $current.t
    $t1 = ConvertTo-FilterNumber $next.t
    $v0 = ConvertTo-FilterNumber $current.$PropertyName
    $v1 = ConvertTo-FilterNumber $next.$PropertyName
    $segment = if ([double]$next.t -le [double]$current.t) {
      $v0
    } else {
      "$v0+($v1-$v0)*(t-$t0)/($t1-$t0)"
    }
    $expression = "if(lt(t\,$t1)\,if(lt(t\,$t0)\,$v0\,$segment)\,$expression)"
  }

  return $expression
}

function Get-ShotReframeFilters($Shot, [int]$Width, [int]$Height) {
  $filters = New-Object System.Collections.Generic.List[string]
  $reframe = Get-ObjectPropertyValue $Shot "reframe" $null
  $mode = [string](Get-ObjectPropertyValue $reframe "mode" "center")

  if ($mode -eq "center" -or $null -eq $reframe) {
    $filters.Add("scale=${Width}:${Height}:force_original_aspect_ratio=increase")
    $filters.Add("crop=${Width}:${Height}")
    return $filters
  }

  $scaleMode = [string](Get-ObjectPropertyValue $reframe "scaleMode" "cover")
  $scaleWidth = Get-ObjectPropertyValue $reframe "scaleWidth" $null
  $scaleHeight = Get-ObjectPropertyValue $reframe "scaleHeight" $null
  if ($null -ne $scaleWidth) {
    $filters.Add(("scale={0}:-2" -f (ConvertTo-FilterNumber $scaleWidth)))
  } elseif ($null -ne $scaleHeight) {
    $filters.Add(("scale=-2:{0}" -f (ConvertTo-FilterNumber $scaleHeight)))
  } elseif ($scaleMode -eq "width") {
    $filters.Add("scale=${Width}:-2")
  } elseif ($scaleMode -eq "height") {
    $filters.Add("scale=-2:${Height}")
  } else {
    $filters.Add("scale=${Width}:${Height}:force_original_aspect_ratio=increase")
  }

  $xDefault = "(iw-${Width})/2"
  $yDefault = "(ih-${Height})/2"

  if ($mode -eq "keyframes") {
    $keyframes = Get-ObjectPropertyValue $reframe "keyframes" @()
    $xExpression = New-LinearReframeExpression $keyframes "x" $xDefault
    $yExpression = New-LinearReframeExpression $keyframes "y" $yDefault
  } elseif ($mode -eq "manual") {
    $xExpression = ConvertTo-FilterNumber (Get-ObjectPropertyValue $reframe "x" $xDefault)
    $yExpression = ConvertTo-FilterNumber (Get-ObjectPropertyValue $reframe "y" $yDefault)
  } else {
    Write-Warning "Unknown reframe mode '$mode' on shot $($Shot.id). Falling back to center crop."
    $xExpression = $xDefault
    $yExpression = $yDefault
  }

  $xExpression = "min(max($xExpression\,0)\,iw-${Width})"
  $yExpression = "min(max($yExpression\,0)\,ih-${Height})"
  $filters.Add("crop=${Width}:${Height}:x='$xExpression':y='$yExpression'")
  return $filters
}

function Get-ShotPreprocessFilters($Shot) {
  $filters = New-Object System.Collections.Generic.List[string]
  $preprocessEffects = @(@($Shot.preprocessEffects) | Where-Object { $null -ne $_ })

  foreach ($effect in $preprocessEffects) {
    $type = if ($effect -is [string]) { [string]$effect } else { [string]$effect.type }
    if ([string]::IsNullOrWhiteSpace($type)) { continue }

    switch ($type) {
      "cinematic-grade" {
        $filters.Add("curves=preset=medium_contrast")
        $filters.Add("eq=contrast=1.07:saturation=1.12:brightness=-0.018")
      }
      "cold-space-grade" {
        $filters.Add("curves=preset=linear_contrast")
        $filters.Add("colorbalance=rs=-0.035:gs=-0.012:bs=0.075")
        $filters.Add("eq=contrast=1.04:saturation=1.06:brightness=-0.012")
      }
      "rgb-shift" {
        $shift = [int](Get-EffectValue $effect "shift" 4)
        $filters.Add("rgbashift=rh=${shift}:bh=-${shift}:edge=smear")
      }
      "vignette-native" {
        $angle = [double](Get-EffectValue $effect "angle" 4.2)
        $filters.Add("vignette=angle=PI/${angle}:eval=init")
      }
      "frei0r-glow" {
        if (Test-Frei0rPlugin "glow") {
          $params = [string](Get-EffectValue $effect "filterParams" "")
          $suffix = if ([string]::IsNullOrWhiteSpace($params)) { "" } else { ":$params" }
          $filters.Add("frei0r=glow$suffix")
        } else {
          Write-Warning "Frei0r plugin 'glow' is not available. Falling back to native unsharp/eq for shot $($Shot.id)."
          $filters.Add("unsharp=5:5:0.55:3:3:0.2")
          $filters.Add("eq=contrast=1.06:saturation=1.1")
        }
      }
      "frei0r-contrast0r" {
        if (Test-Frei0rPlugin "contrast0r") {
          $params = [string](Get-EffectValue $effect "filterParams" "")
          $suffix = if ([string]::IsNullOrWhiteSpace($params)) { "" } else { ":$params" }
          $filters.Add("frei0r=contrast0r$suffix")
        } else {
          Write-Warning "Frei0r plugin 'contrast0r' is not available. Falling back to native curves for shot $($Shot.id)."
          $filters.Add("curves=preset=increase_contrast")
        }
      }
      "frei0r-saturat0r" {
        if (Test-Frei0rPlugin "saturat0r") {
          $params = [string](Get-EffectValue $effect "filterParams" "")
          $suffix = if ([string]::IsNullOrWhiteSpace($params)) { "" } else { ":$params" }
          $filters.Add("frei0r=saturat0r$suffix")
        } else {
          Write-Warning "Frei0r plugin 'saturat0r' is not available. Falling back to native eq saturation for shot $($Shot.id)."
          $filters.Add("eq=saturation=1.18")
        }
      }
      "frei0r-distort0r" {
        if (Test-Frei0rPlugin "distort0r") {
          $params = [string](Get-EffectValue $effect "filterParams" "")
          $suffix = if ([string]::IsNullOrWhiteSpace($params)) { "" } else { ":$params" }
          $filters.Add("frei0r=distort0r$suffix")
        } else {
          Write-Warning "Frei0r plugin 'distort0r' is not available. Falling back to native rgbashift for shot $($Shot.id)."
          $filters.Add("rgbashift=rh=5:bh=-5:edge=smear")
        }
      }
      default {
        Write-Warning "Unknown preprocess effect '$type' on shot $($Shot.id); ignoring."
      }
    }
  }

  return $filters
}

if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) {
  throw "ffmpeg was not found on PATH."
}

. (Join-Path $PSScriptRoot "Frei0r-Effects.ps1")
Initialize-Frei0r $Frei0rPath

$validator = Join-Path $PSScriptRoot "Validate-Edl.ps1"
if (Test-Path -LiteralPath $validator) {
  & $validator -Edl $Edl
}

$edlPath = Resolve-Path -LiteralPath $Edl
$config = Get-Content -LiteralPath $edlPath -Raw | ConvertFrom-Json
$project = $config.project
$audio = if ($config.audio) { $config.audio } elseif ($config.music) { $config.music } else { $null }
$shots = @($config.shots)
$captions = @(@($config.captions) | Where-Object { $null -ne $_ })

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
$styleMode = Get-StyleMode $config
$audioOut = Join-Path $OutDir "media\music.mp3"
$audioStart = [double]$audio.start
$audioDuration = [double]$audio.duration
$audioVolume = if ($audio.volume -ne $null) { [double]$audio.volume } else { 1.0 }
$fadeIn = if ($audio.fadeIn -ne $null) { [double]$audio.fadeIn } else { 0.2 }
$fadeOut = if ($audio.fadeOut -ne $null) { [double]$audio.fadeOut } else { 0.8 }
$fadeOutStart = [Math]::Max(0, $audioDuration - $fadeOut)
$effectCues = @(@($config.effects) | Where-Object { $null -ne $_ })

ffmpeg -hide_banner -y -ss $audioStart -t $audioDuration -i $audio.path -vn `
  -af "volume=${audioVolume},afade=t=in:st=0:d=${fadeIn},afade=t=out:st=${fadeOutStart}:d=${fadeOut}" `
  -c:a libmp3lame -b:a 192k $audioOut
if ($LASTEXITCODE -ne 0) { throw "Audio extraction failed." }

$videoTags = New-Object System.Collections.Generic.List[string]
$captionTags = New-Object System.Collections.Generic.List[string]
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
  $postroll = 0.14
  $extractStart = [Math]::Max(0, $srcStart - $preload)
  $extractDuration = $shotDuration + $preload + $postroll
  $clipStart = [Math]::Max(0, $timelineStart - $preload)
  $clipDuration = $shotDuration + $preload + $postroll
  $trackIndex = if ($PreserveTrackIndex -and $shot.trackIndex -ne $null) { [int]$shot.trackIndex } else { $i % 2 }

  $preprocessFilters = Get-ShotPreprocessFilters $shot -RequireFrei0r:$RequireFrei0r
  $filterParts = New-Object System.Collections.Generic.List[string]
  foreach ($filter in (Get-ShotReframeFilters $shot $width $height)) { $filterParts.Add($filter) }
  foreach ($filter in $preprocessFilters) { $filterParts.Add($filter) }
  $filterParts.Add("setsar=1")
  $filterParts.Add("format=yuv420p")
  $filterParts.Add("fps=$fps")
  $vf = $filterParts -join ","
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

for ($i = 0; $i -lt $captions.Count; $i++) {
  $caption = $captions[$i]
  $captionId = if ($caption.id) { Escape-Attribute ([string]$caption.id) } else { "caption-{0:D2}" -f ($i + 1) }
  if ([string]::IsNullOrWhiteSpace($captionId)) { $captionId = "caption-{0:D2}" -f ($i + 1) }
  $captionStart = if ($caption.timelineStart -ne $null) { [double]$caption.timelineStart } elseif ($caption.start -ne $null) { [double]$caption.start } else { 0.0 }
  $captionDuration = [double]$caption.duration
  $captionText = if ($caption.text) { [string]$caption.text } else { [string]$caption.subtitle }
  $tone = if ($caption.tone) { Escape-Attribute ([string]$caption.tone).ToLowerInvariant() } else { "default" }
  $position = if ($caption.position) { Escape-Attribute ([string]$caption.position).ToLowerInvariant() } else { "bottom" }
  $captionTags.Add("        <div id=""$captionId"" class=""caption-cue caption-tone-$tone caption-position-$position"" data-caption-start=""$captionStart"" data-caption-duration=""$captionDuration""><span>$(Escape-Html $captionText)</span></div>")
}

$templatePath = Join-Path $PSScriptRoot "..\templates\hyperframes\index.template.html"
$template = Get-Content -LiteralPath $templatePath -Raw
$flashColors = if ($config.style.flashColors) { @($config.style.flashColors) } else { @("#f7f0cf", "#93ffd4", "#fff0b4", "#ffd28b") }

$html = $template `
  -replace "{{WIDTH}}", [string]$width `
  -replace "{{HEIGHT}}", [string]$height `
  -replace "{{DURATION}}", [string]$duration `
  -replace "{{STYLE_MODE}}", (Escape-Html $styleMode) `
  -replace "{{VIDEO_CLIPS}}", ($videoTags -join "`n") `
  -replace "{{CAPTION_CLIPS}}", ($captionTags -join "`n") `
  -replace "{{KICKER}}", (Escape-Html $project.kicker) `
  -replace "{{TITLE}}", (Escape-Html $project.title) `
  -replace "{{CUT_TIMES}}", (To-JsonLiteral $cutTimes) `
  -replace "{{EFFECT_CUES}}", (To-JsonLiteral $effectCues) `
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
