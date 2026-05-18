param(
  [Parameter(Mandatory = $true)]
  [string]$ProjectDir,

  [string]$FinalMp4,

  [string]$Times = "0.5,3.1,6.1,9.1,12.1,15.1,18.1,21.1,24.1"
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

$qaDir = Join-Path $project "qa"
New-Item -ItemType Directory -Force -Path $qaDir | Out-Null

ffprobe -hide_banner -v error -show_entries format=duration:stream=codec_type,width,height,r_frame_rate -of default=nw=1 $FinalMp4 |
  Set-Content -LiteralPath (Join-Path $qaDir "ffprobe.txt") -Encoding utf8

ffmpeg -hide_banner -i $FinalMp4 -vf "blackdetect=d=0.08:pix_th=0.08" -an -f null - 2>&1 |
  Set-Content -LiteralPath (Join-Path $qaDir "blackdetect.txt") -Encoding utf8

$timeList = $Times.Split(",") | ForEach-Object { $_.Trim() } | Where-Object { $_ }
for ($i = 0; $i -lt $timeList.Count; $i++) {
  $label = $timeList[$i].Replace(".", "_")
  $out = Join-Path $qaDir ("frame-{0:D2}-at-{1}s.png" -f $i, $label)
  ffmpeg -hide_banner -y -ss $timeList[$i] -i $FinalMp4 -frames:v 1 -update 1 $out
}

Write-Host "QA written to: $qaDir"

