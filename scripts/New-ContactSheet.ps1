param(
  [Parameter(Mandatory = $true)]
  [string]$Path,

  [Parameter(Mandatory = $true)]
  [string]$OutDir,

  [double]$IntervalSec = 8,

  [int]$Columns = 5,

  [int]$Rows = 4,

  [int]$ThumbWidth = 320
)

$ErrorActionPreference = "Stop"

if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) {
  throw "ffmpeg was not found on PATH."
}

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

if (Test-Path -LiteralPath $Path -PathType Container) {
  $items = Get-ChildItem -LiteralPath $Path -File | Where-Object {
    $_.Extension -match '^\.(mp4|mov|mkv|webm|avi)$'
  }
} else {
  $items = @(Get-Item -LiteralPath $Path)
}

foreach ($item in $items) {
  $safeName = [IO.Path]::GetFileNameWithoutExtension($item.Name)
  $out = Join-Path $OutDir ($safeName + ".jpg")
  $vf = "fps=1/$IntervalSec,scale=${ThumbWidth}:-1,tile=${Columns}x${Rows}:margin=6:padding=6:color=black"
  ffmpeg -hide_banner -y -i $item.FullName -vf $vf -frames:v 1 -update 1 $out
  if ($LASTEXITCODE -ne 0) { throw "Contact sheet failed: $($item.FullName)" }
  Write-Host "Wrote contact sheet: $out"
}
