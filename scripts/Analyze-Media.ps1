param(
  [Parameter(Mandatory = $true)]
  [string]$Path,

  [string]$OutJson
)

$ErrorActionPreference = "Stop"

if (-not (Get-Command ffprobe -ErrorAction SilentlyContinue)) {
  throw "ffprobe was not found on PATH."
}

$items = @()
if (Test-Path -LiteralPath $Path -PathType Container) {
  $items = Get-ChildItem -LiteralPath $Path -File | Where-Object {
    $_.Extension -match '^\.(mp4|mov|mkv|webm|avi|mp3|wav|flac|aac)$'
  }
} else {
  $items = @(Get-Item -LiteralPath $Path)
}

$results = foreach ($item in $items) {
  $json = ffprobe -hide_banner -v error -show_format -show_streams -of json $item.FullName
  $probe = $json | ConvertFrom-Json
  [pscustomobject]@{
    path = $item.FullName
    duration = [double]$probe.format.duration
    format = $probe.format.format_name
    streams = $probe.streams | ForEach-Object {
      [pscustomobject]@{
        type = $_.codec_type
        codec = $_.codec_name
        width = $_.width
        height = $_.height
        fps = $_.r_frame_rate
      }
    }
  }
}

if ($OutJson) {
  $results | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $OutJson -Encoding utf8
}

$results | Format-Table -AutoSize

