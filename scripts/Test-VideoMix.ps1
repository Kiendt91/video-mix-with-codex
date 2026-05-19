param(
  [Parameter(Mandatory = $true)]
  [string]$ProjectDir,

  [string]$FinalMp4,

  [string]$Times = "0.5,3.1,6.1,9.1,12.1,15.1,18.1,21.1,24.1",

  [string]$Edl,

  [string]$OutDir,

  [switch]$CreateContactSheet,

  [int]$ContactSheetColumns = 4,

  [int]$ThumbWidth = 320,

  [double]$BlackDetectDuration = 0.08,

  [double]$BlackPixelThreshold = 0.08,

  [double]$ExpectedDuration,

  [double]$DurationTolerance = 0.08,

  [switch]$FailOnBlackFrames,

  [switch]$FailOnDurationMismatch
)

$ErrorActionPreference = "Stop"

if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) {
  throw "ffmpeg was not found on PATH."
}
if (-not (Get-Command ffprobe -ErrorAction SilentlyContinue)) {
  throw "ffprobe was not found on PATH."
}

$project = Resolve-Path -LiteralPath $ProjectDir
if (-not $FinalMp4) {
  $latest = Get-ChildItem -LiteralPath (Join-Path $project "renders") -Filter "*.mp4" | Sort-Object LastWriteTime -Descending | Select-Object -First 1
  if (-not $latest) { throw "No rendered MP4 found under renders/." }
  $FinalMp4 = $latest.FullName
}
$finalPath = Resolve-Path -LiteralPath $FinalMp4

$qaDir = if ($OutDir) { $OutDir } else { Join-Path $project "qa" }
New-Item -ItemType Directory -Force -Path $qaDir | Out-Null
$framesDir = Join-Path $qaDir "frames"
New-Item -ItemType Directory -Force -Path $framesDir | Out-Null
Get-ChildItem -LiteralPath $framesDir -File -ErrorAction SilentlyContinue | Remove-Item -Force

$probeJson = Join-Path $qaDir "ffprobe.json"
ffprobe -hide_banner -v error -show_entries format=duration,size:stream=index,codec_type,codec_name,width,height,r_frame_rate,duration -of json $finalPath |
  Set-Content -LiteralPath $probeJson -Encoding utf8
$probe = Get-Content -LiteralPath $probeJson -Raw | ConvertFrom-Json

$blackOut = Join-Path $qaDir "blackdetect.txt"
$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = "Continue"
try {
  $blackLog = & ffmpeg -hide_banner -i $finalPath -vf "blackdetect=d=${BlackDetectDuration}:pix_th=${BlackPixelThreshold}" -an -f null - 2>&1
  $blackExit = $LASTEXITCODE
} finally {
  $ErrorActionPreference = $previousErrorActionPreference
}
$blackLog | Set-Content -LiteralPath $blackOut -Encoding utf8
if ($blackExit -ne 0) { throw "blackdetect failed." }
$blackHits = @($blackLog | Select-String -Pattern "black_start" -SimpleMatch)

$audioDir = Join-Path $qaDir "audio"
New-Item -ItemType Directory -Force -Path $audioDir | Out-Null
$volumeOut = Join-Path $audioDir "volumedetect.txt"
$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = "Continue"
try {
  $volumeLog = & ffmpeg -hide_banner -i $finalPath -af volumedetect -vn -sn -dn -f null - 2>&1
  $volumeExit = $LASTEXITCODE
} finally {
  $ErrorActionPreference = $previousErrorActionPreference
}
$volumeLog | Set-Content -LiteralPath $volumeOut -Encoding utf8
if ($volumeExit -ne 0) { throw "volumedetect failed." }
$volumeText = $volumeLog -join "`n"
$meanMatch = [regex]::Match($volumeText, "mean_volume:\s+(-?\d+(?:\.\d+)?) dB")
$maxMatch = [regex]::Match($volumeText, "max_volume:\s+(-?\d+(?:\.\d+)?) dB")

$timeValues = New-Object System.Collections.Generic.List[double]
$Times.Split(",") | ForEach-Object { $_.Trim() } | Where-Object { $_ } | ForEach-Object {
  $timeValues.Add([double]::Parse($_, [Globalization.CultureInfo]::InvariantCulture))
}

if ($Edl) {
  $edlConfig = Get-Content -LiteralPath (Resolve-Path -LiteralPath $Edl) -Raw | ConvertFrom-Json
  if (-not $ExpectedDuration -and $edlConfig.project.duration -ne $null) {
    $ExpectedDuration = [double]$edlConfig.project.duration
  }
  foreach ($shot in @($edlConfig.shots) | Where-Object { $null -ne $_ }) {
    $start = [double]$shot.timelineStart
    $duration = [double]$shot.duration
    if ($start -gt 0.001) { $timeValues.Add($start) }
    $mid = $start + ($duration / 2.0)
    if ($ExpectedDuration -eq 0 -or $mid -lt ($ExpectedDuration - 0.1)) {
      $timeValues.Add($mid)
    }
  }
}

if ($ExpectedDuration -gt 0) {
  $timeValues.Add([Math]::Max(0, $ExpectedDuration - 0.5))
}

$timeList = @($timeValues | Sort-Object -Unique)
for ($i = 0; $i -lt $timeList.Count; $i++) {
  $timeText = [string]::Format([Globalization.CultureInfo]::InvariantCulture, "{0:F3}", $timeList[$i])
  $label = $timeText.Replace(".", "_")
  $out = Join-Path $qaDir ("frame-{0:D2}-at-{1}s.png" -f $i, $label)
  $out = Join-Path $framesDir ("frame-{0:D2}-at-{1}s.png" -f $i, $label)
  ffmpeg -hide_banner -loglevel error -y -ss $timeText -i $finalPath -frames:v 1 -update 1 $out
  if ($LASTEXITCODE -ne 0) { throw "Frame extraction failed at ${timeText}s." }
}

$contactSheet = $null
if ($CreateContactSheet -and $timeList.Count -gt 0) {
  Add-Type -AssemblyName System.Drawing
  $frameFiles = @(Get-ChildItem -LiteralPath $framesDir -File | Where-Object { $_.Extension -match '^\.(png|jpg|jpeg)$' } | Sort-Object Name)
  if ($frameFiles.Count -gt 0) {
    $labelHeight = 28
    $first = [System.Drawing.Image]::FromFile($frameFiles[0].FullName)
    try {
      $thumbHeight = [Math]::Max(1, [int]($first.Height * ($ThumbWidth / [double]$first.Width)))
    } finally {
      $first.Dispose()
    }
    $rows = [Math]::Ceiling($frameFiles.Count / $ContactSheetColumns)
    $bitmap = New-Object System.Drawing.Bitmap ($ContactSheetColumns * $ThumbWidth), ($rows * ($thumbHeight + $labelHeight))
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $font = New-Object System.Drawing.Font("Arial", 8)
    try {
      $graphics.Clear([System.Drawing.Color]::FromArgb(18, 18, 18))
      for ($i = 0; $i -lt $frameFiles.Count; $i++) {
        $image = [System.Drawing.Image]::FromFile($frameFiles[$i].FullName)
        try {
          $x = ($i % $ContactSheetColumns) * $ThumbWidth
          $y = [Math]::Floor($i / $ContactSheetColumns) * ($thumbHeight + $labelHeight)
          $graphics.DrawImage($image, $x, $y, $ThumbWidth, $thumbHeight)
          $graphics.DrawString($frameFiles[$i].BaseName, $font, [System.Drawing.Brushes]::White, $x + 5, $y + $thumbHeight + 6)
        } finally {
          $image.Dispose()
        }
      }
      $contactSheet = Join-Path $qaDir "final-frame-contact-sheet.jpg"
      $bitmap.Save($contactSheet, [System.Drawing.Imaging.ImageFormat]::Jpeg)
    } finally {
      $font.Dispose()
      $graphics.Dispose()
      $bitmap.Dispose()
    }
  }
}

$formatDuration = [double]$probe.format.duration
$durationDelta = if ($ExpectedDuration -gt 0) { [Math]::Abs($formatDuration - $ExpectedDuration) } else { $null }
$durationOk = if ($ExpectedDuration -gt 0) { $durationDelta -le $DurationTolerance } else { $true }
$summary = [pscustomobject]@{
  finalMp4 = $finalPath.Path
  qaDir = (Resolve-Path -LiteralPath $qaDir).Path
  expectedDuration = if ($ExpectedDuration -gt 0) { $ExpectedDuration } else { $null }
  formatDuration = $formatDuration
  durationDelta = $durationDelta
  durationOk = $durationOk
  blackDetectHits = $blackHits.Count
  blackDetectOk = $blackHits.Count -eq 0
  meanVolumeDb = if ($meanMatch.Success) { [double]$meanMatch.Groups[1].Value } else { $null }
  maxVolumeDb = if ($maxMatch.Success) { [double]$maxMatch.Groups[1].Value } else { $null }
  extractedFrames = $timeList.Count
  contactSheet = $contactSheet
  probe = $probeJson
  blackdetect = $blackOut
  volumeReport = $volumeOut
}
$summaryPath = Join-Path $qaDir "qa-summary.json"
$summary | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $summaryPath -Encoding utf8

if ($FailOnBlackFrames -and $blackHits.Count -gt 0) {
  throw "Blackdetect found $($blackHits.Count) hit(s). See $blackOut"
}
if ($FailOnDurationMismatch -and -not $durationOk) {
  throw "Duration mismatch: expected $ExpectedDuration, got $formatDuration. See $summaryPath"
}

$summary | Format-List
Write-Host "QA written to: $qaDir"
