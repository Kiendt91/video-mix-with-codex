param(
  [Parameter(Mandatory = $true)]
  [string]$FinalMp4,

  [string]$OutDir,

  [switch]$CreateBalanced,

  [string]$BalancedOutput,

  [string]$Limiter = "alimiter=limit=0.92,volume=0.95"
)

$ErrorActionPreference = "Stop"

if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) {
  throw "ffmpeg was not found on PATH."
}
if (-not (Get-Command ffprobe -ErrorAction SilentlyContinue)) {
  throw "ffprobe was not found on PATH."
}

$mp4 = Resolve-Path -LiteralPath $FinalMp4
if (-not $OutDir) {
  $OutDir = Join-Path (Split-Path -Parent $mp4) "audio-qa"
}
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

$probeOut = Join-Path $OutDir "ffprobe-audio.json"
ffprobe -hide_banner -v error -show_entries format=duration,size:stream=codec_type,codec_name,channels,sample_rate,duration -of json $mp4 |
  Set-Content -LiteralPath $probeOut -Encoding utf8

$volumeOut = Join-Path $OutDir "volumedetect.txt"
$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = "Continue"
try {
  $volumeLog = & ffmpeg -hide_banner -i $mp4 -af volumedetect -vn -sn -dn -f null - 2>&1
  $volumeExitCode = $LASTEXITCODE
} finally {
  $ErrorActionPreference = $previousErrorActionPreference
}
$volumeLog | Set-Content -LiteralPath $volumeOut -Encoding utf8
if ($volumeExitCode -ne 0) { throw "volumedetect failed." }

$volumeText = Get-Content -LiteralPath $volumeOut -Raw
$maxVolume = [regex]::Match($volumeText, "max_volume:\s+(-?\d+(?:\.\d+)?) dB")
$meanVolume = [regex]::Match($volumeText, "mean_volume:\s+(-?\d+(?:\.\d+)?) dB")

if ($maxVolume.Success -and [double]$maxVolume.Groups[1].Value -gt -0.2) {
  Write-Warning "Audio peaks are close to 0 dB. Consider using -CreateBalanced."
}

if ($CreateBalanced) {
  if (-not $BalancedOutput) {
    $base = [IO.Path]::GetFileNameWithoutExtension($mp4)
    $BalancedOutput = Join-Path (Split-Path -Parent $mp4) ($base + "-balanced.mp4")
  }

  & ffmpeg -hide_banner -y -i $mp4 -c:v copy -af $Limiter -c:a aac -b:a 192k $BalancedOutput
  if ($LASTEXITCODE -ne 0) { throw "Balanced audio export failed." }
  Write-Host "Balanced MP4 written to: $BalancedOutput"
}

[pscustomobject]@{
  FinalMp4 = $mp4.Path
  Probe = $probeOut
  VolumeReport = $volumeOut
  MeanVolumeDb = if ($meanVolume.Success) { [double]$meanVolume.Groups[1].Value } else { $null }
  MaxVolumeDb = if ($maxVolume.Success) { [double]$maxVolume.Groups[1].Value } else { $null }
} | Format-List
