param(
  [Parameter(Mandatory = $true)]
  [string]$InputMp4,

  [Parameter(Mandatory = $true)]
  [string]$OutputMp4,

  [switch]$HardCrop
)

$ErrorActionPreference = "Stop"

if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) {
  throw "ffmpeg was not found on PATH."
}

if ($HardCrop) {
  $filter = "scale=1080:1920:force_original_aspect_ratio=increase,crop=1080:1920,format=yuv420p"
} else {
  $filter = "[0:v]scale=1080:1920:force_original_aspect_ratio=increase,crop=1080:1920,gblur=sigma=28,eq=brightness=-0.08:saturation=0.85[bg];[0:v]scale=1080:-2[fg];[bg][fg]overlay=(W-w)/2:(H-h)/2,format=yuv420p"
}

ffmpeg -hide_banner -y -i $InputMp4 -filter_complex $filter -c:v libx264 -preset veryfast -crf 20 -c:a aac -b:a 192k -movflags +faststart $OutputMp4
if ($LASTEXITCODE -ne 0) { throw "Vertical export failed." }

Write-Host "Vertical video written to: $OutputMp4"

