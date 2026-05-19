param(
  [Parameter(Mandatory = $true)]
  [string]$Edl,

  [Parameter(Mandatory = $true)]
  [string]$OutDir,

  [int]$ThumbWidth = 480,

  [double]$DarkThreshold = 0.08,

  [double]$BrightThreshold = 0.92,

  [switch]$UseOcr
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

function Get-FrameStats([string]$Path) {
  $image = [System.Drawing.Bitmap]::FromFile($Path)
  try {
    $sampleStepX = [Math]::Max(1, [int]($image.Width / 80))
    $sampleStepY = [Math]::Max(1, [int]($image.Height / 45))
    $sum = 0.0
    $count = 0
    $bottomSum = 0.0
    $bottomCount = 0
    $bottomStart = [int]($image.Height * 0.76)
    for ($y = 0; $y -lt $image.Height; $y += $sampleStepY) {
      for ($x = 0; $x -lt $image.Width; $x += $sampleStepX) {
        $pixel = $image.GetPixel($x, $y)
        $luma = ((0.2126 * $pixel.R) + (0.7152 * $pixel.G) + (0.0722 * $pixel.B)) / 255.0
        $sum += $luma
        $count++
        if ($y -ge $bottomStart) {
          $bottomSum += $luma
          $bottomCount++
        }
      }
    }
    [pscustomobject]@{
      averageLuma = if ($count -gt 0) { [Math]::Round($sum / $count, 4) } else { $null }
      bottomLuma = if ($bottomCount -gt 0) { [Math]::Round($bottomSum / $bottomCount, 4) } else { $null }
    }
  } finally {
    $image.Dispose()
  }
}

function Invoke-OptionalOcr([string]$Path) {
  if (-not $UseOcr) { return $null }
  if (-not (Get-Command tesseract -ErrorAction SilentlyContinue)) { return $null }
  $tmp = [IO.Path]::ChangeExtension([IO.Path]::GetTempFileName(), $null)
  try {
    & tesseract $Path $tmp --psm 6 2>$null | Out-Null
    $txt = $tmp + ".txt"
    if (Test-Path -LiteralPath $txt) {
      return (Get-Content -LiteralPath $txt -Raw).Trim()
    }
  } finally {
    Remove-Item -LiteralPath ($tmp + ".txt") -Force -ErrorAction SilentlyContinue
  }
  return $null
}

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
  $frameStats = @()
  $ocrText = @()
  for ($j = 0; $j -lt $times.Count; $j++) {
    $frame = Join-Path $framesDir ("{0}-{1:D2}.jpg" -f $id, $j)
    ffmpeg -hide_banner -y -ss $times[$j] -i $shot.source -frames:v 1 -vf "scale=${ThumbWidth}:-1" -update 1 $frame
    if ($LASTEXITCODE -ne 0) { throw "Frame extraction failed for $id at $($times[$j])s." }
    $framePaths += $frame
    $frameStats += Get-FrameStats $frame
    $text = Invoke-OptionalOcr $frame
    if ($text) { $ocrText += $text }
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

  $risks = New-Object System.Collections.Generic.List[string]
  $lumas = @($frameStats | ForEach-Object { $_.averageLuma })
  if (@($lumas | Where-Object { $_ -ne $null -and $_ -le $DarkThreshold }).Count -gt 0) {
    $risks.Add("dark-or-black-frame")
  }
  if (@($lumas | Where-Object { $_ -ne $null -and $_ -ge $BrightThreshold }).Count -gt 0) {
    $risks.Add("bright-or-title-card-like-frame")
  }
  $riskText = (([string]$shot.visualRisk) + " " + ($ocrText -join " ")).ToLowerInvariant()
  if ($riskText -match "subtitle|caption|credit|title|episode|ep\s*\d|subscribe|lico|logo|ending|outro") {
    $risks.Add("text-or-card-risk")
  }

  $manifest.Add([pscustomobject]@{
    id = $id
    source = [string]$shot.source
    sourceStart = $sourceStart
    duration = $duration
    storyBeat = [string]$shot.storyBeat
    visualRisk = [string]$shot.visualRisk
    riskFlags = @($risks | Sort-Object -Unique)
    frameStats = $frameStats
    ocrText = if ($ocrText.Count -gt 0) { $ocrText -join "`n---`n" } else { $null }
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
