param(
  [Parameter(Mandatory = $true)]
  [string]$Edl,

  [switch]$ProbeSources,

  [switch]$Json,

  [switch]$FailOnWarnings
)

$ErrorActionPreference = "Stop"

function Add-Finding($Findings, [string]$Level, [string]$Code, [string]$Message, [string]$Target = "") {
  $Findings.Add([pscustomobject]@{
    level = $Level
    code = $Code
    target = $Target
    message = $Message
  }) | Out-Null
}

function Get-Number($Value, [double]$Default = 0) {
  if ($null -eq $Value) { return $Default }
  $number = 0.0
  if ([double]::TryParse([string]$Value, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$number)) {
    return $number
  }
  return $Default
}

function Get-EffectStart($Effect) {
  if ($Effect.timelineStart -ne $null) { return Get-Number $Effect.timelineStart }
  return Get-Number $Effect.start
}

function Test-Mojibake([string]$Text) {
  if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
  return $Text -match "[ÃÂ�]"
}

function Get-SourceInfo([string]$Path) {
  if (-not (Get-Command ffprobe -ErrorAction SilentlyContinue)) { return $null }
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }

  $probeText = & ffprobe -hide_banner -v error -select_streams v:0 -show_entries stream=width,height -of json $Path 2>$null
  if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($probeText)) { return $null }
  try {
    $probe = $probeText | ConvertFrom-Json
    $stream = @($probe.streams)[0]
    if ($stream) {
      return [pscustomobject]@{
        width = [int]$stream.width
        height = [int]$stream.height
      }
    }
  } catch {
    return $null
  }
  return $null
}

$supportedEffects = @(
  "flash-through-white",
  "impact-pulse",
  "cinematic-zoom",
  "whip-zoom",
  "frame-border",
  "chromatic-radial-split",
  "vignette-swell",
  "beat-freeze",
  "anamorphic-flare",
  "hud-scan",
  "shake-hit",
  "letterbox-pulse",
  "negative-space-reset",
  "subtitle-slam",
  "hold-bloom"
)

$impactEffects = @(
  "flash-through-white",
  "chromatic-radial-split",
  "whip-zoom",
  "shake-hit",
  "negative-space-reset"
)

$edlPath = Resolve-Path -LiteralPath $Edl
$config = Get-Content -LiteralPath $edlPath -Raw | ConvertFrom-Json
$findings = New-Object System.Collections.Generic.List[object]

if (-not $config.project) {
  Add-Finding $findings "error" "project-missing" "EDL is missing project metadata."
}

$project = $config.project
$duration = Get-Number $project.duration
$width = Get-Number $project.width
$height = Get-Number $project.height
$styleMode = if ($config.style -and $config.style.mode) { [string]$config.style.mode } else { "" }
$shots = @(@($config.shots) | Where-Object { $null -ne $_ })
$effects = @(@($config.effects) | Where-Object { $null -ne $_ })
$captions = @(@($config.captions) | Where-Object { $null -ne $_ })
$sections = @(@($config.sections) | Where-Object { $null -ne $_ })

if ([string]::IsNullOrWhiteSpace($styleMode)) {
  Add-Finding $findings "warning" "style-mode-missing" "style.mode is missing. Use a concrete mode such as anime_game_lyric, cinematic_character, captioned_explainer, or space_battle_trailer."
}

if ($duration -le 0) {
  Add-Finding $findings "error" "duration-invalid" "project.duration must be greater than zero."
}

if ($shots.Count -eq 0) {
  Add-Finding $findings "error" "shots-missing" "EDL has no shots."
}

foreach ($section in $sections) {
  foreach ($field in @("label", "intent")) {
    if (Test-Mojibake ([string]$section.$field)) {
      Add-Finding $findings "warning" "mojibake" "Section $field appears to contain mojibake: $($section.$field)" "sections"
    }
  }
}

$shotDurations = New-Object System.Collections.Generic.List[double]
$shotBoundaries = New-Object System.Collections.Generic.List[double]
$shotIds = @{}
$captionIds = @{}
$sourceProbeCache = @{}

for ($i = 0; $i -lt $shots.Count; $i++) {
  $shot = $shots[$i]
  $id = if ($shot.id) { [string]$shot.id } else { "shot-$($i + 1)" }
  $shotIds[$id] = $true
  $start = Get-Number $shot.timelineStart
  $shotDuration = Get-Number $shot.duration
  $shotDurations.Add($shotDuration) | Out-Null
  $shotBoundaries.Add($start) | Out-Null

  if ([string]::IsNullOrWhiteSpace([string]$shot.storyBeat)) {
    Add-Finding $findings "warning" "storybeat-missing" "Shot has no storyBeat, so review cannot tell why it belongs here." $id
  }
  if ([string]::IsNullOrWhiteSpace([string]$shot.visualRisk)) {
    Add-Finding $findings "warning" "visual-risk-missing" "Shot has no visualRisk note for QA review." $id
  }
  if (Test-Mojibake ([string]$shot.storyBeat)) {
    Add-Finding $findings "warning" "mojibake" "Shot storyBeat appears to contain mojibake." $id
  }
  if ($shotDuration -lt 0.45) {
    Add-Finding $findings "warning" "shot-too-short" "Shot duration is under 0.45s; this often reads as accidental unless it is a deliberate micro-cut." $id
  }
  if ($shotDuration -gt 4.5 -and $effects.Count -gt 0) {
    $hasHoldTreatment = $false
    foreach ($effect in $effects) {
      $effectStart = Get-EffectStart $effect
      $effectType = [string]$effect.type
      if ($effectStart -ge $start -and $effectStart -le ($start + $shotDuration) -and @("cinematic-zoom", "hold-bloom", "vignette-swell") -contains $effectType) {
        $hasHoldTreatment = $true
      }
    }
    if (-not $hasHoldTreatment) {
      Add-Finding $findings "info" "long-hold-no-treatment" "Shot is longer than 4.5s and has no hold treatment effect; verify it has internal source motion." $id
    }
  }

  if ($height -gt $width -and $ProbeSources -and -not $shot.reframe) {
    $sourcePath = [string]$shot.source
    if (-not $sourceProbeCache.ContainsKey($sourcePath)) {
      $sourceProbeCache[$sourcePath] = Get-SourceInfo $sourcePath
    }
    $sourceInfo = $sourceProbeCache[$sourcePath]
    if ($sourceInfo -and $sourceInfo.width -gt $sourceInfo.height) {
      Add-Finding $findings "warning" "vertical-crop-needs-reframe" "Landscape source is used in a vertical project without reframe data." $id
    }
  }
}

for ($i = 2; $i -lt $shots.Count; $i++) {
  $a = [string]$shots[$i - 2].source
  $b = [string]$shots[$i - 1].source
  $c = [string]$shots[$i].source
  if ($a -eq $b -and $b -eq $c) {
    Add-Finding $findings "info" "same-source-run" "Three adjacent shots come from the same source. Verify the sequence is not visually repetitive." ([string]$shots[$i].id)
  }
}

if ($shotDurations.Count -ge 8) {
  $avg = ($shotDurations | Measure-Object -Average).Average
  $variance = 0.0
  foreach ($value in $shotDurations) {
    $variance += [Math]::Pow($value - $avg, 2)
  }
  $std = [Math]::Sqrt($variance / $shotDurations.Count)
  if ($std -lt 0.22 -and $avg -gt 0.8 -and $avg -lt 3.5) {
    Add-Finding $findings "warning" "flat-shot-rhythm" "Shot durations are very uniform (avg=$([Math]::Round($avg, 2))s, std=$([Math]::Round($std, 2))s). Add stronger fast/hold contrast."
  }
}

foreach ($caption in $captions) {
  if ($caption.id) {
    $captionIds[[string]$caption.id] = $true
  }
}

foreach ($effect in $effects) {
  $type = [string]$effect.type
  $id = if ($effect.id) { [string]$effect.id } else { "effect:$type" }
  $start = Get-EffectStart $effect
  if ($supportedEffects -notcontains $type) {
    Add-Finding $findings "error" "unsupported-effect" "Unsupported effect type '$type'." $id
  }
  if ($effect.target -and [string]$effect.target -ne "global") {
    $target = [string]$effect.target
    $targetExists = $shotIds.ContainsKey($target) -or ($type -eq "subtitle-slam" -and $captionIds.ContainsKey($target))
    if (-not $targetExists) {
      Add-Finding $findings "error" "effect-target-missing" "Effect targets '$($effect.target)', but no matching shot or caption id exists." $id
    }
  }
  if (Test-Mojibake ([string]$effect.note)) {
    Add-Finding $findings "warning" "mojibake" "Effect note appears to contain mojibake." $id
  }

  if ($impactEffects -contains $type -and $shotBoundaries.Count -gt 0) {
    $nearest = ($shotBoundaries | ForEach-Object { [Math]::Abs($_ - $start) } | Measure-Object -Minimum).Minimum
    if ($nearest -gt 0.35) {
      Add-Finding $findings "info" "impact-off-cut" "Impact effect is not near a shot boundary. Verify it lands on a musical or visual hit." $id
    }
  }
}

for ($i = 2; $i -lt $effects.Count; $i++) {
  $a = [string]$effects[$i - 2].type
  $b = [string]$effects[$i - 1].type
  $c = [string]$effects[$i].type
  if ($a -eq $b -and $b -eq $c) {
    Add-Finding $findings "warning" "repeated-effect-type" "The same effect type appears three times in a row: $c." ([string]$effects[$i].id)
  }
}

$sortedEffects = @($effects | Sort-Object { Get-EffectStart $_ })
for ($i = 1; $i -lt $sortedEffects.Count; $i++) {
  $prev = $sortedEffects[$i - 1]
  $current = $sortedEffects[$i]
  if ([string]$prev.type -eq "flash-through-white" -and [string]$current.type -eq "flash-through-white") {
    $gap = (Get-EffectStart $current) - (Get-EffectStart $prev)
    if ($gap -lt 0.5) {
      Add-Finding $findings "warning" "flash-stacking" "Two flash-through-white cues are less than 0.5s apart." ([string]$current.id)
    }
  }
}

if ($duration -gt 0 -and $effects.Count -gt 0) {
  $effectRate = $effects.Count / $duration
  if ($effectRate -gt 0.85) {
    Add-Finding $findings "warning" "effect-density-high" "Effect density is high ($([Math]::Round($effectRate, 2)) effects/sec). This usually looks noisy unless it is a deliberate glitch edit."
  }

  $impactCount = @($effects | Where-Object { $impactEffects -contains [string]$_.type }).Count
  if ($effects.Count -ge 8 -and ($impactCount / [double]$effects.Count) -gt 0.55) {
    Add-Finding $findings "warning" "impact-heavy-effect-stack" "More than 55% of effects are impact/distortion effects. Add breath, light, or hold treatments."
  }
}

foreach ($caption in $captions) {
  $id = if ($caption.id) { [string]$caption.id } else { "caption" }
  $text = if ($caption.text) { [string]$caption.text } else { [string]$caption.subtitle }
  $captionDuration = Get-Number $caption.duration
  $wordCount = @($text -split "\s+" | Where-Object { $_ }).Count
  if ($wordCount -gt 12 -and $captionDuration -lt 2.2) {
    Add-Finding $findings "warning" "caption-too-dense" "Caption has $wordCount words in $captionDuration seconds; split it or extend the hold." $id
  }
  if (Test-Mojibake $text) {
    Add-Finding $findings "warning" "mojibake" "Caption appears to contain mojibake." $id
  }
}

$summary = [pscustomobject]@{
  edl = $edlPath.Path
  duration = $duration
  shots = $shots.Count
  effects = $effects.Count
  captions = $captions.Count
  findings = $findings
  errors = @($findings | Where-Object { $_.level -eq "error" }).Count
  warnings = @($findings | Where-Object { $_.level -eq "warning" }).Count
  info = @($findings | Where-Object { $_.level -eq "info" }).Count
}

if ($Json) {
  $summary | ConvertTo-Json -Depth 8
} else {
  $summary | Select-Object edl, duration, shots, effects, captions, errors, warnings, info | Format-List
  if ($findings.Count -gt 0) {
    $findings | Sort-Object level, code, target | Format-Table level, code, target, message -AutoSize -Wrap
  } else {
    Write-Host "Aesthetic QA passed with no findings."
  }
}

if ($summary.errors -gt 0) {
  throw "Aesthetic QA found $($summary.errors) error(s)."
}
if ($FailOnWarnings -and $summary.warnings -gt 0) {
  throw "Aesthetic QA found $($summary.warnings) warning(s)."
}
