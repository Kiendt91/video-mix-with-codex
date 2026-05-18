param(
  [Parameter(Mandatory = $true)]
  [string]$Edl,

  [Parameter(Mandatory = $true)]
  [string]$OutDir,

  [int]$ThumbWidth = 480
)

$ErrorActionPreference = "Stop"

if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) {
  throw "ffmpeg was not found on PATH."
}

$edlPath = Resolve-Path -LiteralPath $Edl
$config = Get-Content -LiteralPath $edlPath -Raw | ConvertFrom-Json
$shots = @($config.shots) | Where-Object { $null -ne $_ }
if ($shots.Count -eq 0) { throw "EDL has no shots." }

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$framesDir = Join-Path $OutDir "frames"
New-Item -ItemType Directory -Force -Path $framesDir | Out-Null

Add-Type -AssemblyName System.Drawing
$rows = New-Object System.Collections.Generic.List[string]
$manifest = New-Object System.Collections.Generic.List[object]

for ($i = 0; $i -lt $shots.Count; $i++) {
  $shot = $shots[$i]
  $id = if ($shot.id) { [string]$shot.id } else { "shot-{0:D2}" -f ($i + 1) }
  $duration = [double]$shot.duration
  $sourceStart = [double]$shot.sourceStart
  $times = @(
    $sourceStart,
    ($sourceStart + ($duration / 2.0)),
    ($sourceStart + [Math]::Max(0, $duration - 0.12))
  )

  $framePaths = @()
  for ($j = 0; $j -lt $times.Count; $j++) {
    $frame = Join-Path $framesDir ("{0}-{1:D2}.jpg" -f $id, $j)
    ffmpeg -hide_banner -y -ss $times[$j] -i $shot.source -frames:v 1 -vf "scale=${ThumbWidth}:-1" -update 1 $frame
    if ($LASTEXITCODE -ne 0) { throw "Frame extraction failed for $id at $($times[$j])s." }
    $framePaths += $frame
  }

  $images = @($framePaths | ForEach-Object { [System.Drawing.Image]::FromFile($_) })
  try {
    $thumbHeight = $images[0].Height
    $rowBitmap = New-Object System.Drawing.Bitmap ($ThumbWidth * 3), $thumbHeight
    $graphics = [System.Drawing.Graphics]::FromImage($rowBitmap)
    try {
      $graphics.Clear([System.Drawing.Color]::Black)
      for ($j = 0; $j -lt $images.Count; $j++) {
        $graphics.DrawImage($images[$j], ($j * $ThumbWidth), 0, $ThumbWidth, $thumbHeight)
      }
      $rowPath = Join-Path $OutDir ("{0}.jpg" -f $id)
      $rowBitmap.Save($rowPath, [System.Drawing.Imaging.ImageFormat]::Jpeg)
      $rows.Add($rowPath)
    } finally {
      $graphics.Dispose()
      $rowBitmap.Dispose()
    }
  } finally {
    foreach ($image in $images) { $image.Dispose() }
  }

  $manifest.Add([pscustomobject]@{
    id = $id
    source = [string]$shot.source
    sourceStart = $sourceStart
    duration = $duration
    storyBeat = [string]$shot.storyBeat
    visualRisk = [string]$shot.visualRisk
  })
}

$rowImages = @($rows | ForEach-Object { [System.Drawing.Image]::FromFile($_) })
try {
  $sheetWidth = $ThumbWidth * 3
  $rowHeight = $rowImages[0].Height
  $sheet = New-Object System.Drawing.Bitmap $sheetWidth, ($rowHeight * $rowImages.Count)
  $graphics = [System.Drawing.Graphics]::FromImage($sheet)
  try {
    $graphics.Clear([System.Drawing.Color]::Black)
    for ($i = 0; $i -lt $rowImages.Count; $i++) {
      $graphics.DrawImage($rowImages[$i], 0, ($i * $rowHeight), $sheetWidth, $rowHeight)
    }
    $sheetPath = Join-Path $OutDir "candidate-audit-sheet.jpg"
    $sheet.Save($sheetPath, [System.Drawing.Imaging.ImageFormat]::Jpeg)
  } finally {
    $graphics.Dispose()
    $sheet.Dispose()
  }
} finally {
  foreach ($image in $rowImages) { $image.Dispose() }
}

$manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $OutDir "candidate-audit.json") -Encoding utf8
Write-Host "Candidate audit written to: $OutDir"
